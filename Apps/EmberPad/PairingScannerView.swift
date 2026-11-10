import AVFoundation
import SwiftUI
import UIKit

/// The sheet the Library's File Inbox menu opens: scan the QR the Mac Companion shows. Only the camera usage
/// string is needed, no entitlement. While the screen is being captured or mirrored the camera preview is
/// replaced, because the code it would show is the pairing secret.
struct PairingScannerSheet: View {
    @ObservedObject var pairing: PairingController
    @ObservedObject var presentation: PresentationState
    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraAccess.current

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("On your Mac, open EmberPad Companion and choose **Pair iPad…**, then point this camera at the code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text2)
                scanner
                    .frame(maxWidth: 420, maxHeight: 420)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let error = pairing.errorMessage {
                    Text(error).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { camera = await CameraAccess.request() }
            .onAppear { pairing.errorMessage = nil }
            .onDisappear { pairing.errorMessage = nil }
        }
    }

    @ViewBuilder private var scanner: some View {
        if presentation.captureActive || presentation.externalSceneCount > 0 {
            placeholder("eye.slash", "Stop sharing or recording the screen to scan the pairing code.")
        } else {
            switch camera {
            case .authorized:
                QRScannerView { payload in
                    if pairing.accept(scannedPayload: payload) { dismiss() }
                }
            case .notDetermined:
                placeholder("camera", "Waiting for camera access…")
            case .denied:
                placeholder("camera.badge.ellipsis", "Allow camera access for Ember Slate in Settings to scan the pairing code.")
            case .unavailable:
                placeholder("camera", "No camera is available on this device.")
            }
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Theme.text3)
            Text(text).multilineTextAlignment(.center).foregroundStyle(Theme.text2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface2)
    }
}

enum CameraAccess: Equatable {
    case authorized, notDetermined, denied, unavailable

    static var current: CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func request() async -> CameraAccess {
        guard current == .notDetermined else { return current }
        return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
    }
}

/// A live camera preview that reports the first QR code it reads. The session runs off the main thread and
/// stops as soon as the view goes away.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "EmberPad.QRScanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastPayload: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let connection = previewLayer?.connection, let angle = Self.rotationAngle(for: view.window?.windowScene?.interfaceOrientation),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            // A refused code keeps the camera running; report each distinct code once.
            guard let payload = payloads.first, payload != lastPayload else { return }
            lastPayload = payload
            onCode?(payload)
        }
    }

    private static func rotationAngle(for orientation: UIInterfaceOrientation?) -> CGFloat? {
        switch orientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        default: nil
        }
    }
}
