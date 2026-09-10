import Foundation
import Observation
import WatchConnectivity

/// UI-facing state for the WatchConnectivity link. Main-actor isolated; the bridge
/// posts updates to it from the delegate's background queue.
@MainActor
@Observable
final class ConnectivityModel {
    var isSupported = WCSession.isSupported()
    var activationState = "not activated"
    var isReachable = false
    var isCompanionInstalled = false
    var status = "Idle"
    var outstandingTransfers = 0
    /// iOS: the most recent report received from the watch, and where it was stored.
    var receivedReport: SpikeReport?
    var receivedFileURL: URL?
    var receivedCount = 0
}

/// Owns the `WCSession` and moves spike reports watch → phone with `transferFile`
/// (queued, reliable, background). `transferUserInfo` is deliberately avoided (SPEC §7).
final class ConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let model: ConnectivityModel

    init(model: ConnectivityModel) {
        self.model = model
        super.init()
    }

    func activate() {
        restorePersistedReport()
        guard WCSession.isSupported() else {
            Task { @MainActor in model.status = "WatchConnectivity not supported on this device" }
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// iOS side: a report delivered while the app was not running (or before a relaunch)
    /// already sits in Documents. Show the newest one instead of claiming nothing arrived.
    private func restorePersistedReport() {
        let candidates = SpikeStore.savedReports().filter { $0.lastPathComponent.hasPrefix("spike-watchOS-") }
        guard let newest = candidates.max(by: { modificationDate($0) < modificationDate($1) }) else { return }
        do {
            let report = try SpikeStore.load(newest)
            Task { @MainActor in
                model.receivedFileURL = newest
                model.receivedReport = report
                model.status = "Restored \(newest.lastPathComponent) from Documents"
            }
        } catch {
            Task { @MainActor in model.status = "Stored watch report \(newest.lastPathComponent) could not be decoded: \(error.localizedDescription)" }
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Watch side: write the report to a temporary file and queue it for the phone.
    func send(_ report: SpikeReport) {
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(report.fileStem)-\(Int(Date().timeIntervalSince1970)).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: tmp, options: .atomic)
            let metadata: [String: Any] = ["kind": "spike", "stem": report.fileStem, "platform": report.platform]
            WCSession.default.transferFile(tmp, metadata: metadata)
            let pending = WCSession.default.outstandingFileTransfers.count
            Task { @MainActor in
                model.outstandingTransfers = pending
                model.status = "Queued for iPhone (\(pending) pending)"
            }
        } catch {
            Task { @MainActor in model.status = "Encode failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let stateText: String
        switch state {
        case .activated: stateText = "activated"
        case .inactive: stateText = "inactive"
        case .notActivated: stateText = "not activated"
        @unknown default: stateText = "unknown"
        }
        let reachable = session.isReachable
        #if os(iOS)
        let installed = session.isWatchAppInstalled
        #else
        let installed = session.isCompanionAppInstalled
        #endif
        let err = error?.localizedDescription
        Task { @MainActor in
            model.activationState = stateText
            model.isReachable = reachable
            model.isCompanionInstalled = installed
            if let err { model.status = "Activation error: \(err)" } else if model.status == "Idle" { model.status = "Session \(stateText)" }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in model.isReachable = reachable }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let pending = session.outstandingFileTransfers.count
        let err = error?.localizedDescription
        Task { @MainActor in
            model.outstandingTransfers = pending
            model.status = err.map { "Transfer failed: \($0)" } ?? "Delivered to iPhone (\(pending) pending)"
        }
    }

    /// iOS side. The incoming file is deleted when this returns, so copy synchronously.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let stem = (file.metadata?["stem"] as? String) ?? "watch-spike"
        let destination = SpikeStore.documents.appendingPathComponent("\(stem).json")
        // Copy and decode synchronously; a report that cannot be decoded is a failed receive,
        // not a success with a missing entry.
        let outcome: Result<SpikeReport, Error> = Result {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
            return try SpikeStore.load(destination)
        }
        Task { @MainActor in
            switch outcome {
            case .success(let report):
                model.receivedFileURL = destination
                model.receivedReport = report
                model.receivedCount += 1
                model.status = "Received \(stem).json from Apple Watch"
            case .failure(let error):
                model.status = "Receive failed for \(stem).json: \(error.localizedDescription)"
            }
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in model.activationState = "inactive" }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Required after a watch switch: reactivate to keep receiving.
        session.activate()
    }
    #endif
}
