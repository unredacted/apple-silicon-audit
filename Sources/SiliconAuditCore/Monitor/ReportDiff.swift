import Foundation

/// What changed between two readings of the same device (SPEC §6.5). Only measured facts take
/// part: Apple's documentation and the app's inferences change with data updates, not with the
/// device. Live gauges and the keys that spell the OS build are excluded from the fact list and
/// the build change is reported once, on its own, so a system update reads as one event.
public struct ReportDiff: Codable, Equatable, Sendable {
    public struct FactChange: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case stateChanged = "state_changed"
            case valueChanged = "value_changed"
            case appeared
            case disappeared
        }

        /// The fact id (same in both reports).
        public var id: String
        public var displayName: String?
        public var category: String
        /// The sysctl key behind the fact, when it has one.
        public var key: String?
        public var kind: Kind
        public var before: FactState?
        public var after: FactState?
        public var beforeValue: String?
        public var afterValue: String?
        /// Security category or inventory `security_relevant` flag.
        public var securityRelevant: Bool

        enum CodingKeys: String, CodingKey {
            case id, category, key, kind, before, after
            case displayName = "display_name"
            case beforeValue = "before_value"
            case afterValue = "after_value"
            case securityRelevant = "security_relevant"
        }

        public var name: String { displayName ?? id }
    }

    public var identity: String
    /// True when the two reports describe different devices; the fact list is then empty and
    /// the caller should start a new baseline instead of reading the diff.
    public var identityChanged: Bool
    public var baselineCollectedAt: String
    public var currentCollectedAt: String
    public var osBuildBefore: String
    public var osBuildAfter: String
    public var osVersionBefore: String
    public var osVersionAfter: String
    public var appVersionBefore: String
    public var appVersionAfter: String
    public var changes: [FactChange]

    enum CodingKeys: String, CodingKey {
        case identity, changes
        case identityChanged = "identity_changed"
        case baselineCollectedAt = "baseline_collected_at"
        case currentCollectedAt = "current_collected_at"
        case osBuildBefore = "os_build_before"
        case osBuildAfter = "os_build_after"
        case osVersionBefore = "os_version_before"
        case osVersionAfter = "os_version_after"
        case appVersionBefore = "app_version_before"
        case appVersionAfter = "app_version_after"
    }

    public var osChanged: Bool { osBuildBefore != osBuildAfter }
    public var appVersionChanged: Bool { appVersionBefore != appVersionAfter }
    public var securityChanges: [FactChange] { changes.filter(\.securityRelevant) }
    public var otherChanges: [FactChange] { changes.filter { !$0.securityRelevant } }
    /// Nothing to tell the user: same device, same build, same facts.
    public var isEmpty: Bool { changes.isEmpty && !osChanged && !identityChanged }

    /// Keys whose values move on their own: live tag-storage gauges, and the keys that carry the
    /// OS build (reported once as `osChanged`).
    public static let volatileKeys: Set<String> = [
        "vm.mte.tagged", "vm.mte.cell.active", "vm.mte.tag_storage.activations",
        "kern.osversion", "kern.osproductversion", "kern.version", "kern.osreleasetype",
    ]

    /// Compares two full reports. `inventory` supplies the `security_relevant` flag for facts
    /// decoded from JSON, which do not carry it (the schema omits it); the live report's own flag
    /// is used when set.
    public static func compare(baseline: Report, current: Report, inventory: KnownKeyInventory? = DataStore.shared.knownKeys,
                               ignoring volatile: Set<String> = ReportDiff.volatileKeys) -> ReportDiff {
        var diff = ReportDiff(identity: current.device.identity,
                              identityChanged: baseline.device.identity != current.device.identity,
                              baselineCollectedAt: baseline.collectedAt, currentCollectedAt: current.collectedAt,
                              osBuildBefore: baseline.environment.osBuild, osBuildAfter: current.environment.osBuild,
                              osVersionBefore: baseline.environment.osVersion, osVersionAfter: current.environment.osVersion,
                              appVersionBefore: baseline.appVersion, appVersionAfter: current.appVersion,
                              changes: [])
        guard !diff.identityChanged else { return diff }

        func measured(_ report: Report) -> [String: Fact] {
            var byID: [String: Fact] = [:]
            for fact in report.facts + report.unrecognizedKeys where fact.provenance == .measured {
                if let key = fact.raw?.key, volatile.contains(key) { continue }
                byID[fact.id] = fact
            }
            return byID
        }
        let before = measured(baseline)
        let after = measured(current)
        let flags = Dictionary(uniqueKeysWithValues: (inventory?.entries ?? []).map { ($0.id, $0.securityRelevant) })
        func relevant(_ fact: Fact) -> Bool {
            fact.securityRelevant || Report.securityCategories.contains(fact.category) || flags[fact.id] == true
        }

        for id in Set(before.keys).union(after.keys).sorted() {
            switch (before[id], after[id]) {
            case (let b?, let a?):
                if b.state != a.state {
                    diff.changes.append(FactChange(id: id, displayName: a.displayName ?? b.displayName, category: a.category, key: a.raw?.key ?? b.raw?.key,
                                                   kind: .stateChanged, before: b.state, after: a.state,
                                                   beforeValue: b.raw?.displayValue, afterValue: a.raw?.displayValue, securityRelevant: relevant(a) || relevant(b)))
                } else if a.state == .value, b.raw?.displayValue != a.raw?.displayValue {
                    diff.changes.append(FactChange(id: id, displayName: a.displayName ?? b.displayName, category: a.category, key: a.raw?.key ?? b.raw?.key,
                                                   kind: .valueChanged, before: b.state, after: a.state,
                                                   beforeValue: b.raw?.displayValue, afterValue: a.raw?.displayValue, securityRelevant: relevant(a) || relevant(b)))
                }
            case (let b?, nil):
                diff.changes.append(FactChange(id: id, displayName: b.displayName, category: b.category, key: b.raw?.key, kind: .disappeared,
                                               before: b.state, after: nil, beforeValue: b.raw?.displayValue, afterValue: nil, securityRelevant: relevant(b)))
            case (nil, let a?):
                diff.changes.append(FactChange(id: id, displayName: a.displayName, category: a.category, key: a.raw?.key, kind: .appeared,
                                               before: nil, after: a.state, beforeValue: nil, afterValue: a.raw?.displayValue, securityRelevant: relevant(a)))
            case (nil, nil):
                continue
            }
        }
        // Security-relevant first, then by category order, then by id: the list reads top-down.
        let order = Dictionary(uniqueKeysWithValues: Report.categoryOrder.enumerated().map { ($1, $0) })
        diff.changes.sort {
            if $0.securityRelevant != $1.securityRelevant { return $0.securityRelevant }
            let l = order[$0.category] ?? Int.max, r = order[$1.category] ?? Int.max
            return l != r ? l < r : $0.id < $1.id
        }
        return diff
    }

    /// One technical line, for the CLI and logs.
    public var summary: String {
        if identityChanged { return "Different device: baseline is \(identity), comparison skipped." }
        var parts: [String] = []
        if osChanged { parts.append("OS build \(osBuildBefore) → \(osBuildAfter)") }
        if changes.isEmpty {
            parts.append("no measured facts changed")
        } else {
            parts.append("\(changes.count) changed fact\(changes.count == 1 ? "" : "s"), \(securityChanges.count) security-relevant")
        }
        return parts.joined(separator: "; ")
    }
}

public extension ReportDiff.FactChange {
    /// `present → not_present`, `6 → 4`, `(absent) → present`.
    var technicalTransition: String {
        func side(_ state: FactState?, _ value: String?) -> String {
            guard let state else { return "(absent)" }
            if state == .value, let value { return value }
            return state.rawValue
        }
        return "\(side(before, beforeValue)) → \(side(after, afterValue))"
    }
}

public extension RawReading {
    /// A short rendering of the value: the integer, the string, or the hex bytes.
    var displayValue: String? {
        switch value {
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .string(let s): return s
        case nil: return valueHex.map { "0x" + $0 }
        }
    }
}
