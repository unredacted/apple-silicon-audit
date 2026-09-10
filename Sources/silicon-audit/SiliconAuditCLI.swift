import ArgumentParser
import Foundation
import SiliconAuditCore

/// `silicon-audit` — command-line front end for the probe engine (macOS).
@main
struct SiliconAuditCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silicon-audit",
        abstract: "Report which CPU security features this device's kernel exposes.",
        discussion: "Every fact carries its provenance: measured (read from this kernel), documented (Apple's published claim for the chip family), or inferred (the app's reasoning). The app never conflates them.",
        version: SiliconAuditCore.version,
        subcommands: [Audit.self, Documented.self, DataInfo.self, Export.self, Keys.self, Import.self, Raw.self],
        defaultSubcommand: Audit.self
    )
}

/// Options shared by every subcommand.
struct SourceOptions: ParsableArguments {
    @Option(name: .long, help: "Run against a recorded sysctl(8) text dump instead of this kernel (e.g. docs/evidence/Mac17,7-25G83.txt).")
    var fixture: String?

    @Flag(name: .long, help: "With --fixture: emulate a sandbox that refuses the MIB walk (iOS, watchOS).")
    var walkRefused = false

    func makeAuditor() throws -> Auditor {
        guard let fixture else { return Auditor() }
        let url = URL(fileURLWithPath: fixture)
        let sysctl = try TextDumpSysctl(contentsOf: url, inventory: DataStore.shared.knownKeys,
                                        options: .init(walkRefused: walkRefused))
        return Auditor(sysctl: sysctl)
    }
}

struct Audit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Human-readable audit grouped by category, with provenance.")

    @OptionGroup var source: SourceOptions
    @Flag(name: .long, help: "Include every category, not just the security-relevant ones.")
    var all = false
    @Flag(name: .long, help: "Emit the full JSON export instead of the table.")
    var json = false

    func run() throws {
        let report = try source.makeAuditor().audit()
        if json { print(String(decoding: try report.jsonData(), as: UTF8.self)); return }
        Table.print(report, all: all)
    }
}

