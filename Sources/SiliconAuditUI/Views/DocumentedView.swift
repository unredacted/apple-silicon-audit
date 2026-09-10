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
    /// Every distinct source cited by the documented rows (the guide and the MIE research post).
    private var distinctSources: [FactSource] {
        var seen: Set<String> = []
        return documented.compactMap(\.source).filter { seen.insert($0.url).inserted }
    }
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

            if report.device.socId == nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "No Apple silicon target to look up", bundle: .module), systemImage: "cpu")
                            .font(.headline)
                        Text(String(localized: "kern.version on this device carries no RELEASE_ARM64_T target, so there is no chip identity to look up in Apple's table. This is expected on Intel Macs. The measured facts are unaffected; the documented rows below read unknown.", bundle: .module))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            } else if !isMapped {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Apple hasn't documented this chip yet", bundle: .module), systemImage: "doc.questionmark")
                            .font(.headline)
                        Text(String(localized: "The kernel reports target \(report.device.socId ?? ""), which is not in this app's map of Apple's chip families. The measured facts are unaffected; only the documented rows below read unknown. When Apple publishes the family, a data update fills these in.", bundle: .module))
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(distinctSources, id: \.url) { s in
                        Text(String(localized: "Source: \(URL(string: s.url)?.host() ?? s.url), published \(s.published), last verified by this app \(s.verified).", bundle: .module))
                    }
                    Text(String(localized: "Each row's detail names its own source. Rows marked unknown are either not tabulated by Apple or not applicable to an unmapped chip.", bundle: .module))
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
            if let recorded = report.collection.dataVersions, !recordedMatchesBundle(recorded) {
                Section {
                    ForEach(recorded.rows, id: \.label) { row in
                        HStack {
                            Text(row.label.replacingOccurrences(of: "_", with: " "))
                            Spacer()
                            Text(row.date ?? String(localized: "unknown", bundle: .module)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "Data that annotated this report", bundle: .module))
                } footer: {
                    Text(String(localized: "This report was produced with a different data release than the one bundled in this app; the dates above are the ones recorded in the report itself.", bundle: .module))
                }
            }
            Section {
                versionRow(String(localized: "Known keys", bundle: .module), data.knownKeys.verified, String(localized: "\(data.knownKeys.entries.count) annotated sysctl keys", bundle: .module))
                versionRow(String(localized: "Capability bits", bundle: .module), data.capsBits.verified, String(localized: "\(data.capsBits.entries.count) bits from <arm/cpu_capabilities_public.h>", bundle: .module))
                versionRow(String(localized: "CPU families", bundle: .module), data.cpufamilies.verified, String(localized: "\(data.cpufamilies.entries.count) constants from <mach/machine.h>", bundle: .module))
                versionRow(String(localized: "SoC map", bundle: .module), data.socMap.verified, String(localized: "\(data.socMap.entries.filter { $0.confidence == .verified }.count) verified, \(data.socMap.entries.filter { $0.confidence == .reported }.count) reported entries", bundle: .module))
                versionRow(String(localized: "Apple's matrix", bundle: .module), data.matrix.verified, String(localized: "\(data.matrix.entries.count) rows, \(data.matrix.columns.count) chip-family columns", bundle: .module))
            } header: {
                Text(report.collection.dataVersions.map(recordedMatchesBundle) == true
                     ? String(localized: "Data bundled in this app (also what annotated this report)", bundle: .module)
                     : String(localized: "Data bundled in this app", bundle: .module))
            } footer: {
                Text(String(localized: "Data ships inside the app; updating it never requires a code change. Engine \(report.appVersion), export schema \(report.schemaVersion). The app makes no network requests.", bundle: .module))
            }
            Section {
                ForEach(Array(Set(data.matrix.entries.map(\.source.url))).sorted(), id: \.self) { url in
                    if let u = URL(string: url) {
                        #if os(tvOS)
                        Label(url, systemImage: "safari").font(.callout)
                        #else
                        Link(destination: u) {
                            Label(u.host() ?? url, systemImage: "safari")
                        }
                        #endif
                    }
                }
                if let repo = URL(string: "https://github.com/unredacted/apple-silicon-audit") {
                    #if os(tvOS)
                    Label(repo.absoluteString, systemImage: "chevron.left.forwardslash.chevron.right").font(.callout)
                    #else
                    Link(destination: repo) { Label(String(localized: "Source code and results database", bundle: .module), systemImage: "chevron.left.forwardslash.chevron.right") }
                    #endif
                }
            } header: {
                Text(String(localized: "Sources", bundle: .module))
            } footer: {
                #if os(tvOS)
                Text(String(localized: "Apple TV has no browser; open these on another device.", bundle: .module))
                #endif
            }
        }
        .navigationTitle(String(localized: "About the data", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func recordedMatchesBundle(_ v: Report.DataVersions) -> Bool {
        v == Report.DataVersions(data)
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
