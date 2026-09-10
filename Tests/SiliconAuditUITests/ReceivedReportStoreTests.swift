import Foundation
import Testing
@testable import SiliconAuditCore
@testable import SiliconAuditUI

@Suite("Received report store")
@MainActor
struct ReceivedReportStoreTests {
    static let data = try! DataStore.bundled()

    func makeReport(build: String = "25G83") throws -> Report {
        let text = try String(contentsOf: TopicTests.fixtureURL, encoding: .utf8).replacingOccurrences(of: "kern.osversion: 25G83", with: "kern.osversion: \(build)")
        return Auditor(sysctl: TextDumpSysctl(text: text, inventory: Self.data.knownKeys), data: Self.data).audit()
    }

    func tempStore() -> ReceivedReportStore {
        ReceivedReportStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("silicon-audit-tests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("ingest stores by identity and build, reload finds it, newest wins")
    func ingestAndReload() throws {
        let store = tempStore()
        let report = try makeReport()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-\(UUID()).json")
        try report.jsonData().write(to: tmp)
        let entry = try store.ingest(fileAt: tmp)
        let roundTripped = try Report.decode(report.jsonData())
        #expect(entry.url.lastPathComponent == "silicon-audit-Mac17,7-25G83.json")
        #expect(entry.report == roundTripped)
        #expect(store.entries.count == 1)

        // Same identity and build again replaces rather than duplicates.
        try report.jsonData().write(to: tmp)
        try store.ingest(fileAt: tmp)
        #expect(store.entries.count == 1)

        // A different build is a second entry.
        let other = try makeReport(build: "25H1")
        try other.jsonData().write(to: tmp)
        try store.ingest(fileAt: tmp)
        #expect(store.entries.count == 2)

        let fresh = ReceivedReportStore(directory: store.directory)
        fresh.reload()
        #expect(fresh.entries.count == 2, "persisted across a relaunch")
        try? FileManager.default.removeItem(at: store.directory)
    }

    @Test("a file that is not a report is rejected and nothing is stored")
    func rejectsGarbage() throws {
        let store = tempStore()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID()).json")
        try Data("{\"hello\": 1}".utf8).write(to: tmp)
        #expect(throws: (any Error).self) { try store.ingest(fileAt: tmp) }
        #expect(store.entries.isEmpty)
    }

    @Test("file names never contain path separators or spaces")
    func safeNames() throws {
        var report = try makeReport()
        report.device.identity = "Weird/Name With Spaces"
        let name = ReceivedReportStore.fileName(for: report)
        #expect(!name.contains("/") && !name.contains(" "))
        #expect(name.hasSuffix("-25G83.json"))
    }
}
