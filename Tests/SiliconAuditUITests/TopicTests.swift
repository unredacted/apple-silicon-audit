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
        return Auditor(sysctl: sysctl, data: data).audit()
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
