import Foundation

/// Everything the engine collected, before annotation.
public struct RawAuditResult: Equatable, Sendable {
    public let environment: AuditEnvironment
    public let walk: WalkResult
    /// Keys read by name regardless of the walk (SPEC §4.2: walk ∪ known list).
    public let namedReads: [String: ProbeOutcome]
    public let collectedAt: Date
    /// What this process measured about itself (SPEC §11); nil for fixture runs, whose process
    /// has nothing to do with the recorded device.
    public let selfTest: SelfTestResult?

    public init(environment: AuditEnvironment, walk: WalkResult, namedReads: [String: ProbeOutcome], collectedAt: Date,
                selfTest: SelfTestResult? = nil) {
        self.environment = environment
        self.walk = walk
        self.namedReads = namedReads
        self.collectedAt = collectedAt
        self.selfTest = selfTest
    }

    /// Prefer the walk's reading, fall back to the named read.
    public func outcome(for key: String) -> ProbeOutcome? {
        walk.key(named: key)?.outcome ?? namedReads[key]
    }

    public func discoveredBy(_ key: String) -> DiscoveredBy? {
        let walked = walk.key(named: key) != nil
        let named = namedReads[key] != nil
        switch (walked, named) {
        case (true, true): return .both
        case (true, false): return .walk
        case (false, true): return .knownList
        case (false, false): return nil
        }
    }

