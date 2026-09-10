import SiliconAuditUI
import SwiftUI

@main
struct SiliconAuditApp: App {
    #if os(iOS)
    @State private var connectivity: ConnectivityModel
    private let bridge: ConnectivityBridge

    init() {
        let model = ConnectivityModel()
        _connectivity = State(initialValue: model)
        bridge = ConnectivityBridge(model: model)
        // Activate at launch so files queued by the watch are received even in the background.
        bridge.activate()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            AuditRootView(companion: { AnyView(WatchReportsSection()) })
                .environment(connectivity)
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
/// Reports delivered from Apple Watch (Phase 2 spike payloads until Phase 5 ships the real
/// watch report). Shown only when something has arrived.
struct WatchReportsSection: View {
    @Environment(ConnectivityModel.self) private var connectivity

    var body: some View {
        if let report = connectivity.receivedReport {
            Section("From Apple Watch") {
                NavigationLink {
                    ReceivedReportView(report: report, url: connectivity.receivedFileURL)
                } label: {
                    Label("\(report.hwProduct ?? "Apple Watch") · \(report.osVersion) (\(report.osBuild))", systemImage: "applewatch")
                }
                if let url = connectivity.receivedFileURL {
                    ShareLink(item: url) { Label("Share the watch report", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }
}
#endif
