import SwiftUI
import UIKit
import EmberSyncKit

/// Ready to teach (EP189): one screen before class that says whether the iPad is set to teach. It checks the Mac
/// (paired and presenting), the lesson recording (macOS's microphone permission and the room for recordings), the
/// microphone (the BOYA plugged into the Mac), the iPad's battery, and the Teacher copies of the open worksheet's
/// folder. The Mac's part comes from `PresentLessonReadiness`, on the lesson status of the Present on Mac link, so it
/// is known only while presenting; nothing is checked or sent until the teacher opens this screen.
enum ReadyToTeach {
    enum Item: String, CaseIterable, Equatable {
        case mac, recording, microphone, battery, teacherCopies

        var title: String {
            switch self {
            case .mac: "Mac"
            case .recording: "Lesson recording"
            case .microphone: "Microphone"
            case .battery: "Battery"
            case .teacherCopies: "Teacher copies"
            }
        }

        var symbol: String {
            switch self {
            case .mac: "macbook.and.ipad"
            case .recording: "record.circle"
            case .microphone: "mic"
            case .battery: "battery.75percent"
            case .teacherCopies: "book.closed"
            }
        }
    }

    enum Level: Equatable {
        case ready
        /// Teaching works, but something is worth a look first.
        case warning
        /// Fix this before class.
        case problem
        /// Not known yet: the Mac has not said, or the check needs the Mac first.
        case waiting
    }

    struct Check: Equatable, Identifiable {
        let item: Item
        let level: Level
        let detail: String
        var id: Item { item }
    }

    /// The iPad's battery: `level` from 0 to 1, nil when the iPad does not say (the Simulator).
    struct Battery: Equatable {
        var level: Float?
        var charging: Bool

        @MainActor static var current: Battery {
            let device = UIDevice.current
            let level = device.batteryLevel
            return Battery(level: level < 0 ? nil : level,
                           charging: device.batteryState == .charging || device.batteryState == .full)
        }
    }

    /// The Student worksheets in the open worksheet's folder, and the ones with no Teacher copy to flip to.
    struct TeacherCopies: Equatable {
        var folder: String
        var total: Int
        var missing: [String]
    }

    /// Hours of room below which the recording check warns, and below which it is a problem.
    static let roomWarning: Double = 2
    static let roomProblem: Double = 1
    /// Battery below which the check warns, and below which it is a problem, unless the iPad is charging.
    static let batteryWarning: Float = 0.5
    static let batteryProblem: Float = 0.2

    static func checks(paired: Bool, light: PresentController.Light, macRecords: Bool, lesson: PresentLessonStatus?,
                       battery: Battery, teacherCopies: TeacherCopies, now: Date = Date()) -> [Check] {
        let connected = light == .connected
        return [
            macCheck(paired: paired, light: light),
            recordingCheck(connected: connected, macRecords: macRecords, lesson: lesson, now: now),
            microphoneCheck(connected: connected, macRecords: macRecords, lesson: lesson),
            batteryCheck(battery),
            teacherCopiesCheck(teacherCopies),
        ]
    }

    /// True when nothing needs fixing: every check is ready or only warns.
    static func isReady(_ checks: [Check]) -> Bool {
        checks.allSatisfy { $0.level == .ready || $0.level == .warning }
    }

    static func macCheck(paired: Bool, light: PresentController.Light) -> Check {
        guard paired, light != .notPaired else {
            return Check(item: .mac, level: .problem, detail: "Pair this iPad with your Mac first.")
        }
        switch light {
        case .connected:
            return Check(item: .mac, level: .ready, detail: "Presenting on your Mac.")
        case .connecting, .reconnecting:
            return Check(item: .mac, level: .waiting, detail: light.title)
        case .unsupported:
            return Check(item: .mac, level: .problem, detail: "Update Ember Companion on your Mac to present.")
        case .off, .endedOnMac, .macUnreachable, .stoppedWhileLocked, .notPaired:
            return Check(item: .mac, level: .problem, detail: "Paired, but not presenting. Turn on Present on Mac.")
        }
    }

