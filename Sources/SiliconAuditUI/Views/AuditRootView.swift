#if !os(watchOS)
import SiliconAuditCore
import SwiftUI

/// The app's root. One structure at two depths (SPEC §6.4): the Overview answers plain
/// questions first, and every deeper screen is one tap or one sidebar click away, never a mode
/// to switch into. Compact width (iPhone): a single scrolling list with the summary first and
/// the doors to everything deeper at the end. Regular width (iPad, Mac, Vision Pro): a split
/// view whose sidebar lists the Overview, every category on its shelf, and the reference
/// screens. Apple TV: the same split view, reached entirely from the focusable sidebar
/// (export included, as a QR code); there are no toolbars, sheets, or size classes.
public struct AuditRootView: View {
    @State private var model: ReportModel
    @State private var monitor = ChangeMonitor()
    @State private var selection: Route? = .overview
    @State private var showingExport = false
    @Environment(\.scenePhase) private var scenePhase
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Optional extra section supplied by the app target (e.g. reports received from Apple Watch).
    private let companion: (() -> AnyView)?

    public init(model: ReportModel = ReportModel(), companion: (() -> AnyView)? = nil) {
        _model = State(initialValue: model)
        self.companion = companion
        // Launch argument `-initialSelection <route>` opens a sidebar destination directly: a
        // category id or one of the `__…__` names in `Route`. Written for Apple TV, where the
        // simulator accepts no touch input; it works for scripted screenshots elsewhere too. Off
        // tvOS the export route is a sheet, not a sidebar destination, so it is ignored there.
        if let initial = UserDefaults.standard.string(forKey: "initialSelection"), let route = Route(launchArgument: initial) {
            #if os(tvOS)
            _selection = State(initialValue: route)
            #else
            if route != .export { _selection = State(initialValue: route) }
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
        .environment(monitor)
        .task {
            if model.report == nil { await model.run() }
            if let report = model.report { await monitor.processInForeground(report) }
        }
        #if os(macOS)
        .task { await monitor.periodicChecks(model: model) }
        #endif
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the foreground is a check, at most every 15 minutes; the background
            // refresh may have advanced the shared files meanwhile, so reload first.
            guard phase == .active else { return }
            monitor.load()
            guard monitor.isCheckDue(), model.report != nil else { return }
            Task {
                await model.run()
                if let report = model.report { await monitor.processInForeground(report) }
            }
        }
    }

    // MARK: Compact (iPhone)

    #if !os(tvOS)
    private var compactLayout: some View {
        NavigationStack {
            List {
                OverviewContent(model: model, showsReferenceLinks: true, showsMonitor: true, afterSummary: companion)
            }
            .navigationTitle("Silicon Audit")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { exportButton }
            }
            .refreshable { await model.run() }
            .exportSheet(isPresented: $showingExport, model: model)
        }
    }
    #endif

    // MARK: Regular (iPad, Mac, Vision Pro, Apple TV)

    private var splitLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detailColumn
                    #if !os(tvOS)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            refreshButton
                            exportButton
                        }
                    }
                    #endif
            }
            // A new sidebar selection starts a fresh stack; a pushed fact never survives a switch.
            .id(selection)
        }
        #if !os(tvOS)
        .exportSheet(isPresented: $showingExport, model: model)
        #endif
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label(String(localized: "Overview", bundle: .module), systemImage: "checkmark.shield")
                .tag(Route.overview)
            if model.report != nil {
                ForEach(ReportModel.Group.allCases) { group in
                    let sections = model.sections(in: group)
                    if !sections.isEmpty {
                        Section(group.title) {
                            ForEach(sections) { section in
                                CategoryRow(section: section).tag(Route.category(section.id))
                            }
                        }
                    }
                }
                Section(String(localized: "Reference", bundle: .module)) {
                    Label(String(localized: "Apple's documentation", bundle: .module), systemImage: "doc.text")
                        .tag(Route.documented)
                    Label(String(localized: "How this was measured", bundle: .module), systemImage: "waveform.path.ecg")
                        .tag(Route.measurement)
                    Label(String(localized: "About the data", bundle: .module), systemImage: "info.circle")
                        .tag(Route.aboutData)
                    ChangesRowLabel(count: monitor.unseenRecords.count)
                        .tag(Route.changes)
                    Label(String(localized: "Change monitoring", bundle: .module), systemImage: "bell.badge")
                        .tag(Route.monitor)
                    #if os(tvOS)
                    Label(String(localized: "Export", bundle: .module), systemImage: "qrcode")
                        .tag(Route.export)
                    #endif
                }
            }
        }
        .navigationTitle("Silicon Audit")
        #if os(macOS) || os(iOS) || os(visionOS)
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        #endif
    }

    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if let report = model.report {
                switch selection ?? .overview {
                case .category(let id):
                    if let section = model.section(id: id) {
                        CategoryView(section: section, report: report)
                    } else {
                        overviewList
                    }
                case .documented:
                    DocumentedView(report: report)
                case .measurement:
                    MeasurementView(model: model)
                case .aboutData:
                    AboutDataView(report: report)
                case .changes:
                    ChangesView()
                case .monitor:
                    MonitorView(model: model)
                case .export:
                    #if os(tvOS)
                    ExportView(model: model)
                    #else
                    overviewList
                    #endif
                case .allReadings:
                    AllReadingsView(model: model)
                case .overview:
                    overviewList
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(String(localized: "Checking this device…", bundle: .module))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .navigationTitle(String(localized: "Overview", bundle: .module))
            }
        }
        #if os(tvOS)
        // The tvOS sidebar floats over the detail column's leading edge; keep every screen in a
        // centered band that clears it (the overview list already limits itself to 820pt).
        .frame(maxWidth: 1100)
        #endif
    }

    private var overviewList: some View {
        List {
            OverviewContent(model: model, showsReferenceLinks: false, showsMonitor: true, afterSummary: companion)
        }
        .frame(maxWidth: 820)
        .navigationTitle(String(localized: "Overview", bundle: .module))
    }

    // MARK: Pieces

    #if !os(tvOS)
    private var refreshButton: some View {
        Button {
            Task { await model.run() }
        } label: {
            Label(String(localized: "Refresh", bundle: .module), systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.phase == .running)
        .accessibilityHint(Text(String(localized: "Reads this device again.", bundle: .module)))
    }

    private var exportButton: some View {
        Button {
            showingExport = true
        } label: {
            Label(String(localized: "Export", bundle: .module), systemImage: "square.and.arrow.up")
        }
        .disabled(model.report == nil)
        .accessibilityHint(Text(String(localized: "Share or save the JSON export.", bundle: .module)))
    }
    #endif
}

#endif
