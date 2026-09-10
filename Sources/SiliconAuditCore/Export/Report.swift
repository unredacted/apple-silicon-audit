import Foundation

/// The export document (SPEC §8, `Schema/export-v1.schema.json`). Field names are explicit
/// so the JSON is exactly what the schema expects.
public struct Report: Codable, Equatable, Sendable {
    public static let schemaVersion = "1.0.0"

    public struct Collection: Codable, Equatable, Sendable {
        public var walkSucceeded: Bool
        public var walkRoot: String
        public var walkFailure: String?
        public var knownKeysVersion: String
        public var kernelFormatsAvailable: Bool

        enum CodingKeys: String, CodingKey {
            case walkSucceeded = "walk_succeeded"
            case walkRoot = "walk_root"
            case walkFailure = "walk_failure"
            case knownKeysVersion = "known_keys_version"
            case kernelFormatsAvailable = "kernel_formats_available"
        }
    }

    public struct Environment: Codable, Equatable, Sendable {
        public var platform: String
        public var arch: String
        public var osVersion: String
        public var osBuild: String
        public var kernelVersion: String
        public var isSimulator: Bool
        public var isTranslated: Bool
        public var isiOSAppOnMac: Bool
        public var isCatalyst: Bool
        public var isVirtualMachine: Bool

        enum CodingKeys: String, CodingKey {
            case platform, arch
            case osVersion = "os_version"
            case osBuild = "os_build"
            case kernelVersion = "kernel_version"
            case isSimulator = "is_simulator"
            case isTranslated = "is_translated"
            case isiOSAppOnMac = "is_ios_app_on_mac"
            case isCatalyst = "is_catalyst"
            case isVirtualMachine = "is_virtual_machine"
        }

        public init(_ e: AuditEnvironment) {
            platform = e.platform.rawValue
            arch = e.arch.rawValue
            osVersion = e.osVersion
            osBuild = e.osBuild
            kernelVersion = e.kernelVersion
            isSimulator = e.isSimulator
            isTranslated = e.isTranslated
            isiOSAppOnMac = e.isiOSAppOnMac
            isCatalyst = e.isCatalyst
            isVirtualMachine = e.isVirtualMachine
        }

        /// True when the numbers describe the host or a hypervisor rather than the device.
        public var isMisleading: Bool { isSimulator || isTranslated || isiOSAppOnMac || isVirtualMachine }
    }

    public struct Device: Codable, Equatable, Sendable {
        public var identity: String
        public var hwProduct: String?
        public var hwMachine: String?
        public var hwModel: String?
        public var hwTarget: String?
        public var cpufamily: String?
        public var cpufamilyName: String
        public var cpusubfamily: Int?
        public var cpusubfamilyName: String
        public var socId: String?
        public var socNameInferred: String
        public var socInferenceConfidence: String
        public var marketingNameInferred: String

        enum CodingKeys: String, CodingKey {
            case identity, cpufamily, cpusubfamily
            case hwProduct = "hw_product"
            case hwMachine = "hw_machine"
            case hwModel = "hw_model"
            case hwTarget = "hw_target"
            case cpufamilyName = "cpufamily_name"
            case cpusubfamilyName = "cpusubfamily_name"
            case socId = "soc_id"
            case socNameInferred = "soc_name_inferred"
            case socInferenceConfidence = "soc_inference_confidence"
            case marketingNameInferred = "marketing_name_inferred"
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(identity, forKey: .identity)
            try c.encode(hwProduct, forKey: .hwProduct)
            try c.encode(hwMachine, forKey: .hwMachine)
            try c.encode(hwModel, forKey: .hwModel)
            try c.encodeIfPresent(hwTarget, forKey: .hwTarget)
            try c.encode(cpufamily, forKey: .cpufamily)
            try c.encode(cpufamilyName, forKey: .cpufamilyName)
            try c.encodeIfPresent(cpusubfamily, forKey: .cpusubfamily)
            try c.encode(cpusubfamilyName, forKey: .cpusubfamilyName)
            try c.encode(socId, forKey: .socId)
            try c.encode(socNameInferred, forKey: .socNameInferred)
            try c.encode(socInferenceConfidence, forKey: .socInferenceConfidence)
            try c.encode(marketingNameInferred, forKey: .marketingNameInferred)
        }