    static func recordingCheck(connected: Bool, macRecords: Bool, lesson: PresentLessonStatus?, now: Date) -> Check {
        guard connected else {
            return Check(item: .recording, level: .waiting, detail: "Checked once Present on Mac is on.")
        }
        guard macRecords, let lesson else {
            return Check(item: .recording, level: .problem, detail: "Update Ember Companion on your Mac to record lessons.")
        }
        if lesson.state == .recording {
            return Check(item: .recording, level: .ready, detail: "Recording now, \(PresentLessonText.elapsed(lesson, now: now)).")
        }
        guard let readiness = lesson.readiness else {
            return Check(item: .recording, level: .warning,
                         detail: "Update Ember Companion on your Mac to check the recording before class.")
        }
        switch readiness.micAccess {
        case .off:
            return Check(item: .recording, level: .problem, detail:
                "Microphone access is off for Ember Companion. Turn it on in System Settings, Privacy & Security, Microphone.")
        case .notAsked:
            return Check(item: .recording, level: .warning, detail:
                "Ember Companion has not been allowed the microphone yet. Allow it on the Mac before class.")
        case .allowed:
            break
        }
        let room = readiness.hoursOfRoom.map { " Room for \(roomText($0)) of lessons on the Mac." } ?? ""
        if let hours = readiness.hoursOfRoom, hours < roomProblem {
            return Check(item: .recording, level: .problem, detail: "Only room for \(roomText(hours)) of lesson on the Mac. Free some space.")
        }
        if let hours = readiness.hoursOfRoom, hours < roomWarning {
            return Check(item: .recording, level: .warning, detail: "Ready, but only room for \(roomText(hours)) of lesson on the Mac.")
        }
        if lesson.state == .failed, let message = lesson.message {
            return Check(item: .recording, level: .warning, detail: "The last start failed: \(message)")
        }
        return Check(item: .recording, level: .ready, detail: "Ready. Tap Start lesson when class begins.\(room)")
    }

    static func microphoneCheck(connected: Bool, macRecords: Bool, lesson: PresentLessonStatus?) -> Check {
        guard connected, macRecords, let lesson else {
            return Check(item: .microphone, level: .waiting, detail: "Checked once your Mac can record.")
        }
        if lesson.state == .recording {
            if let warning = lesson.warning { return Check(item: .microphone, level: .problem, detail: warning) }
            let name = lesson.micName ?? "the microphone"
            return lesson.micIsFallback
                ? Check(item: .microphone, level: .warning, detail: "Recording with \(name), not the \(LessonMicrophone.preferredName).")
                : Check(item: .microphone, level: .ready, detail: "Recording with \(name).")
        }
        guard let readiness = lesson.readiness else {
            return Check(item: .microphone, level: .waiting, detail: "Your Mac does not say which microphone is connected.")
        }
        if let name = readiness.preferredMic {
            return Check(item: .microphone, level: .ready, detail: "\(name) is connected to your Mac.")
        }
        return readiness.hasBuiltInMic
            ? Check(item: .microphone, level: .warning, detail:
                "The \(LessonMicrophone.preferredName) is not connected. Plug its receiver into your Mac, or record with the Mac's built-in microphone.")
            : Check(item: .microphone, level: .problem, detail: "Your Mac has no microphone connected.")
    }

    static func batteryCheck(_ battery: Battery) -> Check {
        guard let level = battery.level else {
            return Check(item: .battery, level: .waiting, detail: "This iPad does not report its battery.")
        }
        let percent = "\(Int((level * 100).rounded()))%"
        if battery.charging { return Check(item: .battery, level: .ready, detail: "\(percent), charging.") }
        if level >= batteryWarning { return Check(item: .battery, level: .ready, detail: "\(percent).") }
        if level >= batteryProblem {
            return Check(item: .battery, level: .warning, detail: "\(percent). Charge it before a long lesson.")
        }
        return Check(item: .battery, level: .problem, detail: "\(percent). Plug in the iPad before class.")
    }

    static func teacherCopiesCheck(_ copies: TeacherCopies) -> Check {
        guard copies.total > 0 else {
            return Check(item: .teacherCopies, level: .waiting, detail: "No worksheets in this folder.")
        }
        guard !copies.missing.isEmpty else {
            let all = copies.total == 1 ? "The worksheet" : "All \(copies.total) worksheets"
            return Check(item: .teacherCopies, level: .ready, detail: "\(all) in \(copies.folder) \(copies.total == 1 ? "has" : "have") a Teacher copy.")
        }
        let shown = copies.missing.prefix(3).joined(separator: ", ")
        let more = copies.missing.count > 3 ? " and \(copies.missing.count - 3) more" : ""
        return Check(item: .teacherCopies, level: .warning,
                     detail: "\(copies.missing.count) of \(copies.total) in \(copies.folder) have no Teacher copy: \(shown)\(more).")
    }

