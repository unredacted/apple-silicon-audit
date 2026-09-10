import Foundation

/// Package-level constants for the probe engine.
public enum SiliconAuditCore {
    /// App/engine version reported in exports (`app_version`).
    public static let version = "0.1.0"
}

/// Header shared by every bundled data file (known keys, caps bits, cpufamily names,
/// SoC map, documented matrix). Each file also has an `entries` array whose element
/// type is file-specific and decoded by its own loader.
public struct DataFileManifest: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    /// Date the data set was last changed, ISO-8601 calendar date.
    public let version: String
    /// Date a maintainer last verified the contents against the source, ISO-8601 calendar date.
    public let verified: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version
        case verified
    }
}

/// Access to the JSON data files bundled as SwiftPM resources.
public enum BundledData {
    /// Every data file the core expects to find in its resource bundle.
    public enum File: String, CaseIterable, Sendable {
        case knownKeys = "known-keys"
        case capsBits = "caps-bits"
        case cpufamilyNames = "cpufamily-names"
        case socMap = "soc-map"
        case documentedMatrix = "documented-matrix"
    }

    public enum Error: Swift.Error, Equatable {
        case missing(File)
    }

    /// URL of a bundled data file.
    public static func url(for file: File) throws -> URL {
        guard let url = Bundle.module.url(forResource: file.rawValue, withExtension: "json") else {
            throw Error.missing(file)
        }
        return url
    }

    /// Raw bytes of a bundled data file.
    public static func data(for file: File) throws -> Data {
        try Data(contentsOf: url(for: file))
    }

    /// Only the shared header of a data file.
    public static func manifest(for file: File) throws -> DataFileManifest {
        try JSONDecoder().decode(DataFileManifest.self, from: data(for: file))
    }
}
