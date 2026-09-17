import SiliconAuditUI
import SwiftUI

@main
struct SiliconAuditApp: App {
    #if os(iOS)
    @State private var transfer: TransferState
    @State private var received: ReceivedReportStore
    private let bridge: ReportTransferBridge

    init() {
        let state = TransferState()
        let store = ReceivedReportStore()
        _transfer = State(initialValue: state)
        _received = State(initialValue: store)
        bridge = ReportTransferBridge(state: state, store: store)
        // Activate at launch so files queued by the watch are received even in the background.
        bridge.activate()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            AuditRootView(companion: { AnyView(WatchReportsSection()) })
                .environment(transfer)
                .environment(received)
            #else
            AuditRootView()
            #endif
        }
        // Periodic change check (SPEC §6.5): the system wakes the app, the monitor compares a
        // fresh audit with the stored baseline and notifies if anything moved.
        #if !os(macOS)
        .backgroundTask(.appRefresh(ChangeMonitor.refreshTaskID)) {
            await ChangeMonitor.performBackgroundCheck()
        }
        #else
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}

#if os(iOS)
/// Reports delivered from Apple Watch, browsed with the same views and export as the phone's own.
struct WatchReportsSection: View {
    @Environment(ReceivedReportStore.self) private var received
    @Environment(TransferState.self) private var transfer

    var body: some View {
        // Nothing to show until a watch has delivered a report or a delivery is under way; an
        // iPad or a Mac has no watch to wait for, so it never sees an empty section.
        if !received.entries.isEmpty || (transfer.isSupported && transfer.status != nil) {
            Section {
                ForEach(received.entries) { entry in
                    NavigationLink {
                        ReceivedReportView(report: entry.report, title: entry.report.device.identity)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                Text(entry.receivedAt, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "applewatch")
                        }
                    }
                }
                .onDelete { offsets in
                    received.delete(at: offsets)
                }
                if let status = transfer.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("From Apple Watch")
            }
        }
    }
}
#endif
