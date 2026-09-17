import Foundation
import Testing
@testable import SiliconAuditCore
@testable import SiliconAuditUI

/// Overview-mode verdicts against the recorded Mac17,7 dump.
@Suite("Overview topics")
struct TopicTests {
    static let data = try! DataStore.bundled()
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SiliconAuditCoreTests/Fixtures/Mac17,7-25G83.txt")

    static func report(walkRefused: Bool = false, restricted: Set<String> = [], transform: (String) -> String = { $0 }) throws -> Report {
        let text = transform(try String(contentsOf: fixtureURL, encoding: .utf8))
        let sysctl = TextDumpSysctl(text: text, inventory: data.knownKeys, options: .init(walkRefused: walkRefused, restricted: restricted))
        return Auditor(sysctl: sysctl, data: data, selfTest: true).audit() // the self-test topic needs the in-process probe; it is safe under the test host
    }

    func verdict(_ id: String, in report: Report) -> TopicVerdict {
        Topic.all.first { $0.id == id }!.verdict(in: report)
    }

    @Test("M5 Mac: measured yes for tagging, PAC, BTI, DIT; partial speculation")
    func m5Verdicts() throws {
        let r = try Self.report()
        #expect(verdict("memory_tagging", in: r).level == .yes)
        #expect(verdict("memory_tagging", in: r).provenance == .measured)
        #expect(verdict("pointer_authentication", in: r).level == .yes)
        #expect(verdict("control_flow", in: r).level == .yes)
        #expect(verdict("constant_time", in: r).level == .yes)
        let spec = verdict("speculation", in: r)
        #expect(spec.level == .partial)
        #expect(spec.sentence.contains("3 of 6"))
    }

    @Test("documented topics carry Apple's source and date")
    func documented() throws {
        let r = try Self.report()
        let mie = verdict("mie", in: r)
        #expect(mie.level == .yes)
        #expect(mie.provenance == .documented)
        #expect(mie.source?.published == "2026-01-28")
        let kernel = verdict("kernel_integrity", in: r)
        #expect(kernel.level == .partial)
        #expect(kernel.word == "5 of 6")
    }

    @Test("the tagging gauge counts unsigned values")
    func gaugeUnsigned() throws {
        let r = try Self.report()
        let g = verdict("os_memory_tagging", in: r)
        #expect(g.level == .yes, "the Mac fixture reports hundreds of thousands of tagged pages")
        #expect(g.sentence.contains("tagged pages"))
    }

    @Test("restricted gauge (iOS) reads Not readable, never No")
    func gaugeRestricted() throws {
        let r = try Self.report(walkRefused: true, restricted: ["vm.mte.tagged", "vm.mte.cell.active", "vm.mte.tag_storage.activations"])
        let g = verdict("os_memory_tagging", in: r)
        #expect(g.level == .unknown)
        #expect(g.word == "Not readable")
    }

    @Test("undecodable tagging counters are unknown rather than zero")
    func gaugeUndecodable() throws {
        var report = try Self.report()
        let i = try #require(report.facts.firstIndex { $0.id == "vm.mte.tagged" })
        report.facts[i].raw?.value = nil
        report.facts[i].raw?.valueHex = "0000"
        #expect(verdict("os_memory_tagging", in: report).level == .unknown)
    }

    @Test("legacy PAC keys fill an absent canonical key, but cannot override an explicit off flag")
    func legacyPAC() throws {
        var report = try Self.report()
        let canonical = try #require(report.facts.firstIndex { $0.id == "arm.FEAT_PAuth" })
        let alias = try #require(report.facts.firstIndex { $0.id == "armv8_gpi" })
        report.facts[canonical].state = .keyAbsent
        report.facts[alias].state = .present
        #expect(verdict("pointer_authentication", in: report).level == .yes)
        report.facts[canonical].state = .notPresent
        #expect(verdict("pointer_authentication", in: report).level == .no)
    }

    @Test("one readable mitigation cannot make a partially unreadable group a confident yes")
    func partialGroup() throws {
        var report = try Self.report()
        for i in report.facts.indices where report.facts[i].category == "speculation" {
            report.facts[i].state = report.facts[i].id == "arm.FEAT_CSV2" ? .present : .restricted
        }
        let result = verdict("speculation", in: report)
        #expect(result.level == .partial)
        #expect(result.sentence.contains("1 of 6"))
    }

    @Test("unmapped SoC: documented topics say Not documented, measured topics unaffected")
    func unknownSoC() throws {
        let r = try Self.report { $0.replacingOccurrences(of: "RELEASE_ARM64_T6050", with: "RELEASE_ARM64_T8320") }
        #expect(verdict("mie", in: r).level == .unknown)
        #expect(verdict("mie", in: r).word == "Not documented")
        #expect(verdict("kernel_integrity", in: r).word == "Not documented")
        #expect(verdict("memory_tagging", in: r).level == .yes)
    }

    @Test("a flag reported off is No with the honest sentence")
    func flagOff() throws {
        let r = try Self.report { $0.replacingOccurrences(of: "hw.optional.arm.FEAT_MTE4: 1", with: "hw.optional.arm.FEAT_MTE4: 0") }
        let v = verdict("memory_tagging", in: r)
        #expect(v.level == .no)
        #expect(v.sentence.contains("reports it off"))
    }

    @Test("every topic's facts exist in the report")
    func topicFactsResolve() throws {
        let r = try Self.report()
        for topic in Topic.all {
            for id in topic.factIDs {
                #expect(r.facts.contains { $0.id == id }, "\(topic.id) references missing fact \(id)")
            }
        }
    }
}
