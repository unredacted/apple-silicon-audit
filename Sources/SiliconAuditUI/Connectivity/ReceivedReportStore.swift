import Foundation
import Observation
import SiliconAuditCore

/// Reports received from a companion device (the phone's copy of what the watch measured),
/// persisted as JSON files in Application Support so a delivery while the app was not running
/// survives the next launch (SPEC §7). Foundation only; the WatchConnectivity bridge feeds it.
@MainActor
@Observable
public final class ReceivedReportStore {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let url: URL
        public let report: Report
        public let receivedAt: Date
        public var id: String { url.lastPathComponent }
        public var title: String {
            "\(report.device.identity) · \(report.environment.platform) \(report.environment.osVersion) (\(report.environment.osBuild))"
        }
    }

    public private(set) var entries: [Entry] = []
    public var status: String?
    public let directory: URL

    public static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SiliconAudit/ReceivedReports", isDirectory: true)
    }()

    public init(directory: URL = ReceivedReportStore.defaultDirectory) {
        self.directory = directory
    }

    /// File name for a report: one per device identity and OS build, newest wins.
    public nonisolated static func fileName(for report: Report) -> String {
        let build = report.environment.osBuild.isEmpty ? "nobuild" : report.environment.osBuild
        let safe = "\(report.device.identity)-\(build)".map { $0.isLetter || $0.isNumber || $0 == "," || $0 == "-" || $0 == "." ? $0 : "_" }
        return "silicon-audit-\(String(safe)).json"
    }

    /// Loads every stored report, newest first.
    public func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            entries = []
            return
        }
        entries = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let report = try? Report.decode(data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Entry(url: url, report: report, receivedAt: date)
        }
        .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Validates, decodes and stores a delivered file. Throws on any failure so callers report
    /// a failed receive rather than a phantom success.
    @discardableResult
    public func ingest(fileAt source: URL) throws -> Entry {
        let data = try Data(contentsOf: source)
        let report = try Report.decode(data)
        guard report.schemaVersion.hasPrefix("1.") else { throw IngestError.unsupportedSchema(report.schemaVersion) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(ReceivedReportStore.fileName(for: report))
        try data.write(to: destination, options: .atomic)
        reload()
        guard let entry = entries.first(where: { $0.url.lastPathComponent == destination.lastPathComponent }) else { throw IngestError.notStored }
        return entry
    }

    public func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        reload()
    }

    public enum IngestError: Error, Equatable {
        case unsupportedSchema(String)
        case notStored
    }
}
