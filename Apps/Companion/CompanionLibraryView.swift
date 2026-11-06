import EmberSyncKit
import SwiftUI

// TODO(EP-06): the iPad theme tokens live in the EmberPad target, which the Companion
// cannot see, so this window deliberately uses macOS system colours plus the Ember red
// badge and primary button, exactly as design 5.7 specifies. Adopt a shared token set
// here if one ever moves somewhere both targets can import. Do not create a second set.

/// The menu-bar window content from design 5.7: header, the Drive EMBER source folder,
/// subjects with document counts, the list of PDFs not read this time, the Prepare button, the iPad pairing and sync
/// section and the renewal line. The header's status line is the sync server's (EP-23). Values in, actions out, so the window can render a synthetic snapshot
/// (screenshots) as well as the live model without touching the real library.
struct CompanionLibraryContent: View {
    static let emberRed = Color(red: 178 / 255, green: 58 / 255, blue: 46 / 255)

    /// Nil when no folder was chosen and the Drive EMBER folder was not found.
    let folder: URL?
    let isSourceAvailable: Bool
    let isPreparing: Bool
    let snapshot: LibrarySnapshot?
    let scannedAt: Date?
    let message: String?
    let onChooseFolder: () -> Void
    let onPrepare: () -> Void
    var pairing: CompanionPairingStatus = .notPaired
    var pairingMessage: String?
    var onPair: () -> Void = {}
    var onForgetPairing: () -> Void = {}
    var syncLine = SyncStatusLine(status: nil, servingDocuments: nil)
    var lastSyncedAt: Date?
    var loginItem: CompanionLoginItemState = .off
    var loginItemMessage: String?
    var onSetOpenAtLogin: (Bool) -> Void = { _ in }
    var onOpenLoginItems: () -> Void = {}

    /// Document counts per subject: the fixed Drive EMBER subjects first, then any other subject found.
    static func subjectCounts(_ snapshot: LibrarySnapshot?) -> [(subject: String, documents: Int)] {
        let counts = snapshot?.documentCounts ?? [:]
        return EmberLibrarySource.displayOrder(counts.keys).map { ($0, counts[$0, default: 0]) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            sourceSection
            Divider()
            subjectsSection
            Divider()
            notFoundSection
            Divider()
            iPadSection
            Divider()
            renewalSection
        }
    }

    // MARK: 1. Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image("CompanionBadge")
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("EmberPad Companion").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    if syncLine.tone != .off {
                        Circle().fill(Self.toneColor(syncLine.tone)).frame(width: 7, height: 7)
                    }
                    Text(syncLine.text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                }
                .opacity(0.65)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: 2. Source folder

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder?.lastPathComponent ?? "Drive EMBER folder").font(.system(size: 13, weight: .semibold))
                    Text(folder?.path ?? "Google Drive › My Drive › EMBER").font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if !isSourceAvailable {
                Label("EMBER folder not found", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Button("Choose EMBER folder…", action: onChooseFolder)
                    .buttonStyle(.bordered)
                    .disabled(isPreparing)
                Button(isPreparing ? "Preparing…" : "Prepare iPad library", action: onPrepare)
                    .buttonStyle(.borderedProminent)
                    .tint(Self.emberRed)
                    .disabled(!isSourceAvailable || isPreparing)
            }
            if isPreparing {
                ProgressView().scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: 3. Subjects with counts

    private var subjectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.subjectCounts(snapshot), id: \.subject) { row in
                HStack {
                    Text(row.subject).font(.system(size: 13))
                    Spacer()
                    Text(snapshot == nil ? "—" : "\(row.documents)").font(.system(size: 13))
                        .foregroundStyle(row.documents > 0 ? .primary : .secondary)
                }
            }
            Text(subjectsFooter).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var subjectsFooter: String {
        guard let snapshot, let scannedAt else {
            return isPreparing ? "Reading the EMBER folder…" : "Not prepared yet."
        }
        return "\(snapshot.documents.count) documents · \(snapshot.pairCount) pairs · " +
            "\(snapshot.singleCopyCount) single · \(snapshot.archivedCount) archived\n" +
            "scanned \(Self.timeFormatter.string(from: scannedAt))"
    }

    // MARK: Not-read list (stays on the Mac)

    private var notFoundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not read this time").font(.system(size: 13, weight: .semibold))
            if let snapshot {
                Text(readSummary(snapshot)).font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !snapshot.misses.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(snapshot.misses.enumerated()), id: \.offset) { _, miss in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Text(miss.path).font(.system(size: 12))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(miss.reason.rawValue).font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            } else if !isPreparing {
                Text("Prepare the library to see any PDF that could not be read.").font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func readSummary(_ snapshot: LibrarySnapshot) -> String {
        let read = snapshot.documents.count.formatted(IntegerFormatStyle<Int>.number.grouping(.automatic))
        let skipped = snapshot.skippedLeftoverPDFs.formatted(IntegerFormatStyle<Int>.number.grouping(.automatic))
        if snapshot.misses.isEmpty {
            return "All \(read) documents read · \(skipped) build files skipped"
        }
        let notRead = snapshot.misses.count.formatted(IntegerFormatStyle<Int>.number.grouping(.automatic))
        return "\(read) documents read · \(skipped) build files skipped · \(notRead) not read"
    }

    static func toneColor(_ tone: SyncStatusLine.Tone) -> Color {
        switch tone {
        case .off: .secondary
        case .ready: .green
        case .active: emberRed
        case .problem: .orange
        }
    }

    // MARK: 4. iPad (pairing, the sync server and open at login)

    private static let pairedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    private var iPadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("iPad").font(.system(size: 13, weight: .semibold))
                phaseTag("PHASE 2")
            }
            switch pairing {
            case .notPaired:
                HStack(spacing: 6) {
                    Circle().fill(.secondary).frame(width: 8, height: 8)
                    Text("Not paired. Pair the iPad to sync over Wi-Fi or directly.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("Pair iPad…", action: onPair).buttonStyle(.bordered)
            case .paired(let createdAt, let shortID):
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(pairedLine(createdAt: createdAt, shortID: shortID))
                        .font(.system(size: 12))
                }
                HStack {
                    Button("Show pairing code…", action: onPair).buttonStyle(.bordered)
                    Button("Forget iPad", role: .destructive, action: onForgetPairing).buttonStyle(.bordered)
                }
            }
            if let pairingMessage {
                Text(pairingMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            openAtLoginRow
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func pairedLine(createdAt: Date, shortID: String) -> String {
        let synced = lastSyncedAt.map { "synced \(Self.timeFormatter.string(from: $0))" } ?? "not synced yet"
        return "Paired (\(shortID)) · \(Self.pairedFormatter.string(from: createdAt)) · \(synced)"
    }

    /// Off until the user turns it on; the Companion never registers itself.
    private var openAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { loginItem == .on || loginItem == .needsApproval },
                                                  set: { onSetOpenAtLogin($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                .disabled(loginItem == .unavailable)
            switch loginItem {
            case .needsApproval:
                Button("Allow in Login Items…", action: onOpenLoginItems).buttonStyle(.link).font(.system(size: 11))
            case .unavailable:
                Text("Move EmberPad Companion to Applications to open it at login.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .on, .off:
                EmptyView()
            }
            if let loginItemMessage {
                Text(loginItemMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: 5. Renewal (static placeholder; nothing is loaded, installed or scheduled)

    private var renewalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Install renewal").font(.system(size: 13, weight: .semibold))
                phaseTag("LATER")
            }
            Text("Not installed · nothing scheduled.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func phaseTag(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}
