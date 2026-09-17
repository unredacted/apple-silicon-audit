#if os(watchOS)
import SiliconAuditCore
import SwiftUI

/// The watch app (SPEC §7): a single scrolling list with a summary line, the plain-language
/// topics, the doors to every reading, and export via `transferFile` to the phone or a compact
/// `ShareLink`. Viewing never depends on the phone.
public struct WatchRootView: View {
    @State private var model: ReportModel
    let transfer: TransferState
    let send: (Report) -> Void

    public init(model: ReportModel = ReportModel(), transfer: TransferState, send: @escaping (Report) -> Void) {
        _model = State(initialValue: model)
        self.transfer = transfer
        self.send = send
    }

    public var body: some View {
        NavigationStack {
            List {
                OverviewContent(model: model, watchLayout: true, showsReferenceLinks: true)
                if let report = model.report {
                    exportSection(report)
                }
            }
            .navigationTitle("Silicon Audit")
        }
        .task { if model.report == nil { await model.run() } }
    }

    @ViewBuilder
    private func exportSection(_ report: Report) -> some View {
        Section {
            Button {
                send(report)
            } label: {
                Label(String(localized: "Send to iPhone", bundle: .module), systemImage: "iphone.and.arrow.forward")
            }
            .disabled(!transfer.isSupported || !transfer.isActivated)
            if let compact = try? CompactExport.encode(report) {
                ShareLink(item: compact, subject: Text("Silicon Audit \(report.device.identity)")) {
                    Label(String(localized: "Share compact code", bundle: .module), systemImage: "square.and.arrow.up")
                }
            }
            if let status = transfer.status {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            } else if !transfer.isActivated {
                Text(String(localized: "Connecting to iPhone…", bundle: .module)).font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Export", bundle: .module))
        } footer: {
            Text(String(localized: "Send to iPhone delivers the full JSON export in the background, even if the phone is out of reach right now. The compact code holds the security-relevant facts and fits a message.", bundle: .module))
        }
    }
}
#endif
