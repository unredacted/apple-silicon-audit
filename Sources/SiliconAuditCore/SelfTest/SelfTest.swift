import Foundation
#if canImport(Security)
import Security
#endif

/// Details of a measurement made inside this process rather than read from the kernel (SPEC §11).
/// Exported under `probe` on the fact; `Schema/export-v1.schema.json` lists every field.
public struct ProbeDetails: Codable, Equatable, Sendable {
    public var method: String
    public var samples: Int?
    public var tagged: Int?
    public var distinctTags: Int?
    /// `declared`, `not_declared`, or `unknown`: whether this process carries the Enhanced Security
    /// checked-allocations entitlement, as far as it can tell (SecTask on macOS, an Info.plist
    /// marker set by the hardened build configurations elsewhere).
    public var entitlement: String
    /// Fault test only: the signal that terminated the child, or the exit status when it survived.
    public var childSignal: Int32?
    public var childExitStatus: Int32?

    enum CodingKeys: String, CodingKey {
        case method, samples, tagged, entitlement
        case distinctTags = "distinct_tags"
        case childSignal = "child_signal"
        case childExitStatus = "child_exit_status"
    }

    public init(method: String, samples: Int? = nil, tagged: Int? = nil, distinctTags: Int? = nil,
                entitlement: String, childSignal: Int32? = nil, childExitStatus: Int32? = nil) {
        self.method = method
        self.samples = samples
        self.tagged = tagged
        self.distinctTags = distinctTags
        self.entitlement = entitlement
        self.childSignal = childSignal
        self.childExitStatus = childExitStatus
    }
}

/// Apple's Enhanced Security entitlements (SPEC §11). Adopted by the app's hardened build
/// configurations and by `Scripts/sign-hardened.sh` for the CLI.
public enum EnhancedSecurity {
    public static let processEntitlement = "com.apple.security.hardened-process"
    public static let versionEntitlement = "com.apple.security.hardened-process.enhanced-security-version-string"
    public static let checkedAllocationsEntitlement = "com.apple.security.hardened-process.checked-allocations"
    /// Info.plist key the build configurations set (`YES` in the hardened ones), for platforms
    /// where a process cannot read its own entitlements.
    public static let infoPlistMarker = "SiliconAuditEnhancedSecurity"

    public enum Declaration: String, Sendable, Equatable {
        case declared
        case notDeclared = "not_declared"
        case unknown
    }

    /// Whether this process declares the checked-allocations entitlement.
    public static func checkedAllocationsDeclared() -> Declaration {
        #if os(macOS)
        if let task = SecTaskCreateFromSelf(nil) {
            var error: Unmanaged<CFError>?
            let value = SecTaskCopyValueForEntitlement(task, checkedAllocationsEntitlement as CFString, &error)
            if error == nil {
                // A missing entitlement is a nil value with no error.
                return (value as? Bool) == true ? .declared : .notDeclared
            }
        }
        #endif
        if let marker = Bundle.main.object(forInfoDictionaryKey: infoPlistMarker) {
            let on = (marker as? Bool) == true || (marker as? String)?.uppercased() == "YES"
            return on ? .declared : .notDeclared
        }
        return .unknown
    }
}

/// SPEC §11, probe 2a: allocate heap blocks of varied sizes and read bits 59:56 of each pointer.
/// When the OS tags this process's memory the allocator returns logical tags and most are
/// nonzero; otherwise every tag is zero. No invalid access is made; this cannot fault.
public struct TaggedPointerProbe: Sendable {
    public struct Result: Equatable, Sendable {
        public var samples: Int
        public var tagged: Int
        /// Distinct 4-bit tag values seen, zero included when it occurs.
        public var distinctTags: Int
        public init(samples: Int, tagged: Int, distinctTags: Int) {
            self.samples = samples
            self.tagged = tagged
            self.distinctTags = distinctTags
        }
    }

    /// Small, medium and large blocks, so every allocator size class is sampled.
    public static let sizes: [Int] = [16, 32, 48, 64, 96, 128, 256, 512, 1024, 4096, 16384, 65536, 1 << 20]

