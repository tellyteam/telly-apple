import SwiftUI
#if os(iOS)
import VisionKit
#endif

extension View {
    /** Shows the camera to read a sync QR code (iPad; Macs show their code instead). */
    func qrScanner(isPresented: Binding<Bool>, onFound: @escaping (String) -> Void) -> some View {
        #if os(iOS)
        sheet(isPresented: isPresented) { QRScannerView(onFound: onFound) }
        #else
        self
        #endif
    }
}

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

            func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
                for item in added {
                    guard !done, case let .barcode(code) = item, let text = code.payloadStringValue, text.lowercased().hasPrefix("telly://sync") else { continue }
                    done = true
                    scanner.stopScanning()
                    onFound(text)
                }
            }
        }
    }
}
#endif
