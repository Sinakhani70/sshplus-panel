import SwiftUI
import AVFoundation

/// Camera view that reports the first QR code it sees (the panel shows a QR on every subscription page).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onFail: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        c.onFail = onFail
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onFail: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: setup()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async { ok ? self.setup() : self.onFail?("Camera access was denied.") }
                }
            default: onFail?("Camera access is off. Enable it in Settings > CK Client.")
            }
        }

        private func setup() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { onFail?("No camera available."); return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { onFail?("Cannot read from the camera."); return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered,
                  let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let text = obj.stringValue else { return }
            delivered = true
            session.stopRunning()
            onCode?(text)
        }
    }
}
