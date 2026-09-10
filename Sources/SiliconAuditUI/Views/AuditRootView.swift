#if !os(watchOS)
import SiliconAuditCore
import SwiftUI

/// The app's root. Compact width (iPhone): a single scrolling list with the summary first,
/// then grouped sections, headline group first. Regular width (iPad, Mac, Vision Pro): a split
/// view with categories in the sidebar and the selected section in the detail column (SPEC §6.4).
/// Apple TV: the same split view, but everything is reached from the focusable sidebar (mode,
/// sections, documentation, export as a QR code); there are no toolbars, sheets, or size classes.
public struct AuditRootView: View {
    @State private var model: ReportModel
    @State private var selection: String? = AuditRootView.summaryID
    @State private var showingExport = false
    @AppStorage("presentationMode") private var modeRaw = PresentationMode.overview.rawValue
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

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
        // Launch argument `-initialSelection <route>` opens a sidebar destination directly: a section
        // id, `__documented__`, `__about_data__`, or (tvOS only) `__export__`. Written for Apple TV,
        // where the simulator accepts no touch input; it works for scripted screenshots elsewhere too.
        // Off tvOS the export route is a sheet, not a sidebar destination, so it is ignored there.
        if let initial = UserDefaults.standard.string(forKey: "initialSelection"), !initial.isEmpty {
            #if os(tvOS)
            _selection = State(initialValue: initial)
            #else
            if initial != AuditRootView.exportRoute { _selection = State(initialValue: initial) }
            #endif
        }
    }

    public var body: some View {
        Group {
            #if os(tvOS)
            splitLayout
            #else
            if sizeClass == .compact {
                compactLayout
            } else {
                splitLayout
            }
            #endif
        }
        .task {
            if model.report == nil { await model.run() }
        }
    }

    // MARK: Compact (iPhone)

    #if !os(tvOS)
    private var compactLayout: some View {
        NavigationStack {
            List {
                ReportListContent(model: model, mode: mode, afterSummary: companion)
            }
            .navigationDestination(for: String.self) { route($0) }
            .navigationTitle("Silicon Audit")
            .toolbar {
                modePicker
                exportButton
            }
            .refreshable { await model.run() }
            .sheet(isPresented: $showingExport) { NavigationStack { ExportView(model: model) } }
        }
    }
    #endif

    // MARK: Regular (iPad, Mac, Vision Pro, Apple TV)

    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: $selection) {
                #if os(tvOS)
                // No toolbar on Apple TV: the mode switch is the first focusable row of the sidebar.
                Picker(String(localized: "Mode", bundle: .module), selection: Binding(get: { mode }, set: { mode = $0 })) {
                    ForEach(PresentationMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text(String(localized: "Presentation mode", bundle: .module)))
                #endif
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
                #if os(tvOS)
                Section(String(localized: "More", bundle: .module)) {
                    Label(String(localized: "Apple's documentation", bundle: .module), systemImage: "doc.text")
                        .tag(AuditRootView.documentedRoute)
                    Label(String(localized: "About the data", bundle: .module), systemImage: "info.circle")
                        .tag(AuditRootView.aboutDataRoute)
                    Label(String(localized: "Export", bundle: .module), systemImage: "qrcode")
                        .tag(AuditRootView.exportRoute)
                }
                #endif
            }
            .navigationTitle("Silicon Audit")
            #if !os(tvOS)
            .toolbar { modePicker }
            #endif
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            #endif
        } detail: {
            NavigationStack {
                detailColumn
                    #if !os(tvOS)
                    .toolbar { exportButton }
                    #endif
            }
        }
        #if !os(tvOS)
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
        #endif
    }

    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if let report = model.report {
                if selection == AuditRootView.documentedRoute {
                    DocumentedView(report: report)
                } else if selection == AuditRootView.aboutDataRoute {
                    AboutDataView(report: report)
                } else if isExportRouteSelected {
                    ExportView(model: model)
                } else if selection == nil || selection == AuditRootView.summaryID || mode == .overview {
                    List {
                        if mode == .overview {
                            ReportListContent(model: model, mode: .overview, afterSummary: companion)
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
                            if let companion { companion() }
                        }
                    }
                    .navigationDestination(for: String.self) { route($0) }
                    .frame(maxWidth: 820)
                    .navigationTitle(mode == .overview ? String(localized: "Overview", bundle: .module) : String(localized: "Summary", bundle: .module))
                } else if let section = model.sections.first(where: { $0.id == selection }) {
                    List {
                        sectionView(section)
                    }
                    .navigationDestination(for: String.self) { route($0) }
                    .navigationTitle(section.title)
                }
            } else {
                List { ReportListContent(model: model, mode: mode) }
            }
        }
        #if os(tvOS)
        // The tvOS sidebar floats over the detail column's leading edge; keep every screen in a
        // centered band that clears it (the overview list already limits itself to 820pt).
        .frame(maxWidth: 1100)
        #endif
    }

    /// Export is a sidebar destination only on Apple TV; elsewhere it is a sheet, so the route is
    /// never selected there (and `-initialSelection __export__` is ignored in `init`).
    private var isExportRouteSelected: Bool {
        #if os(tvOS)
        selection == AuditRootView.exportRoute
        #else
        false
        #endif
    }

    // MARK: Pieces

    private func sidebarRow(_ section: ReportModel.Section) -> some View {
        HStack {
            Text(section.title)
                #if os(tvOS)
                // tvOS body text is 29pt; the sidebar is narrow, so match the Label rows above.
                .font(.callout)
                .lineLimit(2)
                #endif
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

    #if !os(tvOS)
    /// Vision Pro puts the mode switch in the window's bottom ornament; everywhere else it is the
    /// principal toolbar item.
    private var modePickerPlacement: ToolbarItemPlacement {
        #if os(visionOS)
        .bottomOrnament
        #else
        .principal
        #endif
    }

    private var modePicker: some ToolbarContent {
        ToolbarItem(placement: modePickerPlacement) {
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
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                NavigationLink(value: AuditRootView.documentedRoute) {
                    Label(String(localized: "Apple's documentation", bundle: .module), systemImage: "doc.text")
                }
                NavigationLink(value: AuditRootView.aboutDataRoute) {
                    Label(String(localized: "About the data", bundle: .module), systemImage: "info.circle")
                }
            } label: {
                Label(String(localized: "Sources", bundle: .module), systemImage: "info.circle")
            }
            .disabled(model.report == nil)
            Button {
                showingExport = true
            } label: {
                Label(String(localized: "Export", bundle: .module), systemImage: "square.and.arrow.up")
            }
            .disabled(model.report == nil)
            .accessibilityHint(Text(String(localized: "Share or save the JSON export.", bundle: .module)))
        }
    }
    #endif

    static let documentedRoute = "__documented__"
    static let aboutDataRoute = "__about_data__"
    static let exportRoute = "__export__"

    /// Routes for the two information screens plus fact ids.
    @ViewBuilder
    private func route(_ id: String) -> some View {
        if id == AuditRootView.documentedRoute, let report = model.report {
            DocumentedView(report: report)
        } else if id == AuditRootView.aboutDataRoute, let report = model.report {
            AboutDataView(report: report)
        } else {
            ReportListContent.destination(for: id, in: model.report)
        }
    }

}

#endif
