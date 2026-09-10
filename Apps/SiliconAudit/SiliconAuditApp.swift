import SiliconAuditUI
import SwiftUI

@main
struct SiliconAuditApp: App {
    var body: some Scene {
        WindowGroup {
            AuditRootView()
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
