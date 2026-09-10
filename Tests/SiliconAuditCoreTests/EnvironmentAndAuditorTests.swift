import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("Environment detection")
struct EnvironmentTests {
    @Test("reads version, build, kernel string, and translation flag through sysctl")
    func detectFromFake() {
        var entries = Trees.device().entries
        entries.append(.int([8, 1], "sysctl.proc_translated", 1))
        let env = Environment.detect(using: FakeSysctl(entries: entries, nodes: ["hw.optional": Trees.hwOptional]))
        #expect(env.osVersion == "26.6.2")
        #expect(env.osBuild == "25G83")
        #expect(env.kernelVersion.hasSuffix("RELEASE_ARM64_T6050"))
        #expect(env.isTranslated)
        #expect(env.isMisleading)
    }

    @Test("absent proc_translated means not translated")
    func notTranslated() {
        let env = Environment.detect(using: Trees.device())
        #expect(!env.isTranslated)
    }

    @Test("iPad product prefix selects iPadOS only when compiled for iOS")
    func ipadDetection() {
        let p = Environment.compiledPlatform(productName: "iPad16,3")
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

    @Test("the named-key list never contains a forbidden identifier key")
    func noForbiddenKeys() {
        for key in Auditor.namedKeys {
            #expect(!Auditor.forbiddenKeys.contains(key), "\(key) is on the never-read list")
            #expect(!key.hasPrefix("kern.host"), "\(key)")
        }
    }
}
