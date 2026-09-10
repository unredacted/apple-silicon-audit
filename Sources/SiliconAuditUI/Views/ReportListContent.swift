import SiliconAuditCore
import SwiftUI

/// The list body shared by the phone's own report, a received watch report, and (with
/// `watchLayout`) the watch itself: banner, summary card, then Overview topics or Details
/// sections. Callers wrap it in a `List` inside their own navigation container and attach the
/// `String` navigation destination for fact rows.
public struct ReportListContent: View {
    let model: ReportModel
    let mode: PresentationMode
    let watchLayout: Bool
    /// Optional extra content placed after the local summary and before the topics/sections
    /// (e.g. the phone's "From Apple Watch" section). The device's own results always come first.
    let afterSummary: (() -> AnyView)?

    public init(model: ReportModel, mode: PresentationMode, watchLayout: Bool = false, afterSummary: (() -> AnyView)? = nil) {
        self.model = model
        self.mode = mode
        self.watchLayout = watchLayout
        self.afterSummary = afterSummary
    }

    public var body: some View {
        if let report = model.report {
            Section {
                EnvironmentBanner(report.environment)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if watchLayout {
                    WatchSummaryRow(report: report, summary: model.securitySummary)
                } else {
                    SummaryCard(report: report, summary: model.securitySummary)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if let afterSummary { afterSummary() }
            if mode == .overview {
                Section {
                    OverviewList(report: report, scope: .device)
                } header: {
                    Text(String(localized: "What this chip protects", bundle: .module))
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
                Section {
                    NavigationLink { DocumentedView(report: report) } label: {
                        Label(String(localized: "Apple's documentation for this chip", bundle: .module), systemImage: "doc.text")
                    }
                    NavigationLink { AboutDataView(report: report) } label: {
                        Label(String(localized: "About the data", bundle: .module), systemImage: "info.circle")
                    }
                } footer: {
                    Text(ReportListContent.footer(for: report))
                }
            } else {
                ForEach(model.securitySections) { section in
                    Section {
                        if section.category == "kernel_integrity" {
                            NavigationLink { DocumentedView(report: report) } label: {
                                Label(String(localized: "How this device maps to Apple's table", bundle: .module), systemImage: "arrow.triangle.branch")
                            }
                        }
                        ForEach(section.facts) { fact in
                            NavigationLink(value: fact.id) { FactRow(fact) }
                        }
                    } header: {
                        Text(section.title)
                    }
                }
                Section {
                    NavigationLink {
                        AllSectionsView(sections: model.otherSections)
                    } label: {
                        Label(String(localized: "Everything else", bundle: .module), systemImage: "list.bullet.indent")
                    }
                } footer: {
                    Text(ReportListContent.footer(for: report))
                }
            }
        } else {
            HStack {
                ProgressView()
                Text(String(localized: "Reading this kernel…", bundle: .module))
            }
            .accessibilityElement(children: .combine)
        }
    }

    public static func footer(for report: Report) -> String {
        String(localized: "Measured means reported by this kernel, not present in the silicon. Documented claims come from Apple's published materials and show their dates. Inventory \(report.collection.knownKeysVersion ?? "unknown"), engine \(report.appVersion).", bundle: .module)
    }

    /// Fact lookup for `navigationDestination(for: String.self)`.
    @ViewBuilder
    public static func destination(for id: String, in report: Report?) -> some View {
        if let fact = report?.facts.first(where: { $0.id == id }) ?? report?.unrecognizedKeys.first(where: { $0.id == id }) {
            FactDetailView(fact)
        }
    }
}

/// A 42mm-friendly summary: identity, build, and the flag count (SPEC §7).
struct WatchSummaryRow: View {
    let report: Report
    let summary: (present: Int, total: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.device.identity).font(.headline)
            Text("\(report.environment.platform) \(report.environment.osVersion) (\(report.environment.osBuild))")
                .font(.caption2).foregroundStyle(.secondary)
            Text(String(localized: "\(summary.present) of \(summary.total) security flags reported present", bundle: .module))
                .font(.caption)
            Text(report.device.socInferenceConfidence == "none"
                 ? String(localized: "Chip \(report.device.socId ?? "?") not in the app's map yet", bundle: .module)
                 : report.device.socNameInferred)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A report that arrived from another device, browsed with the same content and export.
public struct ReceivedReportView: View {
    @State private var model: ReportModel
    @State private var showingExport = false
    @AppStorage("presentationMode") private var modeRaw = PresentationMode.overview.rawValue
    let title: String

    public init(report: Report, title: String) {
        _model = State(initialValue: ReportModel(report: report))
        self.title = title
    }

    public var body: some View {
        List {
            ReportListContent(model: model, mode: PresentationMode(rawValue: modeRaw) ?? .overview)
        }
        .navigationDestination(for: String.self) { ReportListContent.destination(for: $0, in: model.report) }
        .navigationTitle(title)
        #if !os(watchOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingExport = true } label: {
                    Label(String(localized: "Export", bundle: .module), systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingExport) { NavigationStack { ExportView(model: model) } }
        #endif
    }
}

/// Non-security sections behind one tap (iPhone and watch).
struct AllSectionsView: View {
    let sections: [ReportModel.Section]

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.facts) { fact in
                        NavigationLink { FactDetailView(fact) } label: { FactRow(fact) }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Everything else", bundle: .module))
    }
}
