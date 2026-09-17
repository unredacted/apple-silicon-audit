import SiliconAuditCore
import SwiftUI

/// Change monitoring: what is recorded, when it was last checked, whether to notify, and the
/// honest limits of what a kernel reading can catch.
public struct MonitorView: View {
    let model: ReportModel
    @Environment(ChangeMonitor.self) private var monitor: ChangeMonitor?
    @State private var checking = false

    public init(model: ReportModel) { self.model = model }

    public var body: some View {
        Group {
            if let monitor {
                content(monitor)
            }
        }
        .navigationTitle(String(localized: "Change monitoring", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func content(_ monitor: ChangeMonitor) -> some View {
        @Bindable var monitor = monitor
        List {
            Section {
                LabeledContent(String(localized: "Baseline recorded", bundle: .module), value: monitor.baselineRecordedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Not yet", bundle: .module))
                LabeledContent(String(localized: "Last check", bundle: .module), value: monitor.lastCheckAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Not yet", bundle: .module))
                if let baseline = monitor.baseline {
                    LabeledContent(String(localized: "Baseline system", bundle: .module), value: "\(baseline.environment.osVersion) (\(baseline.environment.osBuild))")
                }
                NavigationLink { ChangesView() } label: {
                    LabeledContent(String(localized: "Changes recorded", bundle: .module), value: "\(monitor.records.count)")
                }
            } header: {
                Text(String(localized: "Status", bundle: .module))
            } footer: {
                Text(String(localized: "The first reading becomes the baseline. Every later check is compared with the most recent reading, so each change is reported once.", bundle: .module))
            }

            #if !os(tvOS)
            Section {
                Toggle(isOn: Binding(
                    get: { monitor.notificationsEnabled && monitor.authorization != .denied },
                    set: { on in
                        if on {
                            Task { await monitor.requestNotifications() }
                        } else {
                            monitor.notificationsEnabled = false
                            monitor.promptDismissed = true
                        }
                    }
                )) {
                    Label(String(localized: "Notify when a reading changes", bundle: .module), systemImage: "bell.badge")
                }
                if monitor.authorization == .denied {
                    Text(String(localized: "Notifications are turned off for Silicon Audit in system settings. Changes are still recorded and shown here.", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Notifications", bundle: .module))
            } footer: {
                Text(String(localized: "Checks run when the app opens and periodically in the background, as the system allows. A notification names the device and the first change; the details are in Changes.", bundle: .module))
            }
            #endif

            Section {
                Button {
                    checking = true
                    Task {
                        await model.run()
                        if let report = model.report { await monitor.processInForeground(report) }
                        checking = false
                    }
                } label: {
                    Label(String(localized: "Check now", bundle: .module), systemImage: "arrow.clockwise")
                }
                .disabled(checking || model.phase == .running)
                Button {
                    if let report = model.report { monitor.resetBaseline(report) }
                } label: {
                    Label(String(localized: "Use the current readings as the baseline", bundle: .module), systemImage: "flag.checkered")
                }
                .disabled(model.report == nil)
            } footer: {
                Text(String(localized: "Starting over forgets the recorded changes.", bundle: .module))
            }

            Section {
                Text(ChangeCopy.limits).font(.callout)
            } header: {
                Text(String(localized: "What this can and cannot catch", bundle: .module))
            }
        }
        .task { await monitor.refreshAuthorization() }
    }
}
