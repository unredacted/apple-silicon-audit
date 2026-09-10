import SiliconAuditUI
import SwiftUI

@main
struct SiliconAuditWatchApp: App {
    @State private var transfer: TransferState
    private let bridge: ReportTransferBridge

    init() {
        let state = TransferState()
        _transfer = State(initialValue: state)
        bridge = ReportTransferBridge(state: state, store: nil)
        bridge.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(transfer: transfer) { report in
                bridge.send(report)
            }
        }
    }
}
