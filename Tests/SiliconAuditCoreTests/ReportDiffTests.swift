import Foundation
import Testing
@testable import SiliconAuditCore

/// The change engine, driven by the Mac17,7 fixture with lines edited to simulate a later reading.
@Suite("Report diff")
struct ReportDiffTests {
    static let data = try! DataStore.bundled()

    static func report(edit: (String) -> String = { $0 }) throws -> Report {
        let text = edit(try String(contentsOf: ReportTests.fixtureURL, encoding: .utf8))
        return Auditor(sysctl: TextDumpSysctl(text: text, inventory: data.knownKeys), data: data).audit()
    }

    @Test("identical readings produce an empty diff, and live gauges never count")
    func identical() throws {
        let a = try Self.report()
        let b = try Self.report { $0.replacingOccurrences(of: "vm.mte.tagged: 310530", with: "vm.mte.tagged: 999") }
        let diff = ReportDiff.compare(baseline: a, current: b, inventory: Self.data.knownKeys)
        #expect(diff.isEmpty)
        #expect(!diff.osChanged)
        #expect(diff.changes.isEmpty)
    }

    @Test("a flipped flag, a changed count, a vanished key and a new build are each classified")
    func classified() throws {
        let a = try Self.report()
        let b = try Self.report {
            $0.replacingOccurrences(of: "hw.optional.arm.FEAT_MTE4: 1", with: "hw.optional.arm.FEAT_MTE4: 0")
              .replacingOccurrences(of: "hw.optional.breakpoint: 6", with: "hw.optional.breakpoint: 4")
              .replacingOccurrences(of: "hw.optional.arm.FEAT_BTI: 1\n", with: "")
              .replacingOccurrences(of: "kern.osversion: 25G83", with: "kern.osversion: 25G90")
        }
        let diff = ReportDiff.compare(baseline: a, current: b, inventory: Self.data.knownKeys)
        #expect(diff.osChanged)
        #expect(diff.osBuildBefore == "25G83" && diff.osBuildAfter == "25G90")
        #expect(!diff.identityChanged)

        let mte4 = try #require(diff.changes.first { $0.key == "hw.optional.arm.FEAT_MTE4" })
        #expect(mte4.kind == .stateChanged)
        #expect(mte4.before == .present && mte4.after == .notPresent)
        #expect(mte4.securityRelevant)

        let bti = try #require(diff.changes.first { $0.key == "hw.optional.arm.FEAT_BTI" })
        #expect(bti.kind == .stateChanged)
        #expect(bti.before == .present && bti.after == .keyAbsent)
        #expect(bti.securityRelevant)

        let bp = try #require(diff.changes.first { $0.key == "hw.optional.breakpoint" })
        #expect(bp.kind == .valueChanged)
        #expect(bp.beforeValue == "6" && bp.afterValue == "4")
        #expect(!bp.securityRelevant)
        #expect(bp.technicalTransition == "6 → 4")

        // Security-relevant changes sort first; the build keys themselves are not listed as facts.
        #expect(diff.changes.first?.securityRelevant == true)
        #expect(!diff.changes.contains { $0.key == "kern.osversion" })
        #expect(diff.securityChanges.count == 2)
        #expect(diff.summary.contains("25G83 → 25G90"))
    }

    @Test("a different device is flagged and not compared")
    func differentDevice() throws {
        let a = try Self.report()
        let b = try Self.report { $0.replacingOccurrences(of: "hw.product: Mac17,7", with: "hw.product: Mac16,1") }
        let diff = ReportDiff.compare(baseline: a, current: b, inventory: Self.data.knownKeys)
        #expect(diff.identityChanged)
        #expect(diff.changes.isEmpty)
        #expect(!diff.isEmpty)
    }

    @Test("decoded JSON reports diff the same as live ones, with security relevance from the inventory")
    func roundTrip() throws {
        let a = try Report.decode(try Self.report().jsonData())
        let b = try Report.decode(try Self.report { $0.replacingOccurrences(of: "hw.optional.arm.FEAT_DIT: 1", with: "hw.optional.arm.FEAT_DIT: 0") }.jsonData())
        let diff = ReportDiff.compare(baseline: a, current: b, inventory: Self.data.knownKeys)
        #expect(diff.changes.count == 1)
        #expect(diff.changes[0].securityRelevant, "decoded facts carry no flag; the inventory supplies it")
        let encoded = try JSONEncoder().encode(diff)
        #expect(try JSONDecoder().decode(ReportDiff.self, from: encoded) == diff)
    }
}
