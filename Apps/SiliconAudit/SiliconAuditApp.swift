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
        #if os(macOS)
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
        if !received.entries.isEmpty || transfer.status != nil {
            Section {
                ForEach(received.entries) { entry in
                    NavigationLink {
                        ReceivedReportView(report: entry.report, title: entry.report.device.identity)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                Text(entry.receivedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
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
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("From Apple Watch")
            }
        }
    }
}
#endif
