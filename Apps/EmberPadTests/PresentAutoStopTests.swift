import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP172: Present on Mac turns itself off, so an iPad forgotten after a lesson does not keep presenting and drain its
/// battery. (1) The teacher closes the presentation in Ember Companion: the Mac says so and Present turns off. (2) The
/// Mac cannot be reached for `autoStopAfter` in a row while EmberPad is on screen. (3) EmberPad comes back after being
/// locked or away for `autoStopAfter` or longer. Rules 2 and 3 never stop Present while the Mac records a lesson, and
/// a shorter lock still reconnects quietly. The Mac end is a real `PresentHost` in memory (`FakeRecordingMac`); time
/// for rules 2 and 3 is a test clock, never a real wait.
@MainActor
final class PresentAutoStopTests: XCTestCase {
    private var controllers: [PresentController] = []

    override func tearDown() {
        for controller in controllers { controller.stop() }
        controllers = []
        super.tearDown()
    }

    // MARK: 1. The Mac closes the presentation

    func testClosingThePresentationOnTheMacTurnsPresentOff() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, _, _) = try await presenting(to: mac)

        XCTAssertTrue(mac.host.end(), "the Companion tells this iPad")
        try await waitUntil { !controller.isOn }
        XCTAssertEqual(controller.light, .endedOnMac)
        XCTAssertEqual(controller.light.title, "Presentation ended on your Mac")
        XCTAssertNil(controller.light.dotColor)
        try await waitUntil { mac.host.status == .off }

        // Turning Present on again presents as before, and the note goes.
        controller.start()
        XCTAssertEqual(controller.light, .connecting)
        try await waitUntil { controller.light == .connected }
    }

    /// The Mac keeps its recording as it does whenever the iPad stops presenting: the iPad sends no End lesson.
    func testTheMacClosingThePresentationStopsPresentWhileItRecordsButSendsNoEndLesson() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, _, _) = try await presenting(to: mac)
        try await recordLesson(controller)

        mac.host.end()
        try await waitUntil { !controller.isOn }
        XCTAssertEqual(controller.light, .endedOnMac)
        XCTAssertEqual(mac.commands.map(\.action), [.start])
    }

    func testALinkThatMerelyDropsDoesNotTurnPresentOff() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, reach, _) = try await presenting(to: mac)

        await reach.drop()
        try await waitUntil { controller.light == .reconnecting }
        try await waitUntil { controller.light == .connected }
        XCTAssertTrue(controller.isOn)
    }

    // MARK: 2. The Mac out of reach

    func testAMacOutOfReachForTwoMinutesTurnsPresentOff() throws {
        let controller = PresentController(student: StudentDisplayModel())
        controllers.append(controller)
        let clock = TestClock()
        controller.now = { clock.time }
        let credential = try PairingCredential.generate()
        controller.credential = { credential }
        controller.connect = { _, _ in throw CancellationError() }
        controller.start()
        XCTAssertEqual(controller.light, .connecting)

        clock.time += PresentController.autoStopAfter - 1
        controller.tick()
        XCTAssertTrue(controller.isOn, "under two minutes it keeps trying")

        clock.time += 1
        controller.tick()
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.light, .macUnreachable)
        XCTAssertEqual(controller.light.title, "Stopped presenting: your Mac could not be reached")
    }

    /// Only two minutes in a row count: reaching the Mac in between starts again.
    func testOutOfReachTimeStartsAgainOnceTheMacIsReached() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, reach, clock) = try await presenting(to: mac)

        reach.reachable = false
        await reach.drop()
        try await waitUntil { controller.light == .reconnecting }
        clock.time += PresentController.autoStopAfter - 20
        controller.tick()
        XCTAssertTrue(controller.isOn)

        reach.reachable = true
        try await waitUntil { controller.light == .connected }
        reach.reachable = false
        await reach.drop()
        try await waitUntil { controller.light == .reconnecting }
        clock.time += PresentController.autoStopAfter - 20
        controller.tick()
        XCTAssertTrue(controller.isOn, "neither stretch was two minutes on its own")

        clock.time += 20
        controller.tick()
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.light, .macUnreachable)
    }

    func testAMacOutOfReachNeverStopsALessonItRecords() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, reach, clock) = try await presenting(to: mac)
        try await recordLesson(controller)

        reach.reachable = false
        await reach.drop()
        try await waitUntil { controller.light == .reconnecting }
        clock.time += PresentController.autoStopAfter * 10
        controller.tick()
        XCTAssertTrue(controller.isOn)
        XCTAssertTrue(controller.isRecordingLesson)

        reach.reachable = true
        try await waitUntil { controller.light == .connected }
        XCTAssertTrue(controller.isOn)
    }

    // MARK: 3. Locked for two minutes

    func testComingBackFromALockOfTwoMinutesLeavesPresentOff() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, reach, clock) = try await presenting(to: mac)

        try await lock(controller)
        let connections = reach.connections
        clock.time += PresentController.autoStopAfter
        controller.becameActive()
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.light, .stoppedWhileLocked)
        XCTAssertEqual(controller.light.title, "Stopped presenting while the iPad was locked")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(reach.connections, connections, "it does not reconnect")
    }

    func testAShortLockStillReconnectsQuietly() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, reach, clock) = try await presenting(to: mac)

        try await lock(controller)
        let connections = reach.connections
        clock.time += PresentController.autoStopAfter - 1
        controller.becameActive()
        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(controller.light, .reconnecting)
        try await waitUntil { controller.light == .connected }
        XCTAssertGreaterThan(reach.connections, connections)
    }

    func testALongLockNeverStopsALessonTheMacRecords() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (controller, _, clock) = try await presenting(to: mac)
        try await recordLesson(controller)

        try await lock(controller)
        clock.time += PresentController.autoStopAfter * 10
        controller.becameActive()
        XCTAssertTrue(controller.isOn)
        try await waitUntil { controller.light == .connected }
        XCTAssertTrue(controller.isRecordingLesson)
    }

    // MARK: Helpers

    private func presenting(to mac: FakeRecordingMac) async throws -> (PresentController, MacReach, TestClock) {
        let controller = PresentController(student: StudentDisplayModel())
        controllers.append(controller)
        let clock = TestClock()
        controller.now = { clock.time }
        let credential = try PairingCredential.generate()
        controller.credential = { credential }
        let reach = MacReach()
        controller.connect = { _, _ in try await reach.connect(mac) }
        controller.start()
        try await waitUntil { controller.light == .connected }
        return (controller, reach, clock)
    }

    private func recordLesson(_ controller: PresentController) async throws {
        try await waitUntil { controller.lesson != nil }
        controller.startLesson()
        try await waitUntil { controller.isRecordingLesson }
    }

    /// The iPad locks: the link closes quietly within about a second (`enteredBackground`).
    private func lock(_ controller: PresentController) async throws {
        controller.enteredBackground()
        try await waitUntil { controller.light == .reconnecting }
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The clock `PresentController.autoStopAfter` is measured by, moved by hand.
@MainActor
private final class TestClock {
    var time: TimeInterval = 1_000
}

/// Whether the Mac can be reached, and the iPad's open connections to it, so a test can cut them as a radio drop does.
private final class MacReach: @unchecked Sendable {
    private let lock = NSLock()
    private var isReachable = true
    private var open: [any WireTransport] = []
    private var count = 0

    var reachable: Bool {
        get { lock.withLock { isReachable } }
        set { lock.withLock { isReachable = newValue } }
    }

    var connections: Int { lock.withLock { count } }

    func connect(_ mac: FakeRecordingMac) async throws -> any WireTransport {
        guard reachable else { throw CancellationError() }
        let transport = try await mac.connect()
        lock.withLock {
            open.append(transport)
            count += 1
        }
        return transport
    }

    func drop() async {
        let all = lock.withLock { () -> [any WireTransport] in
            defer { open = [] }
            return open
        }
        for transport in all { await transport.close() }
    }
}
