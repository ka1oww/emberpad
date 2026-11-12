import Foundation
@testable import EmberPad

/// EP94: queued ink changes land on a display frame after PencilKit's latest commit, and the pen's own swaps only
/// once the writing has paused (`InkLandingTiming.pause`). Waits until no controller has any left to land, or
/// `timeout` has passed (generous, since a loaded CI runner is slow; it returns as soon as nothing is pending; for a test whose edits are meant to keep waiting), then one more turn of the main queue.
@MainActor
enum InkSettle {
    static func settle(timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        await turn()
        while PDFOverlayPageController.inkWorkers.allObjects.contains(where: \.hasPendingInk), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await turn()
    }

    static func turn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}
