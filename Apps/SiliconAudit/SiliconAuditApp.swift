import SwiftUI

@main
struct SiliconAuditApp: App {
    @State private var connectivity: ConnectivityModel
    private let bridge: ConnectivityBridge

    init() {
        let model = ConnectivityModel()
        _connectivity = State(initialValue: model)
        bridge = ConnectivityBridge(model: model)
        // Activate at launch so files queued by the watch are received in the background.
        bridge.activate()
    }

    var body: some Scene {
        WindowGroup {
            SpikeView(bridge: bridge)
                .environment(connectivity)
        }
    }
}
