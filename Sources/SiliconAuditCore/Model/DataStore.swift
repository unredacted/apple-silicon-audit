import Foundation

/// The five bundled data files, decoded. Loaded once from `Bundle.module`; tests can build
/// one from fixtures. Everything the engine says beyond raw readings comes from here, so
/// each file's `version`/`verified` dates travel into the export and the UI.
public struct DataStore: Sendable {
    public let knownKeys: KnownKeyInventory
    public let capsBits: CapsBitTable
    public let cpufamilies: CPUFamilyTable
    public let socMap: SoCMap
    public let matrix: DocumentedMatrix

    public init(knownKeys: KnownKeyInventory, capsBits: CapsBitTable, cpufamilies: CPUFamilyTable, socMap: SoCMap, matrix: DocumentedMatrix) {
        self.knownKeys = knownKeys
        self.capsBits = capsBits
        self.cpufamilies = cpufamilies
        self.socMap = socMap
        self.matrix = matrix
    }

    /// Decodes all five files from the resource bundle.
    public static func bundled() throws -> DataStore {
        let decoder = JSONDecoder()
        return DataStore(
            knownKeys: try decoder.decode(KnownKeyInventory.self, from: BundledData.data(for: .knownKeys)),
            capsBits: try decoder.decode(CapsBitTable.self, from: BundledData.data(for: .capsBits)),
            cpufamilies: try decoder.decode(CPUFamilyTable.self, from: BundledData.data(for: .cpufamilyNames)),
            socMap: try decoder.decode(SoCMap.self, from: BundledData.data(for: .socMap)),
            matrix: try decoder.decode(DocumentedMatrix.self, from: BundledData.data(for: .documentedMatrix))
        )
    }

    /// The bundled store, or an empty one if the bundle is unreadable (never crashes a probe).
    public static let shared: DataStore = (try? bundled()) ?? .empty

    public static let empty = DataStore(
        knownKeys: KnownKeyInventory(schemaVersion: "1", version: "", verified: "", entries: []),
        capsBits: CapsBitTable(schemaVersion: "1", version: "", verified: "", capBitNB: 0, entries: []),
        cpufamilies: CPUFamilyTable(schemaVersion: "1", version: "", verified: "", entries: [], subfamilies: []),
        socMap: SoCMap(schemaVersion: "1", version: "", verified: "", entries: []),
        matrix: DocumentedMatrix(schemaVersion: "1", version: "", verified: "", columns: [], entries: [])
    )
}
