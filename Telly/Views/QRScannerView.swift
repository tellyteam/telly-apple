import SwiftUI
#if os(iOS)
import VisionKit
#endif

extension View {
    /**
     * Shows the camera to read a sync QR code (iPhone and iPad; Macs show their code instead).
     * [onFound] runs once the scanner has closed, so what it opens (a sheet, an alert) can show.
     */
    func qrScanner(isPresented: Binding<Bool>, onFound: @escaping (String) -> Void) -> some View {
        #if os(iOS)
        modifier(QRScannerSheet(isPresented: isPresented, onFound: onFound))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct QRScannerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let onFound: (String) -> Void
    @State private var found: String?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            if let text = found { found = nil; onFound(text) }
        }) { QRScannerView(onFound: { found = $0 }) }
    }
}
#endif

#if os(iOS)
/** Reads a telly sync QR code with the camera (the code shown on a Fire TV, Mac or another iPad). */
struct QRScannerView: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onFound: { text in
                        onFound(text)
                        dismiss()
                    })
                    .ignoresSafeArea()
                } else {
                    Message(title: "The camera isn't available",
                            detail: "Allow telly to use the camera in Settings → Privacy & Security → Camera, or type the code instead.")
                }
            }
            .navigationTitle("Scan the QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let onFound: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                               isHighlightingEnabled: true)
            vc.delegate = context.coordinator
            try? vc.startScanning()
            return vc
        }

        func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onFound: (String) -> Void
            private var done = false
            init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

            /** Another device's link code, or a new device's join code. */
            static func isTelly(_ text: String) -> Bool {
                let t = text.lowercased()
                return t.hasPrefix("telly://sync") || t.hasPrefix("telly://join")
            }

            func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
                for item in added {
                    guard !done, case let .barcode(code) = item, let text = code.payloadStringValue, Self.isTelly(text) else { continue }
                    done = true
                    scanner.stopScanning()
                    onFound(text)
                }
            }
        }
    }
}
#endif