    /// The Student worksheets beside `record` (same subject and folder, as the library shows them) and which have no
    /// Teacher copy in the library to flip to.
    @MainActor static func teacherCopies(beside record: DocumentRecord, in documents: [DocumentRecord]) -> TeacherCopies {
        let folders = LibraryFolders.folders(of: record.source)
        let teachers = Set(documents.filter { $0.role == .teacher }.map(\.id))
        let worksheets = LibraryController.browsableCards(in: documents)
            .filter { $0.subject == record.subject && LibraryFolders.folders(of: $0.source) == folders }
            .sorted { LibraryFolders.nameOrder(LibraryFolders.ownTitle(of: $0), LibraryFolders.ownTitle(of: $1)) }
        let missing = worksheets.filter { worksheet in
            guard let paired = worksheet.pairedDocumentID else { return true }
            return !teachers.contains(paired)
        }
        return TeacherCopies(folder: folders.last ?? record.subject, total: worksheets.count,
                             missing: missing.map { LibraryFolders.ownTitle(of: $0) })
    }

    static func roomText(_ hours: Double) -> String {
        if hours < 1 { return "\(max(0, Int((hours * 60).rounded(.down)))) minutes" }
        let whole = Int(hours.rounded(.down))
        return whole == 1 ? "about 1 hour" : "about \(whole) hours"
    }

    static let menuIdentifier = "ready-to-teach"
}

/// The Sharing menus' Ready to teach row, which opens the screen.
struct ReadyToTeachRow: View {
    @Binding var isOpen: Bool
    var body: some View {
        Section {
            Button { isOpen = true } label: { Label("Ready to Teach…", systemImage: "checklist") }
                .accessibilityIdentifier(ReadyToTeach.menuIdentifier)
        }
    }
}

/// The Ready to teach screen: one row per check, the fix in words, and the two fixes it can make itself (turning on
/// Present on Mac, and starting the lesson once all is ready).
struct ReadyToTeachSheet: View {
    @ObservedObject var present: PresentController
    let teacherCopies: ReadyToTeach.TeacherCopies
    @Environment(\.dismiss) private var dismiss
    @State private var battery = ReadyToTeach.Battery(level: nil, charging: false)
    @State private var wasMonitoringBattery = false
    /// Read from the keychain when the screen opens, not once a second.
    @State private var paired = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let checks = ReadyToTeach.checks(paired: paired, light: present.light,
                                                 macRecords: present.macRecords, lesson: present.lesson, battery: battery,
                                                 teacherCopies: teacherCopies, now: context.date)
                List {
                    Section {
                        ForEach(checks) { check in ReadyToTeachCheckRow(check: check) }
                    } header: {
                        Text(ReadyToTeach.isReady(checks) ? "Ready to teach" : "Check these before class")
                    }
                    actions(checks)
                }
            }
            .navigationTitle("Ready to Teach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            wasMonitoringBattery = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = .current
            paired = ((try? present.credential()) ?? nil) != nil
        }
        .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = wasMonitoringBattery }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in battery = .current }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in battery = .current }
    }

    @ViewBuilder private func actions(_ checks: [ReadyToTeach.Check]) -> some View {
        let mac = checks.first { $0.item == .mac }
        let recording = checks.first { $0.item == .recording }
        if !present.isOn, mac?.level == .problem, present.light != .notPaired {
            Section {
                Button { present.setOn(true) } label: { Label("Turn On Present on Mac", systemImage: "macbook.and.ipad") }
            }
        } else if present.isOn, present.macRecords, !present.isRecordingLesson, recording?.level == .ready {
            Section {
                Button { present.startLesson() } label: { Label("Start Lesson", systemImage: "record.circle") }
                    .disabled(present.pendingLesson != nil)
            } footer: {
                Text("Your Mac records the presentation and the BOYA microphone. Teacher copies are never recorded.")
            }
        }
    }
}

struct ReadyToTeachCheckRow: View {
    let check: ReadyToTeach.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: levelSymbol)
                .foregroundStyle(levelColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Label(check.item.title, systemImage: check.item.symbol)
                    .labelStyle(.titleOnly)
                    .font(.body.weight(.semibold))
                Text(check.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(levelText)
    }

    private var levelSymbol: String {
        switch check.level {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .waiting: "clock"
        }
    }

    private var levelColor: Color {
        switch check.level {
        case .ready: Theme.ok
        case .warning: Theme.warn
        case .problem: .red
        case .waiting: .secondary
        }
    }

    private var levelText: String {
        switch check.level {
        case .ready: "Ready"
        case .warning: "Worth a look"
        case .problem: "Needs fixing"
        case .waiting: "Not checked yet"
        }
    }
}