    /// True when at least one value carries a kernel-declared format, i.e. CTL_SYSCTL_OIDFMT
    /// answered. False means every decoded type came from the inventory (iOS, watchOS).
    public var kernelFormatsAvailable: Bool {
        namedReads.values.contains { $0.value?.format?.source == .kernel }
            || walk.keys.contains { $0.format?.source == .kernel }
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

/// Orchestrates a run: environment, walk, by-name reads of the whole inventory, then the
/// annotated `Report` (SPEC §4, §8).
public struct Auditor: Sendable {
    public let sysctl: any SysctlReading
    public let data: DataStore
    /// Whether `rawAudit` runs the in-process self-test (SPEC §11). On by default for the live
    /// kernel, off for fixtures.
    public let runsSelfTest: Bool

    /// Keys that must never be read or exported (SPEC §10). Enforced by a test and at runtime.
    public static let forbiddenKeys: Set<String> = [
        "kern.hostname", "kern.bootsessionuuid", "kern.boottime", "kern.uuid",
    ]

    /// Read by name when the inventory cannot be loaded; otherwise every inventory key is read.
    public static let fallbackNamedKeys: [String] = [
        "hw.product", "hw.machine", "hw.model", "hw.target", "hw.cpufamily", "hw.cpusubfamily",
        "kern.version", "kern.osversion", "kern.osproductversion",
        "hw.optional.arm.caps", "hw.optional.arm.FEAT_MTE", "hw.optional.arm.FEAT_MTE2", "hw.optional.arm.FEAT_MTE3",
        "hw.optional.arm.FEAT_MTE4", "hw.optional.arm.FEAT_PAuth", "hw.optional.arm.FEAT_BTI",
        "vm.mte.tagged", "vm.mte.cell.active",
    ]

    /// The keys this auditor reads by name: the whole inventory, minus the forbidden list.
    public var namedKeys: [String] {
        let keys = data.knownKeys.entries.isEmpty ? Auditor.fallbackNamedKeys : data.knownKeys.keys
        return keys.filter { !Auditor.forbiddenKeys.contains($0) }
    }

    /// The bundled inventory's keys (what a default `Auditor()` reads by name).
    public static var namedKeys: [String] { Auditor(sysctl: LiveSysctl()).namedKeys }

    public init(sysctl: any SysctlReading = LiveSysctl(), data: DataStore = .shared, selfTest: Bool? = nil) {
        self.sysctl = sysctl
        self.data = data
        self.runsSelfTest = selfTest ?? (sysctl is LiveSysctl)
    }

    public func rawAudit(now: Date = Date()) -> RawAuditResult {
        let environment = AuditEnvironment.detect(using: sysctl, inventory: data.knownKeys)
        let walk = MIBWalker(sysctl: sysctl, inventory: data.knownKeys).walk()
        var named: [String: ProbeOutcome] = [:]
        for key in namedKeys {
            named[key] = sysctl.read(key).withInventoryFormat(for: key, inventory: data.knownKeys)
        }
        return RawAuditResult(environment: environment, walk: walk, namedReads: named, collectedAt: now,
                              selfTest: runsSelfTest ? SelfTestResult.measure() : nil)
    }

    public func audit(now: Date = Date(), appVersion: String = SiliconAuditCore.version) -> Report {
        report(from: rawAudit(now: now), appVersion: appVersion)
    }

    /// The tagged-pointer self-test as a fact (SPEC §11). `present`: this process's heap is tagged.
    /// `not_present`: it is not (the description says whether the entitlement was declared).
    /// `not_applicable`: the kernel reports no memory-tagging hardware, so no process can be.
    /// `mteStates` are the states of the kernel's own MTE flags (FEAT_MTE4, FEAT_MTE); hardware is
    /// absent only when every one of them reads off, absent, or not-applicable and none reads on.
    public static func taggedPointerFact(_ selfTest: SelfTestResult, mteStates: [FactState]) -> Fact {
        let p = selfTest.probe
        let offStates: Set<FactState> = [.notPresent, .keyAbsent, .notApplicable]
        let hardwareAbsent = !mteStates.isEmpty && !mteStates.contains(.present) && mteStates.allSatisfy { offStates.contains($0) }
        let state: FactState = hardwareAbsent ? .notApplicable : (p.tagged > 0 ? .present : .notPresent)
        let description: String
        switch state {
        case .present:
            description = "\(p.tagged) of \(p.samples) heap allocations came back with a nonzero tag (\(p.distinctTags) distinct tag values): the OS tags this process's memory. This is a per-process fact about this build of the app, not about the device."
        case .notApplicable:
            description = "This kernel reports no memory-tagging hardware, so no process on this device can be tagged (\(p.tagged) of \(p.samples) allocations tagged)."
        default:
            switch selfTest.entitlement {
            case .declared:
                description = "None of \(p.samples) heap allocations carried a tag although this build declares the checked-allocations entitlement: the OS did not tag this process."
            case .notDeclared:
                description = "None of \(p.samples) heap allocations carried a tag. This build does not declare the Enhanced Security checked-allocations entitlement, so the OS does not tag its memory."
            case .unknown:
                description = "None of \(p.samples) heap allocations carried a tag; whether this build declares the checked-allocations entitlement could not be determined."
            }
        }
        return Fact(id: "self_test.tagged_pointers", displayName: "Memory tagging active for this app", category: "enforcement", kind: .flag,
                    provenance: .measured, state: state, discoveredBy: .selfTest,
                    probe: ProbeDetails(method: "tagged_pointer_observation", samples: p.samples, tagged: p.tagged, distinctTags: p.distinctTags,
                                        entitlement: selfTest.entitlement.rawValue),
                    description: description, securityRelevant: true)
    }

    /// Annotates a raw result. Pure: the same raw result and data always give the same report.
    public func report(from raw: RawAuditResult, appVersion: String = SiliconAuditCore.version) -> Report {
        let identity = DeviceIdentity.resolve(from: raw, data: data)
        var facts: [Fact] = []

        // Measured facts for every inventory key that was read or walked.
        for entry in data.knownKeys.entries {
            guard let outcome = raw.outcome(for: entry.key), let discovered = raw.discoveredBy(entry.key) else { continue }
            let walked = raw.walk.key(named: entry.key)
            facts.append(Fact(
                id: entry.id, displayName: entry.displayName, category: entry.category, kind: entry.kind,
                provenance: .measured, state: Fact.state(for: outcome, kind: entry.kind), discoveredBy: discovered,
                raw: RawReading(key: entry.key, outcome: outcome, masked: walked?.isMasked ?? false),
                description: entry.description, securityRelevant: entry.securityRelevant))
        }

        // Walk discoveries outside the inventory. CTLFLAG_MASKED nodes are deprecated
        // compatibility aliases that sysctl(8) hides; they are recorded, not celebrated.
        let known = Set(data.knownKeys.keys)
        let novel = raw.walk.keys.filter { !known.contains($0.name) }
        for k in novel where k.isMasked {
            facts.append(Fact(id: "deprecated." + k.name, displayName: k.name, category: "deprecated", kind: .unknown,
                              provenance: .measured, state: Fact.state(for: k.outcome, kind: .unknown), discoveredBy: .walk,
                              raw: RawReading(key: k.name, outcome: k.outcome, masked: true),
                              description: "Deprecated compatibility node (CTLFLAG_MASKED); hidden by sysctl(8)."))
        }
        let unrecognized: [Fact] = novel.filter { !$0.isMasked }.map { k in
            Fact(id: "unrecognized." + k.name, displayName: k.name, category: "unrecognized", kind: .unknown,
                 provenance: .measured, state: Fact.state(for: k.outcome, kind: .unknown), discoveredBy: .walk,
                 raw: RawReading(key: k.name, outcome: k.outcome, masked: false),
                 description: "Discovered by the walk; not yet in the inventory.")
        }

        // Capabilities bitmask decode and cross-check. Only a buffer covering every header bit
        // is decoded: an 8-byte scalar (what `sysctl -a` prints) would silently drop bits 64–91.
        var capabilities: Report.Capabilities?
        if let capsBytes = raw.outcome(for: "hw.optional.arm.caps")?.value?.rawBytes, !data.capsBits.entries.isEmpty {
            let decoded = CapsDecoder.decode(capsBytes, table: data.capsBits)
            if decoded.covers(data.capsBits) {
                let check = CapsDecoder.crossCheck(decoded, table: data.capsBits) { raw.outcome(for: $0) }
                capabilities = Report.Capabilities(byteCount: decoded.byteCount, popcount: decoded.popcount,
                                                   namedBits: decoded.namedBits, unnamedBits: decoded.unnamedBits, mismatches: check.mismatches)
                let state: FactState = !check.mismatches.isEmpty ? .notPresent : (check.isComplete ? .present : .unknown)
                let reasoning: String
                if !check.mismatches.isEmpty {
                    reasoning = "Disagreements: " + check.mismatches.joined(separator: "; ")
                } else if check.isComplete {
                    reasoning = "Every named bit in hw.optional.arm.caps matches its hw.optional.arm.FEAT_* key (\(check.compared) compared, \(decoded.unnamedBits.count) unnamed bits)."
                } else {
                    reasoning = "\(check.compared) named bits matched their keys, but \(check.unchecked.count) could not be compared (key absent, restricted, or undecodable): \(check.unchecked.prefix(6).joined(separator: ", "))\(check.unchecked.count > 6 ? ", …" : "")."
                }
                facts.append(Fact(
                    id: "caps.consistency", displayName: "Capability bitmask agrees with FEAT_* keys", category: "capability_bitmask",
                    kind: .claim, provenance: .inferred, state: state, reasoning: reasoning,
                    description: "The kernel publishes the same features twice, as a bitmask and as keys; they should agree."))
            } else {
                facts.append(Fact(
                    id: "caps.consistency", displayName: "Capability bitmask agrees with FEAT_* keys", category: "capability_bitmask",
                    kind: .claim, provenance: .inferred, state: .unknown,
                    reasoning: "hw.optional.arm.caps read as \(decoded.byteCount) bytes but the header defines \(data.capsBits.capBitNB) bits (\((data.capsBits.capBitNB + 7) / 8) bytes); the buffer is truncated (typical of a `sysctl -a` text dump), so it is not decoded.",
                    description: "The kernel publishes the same features twice, as a bitmask and as keys; they should agree."))
            }
        }

        // Inferred identity facts.
        facts.append(Fact(
            id: "soc.identity", displayName: "System on chip", category: "identity", kind: .claim, provenance: .inferred,
            state: identity.socInferenceConfidence == "none" ? .unknown : .present,
            reasoning: identity.socReasoning,
            description: identity.socInferenceConfidence == "none" ? "unrecognized" : "\(identity.socNameInferred) (\(identity.socInferenceConfidence))"))
        facts.append(Fact(
            id: "cpu.family", displayName: "CPU core family", category: "identity", kind: .claim, provenance: .inferred,
            state: identity.cpufamilyName == "unrecognized" ? .unknown : .present,
            reasoning: "hw.cpufamily \(identity.cpufamily ?? "absent") → <mach/machine.h> → \(identity.cpufamilyName).",
            description: identity.cpufamilyName))

        // Self-test (SPEC §11, probe 2a): a per-process measured fact. The kernel's own memory-tagging
        // flags gate it: on a chip with no tagging hardware the question does not apply.
        if let selfTest = raw.selfTest {
            let mteStates = ["arm.FEAT_MTE4", "arm.FEAT_MTE"].compactMap { id in facts.first { $0.id == id }?.state }
            facts.append(Auditor.taggedPointerFact(selfTest, mteStates: mteStates))
        }

        // Documented claims via soc_id → column.
        facts.append(contentsOf: data.matrix.facts(forColumn: identity.securityGuideColumn, socId: identity.socId))

        return Report(
            appVersion: appVersion,
            variant: "full",
            collectedAt: Report.timestamp(raw.collectedAt),
            collection: Report.Collection(walkSucceeded: raw.walk.succeeded, walkRoot: raw.walk.root, walkFailure: raw.walk.failure,
                                          knownKeysVersion: data.knownKeys.version.isEmpty ? nil : data.knownKeys.version,
                                          kernelFormatsAvailable: raw.kernelFormatsAvailable,
                                          dataVersions: Report.DataVersions(data)),
            environment: Report.Environment(raw.environment),
            device: Report.Device(identity),
            capabilities: capabilities,
            facts: facts,
            unrecognizedKeys: unrecognized)
    }
}