        public init(_ d: DeviceIdentity) {
            identity = d.identity
            hwProduct = d.hwProduct
            hwMachine = d.hwMachine
            hwModel = d.hwModel
            hwTarget = d.hwTarget
            cpufamily = d.cpufamily
            cpufamilyName = d.cpufamilyName
            cpusubfamily = d.cpusubfamily
            cpusubfamilyName = d.cpusubfamilyName
            socId = d.socId
            socNameInferred = d.socNameInferred
            socInferenceConfidence = d.socInferenceConfidence
            marketingNameInferred = d.marketingNameInferred
        }
    }

    public struct Capabilities: Codable, Equatable, Sendable {
        public var byteCount: Int
        public var popcount: Int
        public var namedBits: [String]
        public var unnamedBits: [Int]
        public var mismatches: [String]

        enum CodingKeys: String, CodingKey {
            case popcount, mismatches
            case byteCount = "byte_count"
            case namedBits = "named_bits"
            case unnamedBits = "unnamed_bits"
        }
    }

    public var schemaVersion: String = Report.schemaVersion
    public var appVersion: String
    public var variant: String
    public var collectedAt: String
    public var collection: Collection
    public var environment: Environment
    public var device: Device
    public var capabilities: Capabilities?
    public var facts: [Fact]
    public var unrecognizedKeys: [Fact]

    enum CodingKeys: String, CodingKey {
        case variant, collection, environment, device, capabilities, facts
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case collectedAt = "collected_at"
        case unrecognizedKeys = "unrecognized_keys"
    }

    public init(appVersion: String, variant: String, collectedAt: String, collection: Collection, environment: Environment,
                device: Device, capabilities: Capabilities?, facts: [Fact], unrecognizedKeys: [Fact]) {
        self.appVersion = appVersion
        self.variant = variant
        self.collectedAt = collectedAt
        self.collection = collection
        self.environment = environment
        self.device = device
        self.capabilities = capabilities
        self.facts = facts
        self.unrecognizedKeys = unrecognizedKeys
    }

    // MARK: - Views

    public var measuredFacts: [Fact] { facts.filter { $0.provenance == .measured } }
    public var documentedFacts: [Fact] { facts.filter { $0.provenance == .documented } }
    public var inferredFacts: [Fact] { facts.filter { $0.provenance == .inferred } }
    /// The headline view: security categories plus any row the inventory marks security-relevant
    /// (legacy PAC alias, Security Research Device flag, x86 security features).
    public var securityFacts: [Fact] { facts.filter { $0.securityRelevant || Report.securityCategories.contains($0.category) } }

    public static let securityCategories: Set<String> = [
        "memory_tagging", "pointer_authentication", "control_flow", "speculation", "constant_time", "capability_bitmask", "os_memory_tagging",
    ]

    /// Category display order (SPEC §4.3): headline group first.
    public static let categoryOrder: [String] = [
        "memory_tagging", "os_memory_tagging", "pointer_authentication", "control_flow", "speculation", "constant_time",
        "capability_bitmask", "kernel_integrity", "identity", "legacy_alias", "isa_crypto", "isa_simd", "isa_sme", "isa_misc",
        "debug", "x86_isa", "context_identity", "context_cpu", "context_os", "deprecated", "unrecognized",
    ]

    // MARK: - Encoding

    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public func jsonData(pretty: Bool = true) throws -> Data {
        try Report.encoder(pretty: pretty).encode(self)
    }

    public static func decode(_ data: Data) throws -> Report {
        try JSONDecoder().decode(Report.self, from: data)
    }

    /// Categories the compact variant keeps: the security-relevant groups plus device identity.
    public static let compactCategories: Set<String> = securityCategories.union(["context_identity", "context_os", "legacy_alias"])

    /// The compact variant (SPEC §8): security-relevant measured facts plus identity context,
    /// no display names, for QR codes and the watch ShareLink. ISA/SIMD and x86 rows are left
    /// to the full export so the payload fits a QR code. `unrecognized_keys` are kept whole.
    public func compact() -> Report {
        var r = self
        r.variant = "compact"
        r.facts = measuredFacts.filter { Report.compactCategories.contains($0.category) }
            .map { var f = $0; f.displayName = nil; f.description = nil; return f }
        r.unrecognizedKeys = unrecognizedKeys.map { var f = $0; f.displayName = nil; f.description = nil; return f }
        return r
    }

    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
