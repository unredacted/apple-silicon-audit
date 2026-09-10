import Foundation
import SiliconAuditCore

/// The M0 feasibility spike's payload: the raw engine result flattened into strings
/// so it can be shown on a watch, saved as JSON, and shipped to the phone.
/// Temporary; replaced by the annotated `Report` in Phase 3.
struct SpikeReport: Codable, Equatable, Sendable {
    struct KeyLine: Codable, Equatable, Sendable, Identifiable {
        let key: String
        let result: String
        var id: String { key }
    }

    // Where it ran
    var platform: String
    var arch: String
    var osVersion: String
    var osBuild: String
    var kernelVersion: String
    var socID: String?
    var isSimulator: Bool
    var isTranslated: Bool
    var isiOSAppOnMac: Bool
    var collectedAt: Date

    // Identity
    var hwProduct: String?
    var hwMachine: String?
    var hwModel: String?
    var hwTarget: String?
    var cpufamilyHex: String?

    // The M0 questions
    var walkSucceeded: Bool
    var walkFailure: String?
    var keyCount: Int
    var maskedCount: Int
    var unnamedCount: Int
    var notApplicableCount: Int
    var restrictedCount: Int
    var restrictedKeys: [String]
    var capsLength: Int?
    var capsHex: String?

    var memoryTagging: [KeyLine]
    var osTagging: [KeyLine]
    var walked: [KeyLine]

    init(_ r: RawAuditResult) {
        let env = r.environment
        platform = env.platform.rawValue
        arch = env.arch.rawValue
        osVersion = env.osVersion
        osBuild = env.osBuild
        kernelVersion = env.kernelVersion
        socID = SpikeReport.socID(from: env.kernelVersion)
        isSimulator = env.isSimulator
        isTranslated = env.isTranslated
        isiOSAppOnMac = env.isiOSAppOnMac
        collectedAt = r.collectedAt

        hwProduct = r.namedReads["hw.product"]?.value?.payload.stringValue
        hwMachine = r.namedReads["hw.machine"]?.value?.payload.stringValue
        hwModel = r.namedReads["hw.model"]?.value?.payload.stringValue
        hwTarget = r.namedReads["hw.target"]?.value?.payload.stringValue
        cpufamilyHex = r.namedReads["hw.cpufamily"]?.value?.payload.integerValue
            .map { String(format: "0x%08x", UInt32(bitPattern: Int32(truncatingIfNeeded: $0))) }

        walkSucceeded = r.walk.succeeded
        walkFailure = r.walk.failure
        keyCount = r.walk.keys.count
        maskedCount = r.walk.keys.filter(\.isMasked).count
        unnamedCount = r.walk.unnamedOIDCount
        notApplicableCount = r.notApplicableCount
        restrictedCount = r.restrictedCount
        restrictedKeys = r.walk.keys.filter { $0.outcome == .restricted }.map(\.name)
            + r.namedReads.filter { $0.value == .restricted }.map(\.key).sorted()
        let caps = r.outcome(for: "hw.optional.arm.caps")?.value
        capsLength = caps?.length
        capsHex = caps?.hex

        let mteKeys = Auditor.namedKeys.filter { $0.hasPrefix("hw.optional.arm.FEAT_MTE") || $0 == "hw.optional.arm.caps" }
        memoryTagging = mteKeys.map { KeyLine(key: $0, result: SpikeReport.describe(r.outcome(for: $0))) }
        let vmKeys = Auditor.namedKeys.filter { $0.hasPrefix("vm.mte.") }
        osTagging = vmKeys.map { KeyLine(key: $0, result: SpikeReport.describe(r.outcome(for: $0))) }
        walked = r.walk.keys.map { KeyLine(key: $0.name, result: SpikeReport.describe($0.outcome) + ($0.isMasked ? " [masked]" : "")) }
    }

    /// One-line answers to the M0 checklist, in checklist order.
    var verdict: [String] {
        var lines: [String] = []
        lines.append(walkSucceeded ? "Walk: OK, \(keyCount) keys under hw.optional" : "Walk: FAILED — \(walkFailure ?? "unknown")")
        let armReadable = walked.filter { $0.key.hasPrefix("hw.optional.arm.") && !$0.result.hasPrefix("restricted") }.count
        lines.append("hw.optional.arm.* readable: \(armReadable > 0 ? "yes (\(armReadable))" : "NO")")
        lines.append("Restricted reads: \(restrictedCount)")
        lines.append("Not applicable (other arch): \(notApplicableCount)")
        if let capsLength { lines.append("caps length: \(capsLength) bytes") } else { lines.append("caps: not read") }
        lines.append("hw.product: \(hwProduct ?? "absent")")
        lines.append("vm.mte.tagged: \(osTagging.first(where: { $0.key == "vm.mte.tagged" })?.result ?? "-")")
        if let socID { lines.append("SoC id from kern.version: \(socID)") }
        if isSimulator || isTranslated || isiOSAppOnMac {
            lines.append("WARNING: simulator/translated/iOS-on-Mac — values describe the host")
        }
        return lines
    }

    var fileStem: String {
        "spike-\(platform)-\(hwProduct ?? "unknown")-\(osBuild.isEmpty ? "nobuild" : osBuild)"
    }

    static func socID(from kernelVersion: String) -> String? {
        guard let range = kernelVersion.range(of: #"RELEASE_ARM64_(T\d+)"#, options: .regularExpression) else { return nil }
        return kernelVersion[range].split(separator: "_").last.map(String.init)
    }

    static func describe(_ outcome: ProbeOutcome?) -> String {
        switch outcome {
        case nil: return "-"
        case .absent: return "absent (ENOENT)"
        case .restricted: return "restricted (EPERM/EACCES)"
        case .notApplicable: return "not applicable (ENOTSUP)"
        case .error(let e): return "error errno=\(e)"
        case .value(let v):
            let type = v.format?.typeName ?? "?"
            switch v.payload {
            case .int(let n): return "\(n) [\(type), \(v.length)B]"
            case .uint(let n): return "\(n) [\(type), \(v.length)B]"
            case .string(let s): return "\"\(s)\" [\(type), \(v.length)B]"
            case .bytes: return "0x\(v.hex) [\(type), \(v.length)B]"
            }
        }
    }
}

/// Runs the engine and persists spike reports in the app's Documents directory,
/// where `devicectl device copy from` can fetch them for the evidence files.
enum SpikeStore {
    static func run() -> SpikeReport {
        SpikeReport(Auditor().rawAudit())
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    static func save(_ report: SpikeReport, name: String? = nil) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = documents.appendingPathComponent("\(name ?? report.fileStem).json")
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    static func load(_ url: URL) throws -> SpikeReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SpikeReport.self, from: Data(contentsOf: url))
    }

    static func savedReports() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}
