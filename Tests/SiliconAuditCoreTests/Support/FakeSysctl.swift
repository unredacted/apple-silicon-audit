import Foundation
@testable import SiliconAuditCore

/// An in-memory MIB tree. Entries are leaves; nodes are implied by name prefixes.
/// `nextOID` is tree order, which for this fake is lexicographic OID order.
struct FakeSysctl: SysctlReading {
    struct Entry: Sendable {
        let oid: [Int32]
        let name: String?
        let format: OIDFormat?
        let outcome: ProbeOutcome
    }

    let entries: [Entry]
    /// Node names → OIDs, so `oid(forName:)` can resolve a walk root.
    let nodes: [String: [Int32]]

    init(entries: [Entry], nodes: [String: [Int32]] = [:]) {
        self.entries = entries.sorted { $0.oid.lexicographicallyPrecedes($1.oid) }
        self.nodes = nodes
    }

    func read(_ name: String) -> ProbeOutcome {
        entries.first { $0.name == name }?.outcome ?? .absent
    }

    func oid(forName name: String) -> [Int32]? {
        nodes[name] ?? entries.first { $0.name == name }?.oid
    }

    func nextOID(after oid: [Int32]) -> [Int32]? {
        entries.first { oid.lexicographicallyPrecedes($0.oid) }?.oid
    }

    func name(forOID oid: [Int32]) -> String? {
        entries.first { $0.oid == oid }?.name
    }

    func format(forOID oid: [Int32]) -> OIDFormat? {
        entries.first { $0.oid == oid }?.format
    }

    func readOID(_ oid: [Int32]) -> ProbeOutcome {
        entries.first { $0.oid == oid }?.outcome ?? .absent
    }
}

// MARK: - Builders

extension FakeSysctl.Entry {
    static func int(_ oid: [Int32], _ name: String, _ value: Int32, format: OIDFormat = .int) -> Self {
        .init(oid: oid, name: name, format: format, outcome: .value(SysctlValue(format: format, bytes: le(UInt32(bitPattern: value)))))
    }

    static func quad(_ oid: [Int32], _ name: String, _ value: Int64) -> Self {
        .init(oid: oid, name: name, format: .quad, outcome: .value(SysctlValue(format: .quad, bytes: le(UInt64(bitPattern: value)))))
    }

    static func string(_ oid: [Int32], _ name: String, _ value: String) -> Self {
        .init(oid: oid, name: name, format: .string, outcome: .value(SysctlValue(format: .string, bytes: Array(value.utf8) + [0])))
    }

    static func bytes(_ oid: [Int32], _ name: String, _ bytes: [UInt8], format: OIDFormat) -> Self {
        .init(oid: oid, name: name, format: format, outcome: .value(SysctlValue(format: format, bytes: bytes)))
    }

    static func failing(_ oid: [Int32], _ name: String, _ outcome: ProbeOutcome, format: OIDFormat? = .int) -> Self {
        .init(oid: oid, name: name, format: format, outcome: outcome)
    }

    static func unnamed(_ oid: [Int32]) -> Self {
        .init(oid: oid, name: nil, format: nil, outcome: .absent)
    }
}

func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

/// A small tree resembling a real device: hw (6) → optional (110) → arm (1) → FEAT_*.
enum Trees {
    static let hwOptional: [Int32] = [6, 110]
    static let hwOptionalArm: [Int32] = [6, 110, 1]

    static func device(mte4: Int32 = 1, includeMasked: Bool = false) -> FakeSysctl {
        var entries: [FakeSysctl.Entry] = [
            .int([6, 1], "hw.ncpu", 8),
            .string([6, 2], "hw.product", "Test1,1"),
            .string([6, 3], "hw.machine", "Test1,1"),
            .int([6, 4], "hw.cpufamily", Int32(bitPattern: 0xf76c_5b1a)),
            .int([6, 110, 1, 1], "hw.optional.arm.FEAT_PAuth", 1),
            .int([6, 110, 1, 2], "hw.optional.arm.FEAT_MTE", 1),
            .int([6, 110, 1, 3], "hw.optional.arm.FEAT_MTE3", 0),
            .int([6, 110, 1, 4], "hw.optional.arm.FEAT_MTE4", mte4),
            // Declared int64_t, actually 12 bytes: the caps trap.
            .bytes([6, 110, 1, 5], "hw.optional.arm.caps", [UInt8](repeating: 0xff, count: 12), format: .quad),
            .failing([6, 110, 1, 6], "hw.optional.arm.FEAT_RESTRICTED", .restricted),
            .int([6, 110, 2], "hw.optional.arm64", 1),
            .int([6, 110, 3], "hw.optional.breakpoint", 6),
            // First leaf outside the subtree; the walk must stop before it.
            .int([6, 111], "hw.pagesize", 16384),
            .string([1, 65], "kern.osversion", "25G83"),
            .string([1, 66], "kern.osproductversion", "26.6.2"),
            .string([1, 67], "kern.version", "Darwin Kernel Version 25.6.0: ...; root:xnu-12377.161.14~5/RELEASE_ARM64_T6050"),
        ]
        if includeMasked {
            entries.append(.int([6, 110, 4], "hw.optional.old_compat", 1,
                                format: OIDFormat(kind: OIDFormat.Flags.readable | OIDFormat.Flags.masked | OIDFormat.CTLType.int.rawValue, formatString: "I")))
        }
        return FakeSysctl(entries: entries, nodes: ["hw.optional": hwOptional, "hw.optional.arm": hwOptionalArm, "hw": [6]])
    }
}
