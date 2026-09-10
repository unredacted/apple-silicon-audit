import Foundation
import Observation
import SiliconAuditCore

/// Drives the audit UI: runs the engine off the main actor, exposes the report grouped the
/// way SPEC §6.4 asks (summary first, headline categories first), and hands out export files.
@MainActor
@Observable
public final class ReportModel {
    public enum Phase: Equatable {
        case idle
        case running
        case loaded(Report)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public var report: Report? {
        if case .loaded(let r) = phase { return r }
        return nil
    }

    private let makeAuditor: @Sendable () -> Auditor

    public init(auditor: @escaping @Sendable () -> Auditor = { Auditor() }) {
        self.makeAuditor = auditor
    }

    /// Convenience for previews and tests: a model already holding a report.
    public init(report: Report) {
        self.makeAuditor = { Auditor() }
        self.phase = .loaded(report)
    }

    public func run() async {
        phase = .running
        let make = makeAuditor
        let report = await Task.detached(priority: .userInitiated) { make().audit() }.value
        phase = .loaded(report)
    }

    // MARK: - Grouping

    public struct Section: Identifiable, Equatable {
        public let category: String
        public let facts: [Fact]
        public var id: String { category }
        public var title: String { ReportModel.title(for: category) }
        public var isSecurity: Bool { Report.securityCategories.contains(category) || category == "kernel_integrity" }
    }

    /// Sections in SPEC §4.3 order; empty categories omitted; `unrecognized_keys` appended last.
    public var sections: [Section] {
        guard let report else { return [] }
        var sections: [Section] = Report.categoryOrder.compactMap { category in
            let facts = report.facts.filter { $0.category == category }
            return facts.isEmpty ? nil : Section(category: category, facts: facts)
        }
        let known = Set(Report.categoryOrder)
        for category in Set(report.facts.map(\.category)).subtracting(known).sorted() {
            sections.append(Section(category: category, facts: report.facts.filter { $0.category == category }))
        }
        if !report.unrecognizedKeys.isEmpty {
            sections.append(Section(category: "unrecognized", facts: report.unrecognizedKeys))
        }
        return sections
    }

    public var securitySections: [Section] { sections.filter(\.isSecurity) }
    public var otherSections: [Section] { sections.filter { !$0.isSecurity } }

    /// "N of M security flags reported present" for the summary card.
    public var securitySummary: (present: Int, total: Int) {
        guard let report else { return (0, 0) }
        let flags = report.securityFacts.filter { $0.provenance == .measured && $0.kind == .flag }
        return (flags.filter { $0.state == .present }.count, flags.count)
    }

    public nonisolated static func title(for category: String) -> String {
        switch category {
        case "memory_tagging": return String(localized: "Memory tagging", bundle: .module)
        case "os_memory_tagging": return String(localized: "OS memory-tagging activity", bundle: .module)
        case "pointer_authentication": return String(localized: "Pointer authentication", bundle: .module)
        case "control_flow": return String(localized: "Control flow", bundle: .module)
        case "speculation": return String(localized: "Speculation and side channels", bundle: .module)
        case "constant_time": return String(localized: "Constant-time execution", bundle: .module)
        case "capability_bitmask": return String(localized: "Capability bitmask", bundle: .module)
        case "kernel_integrity": return String(localized: "Apple's documented protections", bundle: .module)
        case "identity": return String(localized: "Chip identity (inferred)", bundle: .module)
        case "legacy_alias": return String(localized: "Legacy key names", bundle: .module)
        case "isa_crypto": return String(localized: "Cryptography instructions", bundle: .module)
        case "isa_simd": return String(localized: "SIMD and floating point", bundle: .module)
        case "isa_sme": return String(localized: "Scalable Matrix Extension", bundle: .module)
        case "isa_misc": return String(localized: "Other ISA features", bundle: .module)
        case "debug": return String(localized: "Debug hardware", bundle: .module)
        case "x86_isa": return String(localized: "x86 feature table", bundle: .module)
        case "context_identity": return String(localized: "Device identifiers", bundle: .module)
        case "context_cpu": return String(localized: "CPU and memory", bundle: .module)
        case "context_os": return String(localized: "Operating system", bundle: .module)
        case "deprecated": return String(localized: "Deprecated compatibility keys", bundle: .module)
        case "unrecognized": return String(localized: "New keys not yet in the inventory", bundle: .module)
        default: return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - Export

    /// Writes the full JSON export to a temporary file named after the device and build.
    public func exportFileURL() throws -> URL {
        guard let report else { throw ExportError.noReport }
        let name = "silicon-audit-\(report.device.identity)-\(report.environment.osBuild.isEmpty ? "nobuild" : report.environment.osBuild).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try report.jsonData().write(to: url, options: .atomic)
        return url
    }

    public func compactText() throws -> String {
        guard let report else { throw ExportError.noReport }
        return try CompactExport.encode(report)
    }

    public enum ExportError: Error {
        case noReport
    }
}
