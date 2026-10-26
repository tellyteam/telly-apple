import CoreImage.CIFilterBuiltins

/**
 * The address a QR code carries to link another device: `telly://sync?code=…`. Sync always uses
 * telly's relay, so a `relay` an older app added is ignored.
 */
enum SyncLink {
    static func url(code: String) -> String { "telly://sync?code=\(code)" }

    /** The code from a link, or nil if it isn't one. */
    static func parse(_ text: String) -> String? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "telly", c.host?.lowercased() == "sync"
        else { return nil }
        return c.queryItems?.first(where: { $0.name == "code" })?.value.flatMap(SyncCrypto.normaliseCode)
    }

    /** A crisp QR image of [text], for showing this device's code to another. */
    static func image(_ text: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return cg
    }
}
