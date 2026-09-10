import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("Self-test (SPEC §11)")
struct SelfTestTests {
    @Test("the tagged-pointer probe samples every size class and never reports more tagged than sampled")
    func probeCounts() {
        let r = TaggedPointerProbe.run(rounds: 3)
        #expect(r.samples == TaggedPointerProbe.sizes.count * 3)
        #expect(r.tagged <= r.samples)
        #expect(r.distinctTags >= 1 && r.distinctTags <= 16)
        // Either nothing is tagged (the test runner is not entitled) or tags vary; never one nonzero tag everywhere.
        #expect(r.tagged == 0 || r.distinctTags > 1)
    }

    @Test("a tagged process on tagging hardware is present; no tags is not_present; no hardware is not_applicable")
    func factStates() {
        let tagged = SelfTestResult(probe: .init(samples: 65, tagged: 55, distinctTags: 16), entitlement: .declared)
        let untagged = SelfTestResult(probe: .init(samples: 65, tagged: 0, distinctTags: 1), entitlement: .notDeclared)
        #expect(Auditor.taggedPointerFact(tagged, mteStates: [.present, .present]).state == .present)
        #expect(Auditor.taggedPointerFact(untagged, mteStates: [.present, .present]).state == .notPresent)
        #expect(Auditor.taggedPointerFact(untagged, mteStates: [.notPresent, .notPresent]).state == .notApplicable)
        #expect(Auditor.taggedPointerFact(untagged, mteStates: [.keyAbsent, .keyAbsent]).state == .notApplicable)
        // MTE4 absent but base MTE present: hardware exists, so the answer is a real no, not "not applicable".
        #expect(Auditor.taggedPointerFact(untagged, mteStates: [.keyAbsent, .present]).state == .notPresent)
        // Nothing readable about the hardware: report what was measured.
        #expect(Auditor.taggedPointerFact(tagged, mteStates: [.restricted, .restricted]).state == .present)
        #expect(Auditor.taggedPointerFact(untagged, mteStates: []).state == .notPresent)
        let f = Auditor.taggedPointerFact(untagged, mteStates: [.present])
        #expect(f.description?.contains("does not declare") == true)
        #expect(f.probe?.entitlement == "not_declared")
        #expect(f.raw == nil && f.discoveredBy == .selfTest && f.category == "enforcement" && f.securityRelevant)
    }

    @Test("self-test facts export a probe object and no raw reading, and decode back")
    func encoding() throws {
        let f = Auditor.taggedPointerFact(SelfTestResult(probe: .init(samples: 65, tagged: 55, distinctTags: 16), entitlement: .declared), mteStates: [.present])
        let data = try JSONEncoder().encode(f)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["raw"] == nil)
        let probe = try #require(json["probe"] as? [String: Any])
        #expect(probe["method"] as? String == "tagged_pointer_observation")
        #expect(probe["distinct_tags"] as? Int == 16)
        #expect(probe["entitlement"] as? String == "declared")
        #expect(json["discovered_by"] as? String == "self_test")
        let back = try JSONDecoder().decode(Fact.self, from: data)
        #expect(back.probe == f.probe && back.state == .present)
    }

    @Test("fixture audits carry no self-test; live audits can be asked not to")
    func fixtureHasNoSelfTest() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Mac17,7-25G83.txt")
        let auditor = Auditor(sysctl: try TextDumpSysctl(contentsOf: url, inventory: DataStore.shared.knownKeys))
        #expect(!auditor.runsSelfTest)
        #expect(auditor.audit().facts.contains { $0.probe != nil } == false)
        #expect(Auditor(sysctl: LiveSysctl(), selfTest: false).runsSelfTest == false)
    }

    #if os(macOS)
    @Test("the fault-test fact maps outcomes to states")
    func faultFact() {
        #expect(FaultTest.fact(for: .tagCheckKill, entitlement: .declared).state == .present)
        #expect(FaultTest.fact(for: .tagCheckKill, entitlement: .declared).probe?.childSignal == SIGKILL)
        #expect(FaultTest.fact(for: .survived(exitStatus: 0), entitlement: .notDeclared).state == .notPresent)
        #expect(FaultTest.fact(for: .survived(exitStatus: 0), entitlement: .notDeclared).probe?.childExitStatus == 0)
        #expect(FaultTest.fact(for: .inconclusive("x"), entitlement: .declared).state == .error)
        #expect(FaultTest.fact(for: .failed("x"), entitlement: .unknown).state == .error)
        #expect(FaultTest.fact(for: .survived(exitStatus: 0), entitlement: .declared).description?.contains("although") == true)
    }

    @Test("only SIGKILL after the store announcement counts as a tag-check kill")
    func faultClassification() {
        let announced = "SILICON_AUDIT_FAULT_CHILD storing\n"
        #expect(FaultTest.classify(reason: .uncaughtSignal, status: SIGKILL, output: announced) == .tagCheckKill)
        #expect(FaultTest.classify(reason: .exit, status: 0, output: announced + "SILICON_AUDIT_FAULT_CHILD survived (read back 7)\n") == .survived(exitStatus: 0))
        // A sanitizer abort, a Guard Malloc segfault, or an outside signal prove nothing.
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGTERM] {
            if case .inconclusive = FaultTest.classify(reason: .uncaughtSignal, status: sig, output: announced) {} else { Issue.record("signal \(sig) treated as evidence") }
        }
        // SIGKILL before the store was announced, or after the child already reported survival, is not a tag check either.
        if case .inconclusive = FaultTest.classify(reason: .uncaughtSignal, status: SIGKILL, output: "") {} else { Issue.record("SIGKILL without announcement treated as evidence") }
        if case .inconclusive = FaultTest.classify(reason: .exit, status: 3, output: announced) {} else { Issue.record("odd exit treated as evidence") }
    }
    #endif
}
