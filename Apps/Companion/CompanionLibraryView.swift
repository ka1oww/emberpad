import SwiftUI
import EmberSyncKit

// TODO(EP-06): the iPad theme tokens live in the EmberPad target, which the Companion
// cannot see, so this window deliberately uses macOS system colours plus the Ember red
// badge and primary button, exactly as design 5.7 specifies. Adopt a shared token set
// here if one ever moves somewhere both targets can import. Do not create a second set.

/// The menu-bar window content from design 5.7: header, source folder, subjects with
/// counts, the not-found list, the Prepare button, the phase-2 iPad placeholder and the
/// renewal line. Values in, actions out, so the window can render a synthetic snapshot
/// (screenshots) as well as the live model without touching the real library.
struct CompanionLibraryContent: View {
    static let emberRed = Color(red: 178 / 255, green: 58 / 255, blue: 46 / 255)

    let folder: URL
    let isSourceAvailable: Bool
    let isPreparing: Bool
    let snapshot: LibrarySnapshot?
    let scannedAt: Date?
    let message: String?
    let onChooseFolder: () -> Void
    let onPrepare: () -> Void

    /// Finished-pair counts in the canonical subject order.
    static func subjectCounts(_ snapshot: LibrarySnapshot?) -> [(subject: String, pairs: Int)] {
        var counts: [String: Int] = [:]
        for pair in snapshot?.pairs ?? [] {
            counts[pair.student.entry.subject, default: 0] += 1
        }
        return EmberLibrarySource.subjectFolders.map { ($0, counts[$0, default: 0]) }
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.emberRed)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "doc.text").foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text("EmberPad Companion").font(.system(size: 14, weight: .semibold))
                Text("Local library preparation").font(.system(size: 12)).opacity(0.65)
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
                    Text(folder.lastPathComponent).font(.system(size: 13, weight: .semibold))
                    Text(folder.path).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if !isSourceAvailable {
                Label("Source folder not found", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Button("Choose master folder…", action: onChooseFolder)
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
                    Text(snapshot == nil ? "—" : "\(row.pairs)").font(.system(size: 13))
                        .foregroundStyle(row.pairs > 0 ? .primary : .secondary)
                }
            }
            Text(subjectsFooter).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 4)
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var subjectsFooter: String {
        guard let snapshot, let scannedAt else {
            return isPreparing ? "Reading the source folder…" : "Not prepared yet."
        }
        return "\(snapshot.manifest.files.count) worksheets · " +
            "\(snapshot.pairs.count) papers · scanned \(Self.timeFormatter.string(from: scannedAt))"
    }

    // MARK: Not-found list (stays on the Mac)

    private var notFoundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not found on this Mac").font(.system(size: 13, weight: .semibold))
            if let snapshot {
                if snapshot.misses.isEmpty {
                    Text("Everything with a record finished.").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(snapshot.misses.enumerated()), id: \.offset) { _, miss in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Text(miss.project).font(.system(size: 12))
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
                Text("Prepare the library to see what is missing.").font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: 4. iPad (phase 2 placeholder)

    private var iPadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("iPad").font(.system(size: 13, weight: .semibold))
                phaseTag("PHASE 2")
            }
            HStack(spacing: 6) {
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("Not paired. Device sync arrives in phase 2.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Pair iPad…") {}.disabled(true).buttonStyle(.bordered)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
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