struct Documented: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apple's published claims for this chip family, with the chain that gets there.")

    @OptionGroup var source: SourceOptions

    func run() throws {
        let report = try source.makeAuditor().audit()
        let dev = report.device
        print("1. measured   kernel target      \(dev.socId ?? "none")  (kern.version)")
        print("2. inferred   SoC                \(dev.socInferenceConfidence == "none" ? "not in soc-map.json" : "\(dev.socNameInferred) [\(dev.socInferenceConfidence)]")")
        let column = report.documentedFacts.first { $0.state != .unknown }?.source?.note
            .flatMap { n in n.range(of: #"column [A-Za-z0-9\-]+"#, options: .regularExpression).map { String(n[$0].dropFirst(7)) } }
        print("3. documented Apple's table column \(column ?? "none")")
        print("")
        if dev.socInferenceConfidence == "none" {
            print("Apple hasn't documented this chip yet: target \(dev.socId ?? "?") is not in the app's map. Documented rows read unknown; measured facts are unaffected.")
            print("")
        }
        for f in report.documentedFacts {
            print("  \(Table.glyph(f.state)) \((f.displayName ?? f.id).padding(toLength: 44, withPad: " ", startingAt: 0)) \(f.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(f.source?.note ?? "")")
        }
        if let s = report.documentedFacts.first?.source {
            print("")
            print("Source: \(s.url) (published \(s.published), verified \(s.verified))")
        }
    }
}

struct DataInfo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "data", abstract: "Bundled data files and when each was last verified.")

    func run() throws {
        let d = DataStore.shared
        func row(_ name: String, _ verified: String, _ detail: String) { print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(verified.isEmpty ? "-" : verified)  \(detail)") }
        row("known-keys", d.knownKeys.verified, "\(d.knownKeys.entries.count) annotated keys, \(d.knownKeys.entries.filter(\.securityRelevant).count) security-relevant")
        row("caps-bits", d.capsBits.verified, "\(d.capsBits.entries.count) bits, CAP_BIT_NB \(d.capsBits.capBitNB)")
        row("cpufamily-names", d.cpufamilies.verified, "\(d.cpufamilies.entries.count) families, \(d.cpufamilies.subfamilies.count) subfamilies")
        row("soc-map", d.socMap.verified, "\(d.socMap.entries.filter { $0.confidence == .verified }.count) verified, \(d.socMap.entries.filter { $0.confidence == .reported }.count) reported")
        row("documented-matrix", d.matrix.verified, "\(d.matrix.entries.count) rows × \(d.matrix.columns.count) columns: \(d.matrix.columns.joined(separator: ", "))")
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the JSON export (schema 1.x) to stdout or a file.")

    @OptionGroup var source: SourceOptions
    @Flag(name: .long, help: "Compact variant: measured facts only, deflate + Base45 text for QR codes.")
    var compact = false
    @Option(name: .shortAndLong, help: "Output path (default: stdout).")
    var output: String?

    func run() throws {
        let report = try source.makeAuditor().audit()
        let text = compact ? try CompactExport.encode(report) : String(decoding: try report.jsonData(), as: UTF8.self)
        if let output {
            try (text + "\n").write(toFile: output, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("wrote \(output) (\(text.utf8.count) bytes)\n".utf8))
        } else {
            print(text)
        }
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decode a compact (Base45) export back to JSON.")

    @Argument(help: "Base45 text, or a path to a file containing it. Reads stdin if omitted.")
    var input: String?

    func run() throws {
        var text = input ?? ""
        if text.isEmpty {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else if FileManager.default.fileExists(atPath: text) {
            text = try String(contentsOfFile: text, encoding: .utf8)
        }
        // Only line endings are stripped: a space is a Base45 digit and may legitimately begin or end the payload.
        let report = try CompactExport.decode(text.trimmingCharacters(in: .newlines))
        print(String(decoding: try report.jsonData(), as: UTF8.self))
    }
}

struct Keys: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List every key the walk found, annotated or not, with its reading.")

    @OptionGroup var source: SourceOptions

    func run() throws {
        let auditor = try source.makeAuditor()
        let raw = auditor.rawAudit()
        let known = DataStore.shared.knownKeys
        print("walk: succeeded=\(raw.walk.succeeded) keys=\(raw.walk.keys.count) notApplicable=\(raw.notApplicableCount) restricted=\(raw.restrictedCount)\(raw.walk.failure.map { " failure=\"\($0)\"" } ?? "")")
        for k in raw.walk.keys {
            let tag = known.entry(for: k.name) == nil ? "  [unrecognized]" : ""
            print("  \(k.name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(Table.describe(k.outcome))\(k.isMasked ? "  [masked]" : "")\(tag)")
        }
    }
}

struct Raw: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dump the unannotated by-name reads (engine development view).")

    @OptionGroup var source: SourceOptions

    func run() throws {
        let auditor = try source.makeAuditor()
        let result = auditor.rawAudit()
        let env = result.environment
        print("Environment: \(env.platform.rawValue) \(env.arch.rawValue), OS \(env.osVersion) (\(env.osBuild))")
        print("Kernel:      \(env.kernelVersion)")
        if env.isMisleading {
            print("WARNING:     simulator=\(env.isSimulator) translated=\(env.isTranslated) iOSAppOnMac=\(env.isiOSAppOnMac) virtualMachine=\(env.isVirtualMachine); values describe the host, not the device")
        }
        print("Walk:        root=\(result.walk.root) succeeded=\(result.walk.succeeded) keys=\(result.walk.keys.count) notApplicable=\(result.notApplicableCount) restricted=\(result.restrictedCount)")
        if let f = result.walk.failure { print("Walk failure: \(f)") }
        print("OIDFMT:      \(result.kernelFormatsAvailable ? "kernel-declared formats available" : "unavailable; types from inventory (*)")")
        print("")
        for key in auditor.namedKeys.sorted() {
            print("  \(key.padding(toLength: 46, withPad: " ", startingAt: 0)) \(Table.describe(result.namedReads[key]))")
        }
    }
}

