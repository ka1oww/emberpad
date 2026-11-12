import Foundation

/// EP91: the quiet background check. While EmberPad is the active app it asks the paired Mac about once a minute
/// whether its prepared library changed (`SyncClient.checkForChanges`, one TLS-PSK connection carrying a 9-byte
/// question and a 41-byte answer), so a worksheet the Companion prepares while the app stays open appears without
/// Sync now. Only a changed library starts a sync, which downloads only the changed PDFs, as every sync does.
///
/// Battery rules: it runs only between becoming active and resigning active (the foreground sync covers the moment
/// it starts); it skips its turn while Low Power Mode is on or while a worksheet is open, and checks as soon as the
/// last open worksheet closes; when the Mac cannot be reached, or a sync it started did not finish, it waits twice
/// as long each time, up to five minutes, and goes back to a minute after the next answer. It shows nothing itself.
@MainActor
final class LibraryChangeMonitor {
    typealias Check = @MainActor () async -> SyncClient.ChangeCheck
    typealias Sleep = @Sendable (Duration) async throws -> Void

    nonisolated static let baseInterval: Duration = .seconds(60)
    nonisolated static let maximumInterval: Duration = .seconds(300)

    private let check: Check
    private let isLowPowerMode: @MainActor () -> Bool
    private let isWorksheetOpen: @MainActor () -> Bool
    private let sleep: Sleep
    private let base: Duration
    private let maximum: Duration

    /// The wait before the next check.
    private(set) var interval: Duration
    private var loop: Task<Void, Never>?
    /// Bumped whenever the loop is replaced, so an old loop never touches the new one's state.
    private var generation = 0
    private var checking = false
    /// A worksheet closed during a check: check once more straight after it.
    private var checkAgain = false

    /// Whether the loop is waiting or checking now. For tests and the scene delegate.
    var isRunning: Bool { loop != nil }

    init(check: @escaping Check,
         isLowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         isWorksheetOpen: @escaping @MainActor () -> Bool,
         base: Duration = LibraryChangeMonitor.baseInterval, maximum: Duration = LibraryChangeMonitor.maximumInterval,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.check = check
        self.isLowPowerMode = isLowPowerMode
        self.isWorksheetOpen = isWorksheetOpen
        self.base = base
        self.maximum = max(base, maximum)
        self.sleep = sleep
        interval = base
    }

    /// The app became active. Its foreground sync has just started, so the first check is one interval later.
    func start() {
        interval = base
        run(after: base)
    }

    /// The app is leaving the foreground: no more checks until it is active again.
    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        checkAgain = false
    }

    /// The last open worksheet closed: check now, so whatever waited for it is filed, then carry on as before.
    func worksheetClosed() {
        guard loop != nil else { return }
        if checking { checkAgain = true } else { run(after: .zero) }
    }

    private func run(after delay: Duration) {
        stop()
        let id = generation
        let sleep = self.sleep
        loop = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                if wait > .zero {
                    do { try await sleep(wait) } catch { return }
                }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                let keepGoing = await self.turn()
                guard self.generation == id else { return }
                guard keepGoing else {
                    self.loop = nil
                    return
                }
                wait = self.checkAgain ? .zero : self.interval
                self.checkAgain = false
            }
        }
    }

    /// One turn: a check unless Low Power Mode is on or a worksheet is open. False stops the loop until the next
    /// foreground, for a Companion too old to answer.
    private func turn() async -> Bool {
        if isLowPowerMode() || isWorksheetOpen() { return true }
        checking = true
        defer { checking = false }
        switch await check() {
        case .unchanged, .synced: interval = base
        case .unreachable, .syncFailed: interval = min(interval * 2, maximum)
        case .skipped: break
        case .unsupported: return false
        }
        return true
    }
}
