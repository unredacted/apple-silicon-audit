import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("Bundled data files")
struct BundledDataTests {
    @Test("every data file is present and has a valid header", arguments: BundledData.File.allCases)
    func manifestLoads(file: BundledData.File) throws {
        let manifest = try BundledData.manifest(for: file)
        #expect(manifest.schemaVersion == "1")
        #expect(isCalendarDate(manifest.version))
        #expect(isCalendarDate(manifest.verified))
    }

    @Test("data files are valid JSON objects with an entries array")
    func entriesArrayPresent() throws {
        for file in BundledData.File.allCases {
            let object = try JSONSerialization.jsonObject(with: BundledData.data(for: file))
            let dict = try #require(object as? [String: Any])
            #expect(dict["entries"] is [Any], "\(file.rawValue) lacks an entries array")
        }
    }

    private func isCalendarDate(_ s: String) -> Bool {
        s.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }
}