enum Table {
    static func print(_ report: Report, all: Bool) {
        let env = report.environment, dev = report.device
        Swift.print("Silicon Audit \(report.appVersion) — \(dev.identity) · \(env.platform) \(env.osVersion) (\(env.osBuild)) · kernel target \(dev.socId ?? "?")")
        Swift.print("SoC (inferred, \(dev.socInferenceConfidence)): \(dev.socNameInferred) · cores: \(dev.cpufamilyName) \(dev.cpufamily ?? "")")
        if env.isMisleading {
            Swift.print("!! WARNING: simulator=\(env.isSimulator) translated=\(env.isTranslated) iOS-on-Mac=\(env.isiOSAppOnMac) VM=\(env.isVirtualMachine) — values describe the host, not the device")
        }
        Swift.print("Collection: walk \(report.collection.walkSucceeded ? "ok" : "failed (\(report.collection.walkFailure ?? "?"))") · kernel types \(report.collection.kernelFormatsAvailable ? "yes" : "no (inventory)") · inventory \(report.collection.knownKeysVersion ?? "unknown")")
        if let caps = report.capabilities {
            Swift.print("caps: \(caps.byteCount) bytes, \(caps.popcount) bits set (\(caps.namedBits.count) named, unnamed \(caps.unnamedBits)), mismatches \(caps.mismatches.count)")
        }
        let measuredPresent = report.securityFacts.filter { $0.provenance == .measured && $0.state == .present }.count
        let measuredFlags = report.securityFacts.filter { $0.provenance == .measured && $0.kind == .flag }.count
        Swift.print("Security flags reported present: \(measuredPresent) of \(measuredFlags)")
        Swift.print("")

        let categories = all ? Report.categoryOrder : Report.categoryOrder.filter { Report.securityCategories.contains($0) || $0 == "kernel_integrity" || $0 == "identity" }
        for category in categories {
            let facts = report.facts.filter { $0.category == category }
            guard !facts.isEmpty else { continue }
            Swift.print("[\(category)]")
            for f in facts {
                let name = (f.displayName ?? f.id).padding(toLength: 44, withPad: " ", startingAt: 0)
                Swift.print("  \(glyph(f.state)) \(name) \(f.state.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(tag(f.provenance))\(detail(f))")
            }
        }
        if !report.unrecognizedKeys.isEmpty {
            Swift.print("[unrecognized — new discoveries]")
            for f in report.unrecognizedKeys {
                Swift.print("  \(glyph(f.state)) \((f.displayName ?? f.id).padding(toLength: 44, withPad: " ", startingAt: 0)) \(f.state.rawValue)")
            }
        }
    }

    static func glyph(_ s: FactState) -> String {
        switch s {
        case .present: return "●"
        case .notPresent: return "○"
        case .value: return "◆"
        case .keyAbsent: return "–"
        case .restricted: return "⊘"
        case .notApplicable: return "×"
        case .error: return "!"
        case .unknown: return "?"
        }
    }

    static func tag(_ p: Provenance) -> String {
        switch p {
        case .measured: return "measured  "
        case .documented: return "documented"
        case .inferred: return "inferred  "
        case .unknown: return "unknown   "
        }
    }

    static func detail(_ f: Fact) -> String {
        if let r = f.raw {
            let star = r.formatSource == "inventory" ? "*" : ""
            if let v = r.value {
                let vs: String
                switch v { case .int(let i): vs = "\(i)"; case .uint(let u): vs = "\(u)"; case .string(let s): vs = "\"\(s)\"" }
                return "  \(vs) [\(r.format ?? "?")\(star), \(r.length)B]"
            }
            if let h = r.valueHex { return "  0x\(h) [\(r.format ?? "?")\(star), \(r.length)B]" }
            if let e = r.errno { return "  errno \(e)" }
        }
        if let s = f.source { return "  \(s.url) (published \(s.published), verified \(s.verified))" }
        if let r = f.reasoning { return "  \(r)" }
        return ""
    }

    static func describe(_ outcome: ProbeOutcome?) -> String {
        switch outcome {
        case nil: return "-"
        case .absent: return "absent (ENOENT)"
        case .restricted: return "restricted (EPERM/EACCES)"
        case .notApplicable: return "not applicable (ENOTSUP)"
        case .error(let e): return "error errno=\(e)"
        case .value(let v):
            let type = (v.format?.typeName ?? "?") + (v.format?.source == .inventory ? "*" : "")
            switch v.payload {
            case .int(let n): return "\(n)  [\(type), \(v.length)B]"
            case .uint(let n): return "\(n)  [\(type), \(v.length)B]"
            case .string(let s): return "\"\(s)\"  [\(type), \(v.length)B]"
            case .bytes: return "0x\(v.hex)  [\(type), \(v.length)B]"
            }
        }
    }
}
