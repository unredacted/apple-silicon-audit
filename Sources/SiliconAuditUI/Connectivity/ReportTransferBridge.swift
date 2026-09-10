// visionOS can import WatchConnectivity but pairs with nothing; only iPhone and watch take part.
#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
import Foundation
import Observation
import SiliconAuditCore
import WatchConnectivity

/// UI-facing state of the watch ↔ phone link.
@MainActor
@Observable
public final class TransferState {
    public var isSupported = WCSession.isSupported()
    public var isActivated = false
    public var isReachable = false
    public var isCompanionInstalled = false
    public var outstandingTransfers = 0
    public var status: String?

    public init() {}
}

/// Moves the full JSON `Report` from the watch to the phone with `WCSession.transferFile`
/// (queued, reliable, delivered in the background), and on the phone ingests deliveries into a
/// `ReceivedReportStore` (SPEC §7). `transferUserInfo` is deliberately not used.
public final class ReportTransferBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let state: TransferState
    private let store: ReceivedReportStore?

    /// - Parameter store: the phone passes its store; the watch passes nil.
    public init(state: TransferState, store: ReceivedReportStore?) {
        self.state = state
        self.store = store
        super.init()
    }

    public func activate() {
        Task { @MainActor in store?.reload() }
        guard WCSession.isSupported() else {
            Task { @MainActor in state.status = String(localized: "WatchConnectivity is not available on this device.", bundle: .module) }
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Watch side: write the report to a temporary file and queue it for the phone.
    public func send(_ report: Report) {
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(ReceivedReportStore.fileName(for: report).dropLast(5))-\(Int(Date().timeIntervalSince1970)).json")
            try report.jsonData().write(to: tmp, options: .atomic)
            let metadata: [String: Any] = [
                "kind": "silicon-audit-report",
                "schema_version": report.schemaVersion,
                "identity": report.device.identity,
                "os_build": report.environment.osBuild,
            ]
            WCSession.default.transferFile(tmp, metadata: metadata)
            let pending = WCSession.default.outstandingFileTransfers.count
            Task { @MainActor in
                state.outstandingTransfers = pending
                state.status = String(localized: "Queued for iPhone (\(pending) pending). Delivery continues in the background.", bundle: .module)
            }
        } catch {
            Task { @MainActor in state.status = String(localized: "Could not prepare the report: \(error.localizedDescription)", bundle: .module) }
        }
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let activated = activationState == .activated
        let reachable = session.isReachable
        #if os(iOS)
        let installed = session.isWatchAppInstalled
        #else
        let installed = session.isCompanionAppInstalled
        #endif
        let message = error?.localizedDescription
        Task { @MainActor in
            state.isActivated = activated
            state.isReachable = reachable
            state.isCompanionInstalled = installed
            if let message { state.status = String(localized: "Activation failed: \(message)", bundle: .module) }
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in state.isReachable = reachable }
    }

    public func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let pending = session.outstandingFileTransfers.count
        let message = error?.localizedDescription
        Task { @MainActor in
            state.outstandingTransfers = pending
            state.status = message.map { String(localized: "Transfer failed: \($0)", bundle: .module) }
                ?? String(localized: "Delivered to iPhone.", bundle: .module)
        }
    }

    /// Phone side. The incoming file is deleted when this returns, so read it synchronously.
    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let store else { return }
        // Copy to a stable temporary location first; ingestion happens on the main actor.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-\(UUID().uuidString).json")
        let staging: Result<Void, Error> = Result { try FileManager.default.copyItem(at: file.fileURL, to: staged) }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: staged) }
            switch staging {
            case .failure(let error):
                state.status = String(localized: "Receive failed: \(error.localizedDescription)", bundle: .module)
            case .success:
                do {
                    let entry = try store.ingest(fileAt: staged)
                    state.status = String(localized: "Received \(entry.report.device.identity) from Apple Watch.", bundle: .module)
                } catch {
                    state.status = String(localized: "Received a file that is not a valid report: \(error.localizedDescription)", bundle: .module)
                }
            }
        }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in state.isActivated = false }
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        // Required after a watch switch: reactivate to keep receiving.
        session.activate()
    }
    #endif
}
#endif
