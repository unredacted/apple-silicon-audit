import SwiftUI

@main
struct SiliconAuditWatchApp: App {
    @State private var connectivity: ConnectivityModel
    private let bridge: ConnectivityBridge

    init() {
        let model = ConnectivityModel()
        _connectivity = State(initialValue: model)
        bridge = ConnectivityBridge(model: model)
        bridge.activate()
    }

    var body: some Scene {
        WindowGroup {
            SpikeView(bridge: bridge)
                .environment(connectivity)
        }
    }
}
