// Only the tvOS export screen shows a QR code; keeping this tvOS-only keeps CoreImage out of the
// other platforms' link.
#if os(tvOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR rendering of the compact export (SPEC §8). Base45's alphabet is exactly QR's alphanumeric
/// set, and CoreImage's generator picks alphanumeric mode for it, so capacity is 4,296 characters
/// at level L and 3,391 at level M; the compact export is kept under 3,300 characters (ExportTests),
/// which leaves room for level M on every platform.
enum QRCode {
    static let correctionLevel = "M"

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// One module per pixel, upscaled without interpolation inside a white quiet zone, so the code
/// stays crisp at any size.
struct QRCodeView: View {
    let text: String
    let label: String
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if failed {
                Label(String(localized: "The compact export is too large for a QR code.", bundle: .module), systemImage: "qrcode")
            } else {
                ProgressView()
            }
        }
        .task(id: text) {
            image = QRCode.image(for: text)
            failed = image == nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}
#endif
