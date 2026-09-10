import Foundation

/// `documented-matrix.json`: Apple's published chip-family claims (SPEC §5).
public struct DocumentedMatrix: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let category: String
        /// False for claims Apple makes but does not tabulate per chip: always `unknown`.
        public let tabulated: Bool
        public let columnsPresent: [String]
        public let description: String
        public let source: FactSource

        enum CodingKeys: String, CodingKey {
            case id, category, tabulated, description, source
            case displayName = "display_name"
            case columnsPresent = "columns_present"
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
    /// out in the source note so the UI can show it (SPEC §5).
    public func facts(forColumn column: String?, socId: String?) -> [Fact] {
        entries.map { e in
            var source = e.source
            let state: FactState
            if !e.tabulated {
                state = .unknown
                source.note = [source.note, "Apple does not tabulate this per chip family."].compactMap { $0 }.joined(separator: " ")
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
