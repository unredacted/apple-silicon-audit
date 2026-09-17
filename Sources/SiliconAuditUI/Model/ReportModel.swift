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
        guard phase != .running else { return }
        phase = .running
        let make = makeAuditor
        let report = await Task.detached(priority: .userInitiated) { make().audit() }.value
        phase = .loaded(report)
    }

    // MARK: - Grouping

    /// The three shelves every category sits on. Security first because it is the headline; the
    /// chip's instruction sets next; device and OS context last.
    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case security, chip, system
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .security: return String(localized: "Security protections", bundle: .module)
            case .chip: return String(localized: "Chip and instruction sets", bundle: .module)
            case .system: return String(localized: "Device and system", bundle: .module)
            }
        }

        public static func of(category: String) -> Group {
            if Report.securityCategories.contains(category) || category == "kernel_integrity" { return .security }
            switch category {
            case "identity", "legacy_alias", "isa_crypto", "isa_simd", "isa_sme", "isa_misc", "debug", "x86_isa": return .chip
            default: return .system
            }
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let category: String
        public let facts: [Fact]
        public var id: String { category }
        public var title: String { ReportModel.title(for: category) }
        public var symbol: String { ReportModel.symbol(for: category) }
        public var group: Group { Group.of(category: category) }
        public var isSecurity: Bool { group == .security }
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

    public func sections(in group: Group) -> [Section] { sections.filter { $0.group == group } }
    public var securitySections: [Section] { sections(in: .security) }
    public var otherSections: [Section] { sections.filter { !$0.isSecurity } }
    public func section(id: String) -> Section? { sections.first { $0.id == id } }

    /// Every fact the Details screens list, including keys the inventory does not know yet.
    public var factCount: Int { sections.reduce(0) { $0 + $1.facts.count } }

    /// "N of M security flags reported present" for the summary card.
    public var securitySummary: (present: Int, total: Int) {
        guard let report else { return (0, 0) }
        let flags = report.securityFacts.filter { $0.provenance == .measured && $0.kind == .flag }
        return (flags.filter { $0.state == .present }.count, flags.count)
    }

    /// How the Overview's checks came out, for the hero card's at-a-glance line. Counts exactly
    /// what the Overview renders: every device topic, plus the process topics when the report
    /// carries a self-test for them (imported and fixture reports may not).
    public var overviewTally: [TopicVerdict.Level: Int] {
        guard let report else { return [:] }
        var tally: [TopicVerdict.Level: Int] = [:]
        let topics = Topic.deviceTopics + (OverviewList.hasContent(.process, in: report) ? Topic.processTopics : [])
        for topic in topics {
            tally[topic.verdict(in: report).level, default: 0] += 1
        }
        return tally
    }

    public nonisolated static func title(for category: String) -> String {
        switch category {
        case "memory_tagging": return String(localized: "Memory tagging", bundle: .module)
        case "os_memory_tagging": return String(localized: "OS tagging activity", bundle: .module)
        case "enforcement": return String(localized: "This app's self-test", bundle: .module)
        case "pointer_authentication": return String(localized: "Pointer authentication", bundle: .module)
        case "control_flow": return String(localized: "Control flow", bundle: .module)
        case "speculation": return String(localized: "Speculation hardening", bundle: .module)
        case "constant_time": return String(localized: "Constant-time execution", bundle: .module)
        case "capability_bitmask": return String(localized: "Capability bitmask", bundle: .module)
        case "kernel_integrity": return String(localized: "Documented kernel protections", bundle: .module)
        case "identity": return String(localized: "Chip identity", bundle: .module)
        case "legacy_alias": return String(localized: "Legacy key names", bundle: .module)
        case "isa_crypto": return String(localized: "Cryptography", bundle: .module)
        case "isa_simd": return String(localized: "SIMD and floating point", bundle: .module)
        case "isa_sme": return String(localized: "Scalable Matrix Extension", bundle: .module)
        case "isa_misc": return String(localized: "Other ISA features", bundle: .module)
        case "debug": return String(localized: "Debug hardware", bundle: .module)
        case "x86_isa": return String(localized: "x86 feature table", bundle: .module)
        case "context_identity": return String(localized: "Device identifiers", bundle: .module)
        case "context_cpu": return String(localized: "CPU and memory", bundle: .module)
        case "context_os": return String(localized: "Operating system", bundle: .module)
        case "deprecated": return String(localized: "Deprecated keys", bundle: .module)
        case "unrecognized": return String(localized: "New keys", bundle: .module)
        default: return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// One SF Symbol per category so sidebar and list rows line up the same way everywhere.
    public nonisolated static func symbol(for category: String) -> String {
        switch category {
        case "memory_tagging": return "tag"
        case "os_memory_tagging": return "waveform.path.ecg"
        case "enforcement": return "checkmark.seal"
        case "pointer_authentication": return "signature"
        case "control_flow": return "arrow.triangle.turn.up.right.diamond"
        case "speculation": return "bolt.shield"
        case "constant_time": return "timer"
        case "capability_bitmask": return "number.square"
        case "kernel_integrity": return "lock.doc"
        case "identity": return "cpu"
        case "legacy_alias": return "clock.arrow.circlepath"
        case "isa_crypto": return "key"
        case "isa_simd": return "function"
        case "isa_sme": return "square.grid.3x3"
        case "isa_misc": return "puzzlepiece"
        case "debug": return "ladybug"
        case "x86_isa": return "tablecells"
        case "context_identity": return "barcode"
        case "context_cpu": return "memorychip"
        case "context_os": return "gearshape"
        case "deprecated": return "archivebox"
        case "unrecognized": return "sparkles"
        default: return "list.bullet"
        }
    }

    // MARK: - Export

    /// Writes the full JSON export to a temporary file named after the device and build.
    public func exportFileURL() throws -> URL {
        guard let report else { throw ExportError.noReport }
        let name = ReceivedReportStore.fileName(for: report)
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
