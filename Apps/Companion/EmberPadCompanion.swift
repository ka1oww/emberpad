import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmberSyncKit

@main
struct EmberPadCompanion: App {
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        MenuBarExtra("EmberPad", systemImage: "doc.text") {
            Text("EmberPad Companion")
            Text("Local library preparation").font(.caption)
            if let folder = model.folder { Text(folder.lastPathComponent) }
            Button("Choose master folder…") { model.chooseFolder() }
            Button("Scan worksheets") { model.scan() }.disabled(model.folder == nil || model.isScanning)
            if model.isScanning { Text("Scanning…") }
            if let count = model.worksheetCount { Text("\(count) worksheets in manifest preview") }
            if let message = model.message { Text(message) }
            Divider()
            Text("Device sync and pairing await the next build phase.")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var worksheetCount: Int?
    @Published private(set) var message: String?
    @Published private(set) var isScanning = false

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use local master folder"
        guard panel.runModal() == .OK else { return }
        folder = panel.url; worksheetCount = nil; message = nil
    }

    func scan() {
        guard let folder, !isScanning else { return }
        isScanning = true
        Task {
            defer { isScanning = false }
            do {
                let manifest = try await Task.detached {
                    let items = try InboxScanner.items(in: folder)
                    let entries = try items.map { item in
                        let values = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        return try ManifestEntry(source: item.source, sha256: .digest(fileAt: item.url),
                                                 size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
                    }
                    return try Manifest(generatedAt: Date(), files: entries)
                }.value
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("EmberPad Companion", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                try ManifestCodec.encode(manifest).write(to: support.appendingPathComponent("manifest-preview.json"), options: .atomic)
                worksheetCount = manifest.files.count
                message = "Manifest preview saved locally. No device connection is active."
            } catch { message = error.localizedDescription }
        }
    }
}
