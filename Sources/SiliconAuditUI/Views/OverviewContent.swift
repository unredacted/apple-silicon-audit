import SiliconAuditCore
import SwiftUI

/// The home list shared by the device's own report, a report received from Apple Watch, and
/// the watch itself: banner, summary card, the plain-language topics, and (where the sidebar
/// does not already offer them) the doors to everything deeper. Callers wrap it in a `List`.
public struct OverviewContent: View {
    let model: ReportModel
    let watchLayout: Bool
    /// Compact widths and the watch show the reference screens here; the split view lists them
    /// in its sidebar instead.
    let showsReferenceLinks: Bool
    /// Optional extra content placed after the summary and before the topics (the phone's
    /// "From Apple Watch" section). The device's own results always come first.
    let afterSummary: (() -> AnyView)?

    public init(model: ReportModel, watchLayout: Bool = false, showsReferenceLinks: Bool = true, afterSummary: (() -> AnyView)? = nil) {
        self.model = model
        self.watchLayout = watchLayout
        self.showsReferenceLinks = showsReferenceLinks
        self.afterSummary = afterSummary
    }

    public var body: some View {
        if let report = model.report {
            Section {
                if watchLayout {
                    EnvironmentBanner(report.environment)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    WatchSummaryRow(report: report, summary: model.securitySummary)
                } else {
                    VStack(spacing: 16) {
                        EnvironmentBanner(report.environment)
                        SummaryCard(report: report, tally: model.overviewTally)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if let afterSummary { afterSummary() }
            Section {
                OverviewList(report: report, scope: .device)
            } header: {
                Text(String(localized: "What this chip protects", bundle: .module))
            } footer: {
                if !OverviewList.hasContent(.process, in: report) {
                    Text(OverviewContent.provenanceFooter)
                }
            }
            if OverviewList.hasContent(.process, in: report) {
                Section {
                    OverviewList(report: report, scope: .process)
                } header: {
                    Text(String(localized: "What the OS does for this app", bundle: .module))
                } footer: {
                    Text(String(localized: "Measured inside this app. It depends on how this build was signed, not on the chip; another app on the same device can differ.", bundle: .module))
                }
            }
            if showsReferenceLinks {
                Section {
                    NavigationLink { AllReadingsView(model: model) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "All readings", bundle: .module))
                                Text(String(localized: "\(model.factCount) facts in \(model.sections.count) categories", bundle: .module))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                    }
                    NavigationLink { DocumentedView(report: report) } label: {
                        Label(String(localized: "Apple's documentation for this chip", bundle: .module), systemImage: "doc.text")
                    }
                    NavigationLink { MeasurementView(model: model) } label: {
                        Label(String(localized: "How this was measured", bundle: .module), systemImage: "waveform.path.ecg")
                    }
                    NavigationLink { AboutDataView(report: report) } label: {
                        Label(String(localized: "About the data", bundle: .module), systemImage: "info.circle")
                    }
                } header: {
                    Text(String(localized: "Look deeper", bundle: .module))
                } footer: {
                    Text(OverviewContent.versionFooter(for: report))
                }
            }
        } else {
            LoadingRow()
        }
    }

    static var provenanceFooter: String {
        String(localized: "Measured means reported by this device's kernel, not proven in the silicon. Documented means Apple published it, and the date is shown.", bundle: .module)
    }

    static func versionFooter(for report: Report) -> String {
        String(localized: "Inventory \(report.collection.knownKeysVersion ?? "unknown"), engine \(report.appVersion).", bundle: .module)
    }
}

/// The waiting state, as a list row so it sits where the summary card will appear.
struct LoadingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Checking this device…", bundle: .module))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

/// A 42mm-friendly summary: chip or device, build, and the flag count (SPEC §7).
struct WatchSummaryRow: View {
    let report: Report
    let summary: (present: Int, total: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SummaryCard.chipTitle(for: report)).font(.headline)
            // The build is the results-database conflict key; two audits of one marketing version can differ.
            Text("\(report.device.identity) · \(report.environment.platform) \(report.environment.osVersion) (\(report.environment.osBuild))")
                .font(.caption2).foregroundStyle(.secondary)
            Text(String(localized: "\(summary.present) of \(summary.total) security flags reported present", bundle: .module))
                .font(.caption)
            if report.device.socInferenceConfidence == "none" {
                Text(String(localized: "Chip \(report.device.socId ?? "?") not in the app's map yet", bundle: .module))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every category on its shelf, one tap from the Overview on compact widths and the watch. The
/// split view reaches the same categories from its sidebar.
public struct AllReadingsView: View {
    let model: ReportModel
    public init(model: ReportModel) { self.model = model }

    public var body: some View {
        List {
            ForEach(ReportModel.Group.allCases) { group in
                let sections = model.sections(in: group)
                if !sections.isEmpty {
                    Section(group.title) {
                        ForEach(sections) { section in
                            NavigationLink { CategoryView(section: section, report: model.report) } label: {
                                CategoryRow(section: section)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "All readings", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Symbol, title, and a fact count in the trailing column.
struct CategoryRow: View {
    let section: ReportModel.Section

    var body: some View {
        HStack(spacing: 12) {
            Label(section.title, systemImage: section.symbol)
                #if os(tvOS)
                // tvOS body text is 29pt and the sidebar is narrow.
                .font(.callout)
                .lineLimit(2)
                #endif
            Spacer(minLength: 8)
            Text("\(section.facts.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(section.title))
        .accessibilityValue(Text(String(localized: "\(section.facts.count) facts", bundle: .module)))
    }
}

/// The facts of one category. Apple's documented protections also link to the chain that maps
/// this device onto Apple's table.
public struct CategoryView: View {
    let section: ReportModel.Section
    let report: Report?
    public init(section: ReportModel.Section, report: Report?) {
        self.section = section
        self.report = report
    }

    public var body: some View {
        List {
            if section.category == "kernel_integrity", let report {
                Section {
                    NavigationLink { DocumentedView(report: report) } label: {
                        Label(String(localized: "How this device maps to Apple's table", bundle: .module), systemImage: "arrow.triangle.branch")
                    }
                }
            }
            Section {
                ForEach(section.facts) { fact in
                    NavigationLink { FactDetailView(fact) } label: { FactRow(fact) }
                }
            } footer: {
                Text(String(localized: "\(section.facts.count) facts. Tap one for its raw reading and provenance.", bundle: .module))
            }
        }
        .navigationTitle(section.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A report that arrived from another device, browsed with the same content and export.
public struct ReceivedReportView: View {
    @State private var model: ReportModel
    @State private var showingExport = false
    let title: String

    public init(report: Report, title: String) {
        _model = State(initialValue: ReportModel(report: report))
        self.title = title
    }

    public var body: some View {
        List {
            OverviewContent(model: model)
        }
        .navigationTitle(title)
        #if !os(watchOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingExport = true } label: {
                    Label(String(localized: "Export", bundle: .module), systemImage: "square.and.arrow.up")
                }
            }
        }
        .exportSheet(isPresented: $showingExport, model: model)
        #endif
    }
}
