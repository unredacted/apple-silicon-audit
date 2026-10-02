import Foundation
import Testing
@testable import SiliconAuditCore

/// The bundled table against Apple's guide, and the exceptions where Apple's firmware disagrees
/// with it (docs/evidence/sptm-txm-firmware.md).
@Suite("Documented matrix")
struct DocumentedMatrixTests {
    static let matrix = try! DataStore.bundled().matrix

    func state(_ id: String, column: String?, soc: String?, os: String?) -> FactState? {
        Self.matrix.facts(forColumn: column, socId: soc, osVersion: os).first { $0.id == id }?.state
    }

    @Test("PPL follows the guide's seven-column table: A11 through A14, S4-S10 and M1, replaced by SPTM from A15")
    func pplRow() {
        #expect(state("ppl", column: "A11-S3", soc: nil, os: nil) == .present)
        #expect(state("ppl", column: "M1", soc: "T8103", os: "26.6.2") == .present)
        #expect(state("ppl", column: "A15-A18", soc: "T8110", os: "27.0") == .notPresent)
        #expect(state("ppl", column: "M2-M4", soc: "T8112", os: "27.0") == .notPresent)
    }

    @Test("A13, A14, M1 on 27: SPTM and PPL unknown, with Apple's table and the firmware evidence in the note",
          arguments: [("T8030", "A12-A14"), ("T8101", "A12-A14"), ("T8103", "M1")])
    func backport27(soc: String, column: String) throws {
        let facts = Self.matrix.facts(forColumn: column, socId: soc, osVersion: "27.0.1")
        let sptm = try #require(facts.first { $0.id == "sptm" })
        #expect(sptm.state == .unknown)
        #expect(sptm.provenance == .documented)
        #expect(sptm.source?.note?.contains("column \(column), says not present") == true)
        #expect(sptm.source?.note?.contains("Ap,SecurePageTableMonitor") == true)
        #expect(facts.first { $0.id == "ppl" }?.state == .unknown)
        #expect(facts.first { $0.id == "kip" }?.state == .present, "rows without exceptions keep Apple's answer")
    }

    @Test("before 27 the same chips read Apple's table")
    func before27() {
        #expect(state("sptm", column: "A12-A14", soc: "T8030", os: "26.6.2") == .notPresent)
        #expect(state("ppl", column: "A12-A14", soc: "T8101", os: "26.6.2") == .present)
    }

    @Test("A12 shares the column but gets no OS 27, so it keeps Apple's answer")
    func a12() {
        #expect(state("sptm", column: "A12-A14", soc: "T8020", os: "27.0") == .notPresent)
    }

    @Test("M1 Pro, Max, Ultra: unknown from macOS 26.4, Apple's table before")
    func m1ProFamily() {
        for soc in ["T6000", "T6001", "T6002"] {
            #expect(state("sptm", column: "M1", soc: soc, os: "26.4") == .unknown)
            #expect(state("sptm", column: "M1", soc: soc, os: "26.3.1") == .notPresent)
            #expect(state("ppl", column: "M1", soc: soc, os: "26.3.1") == .present)
        }
    }

    @Test("S9/S10: unknown from watchOS 10.1 (firmware boots SPTM by 26.3), Apple's table through 10.0.2; S6-S8 unaffected")
    func s9() {
        #expect(state("sptm", column: "S4-S10", soc: "T8310", os: "26.3") == .unknown)
        #expect(state("sptm", column: "S4-S10", soc: "T8310", os: "27.0.1") == .unknown)
        #expect(state("ppl", column: "S4-S10", soc: "T8310", os: "26.6") == .unknown)
        #expect(state("sptm", column: "S4-S10", soc: "T8310", os: "10.0.2") == .notPresent)
        #expect(state("ppl", column: "S4-S10", soc: "T8310", os: "10.0.2") == .present)
        #expect(state("sptm", column: "S4-S10", soc: "T8301", os: "26.6") == .notPresent)
        #expect(state("ppl", column: "S4-S10", soc: "T8301", os: "26.6") == .present)
    }

    @Test("version comparison: shorter versions pad with zeros, an unreadable version cannot rule an exception out")
    func versions() {
        #expect(state("sptm", column: "A12-A14", soc: "T8030", os: "27") == .unknown)
        #expect(state("sptm", column: "A12-A14", soc: "T8030", os: "26.99") == .notPresent)
        #expect(state("sptm", column: "A12-A14", soc: "T8030", os: "") == .unknown)
        #expect(state("sptm", column: "A12-A14", soc: "T8030", os: nil) == .unknown)
    }
}
