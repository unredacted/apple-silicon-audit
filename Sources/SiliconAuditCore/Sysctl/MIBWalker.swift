import Foundation

/// One leaf found by walking the MIB tree.
public struct DiscoveredKey: Equatable, Hashable, Sendable {
    public let name: String
    public let oid: [Int32]
    public let format: OIDFormat?
    public let outcome: ProbeOutcome

    public init(name: String, oid: [Int32], format: OIDFormat?, outcome: ProbeOutcome) {
        self.name = name
        self.oid = oid
        self.format = format
        self.outcome = outcome
    }

    /// True for keys the kernel flags CTLFLAG_MASKED (deprecated; hidden by sysctl(8)).
    public var isMasked: Bool { format?.isMasked ?? false }
}

/// Outcome of a walk. `succeeded == false` means the result is not evidence of
/// absence for anything outside the known-key inventory (spec §4.2).
public struct WalkResult: Equatable, Sendable {
    public let root: String
    public let keys: [DiscoveredKey]
    public let succeeded: Bool
    /// Human-readable reason when `succeeded` is false.
    public let failure: String?
    /// OIDs the walk visited but could not resolve to a name.
    public let unnamedOIDCount: Int

    public init(root: String, keys: [DiscoveredKey], succeeded: Bool, failure: String?, unnamedOIDCount: Int) {
        self.root = root
        self.keys = keys
        self.succeeded = succeeded
        self.failure = failure
        self.unnamedOIDCount = unnamedOIDCount
    }

    public func key(named name: String) -> DiscoveredKey? { keys.first { $0.name == name } }
}

/// Walks every leaf under a subtree with the kernel's CTL_SYSCTL_NEXT meta node,
/// resolving each OID to a name and format and reading its value.
public struct MIBWalker: Sendable {
    public static let defaultRoot = "hw.optional"

    let sysctl: any SysctlReading
    /// Hard stop to guarantee termination even against a misbehaving fake or kernel.
    let limit: Int

    public init(sysctl: any SysctlReading, limit: Int = 8192) {
        self.sysctl = sysctl
        self.limit = limit
    }

    public func walk(root: String = MIBWalker.defaultRoot) -> WalkResult {
        guard let rootOID = sysctl.oid(forName: root) else {
            return WalkResult(root: root, keys: [], succeeded: false, failure: "root '\(root)' is unknown to this kernel", unnamedOIDCount: 0)
        }
        let prefix = root + "."
        var keys: [DiscoveredKey] = []
        var unnamed = 0
        var current = rootOID
        var steps = 0

        while let next = sysctl.nextOID(after: current) {
            steps += 1
            if steps > limit {
                return WalkResult(root: root, keys: keys, succeeded: false, failure: "walk exceeded \(limit) steps", unnamedOIDCount: unnamed)
            }
            // The walk must always advance; a repeated OID would loop forever.
            guard next != current, next.count >= rootOID.count else { break }
            current = next
            // Leaving the subtree ends the walk. Compare OIDs first (cheap, exact), then names.
            guard Array(next.prefix(rootOID.count)) == rootOID else { break }
            guard let name = sysctl.name(forOID: next) else {
                unnamed += 1
                continue
            }
            guard name.hasPrefix(prefix) else { break }
            let format = sysctl.format(forOID: next)
            keys.append(DiscoveredKey(name: name, oid: next, format: format, outcome: sysctl.readOID(next)))
        }

        if keys.isEmpty {
            return WalkResult(root: root, keys: keys, succeeded: false, failure: "no keys found under '\(root)'", unnamedOIDCount: unnamed)
        }
        return WalkResult(root: root, keys: keys, succeeded: true, failure: nil, unnamedOIDCount: unnamed)
    }
}
