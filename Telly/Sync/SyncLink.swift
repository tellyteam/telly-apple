import CoreImage.CIFilterBuiltins
import UIKit

/**
 * The address a QR code carries to link another device (telly-sync PROTOCOL.md):
 * `telly://sync?code=…`, plus `&relay=…` only for a relay other than telly's own.
 */
enum SyncLink {
    static func url(code: String, relay: String, defaultRelay: String) -> String {
        let base = "telly://sync?code=\(code)"
        var r = relay
        while r.hasSuffix("/") { r.removeLast() }
        guard r != defaultRelay else { return base }
        return base + "&relay=" + (relay.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? relay)
    }

    /** The code and relay from a link, or nil if it isn't one. */
    static func parse(_ text: String, defaultRelay: String) -> (code: String, relay: String)? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "telly", c.host?.lowercased() == "sync",
              let code = c.queryItems?.first(where: { $0.name == "code" })?.value.flatMap(SyncCrypto.normaliseCode)
        else { return nil }
        let relay = c.queryItems?.first(where: { $0.name == "relay" })?.value ?? defaultRelay
        return relay.hasPrefix("https://") ? (code, relay) : nil
    }

    /** A crisp QR image of [text], for showing this iPad's code to another device. */
    static func image(_ text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
