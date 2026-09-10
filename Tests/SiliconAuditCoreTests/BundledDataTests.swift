import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("Bundled data files")
struct BundledDataTests {
    @Test("every data file is present and has a valid header", arguments: BundledData.File.allCases)
    func manifestLoads(file: BundledData.File) throws {
        let manifest = try BundledData.manifest(for: file)
        #expect(manifest.schemaVersion == "1")
        #expect(isCalendarDate(manifest.version), "\(file.rawValue) version '\(manifest.version)' is not a real date")
        #expect(isCalendarDate(manifest.verified), "\(file.rawValue) verified '\(manifest.verified)' is not a real date")
    }

    @Test("data files are valid JSON objects with an entries array")
    func entriesArrayPresent() throws {
        for file in BundledData.File.allCases {
            let object = try JSONSerialization.jsonObject(with: BundledData.data(for: file))
            let dict = try #require(object as? [String: Any])
            #expect(dict["entries"] is [Any], "\(file.rawValue) lacks an entries array")
        }
    }

    @Test("the date check rejects well-shaped nonsense", arguments: ["2026-99-40", "2026-02-30", "2026-00-10", "2026-9-1", "20260910", "2026-09-10T00:00:00Z"])
    func rejectsInvalidDates(_ s: String) {
        #expect(!isCalendarDate(s))
    }

    @Test("the date check accepts real dates", arguments: ["2026-09-10", "2024-02-29", "2025-12-31"])
    func acceptsValidDates(_ s: String) {
        #expect(isCalendarDate(s))
    }

    /// Strict ISO-8601 calendar date: shape, real month/day, and exact round-trip
    /// so "2026-02-30" cannot slip through as March 2.
    private func isCalendarDate(_ s: String) -> Bool {
        guard s.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: s) else { return false }
        return formatter.string(from: date) == s
    }
}
