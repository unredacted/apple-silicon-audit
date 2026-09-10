import Foundation

/// Everything the engine collected, before annotation. This is what the Phase 2
/// spike displays; the annotated `Report` arrives in Phase 3.
public struct RawAuditResult: Equatable, Sendable {
    public let environment: Environment
    public let walk: WalkResult
    /// Keys read by name regardless of the walk (spec §4.2: walk ∪ known list).
    public let namedReads: [String: ProbeOutcome]
    public let collectedAt: Date

    public init(environment: Environment, walk: WalkResult, namedReads: [String: ProbeOutcome], collectedAt: Date) {
        self.environment = environment
        self.walk = walk
        self.namedReads = namedReads
        self.collectedAt = collectedAt
    }

    /// Prefer the walk's reading, fall back to the named read.
    public func outcome(for key: String) -> ProbeOutcome? {
        walk.key(named: key)?.outcome ?? namedReads[key]
    }

    /// Walked keys registered for another architecture (ENOTSUP).
    public var notApplicableCount: Int {
        walk.keys.filter { $0.outcome == .notApplicable }.count
    }

    /// How many reads the sandbox or kernel refused.
    public var restrictedCount: Int {
        walk.keys.filter { $0.outcome == .restricted }.count
            + namedReads.values.filter { $0 == .restricted }.count
    }
}

/// Orchestrates a run. Phase 1 scope: environment, walk, and a fixed set of named reads.
public struct Auditor: Sendable {
    let sysctl: any SysctlReading

    /// Keys read by name on every run. Context and identity keys, the MTE headline
    /// group (also found by the walk, deliberately duplicated so the union can be
    /// checked), and the OS-level memory-tagging counters that live outside `hw.optional`.
    /// Nothing from the spec §10 never-read list may appear here.
    public static let namedKeys: [String] = [
        "hw.product", "hw.machine", "hw.model", "hw.target", "hw.targettype",
        "hw.cputype", "hw.cpusubtype", "hw.cpufamily", "hw.cpusubfamily",
        "hw.ncpu", "hw.nperflevels", "hw.memsize", "hw.pagesize",
        "hw.features.allows_security_research", "hw.engineering_sample",
        "kern.version", "kern.osversion", "kern.osproductversion", "kern.osreleasetype", "kern.hv_support",
        "sysctl.proc_translated",
        "hw.optional.arm.caps",
        "hw.optional.arm.FEAT_MTE", "hw.optional.arm.FEAT_MTE2", "hw.optional.arm.FEAT_MTE3", "hw.optional.arm.FEAT_MTE4",
        "hw.optional.arm.FEAT_MTE_ASYNC", "hw.optional.arm.FEAT_MTE_CANONICAL_TAGS",
        "hw.optional.arm.FEAT_MTE_STORE_ONLY", "hw.optional.arm.FEAT_MTE_NO_ADDRESS_TAGS",
        "vm.mte.tagged", "vm.mte.tag_storage.activations", "vm.mte.cell.active",
    ]

    /// Keys that must never be read or exported (spec §10). Enforced by a test.
    public static let forbiddenKeys: Set<String> = [
        "kern.hostname", "kern.bootsessionuuid", "kern.boottime", "kern.uuid",
    ]

    public init(sysctl: any SysctlReading = LiveSysctl()) {
        self.sysctl = sysctl
    }

    public func rawAudit(now: Date = Date()) -> RawAuditResult {
        let environment = Environment.detect(using: sysctl)
        let walk = MIBWalker(sysctl: sysctl).walk()
        var named: [String: ProbeOutcome] = [:]
        for key in Auditor.namedKeys {
            named[key] = sysctl.read(key)
        }
        return RawAuditResult(environment: environment, walk: walk, namedReads: named, collectedAt: now)
    }
}
