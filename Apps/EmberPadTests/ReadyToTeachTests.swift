import EmberSyncKit
import XCTest
@testable import EmberPad

/// EP189: Ready to teach says, before class, whether the Mac presents and can record, which microphone it has, the
/// iPad's battery, and which worksheets in the open folder lack a Teacher copy. Synthetic records only.
@MainActor
final class ReadyToTeachTests: XCTestCase {
    private let boya = "BOYA BY-M1"
    private let hour: Int64 = PresentLessonReadiness.bytesPerHour(videoBitRate: 4_000_000, audioBitRate: 192_000)

    private func readiness(mic: String? = "BOYA BY-M1", builtIn: Bool = true, access: PresentLessonReadiness.MicAccess = .allowed,
                           hours: Double? = 20) -> PresentLessonReadiness {
        PresentLessonReadiness(preferredMic: mic, hasBuiltInMic: builtIn, micAccess: access,
                               freeBytes: hours.map { Int64($0 * Double(hour)) }, bytesPerHour: hour)
    }

    private func checks(paired: Bool = true, light: PresentController.Light = .connected, macRecords: Bool = true,
                        lesson: PresentLessonStatus? = PresentLessonStatus(state: .idle),
                        battery: ReadyToTeach.Battery = .init(level: 0.9, charging: false),
                        copies: ReadyToTeach.TeacherCopies = .init(folder: "Organic", total: 3, missing: []))
        -> [ReadyToTeach.Item: ReadyToTeach.Check] {
        let all = ReadyToTeach.checks(paired: paired, light: light, macRecords: macRecords, lesson: lesson,
                                      battery: battery, teacherCopies: copies, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(all.map(\.item), ReadyToTeach.Item.allCases, "one row per check, always in the same order")
        return Dictionary(uniqueKeysWithValues: all.map { ($0.item, $0) })
    }

    func testEverythingReadyBeforeClass() {
        let result = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness()))
        XCTAssertEqual(result.values.map(\.level).filter { $0 != .ready }, [], "\(result.values.map(\.detail))")
        XCTAssertEqual(result[.microphone]?.detail, "BOYA BY-M1 is connected to your Mac.")
        XCTAssertEqual(result[.recording]?.detail, "Ready. Tap Start lesson when class begins. Room for about 20 hours of lessons on the Mac.")
        XCTAssertTrue(ReadyToTeach.isReady(Array(result.values)))
    }

    func testAnUnpairedIPadIsAProblemAndTheMacChecksWait() {
        let result = checks(paired: false, light: .off, macRecords: false, lesson: nil)
        XCTAssertEqual(result[.mac]?.level, .problem)
        XCTAssertEqual(result[.mac]?.detail, "Pair this iPad with your Mac first.")
        XCTAssertEqual(result[.recording]?.level, .waiting)
        XCTAssertEqual(result[.microphone]?.level, .waiting)
        XCTAssertFalse(ReadyToTeach.isReady(Array(result.values)))
    }

    func testPairedButNotPresentingAsksToTurnOnPresent() {
        for light in [PresentController.Light.off, .endedOnMac, .macUnreachable, .stoppedWhileLocked] {
            let result = checks(light: light, macRecords: false, lesson: nil)
            XCTAssertEqual(result[.mac]?.level, .problem, "\(light)")
            XCTAssertEqual(result[.mac]?.detail, "Paired, but not presenting. Turn on Present on Mac.")
        }
        XCTAssertEqual(checks(light: .connecting, macRecords: false, lesson: nil)[.mac]?.level, .waiting)
        XCTAssertEqual(checks(light: .unsupported, macRecords: false, lesson: nil)[.mac]?.level, .problem)
    }

    func testAnOlderCompanionSaysToUpdateIt() {
        XCTAssertEqual(checks(macRecords: false, lesson: nil)[.recording]?.level, .problem, "a Companion that cannot record")
        let older = checks(lesson: PresentLessonStatus(state: .idle))
        XCTAssertEqual(older[.recording]?.level, .warning, "a Companion that records but says nothing before a lesson")
        XCTAssertEqual(older[.microphone]?.level, .waiting)
    }

    func testMicrophoneAccessOffIsAProblemAndNotAskedYetIsAWarning() {
        let off = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(access: .off)))
        XCTAssertEqual(off[.recording]?.level, .problem)
        XCTAssertTrue(off[.recording]?.detail.contains("System Settings") == true)
        let notAsked = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(access: .notAsked)))
        XCTAssertEqual(notAsked[.recording]?.level, .warning)
    }

    func testLittleRoomOnTheMacWarnsThenIsAProblem() {
        let tight = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(hours: 1.5)))
        XCTAssertEqual(tight[.recording]?.level, .warning)
        XCTAssertEqual(tight[.recording]?.detail, "Ready, but only room for about 1 hour of lesson on the Mac.")
        let full = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(hours: 0.5)))
        XCTAssertEqual(full[.recording]?.level, .problem)
        XCTAssertEqual(full[.recording]?.detail, "Only room for 30 minutes of lesson on the Mac. Free some space.")
        let unknown = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(hours: nil)))
        XCTAssertEqual(unknown[.recording]?.detail, "Ready. Tap Start lesson when class begins.")
    }

    func testNoBoyaWarnsWithTheBuiltInMicrophoneAndIsAProblemWithout() {
        let builtIn = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(mic: nil)))
        XCTAssertEqual(builtIn[.microphone]?.level, .warning)
        XCTAssertTrue(builtIn[.microphone]?.detail.hasPrefix("The BOYA is not connected.") == true)
        let none = checks(lesson: PresentLessonStatus(state: .idle, readiness: readiness(mic: nil, builtIn: false)))
        XCTAssertEqual(none[.microphone]?.level, .problem)
    }

    func testWhileRecordingTheRowsSayWhatIsRecording() {
        let start = Date(timeIntervalSince1970: 100 - 192)
        let boyaLesson = checks(lesson: PresentLessonStatus(state: .recording, startedAt: start, micName: boya))
        XCTAssertEqual(boyaLesson[.recording]?.detail, "Recording now, 3:12.")
        XCTAssertEqual(boyaLesson[.microphone]?.level, .ready)
        let fallback = checks(lesson: PresentLessonStatus(state: .recording, startedAt: start, micName: "MacBook Pro Microphone",
                                                           micIsFallback: true))
        XCTAssertEqual(fallback[.microphone]?.level, .warning)
        let silent = checks(lesson: PresentLessonStatus(state: .recording, startedAt: start, micName: boya,
                                                         warning: "The microphone is silent"))
        XCTAssertEqual(silent[.microphone]?.level, .problem)
        XCTAssertEqual(silent[.microphone]?.detail, "The microphone is silent")
    }

    func testBattery() {
        XCTAssertEqual(ReadyToTeach.batteryCheck(.init(level: 0.8, charging: false)), .init(item: .battery, level: .ready, detail: "80%."))
        XCTAssertEqual(ReadyToTeach.batteryCheck(.init(level: 0.3, charging: false)).level, .warning)
        XCTAssertEqual(ReadyToTeach.batteryCheck(.init(level: 0.1, charging: false)).level, .problem)
        XCTAssertEqual(ReadyToTeach.batteryCheck(.init(level: 0.1, charging: true)),
                       .init(item: .battery, level: .ready, detail: "10%, charging."))
        XCTAssertEqual(ReadyToTeach.batteryCheck(.init(level: nil, charging: false)).level, .waiting)
    }

    func testTeacherCopiesOfTheOpenWorksheetsFolder() throws {
        let teacherA = try record("Organic/Worksheet A (Teacher).pdf", role: .teacher)
        let a = try record("Organic/Worksheet A.pdf", paired: teacherA.id)
        let b = try record("Organic/Worksheet B.pdf")
        let lost = try record("Organic/Worksheet C.pdf", paired: UUID())
        let otherFolder = try record("Inorganic/Worksheet D.pdf")
        let otherSubject = try record("Organic/Worksheet E.pdf", subject: "Synthetic Physics")
        let documents = [teacherA, a, b, lost, otherFolder, otherSubject]

        let copies = ReadyToTeach.teacherCopies(beside: a, in: documents)
        XCTAssertEqual(copies, ReadyToTeach.TeacherCopies(folder: "Organic", total: 3, missing: ["Worksheet B", "Worksheet C"]),
                       "only the Student worksheets of the same subject and folder; a pairing whose Teacher copy is gone counts as missing")
        let check = ReadyToTeach.teacherCopiesCheck(copies)
        XCTAssertEqual(check.level, .warning)
        XCTAssertEqual(check.detail, "2 of 3 in Organic have no Teacher copy: Worksheet B, Worksheet C.")

        XCTAssertEqual(ReadyToTeach.teacherCopiesCheck(.init(folder: "Organic", total: 1, missing: [])).detail,
                       "The worksheet in Organic has a Teacher copy.")
        XCTAssertEqual(ReadyToTeach.teacherCopiesCheck(.init(folder: "Organic", total: 5, missing: ["A", "B", "C", "D"])).detail,
                       "4 of 5 in Organic have no Teacher copy: A, B, C and 1 more.")
    }

    private func record(_ path: String, role: DocumentRole = .student, paired: UUID? = nil,
                        subject: String = "Synthetic Chemistry") throws -> DocumentRecord {
        let title = String(path.split(separator: "/").last!.dropLast(4))
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: path)
        let hash = try ContentHash(rawValue: String(repeating: "a", count: 64))
        let paperKey = try PaperKey(rawValue: "synthetic-paper-1")
        let publication = try Publication(subject: subject, classTag: nil, paperKey: paperKey, role: role, title: title)
        let entry = try ManifestEntry(source: source, sha256: hash, size: 1024,
                                      modifiedAt: Date(timeIntervalSince1970: 0), publication: publication)
        return DocumentRecord(source: entry, pageCount: 1, importedAt: Date(timeIntervalSince1970: 0),
                              hasInk: false, status: .current, title: title, isUpdated: false, pairedDocumentID: paired)
    }
}
