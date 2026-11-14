import UIKit

/// How long leaving a notebook waits for PencilKit to commit the strokes it is still holding (EP119). A commit
/// normally comes within 10 ms of the lift and the slowest measured is 164 ms (`InkFlights`); a Pencil still on the
/// glass is waited for too, so a stroke being finished as a finger taps a tab is kept.
enum NotebookLeave {
    static let inkWait: TimeInterval = 2
}

extension PDFOverlayPageController {
    /// Before the worksheet leaves the screen for another tab (EP119): waits, up to `timeout`, for the Pencil to lift
    /// and PencilKit to commit every stroke it holds, puts back from the live pen any stroke it never commits, lands
    /// every queued ink change, and then takes no more input. A canvas that leaves the window with a stroke in
    /// PencilKit's hands loses it, and a queued change left waiting never lands, so leaving never does either. Where
    /// the worksheet was left is remembered too (EP121), so its tab comes back to it.
    func landInkBeforeLeaving(timeout: TimeInterval = NotebookLeave.inkWait) async {
        let deadline = Date().addingTimeInterval(timeout)
        while pencilIsDown || !inkFlights.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // Strokes PencilKit still has not committed were thrown away: the live pen's copies go on the page instead.
        let uncommitted = inkFlights.flights
        for canvas in Set(uncommitted.map(\.canvas)) { inkFlights.remove(canvas: canvas) }
        recoverDiscarded(uncommitted)
        saveReadingPosition()
        setPageInput(false)
    }
}
