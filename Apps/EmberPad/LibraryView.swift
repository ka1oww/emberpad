import SwiftUI
import UniformTypeIdentifiers
import EmberSyncKit

struct LibraryView: View {
    @ObservedObject var library: LibraryController
    @ObservedObject var presentation: PresentationState
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                SigningBanner()
                if presentation.captureActive && presentation.externalSceneCount == 0 {
                    Text("Main screen capture detected. Private answers are hidden.").foregroundStyle(.red)
                } else if presentation.externalSceneCount > 0 {
                    Text("Student display connected. Stay in EmberPad while sharing.").foregroundStyle(.secondary)
                }
                if let error = library.errorMessage {
                    Section("Library needs attention") {
                        Text(error).foregroundStyle(.red)
                        Button("Dismiss") { library.errorMessage = nil }
                    }
                }
                Section("Classes") {
                    ForEach(library.classes, id: \.self) { name in
                        NavigationLink(name) { DocumentListView(library: library, presentation: presentation, className: name) }
                    }
                    if library.classes.isEmpty { Text("Import a worksheet to create a class folder.").foregroundStyle(.secondary) }
                }
                Section {
                    NavigationLink("Archived") { DocumentListView(library: library, presentation: presentation, className: nil) }
                    if let last = library.lastInboxImport { Text("Inbox checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.footnote) }
                    Text("Automatic Mac sync is planned. Worksheets imported here are available offline.").font(.footnote).foregroundStyle(.secondary)
                }
#if DEBUG
                // EP-03 probe entry. Compiled out of Release; release behaviour unchanged.
                Section("Debug") {
                    NavigationLink("Device checks") { DeviceChecksView(presentation: presentation) }
                }
#endif
            }
            .navigationTitle("EmberPad")
            .toolbar {
                Button("Import from Files", systemImage: "square.and.arrow.down") { showImport = true }
                    .disabled(library.isImporting)
                Button("File Inbox", systemImage: "tray") { Task { await library.fileInbox() } }.disabled(library.isImporting)
            }
            .refreshable { await library.fileInbox() }
            .sheet(isPresented: $showImport) { ImportWorksheetView(library: library) }
            .task { await library.refresh() }
        }
        .tint(Theme.tint)
    }
}

private struct DocumentListView: View {
    @ObservedObject var library: LibraryController
    @ObservedObject var presentation: PresentationState
    let className: String?
    var body: some View {
        List {
            ForEach(library.documents.filter {
                className == nil ? $0.status == .archived : ($0.status != .archived && $0.source.source.classFolder == className)
            }) { doc in
                NavigationLink {
                    EditorScreen(documentID: doc.id, library: library, presentation: presentation)
                } label: {
                    VStack(alignment: .leading) {
                        Text(doc.title)
                        if doc.status == .olderVersion { Text("Older version").font(.caption).foregroundStyle(.secondary) }
                        else if doc.isUpdated { Text("Updated").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle(className ?? "Archived")
        .task { await library.refresh() }
    }
}

private struct ImportWorksheetView: View {
    @ObservedObject var library: LibraryController
    @Environment(\.dismiss) private var dismiss
    @State private var className = "Unfiled"
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Class folder", text: $className)
                if !library.classes.isEmpty {
                    Menu("Use existing class") { ForEach(library.classes, id: \.self) { name in Button(name) { className = name } } }
                }
                Button("Choose PDFs") { showPicker = true }
                    .disabled(className.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isImporting)
                if library.isImporting { ProgressView("Importing") }
                if let error = library.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Import worksheets")
            .toolbar { Button("Close") { dismiss() } }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls, className: className); if library.errorMessage == nil { dismiss() } }
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct SigningBanner: View {
    private let expiry = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { ProvisioningProfile.expirationDate(in: $0) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let status = SigningStatus(expirationDate: expiry, now: context.date)
            VStack(alignment: .leading) {
                if let expiry { Text("Signed until \(expiry.formatted(date: .abbreviated, time: .shortened))") }
                else { Text("Signing expiry unknown") }
                if status == .warning || status == .urgent || status == .expired {
                    Text("Keep the iPad on home Wi-Fi near the Mac tonight.")
                }
            }
            .font(.footnote)
            .foregroundStyle(status == .urgent || status == .expired ? Color.red : status == .warning ? .orange : .secondary)
        }
    }
}
