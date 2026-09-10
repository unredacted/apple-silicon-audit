import Foundation
import Testing
@testable import SiliconAuditCore

/// Fixture-driven tests of the annotated report, using the recorded Mac17,7 dump through
/// the same `TextDumpSysctl` the CLI's `--fixture` uses.
@Suite("Report from the Mac17,7 fixture")
struct ReportTests {
    static let data = try! DataStore.bundled()
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Mac17,7-25G83.txt")

    static func auditor(walkRefused: Bool = false, restricted: Set<String> = []) throws -> Auditor {
        let sysctl = try TextDumpSysctl(contentsOf: fixtureURL, inventory: data.knownKeys, options: .init(walkRefused: walkRefused, restricted: restricted))
        return Auditor(sysctl: sysctl, data: data)
    }

    @Test("data files decode and cover every key the Mac exposes")
    func dataFiles() throws {
        #expect(Self.data.knownKeys.entries.count > 130)
        #expect(Self.data.capsBits.capBitNB == 92)
        #expect(Self.data.matrix.entries.count == 10)
        #expect(Self.data.socMap.entry(for: "T8150")?.socName == "Apple A19 Pro")
        #expect(Self.data.cpufamilies.familyName(forHex: "0xf76c5b1a") == "CPUFAMILY_ARM_SOTRA")
        let walk = MIBWalker(sysctl: try Self.auditor().sysctl).walk()
        let known = Set(Self.data.knownKeys.keys)
        let unknown = walk.keys.map(\.name).filter { !known.contains($0) }
        #expect(unknown.isEmpty, "unannotated keys in the Mac dump: \(unknown)")
    }

