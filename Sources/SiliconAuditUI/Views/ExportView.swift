#if !os(watchOS)
import SiliconAuditCore
import SwiftUI
import UniformTypeIdentifiers

/// Export surface (SPEC §6.4, §8): one primary action per platform, raw JSON never the
/// primary surface. Share sheet and a Save panel/Files picker for the full JSON; the compact
/// Base45 text for QR and paste.
public struct ExportView: View {
    let model: ReportModel
    @State private var fileURL: URL?
    @State private var showingExporter = false
    @State private var compact: String?
    @State private var error: String?
    @State private var copied = false

    public init(model: ReportModel) { self.model = model }

    public var body: some View {
        List {
            Section {
                if let url = fileURL {
                    ShareLink(item: url) {
                        Label(String(localized: "Share JSON export", bundle: .module), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showingExporter = true
                    } label: {
                        Label(String(localized: "Save JSON export…", bundle: .module), systemImage: "folder")
                    }
                    Text(url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView()
                }
            } header: {
                Text(String(localized: "Full export", bundle: .module))
            } footer: {
                Text(String(localized: "Schema 1.x JSON with provenance on every fact. Contains no serial number, UDID, hostname, or account. Contribute it to the results database with a pull request.", bundle: .module))
            }

            Section {
                if let compact {
                    Button {
                        copy(compact)
                    } label: {
                        Label(copied ? String(localized: "Copied", bundle: .module) : String(localized: "Copy compact code", bundle: .module),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Text(String(localized: "\(compact.count) characters, Base45 over deflate. Decode with `silicon-audit import`.", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Compact code", bundle: .module))
            } footer: {
                Text(String(localized: "Security-relevant measured facts and identity only; fits a QR code.", bundle: .module))
            }
        }
        .navigationTitle(String(localized: "Export", bundle: .module))
        .task {
            do {
                fileURL = try model.exportFileURL()
                compact = try model.compactText()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showingExporter, document: ReportDocument(url: fileURL), contentType: .json,
                      defaultFilename: fileURL?.deletingPathExtension().lastPathComponent ?? "silicon-audit") { result in
            if case .failure(let e) = result { error = e.localizedDescription }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
    }
}

/// The JSON export as a `FileDocument` for `fileExporter`.
public struct ReportDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [.json]
    public var data: Data

    public init(url: URL?) {
        data = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
    }

    public init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
