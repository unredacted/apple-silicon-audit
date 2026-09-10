import SiliconAuditCore
import SwiftUI

/// Apple's published claims for this chip family, with the chain that gets there spelled out
/// (SPEC §5, §6.4): measured kernel target → inferred SoC family → Apple's table column.
/// When the chain breaks, the screen says so instead of guessing.
public struct DocumentedView: View {
    let report: Report
    public init(report: Report) { self.report = report }

    private var documented: [Fact] { report.documentedFacts }
    private var tabulated: [Fact] { documented.filter { $0.state != .unknown || !$0.id.isUntabulated } }
    private var source: FactSource? { documented.first?.source }
    private var isMapped: Bool { report.device.socInferenceConfidence != "none" }

    public var body: some View {
        List {
            Section {
                ChainRow(step: 1, title: String(localized: "Measured", bundle: .module), provenance: .measured,
                         value: report.device.socId ?? String(localized: "no kernel target", bundle: .module),
                         detail: String(localized: "Kernel build target from kern.version", bundle: .module))
                ChainRow(step: 2, title: String(localized: "Inferred", bundle: .module), provenance: .inferred,
                         value: isMapped ? report.device.socNameInferred : String(localized: "not in the app's map", bundle: .module),
                         detail: isMapped
                            ? String(localized: "soc-map.json, \(report.device.socInferenceConfidence) entry", bundle: .module)
                            : String(localized: "soc-map.json has no entry for this target", bundle: .module))
                ChainRow(step: 3, title: String(localized: "Documented", bundle: .module), provenance: .documented,
                         value: columnText,
                         detail: String(localized: "Column of Apple's runtime-protection table", bundle: .module))
            } header: {
                Text(String(localized: "How this device maps to Apple's table", bundle: .module))
            } footer: {
                Text(String(localized: "Each step is labeled with its provenance. The app never applies Apple's claims to a chip it could not place in the table.", bundle: .module))
            }

            if !isMapped {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Apple hasn't documented this chip yet", bundle: .module), systemImage: "doc.questionmark")
                            .font(.headline)
                        Text(String(localized: "The kernel reports target \(report.device.socId ?? "unknown"), which is not in this app's map of Apple's chip families. The measured facts above are unaffected; only the documented rows below read unknown. When Apple publishes the family, a data update fills these in.", bundle: .module))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }

            Section {
                ForEach(documented) { fact in
                    NavigationLink { FactDetailView(fact) } label: { FactRow(fact) }
                }
            } header: {
                Text(String(localized: "Apple's claims for this chip family", bundle: .module))
            } footer: {
                if let source {
                    Text(String(localized: "Source: Apple Platform Security, published \(source.published), last verified by this app \(source.verified). Rows marked unknown are either not tabulated by Apple or not applicable to an unmapped chip.", bundle: .module))
                }
            }
        }
        .navigationTitle(String(localized: "Apple's documentation", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var columnText: String {
        guard isMapped else { return String(localized: "no column", bundle: .module) }
        // The column is only in the fact notes; surface the family name instead of parsing them.
        if let note = documented.first(where: { $0.state != .unknown })?.source?.note,
           let range = note.range(of: #"column [A-Za-z0-9\-]+"#, options: .regularExpression) {
            return String(note[range].dropFirst("column ".count))
        }
        return report.device.socNameInferred
    }
}

private extension String {
    var isUntabulated: Bool { ["tce", "secure_exclaves", "secure_enclave_generation"].contains(self) }
}

struct ChainRow: View {
    let step: Int
    let title: String
    let provenance: Provenance
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(step)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(value).font(.body.weight(.medium))
                    Spacer()
                    ProvenanceBadge(provenance)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(step), \(title): \(value). \(detail)"))
    }
}

/// Where every non-measured word in the app comes from, and how old it is (SPEC §5, §6.4).
public struct AboutDataView: View {
    let report: Report
    let data: DataStore
    public init(report: Report, data: DataStore = .shared) {
        self.report = report
        self.data = data
    }

    public var body: some View {
        List {
            Section(String(localized: "Provenance", bundle: .module)) {
                ForEach([Provenance.measured, .documented, .inferred], id: \.rawValue) { p in
                    HStack(alignment: .firstTextBaseline) {
                        ProvenanceBadge(p)
                        Text(ProvenanceStyle.explanation(p)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                versionRow(String(localized: "Known keys", bundle: .module), data.knownKeys.verified, String(localized: "\(data.knownKeys.entries.count) annotated sysctl keys", bundle: .module))
                versionRow(String(localized: "Capability bits", bundle: .module), data.capsBits.verified, String(localized: "\(data.capsBits.entries.count) bits from <arm/cpu_capabilities_public.h>", bundle: .module))
                versionRow(String(localized: "CPU families", bundle: .module), data.cpufamilies.verified, String(localized: "\(data.cpufamilies.entries.count) constants from <mach/machine.h>", bundle: .module))
                versionRow(String(localized: "SoC map", bundle: .module), data.socMap.verified, String(localized: "\(data.socMap.entries.filter { $0.confidence == .verified }.count) verified, \(data.socMap.entries.filter { $0.confidence == .reported }.count) reported entries", bundle: .module))
                versionRow(String(localized: "Apple's matrix", bundle: .module), data.matrix.verified, String(localized: "\(data.matrix.entries.count) rows, \(data.matrix.columns.count) chip-family columns", bundle: .module))
            } header: {
                Text(String(localized: "Bundled data and when it was last verified", bundle: .module))
            } footer: {
                Text(String(localized: "Data ships inside the app; updating it never requires a code change. Engine \(report.appVersion), export schema \(report.schemaVersion). The app makes no network requests.", bundle: .module))
            }
            Section(String(localized: "Sources", bundle: .module)) {
                ForEach(Array(Set(data.matrix.entries.map(\.source.url))).sorted(), id: \.self) { url in
                    if let u = URL(string: url) {
                        Link(destination: u) {
                            Label(u.host() ?? url, systemImage: "safari")
                        }
                    }
                }
                if let repo = URL(string: "https://github.com/unredacted/apple-silicon-audit") {
                    Link(destination: repo) { Label(String(localized: "Source code and results database", bundle: .module), systemImage: "chevron.left.forwardslash.chevron.right") }
                }
            }
        }
        .navigationTitle(String(localized: "About the data", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func versionRow(_ title: String, _ verified: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verified.isEmpty ? "—" : verified).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
