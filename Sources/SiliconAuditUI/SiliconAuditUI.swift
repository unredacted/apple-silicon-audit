import SiliconAuditCore
import SwiftUI

/// Shared SwiftUI layer. Real views arrive in Phase 4; this proves the module
/// builds for every platform in the package manifest.
public enum SiliconAuditUI {
    public static let version = SiliconAuditCore.version
}

/// Shows the engine version. Used by app targets as a placeholder root view.
public struct VersionLabel: View {
    public init() {}

    public var body: some View {
        Text("Silicon Audit \(SiliconAuditUI.version)")
            .font(.headline)
            .accessibilityLabel("Silicon Audit version \(SiliconAuditUI.version)")
    }
}
