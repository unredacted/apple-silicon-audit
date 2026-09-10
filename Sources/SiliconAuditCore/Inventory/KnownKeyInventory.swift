import Foundation

/// `known-keys.json`: the curated annotations for sysctl keys the engine recognizes.
public struct KnownKeyInventory: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let id: String
        public let key: String
        public let displayName: String
        public let category: String
        public let kind: FactKind
        /// sysctl format string used when the sandbox refuses OIDFMT: I, Q, A. Nil = unknown.
        public let format: String?
        public let securityRelevant: Bool
        public let description: String
        public let aliasOf: String?

        enum CodingKeys: String, CodingKey {
            case id, key, category, kind, format, description
            case displayName = "display_name"
            case securityRelevant = "security_relevant"
            case aliasOf = "alias_of"
        }

        /// The inventory's declared format as an `OIDFormat` with `source == .inventory`.
        public var inventoryFormat: OIDFormat? {
            switch format {
            case "I": return OIDFormat(kind: OIDFormat.Flags.readable | OIDFormat.CTLType.int.rawValue, formatString: "I", source: .inventory)
            case "Q": return OIDFormat(kind: OIDFormat.Flags.readable | OIDFormat.CTLType.quad.rawValue, formatString: "Q", source: .inventory)
            case "A": return OIDFormat(kind: OIDFormat.Flags.readable | OIDFormat.CTLType.string.rawValue, formatString: "A", source: .inventory)
            default: return nil
            }
        }
    }

    public let schemaVersion: String
    public let version: String
    public let verified: String
    public let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case version, verified, entries
        case schemaVersion = "schema_version"
    }

    public init(schemaVersion: String, version: String, verified: String, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.verified = verified
        self.entries = entries
    }

    public var byKey: [String: Entry] { Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) }) }
    public var keys: [String] { entries.map(\.key) }

    public func entry(for key: String) -> Entry? { byKey[key] }

    /// Declared format for a key: the entry's, else `I` for any `hw.optional` leaf (every leaf
    /// XNU registers there is a SYSCTL_INT except `caps`, which the inventory lists as `Q`).
    public func format(for key: String) -> OIDFormat? {
        if let f = entry(for: key)?.inventoryFormat { return f }
        if key.hasPrefix("hw.optional.") {
            return OIDFormat(kind: OIDFormat.Flags.readable | OIDFormat.CTLType.int.rawValue, formatString: "I", source: .inventory)
        }
        return nil
    }
}

/// `caps-bits.json`: bit position → feature name, from `<arm/cpu_capabilities_public.h>`.
public struct CapsBitTable: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let bit: Int
        public let name: String
    }

    public let schemaVersion: String
    public let version: String
    public let verified: String
    public let capBitNB: Int
    public let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case version, verified, entries
        case schemaVersion = "schema_version"
        case capBitNB = "cap_bit_nb"
    }

    public init(schemaVersion: String, version: String, verified: String, capBitNB: Int, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.verified = verified
        self.capBitNB = capBitNB
        self.entries = entries
    }

    public var nameByBit: [Int: String] { Dictionary(uniqueKeysWithValues: entries.map { ($0.bit, $0.name) }) }
}

/// `cpufamily-names.json`: `hw.cpufamily` / `hw.cpusubfamily` constants from `<mach/machine.h>`.
public struct CPUFamilyTable: Decodable, Sendable {
    public struct Family: Decodable, Sendable, Equatable {
        public let value: String   // "0x%08x"
        public let name: String
        public let arch: String
    }
    public struct Subfamily: Decodable, Sendable, Equatable {
        public let value: Int
        public let name: String
    }

    public let schemaVersion: String
    public let version: String
    public let verified: String
    public let entries: [Family]
    public let subfamilies: [Subfamily]

    enum CodingKeys: String, CodingKey {
        case version, verified, entries, subfamilies
        case schemaVersion = "schema_version"
    }

    public init(schemaVersion: String, version: String, verified: String, entries: [Family], subfamilies: [Subfamily]) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.verified = verified
        self.entries = entries
        self.subfamilies = subfamilies
    }

    public func familyName(forHex hex: String) -> String? { entries.first { $0.value == hex }?.name }
    public func subfamilyName(_ value: Int) -> String? { subfamilies.first { $0.value == value }?.name }
}

/// `soc-map.json`: kernel target (T-number) → SoC name → security-guide column, with confidence.
public struct SoCMap: Decodable, Sendable {
    public enum Confidence: String, Decodable, Sendable {
        case verified, reported
    }
    public struct Entry: Decodable, Sendable, Equatable {
        public let socId: String
        public let socName: String
        public let securityGuideColumn: String
        public let confidence: Confidence
        public let evidence: String

        enum CodingKeys: String, CodingKey {
            case confidence, evidence
            case socId = "soc_id"
            case socName = "soc_name"
            case securityGuideColumn = "security_guide_column"
        }
    }

    public let schemaVersion: String
    public let version: String
    public let verified: String
    public let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case version, verified, entries
        case schemaVersion = "schema_version"
    }

    public init(schemaVersion: String, version: String, verified: String, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.verified = verified
        self.entries = entries
    }

    public func entry(for socId: String) -> Entry? { entries.first { $0.socId == socId } }
}
