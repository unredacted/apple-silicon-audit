import Foundation

/// Where a fact came from (SPEC §3). Never conflated; every fact carries one.
public enum Provenance: String, Codable, Sendable {
    case measured, documented, inferred, unknown
}

/// The single state enum for every fact (SPEC §8).
public enum FactState: String, Codable, Sendable {
    case present
    case notPresent = "not_present"
    /// A non-flag key that read successfully; the reading is in `raw`.
    case value
    case keyAbsent = "key_absent"
    case restricted
    case notApplicable = "not_applicable"
    case error
    case unknown
}

public enum FactKind: String, Codable, Sendable {
    case flag, count, bitmask, string, unknown, claim
}

public enum DiscoveredBy: String, Codable, Sendable {
    case walk
    case knownList = "known_list"
    case both
}

/// A decoded sysctl value as it appears in the export.
public enum RawValue: Equatable, Sendable, Codable {
    case int(Int64)
    case uint(UInt64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let u = try? c.decode(UInt64.self) { self = .uint(u); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .uint(let u): try c.encode(u)
        case .string(let s): try c.encode(s)
        }
    }
}

/// The exact reading behind a measured fact (SPEC §8 `raw`).
public struct RawReading: Codable, Equatable, Sendable {
    public var key: String
    /// Type name as sysctl(8) prints it, or nil when unknown.
    public var format: String?
    /// "kernel" (OIDFMT answered) or "inventory" (sandbox refused OIDFMT; type from known-keys.json).
    public var formatSource: String?
    public var length: Int
    public var value: RawValue?
    public var valueHex: String?
    public var errno: Int32?
    public var masked: Bool?

    enum CodingKeys: String, CodingKey {
        case key, format, length, value, errno, masked
        case formatSource = "format_source"
        case valueHex = "value_hex"
    }

    /// The schema requires `format` and `errno` to be present (null on success/unknown) so a
    /// missing type or missing errno is never ambiguous; Swift would otherwise drop nil keys.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(formatSource, forKey: .formatSource)
        try c.encode(length, forKey: .length)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(valueHex, forKey: .valueHex)
        try c.encode(errno, forKey: .errno)
        try c.encodeIfPresent(masked, forKey: .masked)
    }

    public init(key: String, outcome: ProbeOutcome, masked: Bool = false) {
        self.key = key
        self.masked = masked ? true : nil
        switch outcome {
        case .value(let v):
            format = v.format?.typeName
            formatSource = v.format.map { $0.source.rawValue }
            length = v.length
            errno = nil
            switch v.payload {
            case .int(let i): value = .int(i)
            case .uint(let u): value = .uint(u)
            case .string(let s): value = .string(s)
            case .bytes: value = nil; valueHex = v.hex
            }
        default:
            format = nil
            formatSource = nil
            length = 0
            value = nil
            errno = outcome.errnoValue
        }
    }
}

/// A documented claim's citation (SPEC §5).
public struct FactSource: Codable, Equatable, Sendable {
    public var url: String
    public var published: String
    public var verified: String
    public var note: String?

    public init(url: String, published: String, verified: String, note: String? = nil) {
        self.url = url
        self.published = published
        self.verified = verified
        self.note = note
    }
}

/// One displayed/exported fact (SPEC §8).
public struct Fact: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String?
    public var category: String
    public var kind: FactKind?
    public var provenance: Provenance
    public var state: FactState
    public var discoveredBy: DiscoveredBy?
    public var raw: RawReading?
    public var source: FactSource?
    public var reasoning: String?
    /// One-sentence plain-English meaning from the inventory. Not exported (the schema is strict);
    /// carried for the UI.
    public var description: String?
    /// The inventory's `security_relevant` flag. Not exported; drives the headline view.
    public var securityRelevant: Bool

    enum CodingKeys: String, CodingKey {
        case id, category, kind, provenance, state, raw, source, reasoning
        case displayName = "display_name"
        case discoveredBy = "discovered_by"
    }

    public init(id: String, displayName: String?, category: String, kind: FactKind?, provenance: Provenance, state: FactState,
                discoveredBy: DiscoveredBy? = nil, raw: RawReading? = nil, source: FactSource? = nil, reasoning: String? = nil,
                description: String? = nil, securityRelevant: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.kind = kind
        self.provenance = provenance
        self.state = state
        self.discoveredBy = discoveredBy
        self.raw = raw
        self.source = source
        self.reasoning = reasoning
        self.description = description
        self.securityRelevant = securityRelevant
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        category = try c.decode(String.self, forKey: .category)
        kind = try c.decodeIfPresent(FactKind.self, forKey: .kind)
        provenance = try c.decode(Provenance.self, forKey: .provenance)
        state = try c.decode(FactState.self, forKey: .state)
        discoveredBy = try c.decodeIfPresent(DiscoveredBy.self, forKey: .discoveredBy)
        raw = try c.decodeIfPresent(RawReading.self, forKey: .raw)
        source = try c.decodeIfPresent(FactSource.self, forKey: .source)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        description = nil
        securityRelevant = false
    }

    /// State for a measured reading given the key's kind (SPEC §4.1).
    public static func state(for outcome: ProbeOutcome, kind: FactKind) -> FactState {
        switch outcome {
        case .value:
            if kind == .flag {
                // A flag whose bytes do not decode as an integer (width mismatch) is an error,
                // never a confident "not present".
                guard let set = outcome.flagIsSet else { return .error }
                return set ? .present : .notPresent
            }
            return .value
        case .absent: return .keyAbsent
        case .restricted: return .restricted
        case .notApplicable: return .notApplicable
        case .error: return .error
        }
    }
}
