import SwiftUI
import SiliconAuditCore

/// The M0 spike screen, shared by the iOS and watchOS apps. Deliberately plain:
/// its job is to answer the checklist on hardware, not to be the product UI.
struct SpikeView: View {
    let bridge: ConnectivityBridge
    @Environment(ConnectivityModel.self) private var connectivity

    @State private var report: SpikeReport?
    @State private var savedURL: URL?
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    verdictSection(report)
                    environmentSection(report)
                    keySection("Memory tagging keys", report.memoryTagging)
                    keySection("OS tagging counters", report.osTagging)
                    exportSection(report)
                    keySection("All walked keys (\(report.walked.count))", report.walked)
                } else {
                    ProgressView("Probing…")
                }
            }
            .navigationTitle("Spike")
            .task { runProbe() }
            .refreshable { runProbe() }
        }
    }

    private func runProbe() {
        let r = SpikeStore.run()
        report = r
        do {
            savedURL = try SpikeStore.save(r)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func verdictSection(_ r: SpikeReport) -> some View {
        Section("M0 verdict") {
            ForEach(r.verdict, id: \.self) { line in
                Label {
                    Text(line)
                } icon: {
                    Image(systemName: line.contains("FAILED") || line.hasPrefix("WARNING") ? "exclamationmark.triangle" : "checkmark.circle")
                }
                .font(.footnote)
            }
            if !r.restrictedKeys.isEmpty {
                Text("Restricted: " + r.restrictedKeys.joined(separator: ", ")).font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func environmentSection(_ r: SpikeReport) -> some View {
        Section("Environment") {
            row("Platform", "\(r.platform) \(r.arch)")
            row("OS", "\(r.osVersion) (\(r.osBuild))")
            row("hw.product", r.hwProduct ?? "absent")
            row("hw.machine", r.hwMachine ?? "absent")
            row("hw.model", r.hwModel ?? "absent")
            row("hw.target", r.hwTarget ?? "absent")
            row("cpufamily", r.cpufamilyHex ?? "absent")
            row("SoC id", r.socID ?? "not in kern.version")
            Text(r.kernelVersion).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func keySection(_ title: String, _ lines: [SpikeReport.KeyLine]) -> some View {
        Section(title) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.key.replacingOccurrences(of: "hw.optional.", with: "")).font(.caption.monospaced())
                    Text(line.result).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func exportSection(_ r: SpikeReport) -> some View {
        Section("Export") {
            if let saveError {
                Text("Save failed: \(saveError)").font(.caption2)
            } else if let savedURL {
                Text("Saved \(savedURL.lastPathComponent)").font(.caption2).foregroundStyle(.secondary)
            }
            row("Session", connectivity.activationState)
            row("Reachable", connectivity.isReachable ? "yes" : "no")
            Text(connectivity.status).font(.caption2)
            #if os(watchOS)
            Button {
                bridge.send(r)
            } label: {
                Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
            }
            .disabled(!connectivity.isSupported || connectivity.activationState != "activated")
            #else
            if let received = connectivity.receivedReport {
                NavigationLink {
                    ReceivedReportView(report: received, url: connectivity.receivedFileURL)
                } label: {
                    Label("From Apple Watch: \(received.hwProduct ?? "?") (\(received.osBuild))", systemImage: "applewatch")
                }
            } else {
                Text("Nothing received from Apple Watch yet").font(.caption2).foregroundStyle(.secondary)
            }
            if let savedURL {
                ShareLink(item: savedURL) { Label("Share this device's report", systemImage: "square.and.arrow.up") }
            }
            if let url = connectivity.receivedFileURL {
                ShareLink(item: url) { Label("Share the watch report", systemImage: "square.and.arrow.up") }
            }
            #endif
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// iOS: shows a report that arrived from the watch.
struct ReceivedReportView: View {
    let report: SpikeReport
    let url: URL?

    var body: some View {
        List {
            Section("M0 verdict (Apple Watch)") {
                ForEach(report.verdict, id: \.self) { Text($0).font(.footnote) }
                if !report.restrictedKeys.isEmpty {
                    Text("Restricted: " + report.restrictedKeys.joined(separator: ", ")).font(.caption2)
                }
            }
            Section("Environment") {
                Text("\(report.platform) \(report.arch), \(report.osVersion) (\(report.osBuild))").font(.caption)
                Text("\(report.hwProduct ?? "?") / \(report.hwMachine ?? "?") / \(report.hwModel ?? "?") / \(report.hwTarget ?? "?")").font(.caption.monospaced())
                Text(report.kernelVersion).font(.caption2).foregroundStyle(.secondary)
            }
            Section("Memory tagging keys") {
                ForEach(report.memoryTagging) { line in
                    VStack(alignment: .leading) {
                        Text(line.key).font(.caption.monospaced())
                        Text(line.result).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("OS tagging counters") {
                ForEach(report.osTagging) { line in
                    VStack(alignment: .leading) {
                        Text(line.key).font(.caption.monospaced())
                        Text(line.result).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("All walked keys (\(report.walked.count))") {
                ForEach(report.walked) { line in
                    VStack(alignment: .leading) {
                        Text(line.key).font(.caption.monospaced())
                        Text(line.result).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Apple Watch report")
    }
}
