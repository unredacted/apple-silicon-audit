#if os(tvOS)
import SiliconAuditCore
import SwiftUI

/// Export surface on Apple TV (SPEC §6.4, §8): there is no share sheet, file system access, or
/// pasteboard, so the compact export is shown as a QR code to be scanned by another device and
/// decoded with `silicon-audit import`.
public struct ExportView: View {
    let model: ReportModel
    @State private var compact: String?
    @State private var error: String?

    public init(model: ReportModel) { self.model = model }

    public var body: some View {
        // A centered column, like the lists on the other screens: the tvOS sidebar floats over the
        // leading edge of the detail column, so nothing may sit there.
        ScrollView {
            VStack(spacing: 28) {
                Text(String(localized: "Scan to export", bundle: .module))
                    .font(.title2.weight(.semibold))
                if let compact {
                    QRCodeView(text: compact, label: String(localized: "QR code of the compact export", bundle: .module))
                        .frame(width: 560, height: 560)
                    Text(String(localized: "\(compact.count) characters, Base45 over deflate, error correction level M.", bundle: .module))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .frame(height: 560)
                } else {
                    ProgressView()
                        .frame(height: 560)
                }
                Text(String(localized: "Point a phone camera at the code and copy the text it reads. The silicon-audit import command decodes it into the same JSON the other platforms export.", bundle: .module))
                    .multilineTextAlignment(.center)
                Text(String(localized: "Security-relevant measured facts and identity only. The full export, with every fact and Apple's documented claims, is available from the Mac, iPhone, iPad, and Apple Vision Pro apps.", bundle: .module))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let report = model.report {
                    EnvironmentBanner(report.environment)
                }
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .navigationTitle(String(localized: "Export", bundle: .module))
        .task {
            do {
                compact = try model.compactText()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#elseif !os(watchOS)
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
