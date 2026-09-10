import Foundation

/// Who this device is, with the measured/inferred line drawn explicitly (SPEC §4.3, §8).
public struct DeviceIdentity: Equatable, Sendable {
    // Measured
    public let hwProduct: String?
    public let hwMachine: String?
    public let hwModel: String?
    public let hwTarget: String?
    /// `hw.cpufamily` as unsigned hex, e.g. "0xf76c5b1a".
    public let cpufamily: String?
    public let cpusubfamily: Int?
    /// Kernel build target parsed from `kern.version`, e.g. "T8150".
    public let socId: String?

    // Lookups
    public let cpufamilyName: String
    public let cpusubfamilyName: String
    public let socNameInferred: String
    public let socInferenceConfidence: String   // verified | reported | none
    public let securityGuideColumn: String?
    public let marketingNameInferred: String

    /// hw_product → hw_model (Macs) → hw_machine. The results-database key (SPEC §4.3).
    public var identity: String {
        if let p = hwProduct, !p.isEmpty { return p }
        if let m = hwModel, !m.isEmpty, (hwMachine ?? "").hasPrefix("x86") || (hwMachine ?? "") == "arm64" { return m }
        if let m = hwMachine, !m.isEmpty { return m }
        return "unknown"
    }

    public static func socId(fromKernelVersion s: String) -> String? {
        guard let r = s.range(of: #"RELEASE_ARM64_(T\d{4,5})"#, options: .regularExpression) else { return nil }
        return s[r].split(separator: "_").last.map(String.init)
    }

    public static func resolve(from raw: RawAuditResult, data: DataStore) -> DeviceIdentity {
        func str(_ k: String) -> String? { raw.outcome(for: k)?.value?.payload.stringValue }
        func int(_ k: String) -> Int64? { raw.outcome(for: k)?.value?.payload.integerValue }

        let familyHex = int("hw.cpufamily").map { String(format: "0x%08x", UInt32(bitPattern: Int32(truncatingIfNeeded: $0))) }
        let sub = int("hw.cpusubfamily").map(Int.init)
        let soc = socId(fromKernelVersion: raw.environment.kernelVersion)
        let entry = soc.flatMap(data.socMap.entry(for:))

        return DeviceIdentity(
            hwProduct: str("hw.product"),
            hwMachine: str("hw.machine"),
            hwModel: str("hw.model"),
            hwTarget: str("hw.target"),
            cpufamily: familyHex,
            cpusubfamily: sub,
            socId: soc,
            cpufamilyName: familyHex.flatMap(data.cpufamilies.familyName(forHex:)) ?? "unrecognized",
            cpusubfamilyName: sub.flatMap(data.cpufamilies.subfamilyName) ?? "unrecognized",
            socNameInferred: entry?.socName ?? "unrecognized",
            socInferenceConfidence: entry?.confidence.rawValue ?? "none",
            securityGuideColumn: entry?.securityGuideColumn,
            marketingNameInferred: "unrecognized"
        )
    }

    /// The one-sentence reasoning chain for the inferred SoC fact.
    public var socReasoning: String {
        guard let socId else { return "kern.version carries no RELEASE_ARM64_T target, so no SoC can be inferred." }
        if socInferenceConfidence == "none" { return "kern.version target \(socId) is not in soc-map.json; Apple's documentation cannot be applied to this chip." }
        return "kern.version target \(socId) → soc-map.json (\(socInferenceConfidence)) → \(socNameInferred), security-guide column \(securityGuideColumn ?? "none")."
    }
}
