import SiliconAuditCore
import SwiftUI

/// Every change the monitor recorded, newest first: a headline and context per check, then one
/// row per changed fact that opens to the plain sentence, what it could mean, and the raw
/// transition.
public struct ChangesView: View {
    @Environment(ChangeMonitor.self) private var monitor: ChangeMonitor?

    public init() {}

    public var body: some View {
        Group {
            if let monitor {
                content(monitor)
            }
        }
        .navigationTitle(String(localized: "Changes", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func content(_ monitor: ChangeMonitor) -> some View {
        if monitor.records.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No changes recorded", bundle: .module), systemImage: "checkmark.shield")
            } description: {
                if let date = monitor.baselineRecordedAt {
                    Text(String(localized: "Every check since \(date.formatted(date: .abbreviated, time: .shortened)) has matched the recorded readings.", bundle: .module))
                } else {
                    Text(String(localized: "The first reading becomes the baseline; later checks are compared with it.", bundle: .module))
                }
            }
        } else {
            List {
                ForEach(monitor.records) { record in
                    Section {
                        ChangeSummaryRow(diff: record.diff)
                        ForEach(record.diff.changes) { change in
                            NavigationLink { FactChangeDetailView(change: change, diff: record.diff) } label: {
                                FactChangeRow(change: change)
                            }
                        }
                    } header: {
                        Text(record.detectedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .onAppear { monitor.markAllSeen() }
        }
    }
}

/// Headline and context for one detected change set.
struct ChangeSummaryRow: View {
    let diff: ReportDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(ChangeCopy.headline(diff)).font(.headline)
            } icon: {
                Image(systemName: diff.securityChanges.isEmpty ? (diff.osChanged ? "arrow.down.circle" : "info.circle") : "exclamationmark.shield.fill")
                    .foregroundStyle(diff.securityChanges.isEmpty ? Color.accentColor : .orange)
            }
            Text(ChangeCopy.context(diff))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Before-and-after glyphs, the name, and the plain sentence.
struct FactChangeRow: View {
    let change: ReportDiff.FactChange

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 2) {
                glyph(change.before)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                glyph(change.after)
            }
            .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.name)
                    if change.securityRelevant {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange).imageScale(.small)
                            .accessibilityLabel(Text(String(localized: "Security-relevant", bundle: .module)))
                    }
                }
                Text(ChangeCopy.plain(change))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func glyph(_ state: FactState?) -> some View {
        if let state {
            StateGlyph(state)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary).imageScale(.large).accessibilityHidden(true)
        }
    }
}

/// One change at full depth.
struct FactChangeDetailView: View {
    let change: ReportDiff.FactChange
    let diff: ReportDiff

    var body: some View {
        List {
            Section {
                Text(ChangeCopy.plain(change)).font(.body)
            }
            Section {
                Text(ChangeCopy.meaning(change, osChanged: diff.osChanged)).font(.callout)
            } header: {
                Text(String(localized: "What it could mean", bundle: .module))
            }
            Section {
                LabeledContent(String(localized: "Before", bundle: .module), value: side(change.before, change.beforeValue))
                LabeledContent(String(localized: "After", bundle: .module), value: side(change.after, change.afterValue))
                if let key = change.key {
                    LabeledContent(String(localized: "sysctl key", bundle: .module)) {
                        Text(key).font(.callout.monospaced()).selectableText()
                    }
                }
                LabeledContent(String(localized: "Category", bundle: .module), value: ReportModel.title(for: change.category))
                LabeledContent(String(localized: "Security-relevant", bundle: .module), value: change.securityRelevant ? String(localized: "Yes", bundle: .module) : String(localized: "No", bundle: .module))
                LabeledContent(String(localized: "Earlier reading", bundle: .module), value: "\(diff.osVersionBefore) (\(diff.osBuildBefore)) · \(diff.baselineCollectedAt)")
                LabeledContent(String(localized: "Later reading", bundle: .module), value: "\(diff.osVersionAfter) (\(diff.osBuildAfter)) · \(diff.currentCollectedAt)")
            } header: {
                Text(String(localized: "Technical detail", bundle: .module))
            } footer: {
                Text(String(localized: "Both readings are measured: reported by this device's kernel at the time, not proven in the silicon.", bundle: .module))
            }
        }
        .navigationTitle(change.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func side(_ state: FactState?, _ value: String?) -> String {
        guard let state else { return String(localized: "Not reported", bundle: .module) }
        if state == .value, let value { return value }
        return StateStyle.label(state)
    }
}

/// The Overview card that appears while there are changes the user has not opened yet.
struct ChangesCard: View {
    let records: [ChangeMonitor.Record]

    var body: some View {
        if let latest = records.first {
            NavigationLink { ChangesView() } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: latest.diff.securityChanges.isEmpty ? "info.circle.fill" : "exclamationmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(latest.diff.securityChanges.isEmpty ? Color.accentColor : .orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(records.count == 1
                             ? ChangeCopy.headline(latest.diff)
                             : String(localized: "\(records.count) checks found changes", bundle: .module))
                            .font(.subheadline.weight(.semibold))
                        if let first = latest.diff.changes.first {
                            Text(ChangeCopy.plain(first)).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(ChangeCopy.context(latest.diff)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(String(localized: "See what changed", bundle: .module)).font(.caption.weight(.medium)).foregroundStyle(.tint)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((latest.diff.securityChanges.isEmpty ? Color.accentColor : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The one-time invitation to turn on notifications, shown once a baseline exists.
struct MonitorPromptCard: View {
    let monitor: ChangeMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(String(localized: "Watch for changes?", bundle: .module)).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "bell.badge").foregroundStyle(.tint)
            }
            Text(String(localized: "Silicon Audit recorded what this device reports today. It checks again when you open it and in the background, and can notify you if a reading changes.", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(String(localized: "Notify me", bundle: .module)) {
                    Task { await monitor.requestNotifications() }
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Not now", bundle: .module)) {
                    monitor.promptDismissed = true
                }
                .buttonStyle(.bordered)
            }
            .controlSizeIfAvailable()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func controlSizeIfAvailable() -> some View {
        #if os(tvOS)
        self
        #else
        self.controlSize(.small)
        #endif
    }
}
