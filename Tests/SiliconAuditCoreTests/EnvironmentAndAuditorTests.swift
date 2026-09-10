import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("AuditEnvironment detection")
struct EnvironmentTests {
    @Test("reads version, build, kernel string, and translation flag through sysctl")
    func detectFromFake() {
        var entries = Trees.device().entries
        entries.append(.int([8, 1], "sysctl.proc_translated", 1))
        let env = AuditEnvironment.detect(using: FakeSysctl(entries: entries, nodes: ["hw.optional": Trees.hwOptional]))
        #expect(env.osVersion == "26.6.2")
        #expect(env.osBuild == "25G83")
        #expect(env.kernelVersion.hasSuffix("RELEASE_ARM64_T6050"))
        #expect(env.isTranslated)
        #expect(env.isMisleading)
    }

    @Test("virtual machines are detected from hv_vmm_present, VMAPPLE, or VirtualMac")
    func virtualMachine() {
        var byFlag = Trees.device().entries
        byFlag.append(.int([1, 90], "kern.hv_vmm_present", 1))
        #expect(AuditEnvironment.detect(using: FakeSysctl(entries: byFlag)).isVirtualMachine)

        var byKernel = Trees.device().entries.filter { $0.name != "kern.version" }
        byKernel.append(.string([1, 67], "kern.version", "Darwin Kernel Version 25.6.0: ...; root:xnu-12377.161.14~5/RELEASE_ARM64_VMAPPLE"))
        #expect(AuditEnvironment.detect(using: FakeSysctl(entries: byKernel)).isVirtualMachine)

        var byModel = Trees.device().entries
        byModel.append(.string([6, 5], "hw.model", "VirtualMac2,1"))
        let env = AuditEnvironment.detect(using: FakeSysctl(entries: byModel))
        #expect(env.isVirtualMachine)
        #expect(env.isMisleading)

        #expect(!AuditEnvironment.detect(using: Trees.device()).isVirtualMachine)
    }

    @Test("absent proc_translated means not translated")
    func notTranslated() {
        let env = AuditEnvironment.detect(using: Trees.device())
        #expect(!env.isTranslated)
    }

    @Test("iPad product prefix selects iPadOS only when compiled for iOS")
    func ipadDetection() {
        let p = AuditEnvironment.compiledPlatform(productName: "iPad16,3")
        #if os(iOS)
        #expect(p == .iPadOS)
        #else
        #expect(p != .iPadOS)
        #endif
    }
}

@Suite("Auditor")
struct AuditorTests {
    @Test("named reads union with the walk and expose restricted counts")
    func rawAudit() {
        let result = Auditor(sysctl: Trees.device()).rawAudit(now: Date(timeIntervalSince1970: 0))
        #expect(result.walk.succeeded)
        #expect(result.outcome(for: "hw.optional.arm.FEAT_MTE4")?.flagIsSet == true)
        #expect(result.outcome(for: "hw.optional.arm.FEAT_MTE3")?.flagIsSet == false)
        #expect(result.outcome(for: "vm.mte.tagged") == .absent, "fake has no vm.mte namespace")
        #expect(result.namedReads["hw.product"]?.value?.payload.stringValue == "Test1,1")
        #expect(result.restrictedCount == 1)
    }

    @Test("the named-key list covers every curated security key and legacy alias")
    func namedKeysCoverInventory() {
        for key in ["hw.optional.arm.FEAT_PAuth", "hw.optional.arm.FEAT_BTI", "hw.optional.arm.FEAT_SSBS",
                    "hw.optional.arm.FEAT_DIT", "hw.optional.arm.FEAT_MTE4", "hw.optional.armv8_gpi", "hw.optional.arm64"] {
            #expect(Auditor.namedKeys.contains(key), "\(key) missing from the by-name inventory")
        }
        #expect(Set(Auditor.namedKeys).count == Auditor.namedKeys.count, "no duplicates")
    }

    @Test("the named-key list never contains a forbidden identifier key")
    func noForbiddenKeys() {
        for key in Auditor.namedKeys {
            #expect(!Auditor.forbiddenKeys.contains(key), "\(key) is on the never-read list")
            #expect(!key.hasPrefix("kern.host"), "\(key)")
        }
    }
}
