import AppKit
import EmberSyncKit
import SwiftUI

// The menu-bar window (EP139): one status line, a warning row only while something needs the teacher, the two
// things used in class (Present on Mac and Lesson recording), then Settings… and Quit. Everything set up once lives in
// the Settings window (`CompanionSettingsWindowController`).

/// One line in the menu's warning row.
struct CompanionMenuWarning: Equatable, Identifiable {
    enum Kind: String, Equatable {
        /// The lesson is recording but not saving sound, or recording failed.
        case lesson
        case folderNotFound
        case autoPrepareFailed
        case notRead
        case notPaired
    }

    let kind: Kind
    let text: String
    var id: Kind { kind }

    /// The lesson first (it is happening now), then what stops the iPad getting its library.
    static func warnings(lesson: PresentLessonStatus, isSourceAvailable: Bool, snapshot: LibrarySnapshot?,
                         autoStatus: CompanionAutoPrepareStatus, pairing: CompanionPairingStatus,
                         time: (Date) -> String) -> [CompanionMenuWarning] {
        var warnings: [CompanionMenuWarning] = []
        switch lesson.state {
        case .recording:
            if let warning = lesson.warning { warnings.append(.init(kind: .lesson, text: warning)) }
        case .failed:
            if let message = lesson.message { warnings.append(.init(kind: .lesson, text: message)) }
        case .idle, .needsMicChoice:
            break
        }
        if !isSourceAvailable {
            warnings.append(.init(kind: .folderNotFound, text: "EMBER folder not found · choose it in Settings"))
        } else if let failure = autoStatus.failureLine(time: time) {
            warnings.append(.init(kind: .autoPrepareFailed, text: failure))
        }
        if isSourceAvailable, let misses = snapshot?.misses.count, misses > 0 {
            let files = misses == 1 ? "1 PDF" : "\(misses.formatted()) PDFs"
            warnings.append(.init(kind: .notRead, text: "\(files) not read this time · listed in Settings"))
        }
        if pairing == .notPaired {
            warnings.append(.init(kind: .notPaired, text: "iPad not paired · pair it in Settings"))
        }
        return warnings
    }
}

/// The top of the menu-bar window: the Companion's badge and name, the sync server's status line (EP-23) and, only
/// while something needs the teacher, the warning row.
struct CompanionMenuStatus: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var pairing: CompanionPairingModel
    @ObservedObject var sync: CompanionSyncModel
    @ObservedObject var lesson: CompanionLessonModel

    var body: some View {
        CompanionMenuStatusContent(
            syncLine: sync.statusLine,
            warnings: CompanionMenuWarning.warnings(
                lesson: lesson.status, isSourceAvailable: model.isSourceAvailable, snapshot: model.snapshot,
                autoStatus: model.autoStatus, pairing: pairing.status,
                time: CompanionSettingsContent.timeFormatter.string(from:)))
    }
}

/// `CompanionMenuStatus` with its values in, so tests and screenshots can render it.
struct CompanionMenuStatusContent: View {
    let syncLine: SyncStatusLine
    let warnings: [CompanionMenuWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("CompanionBadge")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ember Companion").font(.system(size: 14, weight: .semibold))
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
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(warnings) { warning in
                        Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(warning.kind == .lesson ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
        }
    }

    static func toneColor(_ tone: SyncStatusLine.Tone) -> Color {
        switch tone {
        case .off: .secondary
        case .ready: .green
        case .active: CompanionSettingsContent.emberRed
        case .problem: .orange
        }
    }
}

/// The bottom of the menu-bar window: Settings… and Quit.
struct CompanionMenuFooter: View {
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack {
            Button("Settings…", action: onSettings)
                .keyboardShortcut(",")
            Spacer()
            Button("Quit Ember Companion", action: onQuit)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// The menu-bar window, top to bottom (EP139).
struct CompanionMenuContent: View {
    static let width: CGFloat = 340

    enum Section: String, CaseIterable {
        /// Only while presenting: where it is shown and **Exit presentation**.
        case presentBanner
        /// The status line and the warning row.
        case status
        case present
        case lesson
        /// Debug builds launched for the peer-to-peer check only.
        case peerHello
        /// Settings… and Quit.
        case footer
    }

    /// The sections shown; the peer-to-peer check's only when asked for at launch.
    static func sections(showsPeerHello: Bool) -> [Section] {
        Section.allCases.filter { $0 != .peerHello || showsPeerHello }
    }

    @ObservedObject var model: CompanionModel
    @ObservedObject var pairing: CompanionPairingModel
    @ObservedObject var sync: CompanionSyncModel
    @ObservedObject var present: CompanionPresentModel
    let showsPeerHello: Bool
    let onSettings: () -> Void

    var body: some View {
        ForEach(Self.sections(showsPeerHello: showsPeerHello), id: \.self) { section in
            // A divider above everything after the status, as between the sections before EP139.
            if section != .presentBanner, section != .status { Divider() }
            view(for: section)
        }
    }

    @ViewBuilder private func view(for section: Section) -> some View {
        switch section {
        case .presentBanner:
            CompanionPresentBanner(model: present).frame(width: Self.width)
        case .status:
            CompanionMenuStatus(model: model, pairing: pairing, sync: sync, lesson: present.lesson).frame(width: Self.width)
        case .present:
            CompanionPresentSection(model: present).frame(width: Self.width, alignment: .leading)
        case .lesson:
            CompanionLessonSection(model: present.lesson).frame(width: Self.width, alignment: .leading)
        case .peerHello:
#if DEBUG
            CompanionPeerHelloSection(model: CompanionPeerHelloModel.shared).frame(width: Self.width)
#else
            EmptyView()
#endif
        case .footer:
            CompanionMenuFooter(onSettings: onSettings, onQuit: { NSApplication.shared.terminate(nil) })
                .frame(width: Self.width)
        }
    }
}