    public static func run(rounds: Int = 5) -> Result {
        var pointers: [UnsafeMutableRawPointer] = []
        var histogram = [Int](repeating: 0, count: 16)
        for _ in 0..<max(rounds, 1) {
            for size in sizes {
                guard let p = malloc(size) else { continue }
                p.storeBytes(of: 1, as: UInt8.self)
                pointers.append(p)
                histogram[Int((UInt(bitPattern: p) >> 56) & 0xF)] += 1
            }
        }
        for p in pointers { free(p) }
        return Result(samples: pointers.count, tagged: pointers.count - histogram[0],
                      distinctTags: histogram.filter { $0 > 0 }.count)
    }
}

/// What the self-test measured about this process, attached to the raw audit result.
public struct SelfTestResult: Equatable, Sendable {
    public var probe: TaggedPointerProbe.Result
    public var entitlement: EnhancedSecurity.Declaration

    public init(probe: TaggedPointerProbe.Result, entitlement: EnhancedSecurity.Declaration) {
        self.probe = probe
        self.entitlement = entitlement
    }

    public static func measure() -> SelfTestResult {
        SelfTestResult(probe: TaggedPointerProbe.run(), entitlement: EnhancedSecurity.checkedAllocationsDeclared())
    }
}

#if os(macOS)
/// SPEC §11, probe 2b: a deliberate tag-mismatch store, isolated in a child process of the same
/// binary so a fault can never touch the parent. Under checked allocations the store one granule
/// past a 32-byte block hits the neighbour's tag and the kernel kills the child (SIGKILL on
/// macOS 26, measured on Mac17,7 / 25G83); without enforcement the store lands and the child
/// exits normally. macOS and the CLI only: nothing on iOS may spawn a process.
public enum FaultTest {
    public enum Outcome: Equatable, Sendable {
        case terminated(signal: Int32)
        case survived(exitStatus: Int32)
        case failed(String)
    }

    public static let childArguments = ["self-test", "--fault-child"]

    /// Runs in the child. Never call this in a process whose state matters.
    public static func performFault() {
        guard let block = malloc(32) else { return }
        memset(block, 1, 32)
        let past = block.advanced(by: 48)
        past.storeBytes(of: 7, as: UInt8.self)
        let readBack = past.load(as: UInt8.self)
        print("tag-mismatch store survived (read back \(readBack)); tag checks are not enforced for this binary")
    }

    public static func runChild(executable: URL, arguments: [String] = childArguments, timeout: TimeInterval = 15) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return .failed("child did not finish within \(Int(timeout)) s") }
        if process.terminationReason == .uncaughtSignal { return .terminated(signal: process.terminationStatus) }
        return .survived(exitStatus: process.terminationStatus)
    }

    /// The measured fact for an outcome (SPEC §11): `present` means the OS detected the mismatch.
    public static func fact(for outcome: Outcome, entitlement: EnhancedSecurity.Declaration) -> Fact {
        let state: FactState
        let description: String
        var probe = ProbeDetails(method: "child_process_tag_mismatch_store", entitlement: entitlement.rawValue)
        switch outcome {
        case .terminated(let signal):
            state = .present
            probe.childSignal = signal
            description = "A child process of this binary stored one granule past a 32-byte heap block and was killed by signal \(signal) (\(signalName(signal))): the OS detected the tag mismatch and stopped the process. This is a per-process fact about this build, not about the device."
        case .survived(let status):
            state = .notPresent
            probe.childExitStatus = status
            description = entitlement == .declared
                ? "The child's out-of-bounds store succeeded and it exited normally although this binary declares the checked-allocations entitlement: tag checks are not enforced for it here."
                : "The child's out-of-bounds store succeeded and it exited normally. This binary does not declare the Enhanced Security checked-allocations entitlement, so no tag check applies to it."
        case .failed(let why):
            state = .error
            description = "The fault test could not run: \(why)."
        }
        return Fact(id: "self_test.tag_check_fault", displayName: "Tag mismatch stops this app", category: "enforcement", kind: .flag,
                    provenance: .measured, state: state, discoveredBy: .selfTest, probe: probe,
                    description: description, securityRelevant: true)
    }

    static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGKILL: return "SIGKILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        default: return "signal \(s)"
        }
    }
}
#endif
