import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import EmberSyncKit
import SwiftUI

/// What the menu-bar window's iPad section shows. It carries only public facts, never the secret.
enum CompanionPairingStatus: Equatable {
    case notPaired
    /// A pairing exists on this Mac: when it was created and the start of its service id.
    case paired(createdAt: Date, shortID: String)
}

/// The Mac side of EP-22. Pair iPad creates one pairing (a fresh secret and service id from the secure random
/// source), saves it only in this Mac's Keychain and shows it once as a QR code in a window that is excluded
/// from screenshots and screen sharing. Forget iPad deletes it, so the old secret stops working for every future
/// connection; pairing again creates a new one. The listener (EP-23) loads the credential from `keychain`.
@MainActor
final class CompanionPairingModel: ObservableObject {
    @Published private(set) var status: CompanionPairingStatus = .notPaired
    @Published private(set) var message: String?

    let keychain: any PairingSecretStore
    private let codeWindow = PairingCodeWindowController()

    init(keychain: any PairingSecretStore = PairingKeychain()) {
        self.keychain = keychain
        reload()
    }

    func reload() {
        do {
            status = Self.status(for: try keychain.load())
        } catch {
            status = .notPaired
            message = error.localizedDescription
        }
    }

    /// Create a pairing if there is none, then show its code.
    func pairIPad() {
        do {
            let credential: PairingCredential
            if let existing = try loadTreatingCorruptAsAbsent() {
                credential = existing
            } else {
                credential = try PairingCredential.generate()
                try keychain.save(credential)
            }
            status = Self.status(for: credential)
            message = nil
            codeWindow.show(credential)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Delete this Mac's pairing and close any visible code.
    func forget() {
        codeWindow.close()
        do {
            try keychain.delete()
            status = .notPaired
            message = "Forgotten. Also choose Forget Mac on the iPad, then pair again."
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadTreatingCorruptAsAbsent() throws -> PairingCredential? {
        do {
            return try keychain.load()
        } catch PairingError.corruptRecord {
            return nil
        }
    }

    private static func status(for credential: PairingCredential?) -> CompanionPairingStatus {
        guard let credential else { return .notPaired }
        return .paired(createdAt: credential.createdAt, shortID: String(credential.serviceID.prefix(6)))
    }
}

/// The pairing-code window. `sharingType = .none` keeps it out of screenshots, screen recordings and screen
/// sharing where macOS honours it; it closes itself after five minutes so the code is not left on screen.
@MainActor
final class PairingCodeWindowController {
    static let visibleFor: Duration = .seconds(300)
    private var window: NSWindow?
    private var closeTask: Task<Void, Never>?

    func show(_ credential: PairingCredential) {
        close()
        let view = PairingCodeView(payload: credential.qrPayload, onDone: { [weak self] in self?.close() })
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair iPad"
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        self.window = window
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
    }
}

struct PairingCodeView: View {
    let payload: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair iPad").font(.system(size: 15, weight: .semibold))
            Text("On the iPad, open EmberPad, touch and hold **File Inbox**, choose **Pair with Mac…** and scan this code.")
                .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let image = PairingQRCode.image(for: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Pairing code")
            } else {
                Text("The pairing code could not be drawn.").foregroundStyle(.red)
            }
            Text("Keep this code private: anyone who scans it can sync with this Mac. It closes in five minutes.")
                .font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CompanionLibraryContent.emberRed)
        }
        .padding(20)
        .frame(width: 360)
    }
}

enum PairingQRCode {
    /// A crisp QR code image for `payload`, one pixel per module (scaled up with no interpolation by the view).
    static func image(for payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
