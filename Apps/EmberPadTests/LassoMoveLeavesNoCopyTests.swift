import XCTest
import PencilKit
@testable import EmberPad

/// EP162: moving lassoed ink leaves no copy of it behind, however often it is moved. While a selection is dragged its
/// ink shows in a layer of its own (EP126); after the drop that layer stays up until the page has drawn the ink at its
/// new place. Ink dropped on empty paper lands on a page tile PencilKit makes only then, and the layer never counted
/// such a tile as drawn: it stayed up until the drop's patience ran out, which each further move started again. Moved
/// again and again, the ink showed at every place it had been. Written end to end with the real lasso recogniser, the
/// selection's own drag, real PencilKit and its tiles' pixels.
@MainActor
final class LassoMoveLeavesNoCopyTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    /// The captain's case: a written word lassoed and nudged six times in a row, a moment apart. The selection's ink
    /// shows once while it is dragged, never also where it was before, and the page shows it at its last place only.
    func testMovingASelectionAgainAndAgainLeavesNoCopyBehind() throws {
        let page = try page()
        let word = try write(on: page)
        try select(word, on: page)
        let steps = [CGVector(dx: 60, dy: -90), CGVector(dx: -40, dy: -70), CGVector(dx: 90, dy: -30),
                     CGVector(dx: -70, dy: -80), CGVector(dx: 30, dy: -60), CGVector(dx: -50, dy: 40)]
        var places: [CGVector] = [.zero]
        for (n, step) in steps.enumerated() {
            var most = 0
            try drag(by: step, on: page) { most = max(most, Self.liftsShowingInk(on: page.canvas)) }
            XCTAssertLessThanOrEqual(most, 1, "move \(n + 1): the selection's ink shows once while it is dragged")
            places.append(CGVector(dx: places[n].dx + step.dx, dy: places[n].dy + step.dy))
            HoldPage.turn(0.25)
        }

        let last = try XCTUnwrap(places.last)
        XCTAssertEqual(page.canvas.drawing.strokes.count, page.base + word.count, "one copy of the word on the page")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, page.base + word.count, "and one saved")
        XCTAssertTrue(waitUntil(1.5) { Self.liftsShowingInk(on: page.canvas) == 0 },
                      "the page draws the moved word itself, well within the drop's patience")
        for (n, place) in places.dropLast().enumerated() {
            XCTAssertEqual(try inkShown(word, at: place, on: page), 0, "nothing left at place \(n)")
        }
        XCTAssertEqual(try inkShown(word, at: last, on: page), word.count, "the word at its last place")
    }

    /// A move undone and redone shows the word at one place each time: the layer that carried the move is gone.
    func testAMoveUndoneAndRedoneShowsTheWordOnce() throws {
        let page = try page()
        let word = try write(on: page)
        try select(word, on: page)
        let move = CGVector(dx: 80, dy: -200)
        try drag(by: move, on: page)
        let undo = try XCTUnwrap(page.canvas.undoManager)
        XCTAssertEqual(undo.undoActionName, "Move")

        undo.undo()
        XCTAssertTrue(waitUntil(1.5) { Self.liftsShowingInk(on: page.canvas) == 0 }, "undone, no moved copy over the page")
        XCTAssertTrue(waitUntil(1.5) { (try? self.inkShown(word, at: .zero, on: page)) == word.count }, "the word back home")
        XCTAssertTrue(waitUntil(1.5) { (try? self.inkShown(word, at: move, on: page)) == 0 }, "and not where it was moved to")

        undo.redo()
        XCTAssertTrue(waitUntil(1.5) { (try? self.inkShown(word, at: move, on: page)) == word.count }, "redone, moved")
        XCTAssertTrue(waitUntil(1.5) { (try? self.inkShown(word, at: .zero, on: page)) == 0 }, "and not at home")
        XCTAssertEqual(Self.liftsShowingInk(on: page.canvas), 0)
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, page.base + word.count)
    }

    /// Duplicate still leaves a copy, as it means to: moving the copy away leaves the original where it was.
    func testDuplicateStillMakesACopyThatMovesOnItsOwn() throws {
        let page = try page()
        let word = try write(on: page)
        try select(word, on: page)
        let first = CGVector(dx: 40, dy: -120)
        try drag(by: first, on: page)
        XCTAssertTrue(waitUntil(1.5) { Self.liftsShowingInk(on: page.canvas) == 0 }, "the move has landed")
        let undo = try XCTUnwrap(page.canvas.undoManager)
        page.controller.inkSelection.duplicateSelection(undoManager: undo)
        XCTAssertEqual(page.canvas.drawing.strokes.count, page.base + 2 * word.count, "Duplicate adds a copy")
        let copy = CGVector(dx: first.dx + SelectionEdit.duplicateOffset, dy: first.dy + SelectionEdit.duplicateOffset)
        let away = CGVector(dx: 0, dy: -200)
        let copied = try XCTUnwrap(page.controller.inkSelection.selection).indices.map { page.canvas.drawing.strokes[$0] }
        let copiedBounds = copied.reduce(CGRect.null) { $0.union($1.renderBounds) }
        HoldPage.turn(0.1)
        var dragged: [CGRect] = []
        try drag(by: away, on: page) {
            dragged += Self.liftsWithInk(on: page.canvas).filter(Self.showsInk).map(\.drawing.bounds)
        }
        XCTAssertFalse(dragged.isEmpty, "the copy is dragged in its lift layer")
        let elsewhere = dragged.filter { abs($0.minX - copiedBounds.minX) > 1 || abs($0.minY - copiedBounds.minY) > 1 }
        XCTAssertEqual(elsewhere, [], "the layer dragged holds the copy at \(copiedBounds), not the original")

        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, page.base + 2 * word.count, "both saved")
        XCTAssertTrue(waitUntil(1.5) { Self.liftsShowingInk(on: page.canvas) == 0 })
        XCTAssertEqual(try inkShown(word, at: first, on: page), word.count, "the original stays where it was moved")
        XCTAssertEqual(try inkShown(word, at: CGVector(dx: copy.dx + away.dx, dy: copy.dy + away.dy), on: page),
                       word.count, "the copy where it was dragged")
        XCTAssertEqual(try inkShown(word, at: copy, on: page), 0, "nothing left where the copy was made")
    }

    // MARK: Fixtures

    /// Lift layers (the page canvas's own PencilKit subviews) holding ink and not masked to nothing: ink shown by one.
    static func liftsShowingInk(on canvas: PKCanvasView) -> Int {
        liftsWithInk(on: canvas).filter(showsInk).count
    }

    private static func liftsWithInk(on canvas: PKCanvasView) -> [PKCanvasView] {
        canvas.subviews.compactMap { $0 as? PKCanvasView }.filter { !$0.drawing.strokes.isEmpty }
    }

    /// A lift layer is hidden by a mask with no path, so PencilKit still draws it.
    private static func showsInk(_ view: PKCanvasView) -> Bool {
        guard !view.isHidden else { return false }
        guard let mask = view.layer.mask else { return true }
        return (mask as? CAShapeLayer)?.path != nil
    }

    /// How many of `word`'s strokes the page's own tiles show moved by `place`, read at each stroke's middle.
    private func inkShown(_ word: [PKStroke], at place: CGVector, on page: HoldPage) throws -> Int {
        let ink = try XCTUnwrap(page.canvas.superview as? PageInkView)
        return word.filter { stroke in
            let points = LassoGeometry.drawingPoints(of: stroke)
            let middle = points[points.count / 2]
            return InkStaysDrawnTests.inkAlpha(of: ink, at: CGPoint(x: middle.x + place.dx, y: middle.y + place.dy)) > 0
        }.count
    }

    private func waitUntil(_ seconds: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return false }
            HoldPage.turn(0.02)
        }
        return true
    }

    /// A five-letter word written with the pen low on the page, clear of the other writing, so the page has no tile
    /// where the word is moved to.
    private func write(on page: HoldPage) throws -> [PKStroke] {
        for n in 0..<5 {
            var pencil = page.pencil()
            let origin = CGPoint(x: 200 + CGFloat(n) * 24, y: 720)
            for k in 0...14 {
                let t = CGFloat(k) / 14
                let point = CGPoint(x: origin.x + 16 * t, y: origin.y - 14 * sin(t * .pi * CGFloat(1 + n % 2)))
                if k == 0 { pencil.down(at: point) } else { pencil.move(to: point) }
            }
            pencil.lift()
            HoldPage.turn(0.05)
        }
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, page.base + 5)
        return Array(page.canvas.drawing.strokes.suffix(5))
    }

    private func select(_ word: [PKStroke], on page: HoldPage) throws {
        page.controller.tools.select(.lasso)
        let recognizer = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: page.canvas))
        lasso(round: CGRect(x: 170, y: 670, width: 190, height: 100), on: page, with: recognizer)
        XCTAssertEqual(page.controller.inkSelection.selection?.indices.count, word.count, "the lasso selects the word")
        HoldPage.turn(0.3)
    }

    /// Drags the selection by `delta` from its middle, as a finger does, in 12 steps a frame apart; `during` runs after
    /// each step.
    private func drag(by delta: CGVector, on page: HoldPage, during: () -> Void = {}) throws {
        let selection = try XCTUnwrap(page.controller.inkSelection.selection)
        let start = CGPoint(x: selection.box.rect.midX, y: selection.box.rect.midY).applying(selection.box.transform)
        let overlay = page.controller.inkSelection.overlay
        func onOverlay(_ point: CGPoint) -> CGPoint { overlay.convert(point, from: page.canvas.pageSpace) }
        _ = overlay.beginDrag(at: onOverlay(start), to: onOverlay(start))
        for k in 1...12 {
            let t = CGFloat(k) / 12
            overlay.continueDrag(to: onOverlay(CGPoint(x: start.x + delta.dx * t, y: start.y + delta.dy * t)))
            HoldPage.turn(1.0 / 120)
            during()
        }
        overlay.endDrag(at: onOverlay(CGPoint(x: start.x + delta.dx, y: start.y + delta.dy)))
    }

    /// The Pencil drawn once round `rect` through the toolbar lasso's recogniser, in page points.
    private func lasso(round rect: CGRect, on page: HoldPage, with recognizer: LassoCaptureRecognizer) {
        let space = page.canvas.pageSpace
        let points = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
        let touch = PencilTouchStub(window: page.canvas.window!, view: page.canvas, at: space.convert(points[0], to: nil))
        recognizer.touchesBegan([touch], with: PencilEventStub(touch))
        HoldPage.turn(0.004)
        for point in points.dropFirst() {
            touch.point = space.convert(point, to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizer.touchesMoved([touch], with: PencilEventStub(touch))
            HoldPage.turn(0.004)
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizer.touchesEnded([touch], with: PencilEventStub(touch))
        HoldPage.turn(0.1)
    }

    /// A worksheet on screen with the pen, its first page holding 40 strokes of writing near its top.
    private func page() throws -> HoldPage {
        let suiteName = "EmberPadTests.EP162.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep162-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: 40)), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        HoldPage.turn(0.3)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: 40,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
