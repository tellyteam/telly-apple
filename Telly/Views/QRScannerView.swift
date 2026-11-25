import SwiftUI
#if os(iOS)
import AVFoundation
import VisionKit
#endif

extension View {
    /**
     * Shows the camera to read a telly code (iPhone and iPad; Macs have no scanner). [onFound]
     * runs once the scanner has closed, so what it opens (a sheet, an alert) can show.
     */
    func qrScanner(isPresented: Binding<Bool>, onFound: @escaping (String) -> Void) -> some View {
        #if os(iOS)
        modifier(QRScannerSheet(isPresented: isPresented, onFound: onFound))
        #else
        self
        #endif
    }

    /**
     * "Scan a telly code": the one scanner. Whatever it reads goes to [AppModel.scanned], which
     * asks before doing anything (RootView shows the question); anything else says so here.
     */
    func tellyCodeScanner(isPresented: Binding<Bool>) -> some View {
        modifier(TellyCodeScanner(isPresented: isPresented))
    }
}

private struct TellyCodeScanner: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool
    @State private var notTelly = false

    func body(content: Content) -> some View {
        content
            .qrScanner(isPresented: $isPresented) { text in
                if !app.scanned(text) { notTelly = true }
            }
            .alert("That isn't a telly code", isPresented: $notTelly) {
                Button("OK", role: .cancel) {}
            } message: { Text("Scan the QR code telly shows on your TV or your other device.") }
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

/** Reads a telly code with the camera: the QR code a TV, a Mac or another iPhone or iPad shows. */
struct QRScannerView: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /** Before the system asks for the camera, one line says what it's for. */
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                if access == .notDetermined {
                    VStack(spacing: 18) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 54)).foregroundStyle(Theme.accent)
                        Text("telly uses the camera only to read telly codes, and nothing it sees leaves this \(Device.name).")
                            .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                        Button("Continue") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .video)
                                access = AVCaptureDevice.authorizationStatus(for: .video)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                    .frame(maxWidth: 480)
                } else if access == .authorized && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onFound: { text in
                        onFound(text)
                        dismiss()
                    })
                    .ignoresSafeArea()
                } else {
                    Message(title: "The camera isn't available",
                            detail: "Allow telly to use the camera in Settings → Privacy & Security → Camera, or enter a link code instead.")
                }
            }
            .navigationTitle("Scan a telly code")
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

            /** A telly code of any kind: other QR codes in view are passed over. */
            static func isTelly(_ text: String) -> Bool { ScannedCode.parse(text) != nil }

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