    @Test("M5 Mac: EMTE profile measured, MIE documented present, identity resolved")
    func m5Report() throws {
        let report = try Self.auditor().report(from: try Self.auditor().rawAudit(now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(report.collection.walkSucceeded)
        #expect(!report.collection.kernelFormatsAvailable, "a text dump has no OIDFMT")
        #expect(report.device.identity == "Mac17,7")
        #expect(report.device.hwMachine == "arm64")
        #expect(report.device.socId == "T6050")
        #expect(report.device.socInferenceConfidence == "verified")
        #expect(report.device.cpufamily == "0xf76c5b1a")
        #expect(report.device.cpufamilyName == "CPUFAMILY_ARM_SOTRA")
        #expect(report.environment.isVirtualMachine == false)

        func fact(_ id: String) -> Fact? { report.facts.first { $0.id == id } }
        #expect(fact("arm.FEAT_MTE4")?.state == .present)
        #expect(fact("arm.FEAT_MTE3")?.state == .notPresent)
        #expect(fact("arm.FEAT_MTE_ASYNC")?.state == .notPresent)
        #expect(fact("arm.FEAT_MTE4")?.provenance == .measured)
        #expect(fact("arm.FEAT_MTE4")?.discoveredBy == .both)
        #expect(fact("arm.FEAT_MTE4")?.raw?.formatSource == "inventory")
        #expect(fact("arm.caps")?.state == .value, "a bitmask is never present/not_present")
        #expect(fact("arm.caps")?.raw?.length == 12)
        #expect(fact("arm.caps")?.raw?.valueHex == "ffefffffd77ffebfdb030008")
        #expect(fact("breakpoint")?.state == .value)
        #expect(fact("x86_64")?.state == .keyAbsent, "sysctl(8) text dumps omit ENOTSUP keys")
        #expect(fact("vm.mte.tagged")?.state == .value)
        #expect(fact("hw.product")?.state == .value)

        let caps = try #require(report.capabilities)
        #expect(caps.popcount == 67)
        #expect(caps.namedBits.count == 64)
        #expect(caps.unnamedBits == [38, 39, 59])
        #expect(caps.mismatches.isEmpty)
        #expect(fact("caps.consistency")?.state == .present)
        #expect(fact("caps.consistency")?.provenance == .inferred)

        #expect(fact("mie")?.provenance == .documented)
        #expect(fact("mie")?.state == .present)
        #expect(fact("sptm")?.state == .present)
        #expect(fact("ppl")?.state == .notPresent)
        #expect(fact("tce")?.state == .unknown)
        #expect(fact("mie")?.source?.published == "2025-09-09" || fact("mie")?.source?.published == "2026-01-28")
        #expect(fact("soc.identity")?.state == .present)
        #expect(fact("soc.identity")?.reasoning?.contains("T6050") == true)
    }

    @Test("refused walk (iOS-like): facts still come from by-name reads, walk_succeeded false")
    func refusedWalk() throws {
        let a = try Self.auditor(walkRefused: true, restricted: ["vm.mte.tagged", "vm.mte.cell.active", "vm.mte.tag_storage.activations"])
        let report = a.audit()
        #expect(!report.collection.walkSucceeded)
        #expect(report.collection.walkFailure?.contains("errno") == true)
        #expect(report.unrecognizedKeys.isEmpty)
        let mte4 = report.facts.first { $0.id == "arm.FEAT_MTE4" }
        #expect(mte4?.state == .present)
        #expect(mte4?.discoveredBy == .knownList)
        #expect(report.facts.first { $0.id == "vm.mte.tagged" }?.state == .restricted)
        #expect(report.capabilities?.popcount == 67, "caps still decodes from the by-name read")
    }

    @Test("unknown SoC: documented rows all unknown with the reason in the note")
    func unknownSoC() throws {
        let text = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
            .replacingOccurrences(of: "RELEASE_ARM64_T6050", with: "RELEASE_ARM64_T8320")
        let sysctl = TextDumpSysctl(text: text, inventory: Self.data.knownKeys)
        let report = Auditor(sysctl: sysctl, data: Self.data).audit()
        #expect(report.device.socId == "T8320")
        #expect(report.device.socInferenceConfidence == "none")
        let documented = report.documentedFacts
        #expect(!documented.isEmpty)
        #expect(documented.allSatisfy { $0.state == .unknown })
        #expect(documented.first?.source?.note?.contains("T8320") == true)
        #expect(report.facts.first { $0.id == "soc.identity" }?.state == .unknown)
    }

    @Test("a key the inventory does not know lands in unrecognized_keys as a measured fact")
    func unrecognized() throws {
        let text = try String(contentsOf: Self.fixtureURL, encoding: .utf8) + "\nhw.optional.arm.FEAT_XYZ: 1\n"
        let report = Auditor(sysctl: TextDumpSysctl(text: text, inventory: Self.data.knownKeys), data: Self.data).audit()
        let u = try #require(report.unrecognizedKeys.first { $0.raw?.key == "hw.optional.arm.FEAT_XYZ" })
        #expect(u.provenance == .measured)
        #expect(u.discoveredBy == .walk)
        #expect(u.kind == .unknown)
        #expect(u.state == .value)
        #expect(u.category == "unrecognized")
        #expect(u.displayName == "hw.optional.arm.FEAT_XYZ")
    }

    @Test("no forbidden key is ever read or exported")
    func forbidden() throws {
        let auditor = try Self.auditor()
        for k in Auditor.forbiddenKeys { #expect(!auditor.namedKeys.contains(k)) }
        let report = auditor.audit()
        let keys = (report.facts + report.unrecognizedKeys).compactMap { $0.raw?.key }
        for k in Auditor.forbiddenKeys { #expect(!keys.contains(k)) }
        #expect(!Self.data.knownKeys.keys.contains { Auditor.forbiddenKeys.contains($0) })
    }
}

@Suite("Export round trips")
struct ExportTests {
    @Test("full JSON encodes with the schema's field names and decodes back equal")
    func jsonRoundTrip() throws {
        let report = try ReportTests.auditor().audit(now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try report.jsonData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["schema_version", "app_version", "collected_at", "collection", "environment", "device", "facts", "unrecognized_keys"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        let env = try #require(object["environment"] as? [String: Any])
        #expect(env["is_ios_app_on_mac"] != nil)
        #expect(env["is_virtual_machine"] != nil)
        let dev = try #require(object["device"] as? [String: Any])
        #expect(dev["identity"] as? String == "Mac17,7")
        #expect(dev["hw_product"] as? String == "Mac17,7")
        let facts = try #require(object["facts"] as? [[String: Any]])
        let mte = try #require(facts.first { $0["id"] as? String == "arm.FEAT_MTE4" })
        #expect(mte["display_name"] != nil)
        #expect(mte["discovered_by"] as? String == "both")
        let raw = try #require(mte["raw"] as? [String: Any])
        #expect(raw["format_source"] as? String == "inventory")
        #expect(raw["value"] as? Int == 1)
        #expect(object["collected_at"] as? String == "2027-01-15T08:00:00Z")

        // `description` is UI-only and never exported; compare with it stripped.
        var exported = report
        exported.facts = report.facts.map { var f = $0; f.description = nil; return f }
        exported.unrecognizedKeys = report.unrecognizedKeys.map { var f = $0; f.description = nil; return f }
        let decoded = try Report.decode(data)
        #expect(decoded == exported)
    }

    @Test("compact variant keeps only measured facts and drops display names")
    func compactVariant() throws {
        let report = try ReportTests.auditor().audit()
        let compact = report.compact()
        #expect(compact.variant == "compact")
        #expect(compact.facts.allSatisfy { $0.provenance == .measured })
        #expect(compact.facts.allSatisfy { $0.displayName == nil })
        #expect(compact.facts.count == report.measuredFacts.filter { Report.compactCategories.contains($0.category) }.count)
        #expect(compact.facts.contains { $0.id == "arm.FEAT_MTE4" })
        #expect(compact.facts.contains { $0.id == "hw.product" })
        #expect(!compact.facts.contains { $0.id == "arm.FEAT_SHA3" }, "ISA rows are full-export only")
        #expect(!report.facts.filter { $0.provenance == .documented }.isEmpty, "the full report still has documented facts")
    }

    @Test("compact export round-trips through deflate + Base45 and is QR-sized")
    func compactWire() throws {
        let report = try ReportTests.auditor().audit(now: Date(timeIntervalSince1970: 1_800_000_000))
        let text = try CompactExport.encode(report)
        #expect(text.allSatisfy { Base45.index[$0] != nil })
        #expect(text.count < 3300, "QR version 40 at error-correction M holds 3391 alphanumeric characters; got \(text.count)")
        let back = try CompactExport.decode(text)
        #expect(back == report.compact())
    }

    @Test("Base45 matches the RFC 9285 vectors")
    func base45Vectors() throws {
        #expect(Base45.encode(Data("AB".utf8)) == "BB8")
        #expect(Base45.encode(Data("Hello!!".utf8)) == "%69 VD92EX0")
        #expect(Base45.encode(Data("base-45".utf8)) == "UJCLQE7W581")
        #expect(Base45.encode(Data("ietf!".utf8)) == "QED8WEX0")
        #expect(try Base45.decode("QED8WEX0") == Data("ietf!".utf8))
        #expect(throws: CompactExport.Error.invalidBase45) { try Base45.decode("GGW") }
        #expect(throws: CompactExport.Error.invalidBase45) { try Base45.decode("A") }
    }
}
