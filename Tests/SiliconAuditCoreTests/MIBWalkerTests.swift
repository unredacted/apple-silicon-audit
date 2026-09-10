import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("MIB walk")
struct MIBWalkerTests {
    @Test("walks every leaf under hw.optional and stops at the subtree boundary")
    func walksSubtree() {
        let result = MIBWalker(sysctl: Trees.device()).walk()
        #expect(result.succeeded)
        #expect(result.failure == nil)
        let names = result.keys.map(\.name)
        #expect(names.contains("hw.optional.arm.FEAT_MTE4"))
        #expect(names.contains("hw.optional.breakpoint"))
        #expect(!names.contains("hw.pagesize"), "must stop before the first leaf outside the subtree")
        #expect(!names.contains("hw.ncpu"))
        #expect(names.count == 8)
    }

    @Test("restricted leaves are reported, not dropped")
    func restrictedLeaf() {
        let result = MIBWalker(sysctl: Trees.device()).walk()
        #expect(result.key(named: "hw.optional.arm.FEAT_RESTRICTED")?.outcome == .restricted)
    }

    @Test("caps comes through with its true 12-byte length")
    func capsLength() {
        let caps = MIBWalker(sysctl: Trees.device()).walk().key(named: "hw.optional.arm.caps")
        #expect(caps?.outcome.value?.length == 12)
        #expect(caps?.format?.type == .quad)
    }

    @Test("masked keys are included and flagged")
    func maskedKey() {
        let result = MIBWalker(sysctl: Trees.device(includeMasked: true)).walk()
        let masked = result.key(named: "hw.optional.old_compat")
        #expect(masked != nil)
        #expect(masked?.isMasked == true)
        #expect(result.keys.filter(\.isMasked).count == 1)
    }

    @Test("unknown root fails cleanly")
    func unknownRoot() {
        let result = MIBWalker(sysctl: Trees.device()).walk(root: "hw.nonexistent")
        #expect(!result.succeeded)
        #expect(result.keys.isEmpty)
        #expect(result.failure?.contains("unknown") == true)
    }

    @Test("empty subtree fails rather than claiming success")
    func emptySubtree() {
        let fake = FakeSysctl(entries: [.int([6, 111], "hw.pagesize", 16384)], nodes: ["hw.optional": [6, 110]])
        let result = MIBWalker(sysctl: fake).walk()
        #expect(!result.succeeded)
        #expect(result.failure?.contains("no keys") == true)
    }

    @Test("unnamed OIDs are counted and skipped")
    func unnamedOID() {
        var entries = Trees.device().entries
        entries.append(.unnamed([6, 110, 1, 7]))
        let result = MIBWalker(sysctl: FakeSysctl(entries: entries, nodes: ["hw.optional": Trees.hwOptional])).walk()
        #expect(result.succeeded)
        #expect(result.unnamedOIDCount == 1)
    }

    @Test("step limit terminates a walk that never leaves the subtree")
    func stepLimit() {
        struct Endless: SysctlReading {
            func read(_ name: String) -> ProbeOutcome { .absent }
            func oid(forName name: String) -> [Int32]? { [6, 110] }
            func nextOID(after oid: [Int32]) -> [Int32]? { [6, 110, oid.count > 2 ? oid[2] + 1 : 1] }
            func name(forOID oid: [Int32]) -> String? { "hw.optional.k\(oid[2])" }
            func format(forOID oid: [Int32]) -> OIDFormat? { .int }
            func readOID(_ oid: [Int32]) -> ProbeOutcome { .value(SysctlValue(format: .int, bytes: le(UInt32(1)))) }
        }
        let result = MIBWalker(sysctl: Endless(), limit: 50).walk()
        #expect(!result.succeeded)
        #expect(result.keys.count == 50)
        #expect(result.failure?.contains("exceeded") == true)
    }
}
