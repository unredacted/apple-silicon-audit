import Foundation

/// `documented-matrix.json`: Apple's published chip-family claims (SPEC §5).
public struct DocumentedMatrix: Decodable, Sendable {
    /// A chip, from some OS version on, where Apple's own firmware contradicts the table
    /// (it boots a monitor the table says the chip lacks). The table stays the source; the
    /// claim reads `unknown` there, with the evidence in the note.
    public struct Exception: Decodable, Sendable, Equatable {
        public let socIds: [String]
        /// First marketing version the exception applies to, e.g. "27.0".
        public let minOSVersion: String
        public let note: String

        enum CodingKeys: String, CodingKey {
            case note
            case socIds = "soc_ids"
            case minOSVersion = "min_os_version"
        }

        public init(socIds: [String], minOSVersion: String, note: String) {
            self.socIds = socIds
            self.minOSVersion = minOSVersion
            self.note = note
        }

        /// An unreadable OS version can't rule the exception out, so it applies.
        func applies(socId: String?, osVersion: String?) -> Bool {
            guard let socId, socIds.contains(socId) else { return false }
            guard var os = Self.components(osVersion), var min = Self.components(minOSVersion) else { return true }
            let width = max(os.count, min.count)   // "27" is "27.0"
            os += Array(repeating: 0, count: width - os.count)
            min += Array(repeating: 0, count: width - min.count)
            return !os.lexicographicallyPrecedes(min)
        }

        static func components(_ version: String?) -> [Int]? {
            guard let parts = version?.split(separator: ".").map({ Int($0) }), !parts.isEmpty,
                  !parts.contains(nil) else { return nil }
            return parts.compactMap { $0 }
        }
    }

    public struct Entry: Decodable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let category: String
        /// False for claims Apple makes but does not tabulate per chip: always `unknown`.
        public let tabulated: Bool
        public let columnsPresent: [String]
        public let description: String
        public let source: FactSource
        public let exceptions: [Exception]

        enum CodingKeys: String, CodingKey {
            case id, category, tabulated, description, source, exceptions
            case displayName = "display_name"
            case columnsPresent = "columns_present"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            displayName = try c.decode(String.self, forKey: .displayName)
            category = try c.decode(String.self, forKey: .category)
            tabulated = try c.decode(Bool.self, forKey: .tabulated)
            columnsPresent = try c.decode([String].self, forKey: .columnsPresent)
            description = try c.decode(String.self, forKey: .description)
            source = try c.decode(FactSource.self, forKey: .source)
            exceptions = try c.decodeIfPresent([Exception].self, forKey: .exceptions) ?? []
        }
    }

    public let schemaVersion: String
    public let version: String
    public let verified: String
    public let columns: [String]
    public let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case version, verified, columns, entries
        case schemaVersion = "schema_version"
    }

    public init(schemaVersion: String, version: String, verified: String, columns: [String], entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.verified = verified
        self.columns = columns
        self.entries = entries
    }

    /// Documented facts for a device whose SoC maps to `column` (nil when unmapped).
    /// The two-step chain (measured soc_id → inferred family → documented claim) is spelled
    /// out in the source note so the UI can show it (SPEC §5). `osVersion` selects the
    /// entries' exceptions.
    public func facts(forColumn column: String?, socId: String?, osVersion: String? = nil) -> [Fact] {
        entries.map { e in
            var source = e.source
            let state: FactState
            if !e.tabulated {
                state = .unknown
                source.note = [source.note, "Apple does not tabulate this per chip family."].compactMap { $0 }.joined(separator: " ")
            } else if let exception = e.exceptions.first(where: { $0.applies(socId: socId, osVersion: osVersion) }) {
                state = .unknown
                let chain = column.map { "Apple's table, via soc_id \(socId ?? "?") → column \($0), says \(e.columnsPresent.contains($0) ? "present" : "not present")." }
                source.note = [source.note, chain, exception.note].compactMap { $0 }.joined(separator: " ")
            } else if let column, columns.contains(column) {
                state = e.columnsPresent.contains(column) ? .present : .notPresent
                source.note = [source.note, "Applied via soc_id \(socId ?? "?") → column \(column)."].compactMap { $0 }.joined(separator: " ")
            } else {
                state = .unknown
                let why = socId.map { "soc_id \($0) is not mapped to a column of Apple's table" } ?? "no soc_id could be measured"
                source.note = [source.note, "\(why); Apple has not documented this chip."].compactMap { $0 }.joined(separator: " ")
            }
            return Fact(id: e.id, displayName: e.displayName, category: e.category, kind: .claim, provenance: .documented,
                        state: state, source: source, description: e.description)
        }
    }
}
