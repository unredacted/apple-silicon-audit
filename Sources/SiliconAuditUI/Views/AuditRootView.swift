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

    public init(model: ReportModel = ReportModel()) {
        _model = State(initialValue: model)
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
                if let report = model.report {
                    Section {
                        EnvironmentBanner(report.environment)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        SummaryCard(report: report, summary: model.securitySummary)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    if mode == .overview {
                        Section {
                            OverviewList(report: report)
                        } header: {
                            Text(String(localized: "What this chip protects", bundle: .module))
                        } footer: {
                            Text(footerText)
                        }
                    } else {
                        ForEach(model.securitySections) { section in
                            sectionView(section)
                        }
                        Section {
                            NavigationLink {
                                AllSectionsView(sections: model.otherSections)
                            } label: {
                                Label(String(localized: "Everything else", bundle: .module), systemImage: "list.bullet.indent")
                            }
                        } footer: {
                            Text(footerText)
                        }
                    }
                } else {
                    loadingRow
                }
            }
            .navigationDestination(for: String.self) { factDestination($0) }
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
                    Section {
                        EnvironmentBanner(report.environment)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        SummaryCard(report: report, summary: model.securitySummary)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    if mode == .overview {
                        Section {
                            OverviewList(report: report)
                        } header: {
                            Text(String(localized: "What this chip protects", bundle: .module))
                        } footer: {
                            Text(footerText)
                        }
                    } else {
                        Section { } footer: { Text(footerText) }
                    }
                }
                .frame(maxWidth: 820)
                .navigationTitle(mode == .overview ? String(localized: "Overview", bundle: .module) : String(localized: "Summary", bundle: .module))
            } else if let section = model.sections.first(where: { $0.id == selection }) {
                List {
                    sectionView(section)
                }
                .navigationDestination(for: String.self) { factDestination($0) }
                .navigationTitle(section.title)
            }
        } else {
            List { loadingRow }
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

    /// Destination for `NavigationLink(value:)` rows; must hang off the List, not a Section.
    @ViewBuilder
    private func factDestination(_ id: String) -> some View {
        if let fact = model.report?.facts.first(where: { $0.id == id }) ?? model.report?.unrecognizedKeys.first(where: { $0.id == id }) {
            FactDetailView(fact)
        }
    }

    private var loadingRow: some View {
        HStack {
            ProgressView()
            Text(String(localized: "Reading this kernel…", bundle: .module))
        }
        .accessibilityElement(children: .combine)
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

    private var footerText: String {
        guard let report = model.report else { return "" }
        return String(localized: "Measured means reported by this kernel, not present in the silicon. Documented claims come from Apple's published materials and show their dates. Inventory \(report.collection.knownKeysVersion), engine \(report.appVersion).", bundle: .module)
    }
}

/// Non-security sections behind one tap on iPhone.
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
#endif
