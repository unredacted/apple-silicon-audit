#if !os(watchOS)
import SiliconAuditCore
import SwiftUI

/// The app's root. Compact width (iPhone): a single scrolling list with the summary first,
/// then grouped sections, headline group first. Regular width (iPad, Mac): a split view with
/// categories in the sidebar and the selected section in the detail column (SPEC §6.4).
public struct AuditRootView: View {
    @State private var model: ReportModel
    @State private var selection: String? = AuditRootView.summaryID
    @State private var showingExport = false
    @AppStorage("presentationMode") private var modeRaw = PresentationMode.overview.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var mode: PresentationMode {
        get { PresentationMode(rawValue: modeRaw) ?? .overview }
        nonmutating set { modeRaw = newValue.rawValue }
    }

    static let summaryID = "__summary__"

    /// Optional extra section supplied by the app target (e.g. reports received from Apple Watch).
    private let companion: (() -> AnyView)?

    public init(model: ReportModel = ReportModel(), companion: (() -> AnyView)? = nil) {
        _model = State(initialValue: model)
        self.companion = companion
    }

    public var body: some View {
        Group {
            if sizeClass == .compact {
                compactLayout
            } else {
                splitLayout
            }
        }
        .task {
            if model.report == nil { await model.run() }
        }
    }

    // MARK: Compact (iPhone)

    private var compactLayout: some View {
        NavigationStack {
            List {
                if let companion, model.report != nil { companion() }
                ReportListContent(model: model, mode: mode)
            }
            .navigationDestination(for: String.self) { ReportListContent.destination(for: $0, in: model.report) }
            .navigationTitle("Silicon Audit")
            .toolbar {
                modePicker
                exportButton
            }
            .refreshable { await model.run() }
            .sheet(isPresented: $showingExport) { NavigationStack { ExportView(model: model) } }
        }
    }

    // MARK: Regular (iPad, Mac)

    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(mode == .overview ? String(localized: "Overview", bundle: .module) : String(localized: "Summary", bundle: .module),
                      systemImage: "checkmark.shield")
                    .tag(AuditRootView.summaryID)
                if mode == .details {
                    Section(String(localized: "Security", bundle: .module)) {
                        ForEach(model.securitySections) { section in
                            sidebarRow(section).tag(section.id)
                        }
                    }
                    Section(String(localized: "Everything else", bundle: .module)) {
                        ForEach(model.otherSections) { section in
                            sidebarRow(section).tag(section.id)
                        }
                    }
                }
            }
            .navigationTitle("Silicon Audit")
            .toolbar { modePicker }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            #endif
        } detail: {
            NavigationStack {
                detailColumn
                    .toolbar { exportButton }
            }
        }
        .sheet(isPresented: $showingExport) {
            NavigationStack {
                ExportView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Done", bundle: .module)) { showingExport = false }
                        }
                    }
            }
            .frame(minWidth: 420, minHeight: 360)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let report = model.report {
            if selection == nil || selection == AuditRootView.summaryID || mode == .overview {
                List {
                    if let companion { companion() }
                    if mode == .overview {
                        ReportListContent(model: model, mode: .overview)
                    } else {
                        Section {
                            EnvironmentBanner(report.environment)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                            SummaryCard(report: report, summary: model.securitySummary)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        } footer: {
                            Text(ReportListContent.footer(for: report))
                        }
                    }
                }
                .navigationDestination(for: String.self) { ReportListContent.destination(for: $0, in: model.report) }
                .frame(maxWidth: 820)
                .navigationTitle(mode == .overview ? String(localized: "Overview", bundle: .module) : String(localized: "Summary", bundle: .module))
            } else if let section = model.sections.first(where: { $0.id == selection }) {
                List {
                    sectionView(section)
                }
                .navigationDestination(for: String.self) { ReportListContent.destination(for: $0, in: model.report) }
                .navigationTitle(section.title)
            }
        } else {
            List { ReportListContent(model: model, mode: mode) }
        }
    }

    // MARK: Pieces

    private func sidebarRow(_ section: ReportModel.Section) -> some View {
        HStack {
            Text(section.title)
            Spacer()
            Text("\(section.facts.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func sectionView(_ section: ReportModel.Section) -> some View {
        Section(section.title) {
            ForEach(section.facts) { fact in
                NavigationLink(value: fact.id) {
                    FactRow(fact)
                }
            }
        }
    }

    private var modePicker: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(String(localized: "Mode", bundle: .module), selection: Binding(get: { mode }, set: { mode = $0 })) {
                ForEach(PresentationMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityLabel(Text(String(localized: "Presentation mode", bundle: .module)))
        }
    }

    private var exportButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingExport = true
            } label: {
                Label(String(localized: "Export", bundle: .module), systemImage: "square.and.arrow.up")
            }
            .disabled(model.report == nil)
            .accessibilityHint(Text(String(localized: "Share or save the JSON export.", bundle: .module)))
        }
    }

}

#endif
