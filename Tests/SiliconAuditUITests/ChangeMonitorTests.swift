import Foundation
import Testing
@testable import SiliconAuditCore
@testable import SiliconAuditUI

@Suite("Change monitor")
@MainActor
struct ChangeMonitorTests {
    static let data = try! DataStore.bundled()

    func makeReport(edit: (String) -> String = { $0 }) throws -> Report {
        let text = edit(try String(contentsOf: TopicTests.fixtureURL, encoding: .utf8))
        return Auditor(sysctl: TextDumpSysctl(text: text, inventory: Self.data.knownKeys), data: Self.data).audit()
    }

    func tempMonitor(directory: URL? = nil) -> (ChangeMonitor, URL) {
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("silicon-audit-monitor-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "silicon-audit-monitor-tests-\(UUID().uuidString)")!
        return (ChangeMonitor(directory: dir, defaults: defaults), dir)
    }

    @Test("first report becomes the baseline; an identical report records nothing")
    func baseline() throws {
        let (monitor, _) = tempMonitor()
        #expect(!monitor.hasBaseline)
        #expect(monitor.isCheckDue())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(monitor.process(try makeReport(), now: t0) == nil)
        #expect(monitor.hasBaseline)
        #expect(monitor.baselineRecordedAt == t0)
        #expect(!monitor.isCheckDue(now: t0.addingTimeInterval(60)))
        #expect(monitor.isCheckDue(now: t0.addingTimeInterval(ChangeMonitor.foregroundInterval)))
        #expect(monitor.process(try makeReport(), now: t0.addingTimeInterval(100)) == nil)
        #expect(monitor.records.isEmpty)
    }

    @Test("a changed reading is recorded, advances the baseline, and survives a reload")
    func change() throws {
        let (monitor, dir) = tempMonitor()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.process(try makeReport(), now: t0)
        let changed = try makeReport { $0.replacingOccurrences(of: "hw.optional.arm.FEAT_MTE4: 1", with: "hw.optional.arm.FEAT_MTE4: 0") }
        let diff = try #require(monitor.process(changed, now: t0.addingTimeInterval(3600)))
        #expect(diff.changes.count == 1)
        #expect(diff.changes[0].securityRelevant)
        #expect(monitor.records.count == 1)
        #expect(monitor.unseenRecords.count == 1)
        // The changed report is now the baseline: the same report again is quiet.
        #expect(monitor.process(changed, now: t0.addingTimeInterval(7200)) == nil)
        #expect(monitor.records.count == 1)

        let (reloaded, _) = tempMonitor(directory: dir)
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records[0].diff == diff)
        #expect(reloaded.baseline?.facts.first { $0.id == "arm.FEAT_MTE4" }?.state == .notPresent)
        reloaded.markAllSeen()
        #expect(reloaded.unseenRecords.isEmpty)
        let (again, _) = tempMonitor(directory: dir)
        #expect(again.unseenRecords.isEmpty)
    }

    @Test("a different device starts a new baseline without a record")
    func differentDevice() throws {
        let (monitor, _) = tempMonitor()
        monitor.process(try makeReport())
        let other = try makeReport { $0.replacingOccurrences(of: "hw.product: Mac17,7", with: "hw.product: Mac16,1") }
        #expect(monitor.process(other) == nil)
        #expect(monitor.baseline?.device.identity == "Mac16,1")
        #expect(monitor.records.isEmpty)
    }

    @Test("copy names the change in plain words and keeps the technical transition")
    func copy() throws {
        let a = try makeReport()
        let b = try makeReport {
            $0.replacingOccurrences(of: "hw.optional.arm.FEAT_MTE4: 1", with: "hw.optional.arm.FEAT_MTE4: 0")
              .replacingOccurrences(of: "kern.osversion: 25G83", with: "kern.osversion: 25G90")
        }
        let diff = ReportDiff.compare(baseline: a, current: b, inventory: Self.data.knownKeys)
        let change = try #require(diff.changes.first)
        #expect(ChangeCopy.plain(change).contains("was reported on and now reports off"))
        #expect(ChangeCopy.headline(diff) == "1 security reading changed")
        #expect(ChangeCopy.context(diff).contains("25G83"))
        #expect(ChangeCopy.meaning(change, osChanged: true).contains("updated between the two readings"))
        #expect(change.technicalTransition == "present → not_present")
    }
}
