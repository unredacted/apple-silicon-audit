import Foundation
import Testing
@testable import SiliconAuditCore

// Runs only against a real Apple silicon macOS kernel (the dev machine, or a
// macos-26 arm64 CI runner). Assertions are chosen to hold on any Apple silicon
// Mac on macOS 26; M5-specific checks are gated on hw.product.
#if os(macOS) && arch(arm64) && !targetEnvironment(simulator)
@Suite("Live kernel (Apple silicon macOS)")
struct LiveKernelTests {
    let live = LiveSysctl()

    @Test("name → OID → name round-trips and OIDFMT is served")
    func metaNodes() throws {
        let oid = try #require(live.oid(forName: "hw.optional.arm.FEAT_PAuth"))
        #expect(live.name(forOID: oid) == "hw.optional.arm.FEAT_PAuth")
        let fmt = try #require(live.format(forOID: oid))
        #expect(fmt.type == .int)
        #expect(!fmt.isMasked)
    }

    @Test("the walk finds the hw.optional subtree with the expected shape")
    func walk() throws {
        let result = MIBWalker(sysctl: live).walk()
        #expect(result.succeeded, "\(result.failure ?? "")")
        #expect(result.keys.count >= 60)
        #expect(result.keys.allSatisfy { $0.name.hasPrefix("hw.optional.") })
        #expect(result.key(named: "hw.optional.arm.FEAT_PAuth")?.outcome.flagIsSet == true, "every Apple silicon Mac has PAuth")
        #expect(result.key(named: "hw.optional.arm64")?.outcome.flagIsSet == true)
        #expect(result.key(named: "hw.optional.x86_64")?.outcome == .notApplicable, "x86 table is registered on arm64 but answers ENOTSUP")
        #expect(result.keys.filter { $0.outcome == .notApplicable }.count >= 20)
        let caps = try #require(result.key(named: "hw.optional.arm.caps"))
        #expect(caps.format?.type == .quad, "declared int64_t")
        #expect(caps.outcome.value?.length == 12, "actually 12 bytes on macOS 26")
        #expect(caps.outcome.value?.payload.bytesValue != nil)
    }

    @Test("named reads return real formats and lengths")
    func namedReads() throws {
        let product = try #require(live.read("hw.product").value)
        #expect(product.format?.type == .string)
        #expect(product.payload.stringValue?.isEmpty == false)
        #expect(product.payload.stringValue != "arm64", "hw.product is the model, unlike hw.machine on macOS")
        #expect(live.read("hw.machine").value?.payload.stringValue == "arm64")
        let memsize = try #require(live.read("hw.memsize").value)
        #expect(memsize.length == 8)
        #expect((memsize.payload.integerValue ?? 0) > 0)
        #expect(live.read("hw.optional.definitely.not.a.key") == .absent)
    }

    @Test("environment reflects this Mac")
    func environment() {
        let env = AuditEnvironment.detect(using: live)
        #expect(env.platform == .macOS)
        #expect(env.arch == .arm64 || env.arch == .arm64e)
        #expect(!env.osBuild.isEmpty)
        #expect(env.kernelVersion.contains("RELEASE_ARM64_T"))
        #expect(!env.isSimulator)
        #expect(!env.isTranslated)
    }

    @Test("M5-class facts, when this is the reviewed Mac17,7")
    func m5Specific() throws {
        guard live.read("hw.product").value?.payload.stringValue == "Mac17,7" else { return }
        let result = Auditor(sysctl: live).rawAudit()
        #expect(result.outcome(for: "hw.optional.arm.FEAT_MTE4")?.flagIsSet == true)
        #expect(result.outcome(for: "hw.optional.arm.FEAT_MTE3")?.flagIsSet == false)
        #expect(result.outcome(for: "hw.optional.arm.FEAT_MTE_ASYNC")?.flagIsSet == false)
        #expect((result.outcome(for: "vm.mte.tagged")?.value?.payload.integerValue ?? 0) > 0)
        #expect(result.environment.kernelVersion.hasSuffix("RELEASE_ARM64_T6050"))
        #expect(result.restrictedCount == 0)
    }
}
#endif
