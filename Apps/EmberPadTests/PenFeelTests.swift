import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// The fountain pen's GoodNotes-style feel, applied when the Pencil lifts:
/// the reshape itself (width, nib, pressure and tips), the stored settings and
/// the one-undo-step swap on the worksheet. Every fixture is synthetic.
@MainActor
final class PenFeelTests: XCTestCase {

    // MARK: - Settings

    func testDefaultsAreTheCaptainsGoodNotesFountainPen() {
        let settings = ToolSettings()
        XCTAssertEqual(settings.penTipSharpness, 1, "Tip sharpness defaults to GoodNotes' maximum")
        XCTAssertEqual(settings.penPressureSensitivity, 0, "pressure defaults to Min")
        XCTAssertFalse(settings.penTipSharpnessChosen)
        XCTAssertEqual(settings.penFeel, PenFeelSettings(tipSharpness: 1, pressureSensitivity: 0))
    }

    func testOlderStoredSettingsTakeTheNewDefaultButKeepAChosenSharpness() throws {
        func decode(_ json: String) throws -> ToolSettings { try JSONDecoder().decode(ToolSettings.self, from: Data(json.utf8)) }
        let old = try decode(#"{"penWidthIndex": 2}"#)
        XCTAssertEqual(old.penWidthIndex, 2)
        XCTAssertEqual(old.penTipSharpness, 1)
        XCTAssertEqual(old.penPressureSensitivity, 0)
        // Builds before EP51 wrote their 50% default with every save: that is not a choice.
        XCTAssertEqual(try decode(#"{"penTipSharpness": 0.5}"#).penTipSharpness, 1)
        // Any other stored value was moved by the teacher, and so is a 50% saved by this build after a move.
        XCTAssertEqual(try decode(#"{"penTipSharpness": 0.75}"#).penTipSharpness, 0.75)
        XCTAssertTrue(try decode(#"{"penTipSharpness": 0.75}"#).penTipSharpnessChosen)
        XCTAssertEqual(try decode(#"{"penTipSharpness": 0.5, "penTipSharpnessChosen": true}"#).penTipSharpness, 0.5)
        XCTAssertEqual(try decode(#"{"penTipSharpness": 0.5, "penTipSharpnessChosen": false}"#).penTipSharpness, 1)
    }

    func testOutOfRangeValuesAreRepaired() {
        var settings = ToolSettings()
        settings.penTipSharpness = 3
        settings.penPressureSensitivity = -1
        XCTAssertEqual(settings.normalized().penTipSharpness, 1)
        XCTAssertEqual(settings.normalized().penPressureSensitivity, 0)
        settings.penTipSharpness = .nan
        XCTAssertEqual(settings.normalized().penTipSharpness, 1)
    }

    func testTipSharpnessPersistsWithoutReapplyingThePencilTool() {
        let suite = "EmberPadTests.PenFeel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ToolState(defaults: defaults)
        var applied = 0
        tools.onToolChange = { _ in applied += 1 }
        tools.setPenTipSharpness(0.5)
        tools.setPenPressureSensitivity(0.25)
        XCTAssertEqual(applied, 0, "the feel is applied after lift, so the live PencilKit tool is unchanged")
        let relaunched = ToolState(defaults: defaults)
        XCTAssertEqual(relaunched.settings.penTipSharpness, 0.5, "a 50% the teacher chose survives a relaunch")
        XCTAssertEqual(relaunched.settings.penPressureSensitivity, 0.25)
    }

    // MARK: - Width, nib and pressure

    func testWidthComesFromThePenWidthNotTheRecordedSize() throws {
        let settings = PenFeelSettings(tipSharpness: 0)
        let thin = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 300, size: 3), settings: settings, toolWidth: 2.5))
        let bold = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 300, size: 6), settings: settings, toolWidth: 2.5))
        XCTAssertEqual(Array(thin.path).map(\.size), Array(bold.path).map(\.size),
                       "PencilKit's own swelling and scale no longer decide the width")
        // Moving sideways at force 1.2 with the middle pen width.
        let expected = PenFeel.widthPerToolWidth * 2.5 * PenFeel.pressureFactor(force: 1.2, sensitivity: 0) * PenFeel.nibFactor(direction: 0)
        let middle = Array(thin.path)[30]
        XCTAssertEqual(middle.size.width, PenFeel.pencilKitSize(forWidth: expected), accuracy: 1e-6)
        XCTAssertEqual(expected, 1.04, accuracy: 0.04, "about GoodNotes' 1 pt at the captain's setting")
        let wider = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 300), settings: settings, toolWidth: 4))
        XCTAssertGreaterThan(Array(wider.path)[30].size.width, middle.size.width, "a wider pen draws wider")
    }

    func testTheNibLiesAcrossTheStrokeSoPencilKitDrawsTheChosenWidth() throws {
        let reshaped = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 300), settings: PenFeelSettings(), toolWidth: 2.5))
        for point in reshaped.path {
            // Horizontal stroke: the nib points straight across it (PencilKit keeps angles in 0..<2π).
            let across = point.azimuth.truncatingRemainder(dividingBy: .pi)
            XCTAssertEqual(across, .pi / 2, accuracy: 1e-3)
        }
        XCTAssertEqual(PenFeel.pencilKitSize(forWidth: 1), 2.5, "PencilKit draws 2 × (size − 2) across its nib")
        XCTAssertEqual(PenFeel.pencilKitSize(forWidth: 0), 2 + PenFeel.hairline / 2, "a tip never vanishes")
    }

    func testUpRightDiagonalsAreSlightlyThinner() {
        let thin = PenFeel.nibFactor(direction: PenFeel.thinDirection)
        let thick = PenFeel.nibFactor(direction: PenFeel.thinDirection + .pi / 2)
        XCTAssertEqual(thin, PenFeel.thinRatio, accuracy: 1e-9)
        XCTAssertEqual(thick, 1, accuracy: 1e-9)
        XCTAssertEqual(PenFeel.nibFactor(direction: 0.3), PenFeel.nibFactor(direction: 0.3 + .pi), accuracy: 1e-9,
                       "the nib is the same both ways along a line")
        XCTAssertGreaterThan(PenFeel.thinRatio, 0.8, "GoodNotes' fountain pen varies only mildly with direction")
    }

    func testPressureAtMinBarelyChangesTheWidth() {
        let light = PenFeel.pressureFactor(force: 0.5, sensitivity: 0)
        let firm = PenFeel.pressureFactor(force: 2, sensitivity: 0)
        XCTAssertLessThan(light, 1)
        XCTAssertGreaterThan(firm, 1)
        XCTAssertLessThan(firm / light, 1.7, "Min reduces the swelling")
        XCTAssertGreaterThan(PenFeel.pressureFactor(force: 2, sensitivity: 1) / PenFeel.pressureFactor(force: 0.5, sensitivity: 1),
                             firm / light, "Max responds more")
        XCTAssertEqual(PenFeel.pressureFactor(force: 0, sensitivity: 0), 1, "no force reading counts as average")
        XCTAssertGreaterThanOrEqual(PenFeel.pressureFactor(force: 0.01, sensitivity: 0), 0.65, "never vanishes")
        XCTAssertLessThanOrEqual(PenFeel.pressureFactor(force: 4, sensitivity: 0), 1.45, "never swells far")
    }

    func testSharpTurnsKeepOneSteadyNib() throws {
        // A zigzag with hairpin turns, like a fast scribble.
        var locations: [CGPoint] = []
        for i in 0...120 {
            let t = CGFloat(i) / 120 * 6
            let f = t - floor(t)
            locations.append(CGPoint(x: 40 + 30 * t, y: 100 + 50 * (Int(t) % 2 == 0 ? f : 1 - f)))
        }
        let stroke = Self.stroke(locations)
        let reshaped = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 0), toolWidth: 2.5))
        let points = Array(reshaped.path)
        let axes = try XCTUnwrap(PenFeel.axes(locations, along: PenFeel.arcLengths(locations)))
        for i in 1..<axes.count {
            XCTAssertLessThanOrEqual(abs(axes[i] - axes[i - 1]), .pi / 2 + 1e-9, "no half-turn flips between neighbours")
        }
        let sizes = points.map(\.size.width)
        let body = PenFeel.pencilKitSize(forWidth: PenFeel.widthPerToolWidth * 2.5 * PenFeel.thinRatio * PenFeel.pressureFactor(force: 1.2, sensitivity: 0))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sizes.min()), body - 0.05, "the turns are not pinched")
    }

    // MARK: - Tips

    func testTaperIsSymmetricAndOnlyThinsTheEnds() throws {
        let reshaped = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 300, size: 6), settings: PenFeelSettings(),
                                                      toolWidth: 2.5))
        let sizes = Array(reshaped.path).map(\.size.width)
        let n = sizes.count
        let middle = sizes[n / 2]
        for i in 0..<n {
            XCTAssertEqual(sizes[i], sizes[n - 1 - i], accuracy: 1e-9, "point \(i) mirrors point \(n - 1 - i)")
            XCTAssertLessThanOrEqual(sizes[i], middle + 1e-9, "a taper never thickens ink")
        }
        // The ends taper over 9.5 widths (about 9 pt at the middle pen width); beyond that nothing changes.
        let reach = PenFeel.taperLength(width: PenFeel.widthPerToolWidth * 2.5, sharpness: 1)
        XCTAssertEqual(reach, 9.0, accuracy: 0.1)
        let along = PenFeel.arcLengths(Array(reshaped.path).map(\.location))
        for i in 0..<n where along[i] > reach && along[n - 1] - along[i] > reach {
            XCTAssertEqual(sizes[i], middle, accuracy: 1e-9)
        }
        // At the tip the drawn width is a quarter of the line's.
        XCTAssertEqual((sizes[0] - 2) / (middle - 2), PenFeel.sharpestTip, accuracy: 1e-6)
    }

    func testSharperTipsAreThinnerAndZeroIsBlunt() throws {
        let stroke = Self.line(length: 300, size: 6)
        let blunt = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 0), toolWidth: 2.5))
        let bluntSizes = Array(blunt.path).map(\.size.width)
        XCTAssertEqual(bluntSizes.first, bluntSizes[bluntSizes.count / 2], "0% keeps blunt ends")
        var previous = try XCTUnwrap(bluntSizes.first)
        for sharpness in [0.25, 0.5, 0.75, 1.0] {
            let reshaped = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: sharpness), toolWidth: 2.5))
            let tip = try XCTUnwrap(reshaped.path.first).size.width
            XCTAssertLessThan(tip, previous, "\(sharpness) is sharper than the step before")
            XCTAssertGreaterThan(tip, 2, "the tip still renders")
            previous = tip
        }
    }

    func testTipsEaseInQuicklyThenGently() {
        let width: CGFloat = 1
        let quarter = PenFeel.taperFactor(distanceFromEnd: 0.25 * PenFeel.taperWidths, width: width, sharpness: 1)
        let half = PenFeel.taperFactor(distanceFromEnd: 0.5 * PenFeel.taperWidths, width: width, sharpness: 1)
        XCTAssertEqual(PenFeel.taperFactor(distanceFromEnd: 0, width: width, sharpness: 1), PenFeel.sharpestTip, accuracy: 1e-9)
        XCTAssertGreaterThan(quarter - PenFeel.sharpestTip, half - quarter, "most of the width returns early, as in GoodNotes")
        XCTAssertEqual(PenFeel.taperFactor(distanceFromEnd: 0, width: width, sharpness: 0), 1)
    }

    func testReshapeKeepsEverythingButSizeAndNib() throws {
        let stroke = Self.line(length: 200, size: 5, transform: CGAffineTransform(translationX: 10, y: 20))
        let reshaped = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 1), toolWidth: 2.5))
        XCTAssertEqual(reshaped.ink.inkType, .fountainPen)
        XCTAssertEqual(reshaped.ink.color, stroke.ink.color)
        XCTAssertEqual(reshaped.transform, stroke.transform)
        XCTAssertEqual(reshaped.randomSeed, stroke.randomSeed)
        XCTAssertEqual(reshaped.path.creationDate, stroke.path.creationDate)
        for (new, old) in zip(Array(reshaped.path), Array(stroke.path)) {
            XCTAssertEqual(new.location, old.location)
            XCTAssertEqual(new.timeOffset, old.timeOffset)
            XCTAssertEqual(new.force, old.force)
            XCTAssertEqual(new.altitude, old.altitude, accuracy: 1e-3, "PencilKit stores angles at reduced precision")
            XCTAssertEqual(new.opacity, old.opacity)
        }
    }

    func testMaskedStrokesAreLeftAlone() {
        var stroke = Self.line(length: 300)
        stroke.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 1), toolWidth: 2.5))
    }

    func testDotsDecimalPointsAndChargesKeepBluntEndsAtTheLineWidth() throws {
        let settings = PenFeelSettings(tipSharpness: 1)
        let line = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 300, size: 6), settings: settings, toolWidth: 2.5))
        let body = Array(line.path)[30].size.width
        // A dot: one point, drawn at the line's width rather than PencilKit's bolder size.
        let dot = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 0, size: 6, count: 1), settings: settings, toolWidth: 2.5))
        XCTAssertEqual(try XCTUnwrap(dot.path.first).size.width, body, accuracy: 0.1)
        // A decimal point or charge: a tiny squiggle under 3 widths keeps blunt ends.
        let tiny = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 2, size: 6), settings: settings, toolWidth: 2.5))
        let sizes = Array(tiny.path).map(\.size.width)
        XCTAssertEqual(try XCTUnwrap(sizes.first), try XCTUnwrap(sizes.last), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(sizes.first), body, accuracy: 1e-6)
        // An arrowhead barb tapers over at most half its length, so its middle still shows.
        let barb = try XCTUnwrap(PenFeel.reshaped(Self.line(length: 6, size: 6, count: 31), settings: settings, toolWidth: 2.5))
        XCTAssertGreaterThan(Array(barb.path)[15].size.width - 2, 0.5 * (body - 2))
    }

    // MARK: - Live line and clean ink (EP53)

    func testLiftedPencilKitInkDrawsAsOneCleanLineWithoutABeadedHalo() throws {
        let drawing = try PKDrawing(data: XCTUnwrap(Data(base64Encoded: Self.pencilKitFountainStroke)))
        let written = try XCTUnwrap(drawing.strokes.first)
        let fresh = PKInk(.fountainPen, color: written.ink.color)
        XCTAssertEqual(written.ink.inkType, .fountainPen)
        XCTAssertNotEqual(written.ink.requiredContentVersion, fresh.requiredContentVersion,
                          "PencilKit commits live strokes with its older fountain-pen ink")
        let toolWidth: CGFloat = 2.5
        let reshaped = try XCTUnwrap(PenFeel.reshaped(written, settings: PenFeelSettings(tipSharpness: 1), toolWidth: toolWidth))
        XCTAssertEqual(reshaped.ink.inkType, .fountainPen)
        XCTAssertEqual(reshaped.ink.requiredContentVersion, fresh.requiredContentVersion, "the pen feel draws with a new ink")
        XCTAssertEqual(reshaped.randomSeed, written.randomSeed)

        // The older ink's seeded grain breaks a line this thin into beads with about half the ink.
        let ink = Self.columnInk(reshaped)
        XCTAssertLessThan(ink.variation, 0.05, "the line is even, with no beads along its edge")
        XCTAssertEqual(ink.mean, PenFeel.widthPerToolWidth * toolWidth, accuracy: 0.2 * PenFeel.widthPerToolWidth * toolWidth,
                       "the line carries its full width of ink")
    }

    func testThePensMonolineInputIsReshapedInTheFountainPenInk() throws {
        var live = Self.line(length: 300, size: 2.5)
        live.ink = PKInk(PenFeel.liveInkType, color: .emberPenBlack)
        let reshaped = try XCTUnwrap(PenFeel.reshaped(live, settings: PenFeelSettings(tipSharpness: 1), toolWidth: 2.5))
        XCTAssertEqual(reshaped.ink.inkType, .fountainPen)
        XCTAssertEqual(reshaped.ink.color, live.ink.color)
        XCTAssertLessThan(try XCTUnwrap(reshaped.path.first).size.width, Array(reshaped.path)[30].size.width, "pointed ends")

        var other = Self.line(length: 300, size: 2.5)
        other.ink = PKInk(.pen, color: .emberPenBlack)
        XCTAssertNil(PenFeel.reshaped(other, settings: PenFeelSettings(tipSharpness: 1), toolWidth: 2.5),
                     "other pens are not the pen's")
    }

    func testTheMonolineToolIsAsWideAsTheLiftedStrokeAtEveryPenWidth() throws {
        // The student view's provisional line takes this width, as would a stroke left in the monoline ink (EP56).
        for penWidth in Theme.penWidths {
            let tool = PenFeel.liveTool(color: .emberPenBlack, penWidth: penWidth)
            XCTAssertEqual(tool.inkType, .monoline)
            // PencilKit records a live monoline point 2 + w across for tool width w and draws it 2 × w (EP53).
            var live = Self.line(length: 300, size: 2 + tool.width)
            live.ink = tool.ink
            let lifted = try XCTUnwrap(PenFeel.reshaped(live, settings: PenFeelSettings(tipSharpness: 1), toolWidth: penWidth))
            let liveInk = Self.columnInk(live).mean, liftedInk = Self.columnInk(lifted).mean
            XCTAssertEqual(liveInk, liftedInk, accuracy: 0.15 * liftedInk, "no jump in width at lift for pen width \(penWidth)")
        }
    }

    // MARK: - Worksheet commit hook

    func testLiftedFountainPenStrokeIsReshapedAsOneUndoStep() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let earlier = Self.line(length: 200, size: 6, y: 60)
        let stroke = Self.line(length: 300, size: 6, y: 120)
        Self.commit(PKDrawing(strokes: [earlier]), on: canvas, controller, undo: undo)
        await Self.settle()
        Self.commit(PKDrawing(strokes: [canvas.drawing.strokes[0], stroke]), on: canvas, controller, undo: undo)
        XCTAssertEqual(try XCTUnwrap(canvas.drawing.strokes.last).path.first?.size.width, 6, "PencilKit's ink is shown as drawn")
        await Self.settle()

        let reshaped = try XCTUnwrap(canvas.drawing.strokes.last)
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        let expected = try XCTUnwrap(PenFeel.reshaped(stroke, settings: controller.tools.settings.penFeel,
                                                      toolWidth: controller.tools.settings.penWidth))
        XCTAssertEqual(Array(reshaped.path).map(\.size), Array(expected.path).map(\.size))
        XCTAssertLessThan(try XCTUnwrap(reshaped.path.first).size.width, 2.5, "the stroke end is pointed after lift")
        XCTAssertEqual(Array(reshaped.path).map(\.location), Array(stroke.path).map(\.location))
        XCTAssertEqual(session.drawing(on: 0).strokes.last?.path.first?.size.width, reshaped.path.first?.size.width,
                       "the session saves the reshaped stroke")
        XCTAssertEqual(undo.undoActionName, "Ink")
        XCTAssertFalse(undo.canRedo)

        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "one undo removes the stroke and its reshape")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        undo.redo()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(try XCTUnwrap(canvas.drawing.strokes.last).path.first?.size.width, reshaped.path.first?.size.width,
                       "redo brings back the reshaped stroke")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 0, "the earlier stroke is its own step")
        XCTAssertFalse(undo.canUndo)
    }

    func testLiftedLiveMonolineIsSwappedForTheFountainPenStrokeAsOneUndoStep() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        XCTAssertEqual((controller.tools.settings.pencilTool(for: .pen) as? PKInkingTool)?.inkType, PenFeel.liveInkType)
        var live = Self.line(length: 300, size: 3, y: 120)
        live.ink = PKInk(PenFeel.liveInkType, color: .emberPenBlack)
        Self.commit(PKDrawing(strokes: [live]), on: canvas, controller, undo: undo)
        await Self.settle()

        let lifted = try XCTUnwrap(canvas.drawing.strokes.last)
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertEqual(lifted.ink.inkType, .fountainPen)
        XCTAssertEqual(lifted.ink.requiredContentVersion, PKInk(.fountainPen, color: .emberPenBlack).requiredContentVersion)
        XCTAssertEqual(session.drawing(on: 0).strokes.last?.ink.inkType, .fountainPen, "the session saves the fountain-pen stroke")
        XCTAssertEqual(Array(lifted.path).map(\.location), Array(live.path).map(\.location))
        XCTAssertEqual(undo.undoActionName, "Ink")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 0, "one undo removes the stroke and its swap")
    }

    func testHighlighterIsLeftAsDrawnAndBluntTipsStillTakeTheLineWidth() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        var marker = Self.line(length: 300, size: 18, y: 200)
        marker.ink = PKInk(.marker, color: .yellow)
        Self.commit(PKDrawing(strokes: [marker]), on: canvas, controller, undo: undo)
        await Self.settle()
        XCTAssertEqual(Array(canvas.drawing.strokes[0].path).map(\.size), Array(marker.path).map(\.size))
        XCTAssertNotEqual(undo.undoActionName, "Ink", "the highlighter is not swapped")

        controller.tools.setPenTipSharpness(0)
        let stroke = Self.line(length: 300, size: 6, y: 320)
        Self.commit(PKDrawing(strokes: [canvas.drawing.strokes[0], stroke]), on: canvas, controller, undo: undo)
        await Self.settle()
        let sizes = Array(try XCTUnwrap(canvas.drawing.strokes.last).path).map(\.size.width)
        XCTAssertEqual(sizes.first, sizes[30], "0% sharpness keeps blunt ends")
        XCTAssertLessThan(try XCTUnwrap(sizes.first), 6, "but the line still takes the pen's width")
        XCTAssertEqual(undo.undoActionName, "Ink")
    }

    func testAStrokeAlreadyFollowedByAnotherIsNotSwapped() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let first = Self.line(length: 300, size: 6, y: 100)
        let second = Self.line(length: 300, size: 6, y: 160)
        canvas.drawing = PKDrawing(strokes: [first])
        controller.canvasViewDrawingDidChange(canvas)
        // The next change lands before the deferred swap runs.
        canvas.drawing = PKDrawing(strokes: [first, second])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(canvas.drawing.strokes[0].path.first?.size.width, 6, "a stale swap leaves the ink alone")
        XCTAssertLessThan(try XCTUnwrap(canvas.drawing.strokes[1].path.first).size.width, 2.5)
    }

    /// A fountain-pen stroke through `locations`, sampled as given.
    static func stroke(_ locations: [CGPoint], size: CGFloat = 4) -> PKStroke {
        let points = locations.indices.map { i in
            PKStrokePoint(location: locations[i], timeOffset: Double(i) / 240, size: CGSize(width: size, height: size),
                          opacity: 1, force: 1.2, azimuth: .pi / 4, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .emberPenBlack),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    // MARK: - Fixtures

    /// A synthetic horizontal fountain-pen stroke, evenly sampled, with constant size.
    static func line(length: CGFloat, size: CGFloat = 6, y: CGFloat = 100, count: Int = 61,
                     transform: CGAffineTransform = .identity) -> PKStroke {
        let points = (0..<count).map { index -> PKStrokePoint in
            let t = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
            return PKStrokePoint(location: CGPoint(x: 40 + length * t, y: y), timeOffset: Double(index) / 240,
                                 size: CGSize(width: size, height: size), opacity: 1, force: 1.2, azimuth: .pi / 4,
                                 altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .emberPenBlack),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000)),
                        transform: transform)
    }

    /// One fountain-pen stroke as PencilKit committed it from a Simulator drag across a page (EP53), before any pen
    /// feel: 24 points, its older live ink and its own random seed. Synthetic, not the captain's writing.
    static let pencilKitFountainStroke = """
        d3Jk8AIACAASEAAAAAAAAAAAAAAAAAAAAAASEOXU8DIUHkG9kQfbbHYkqV8aBggAEAAYABoGCAEQARgBIjwKFA2HFtk9FYcW2T0dhxbZPSUAAIA/\
        Ehljb20uYXBwbGUuaW5rLmZvdW50YWlucGVuGANBAAAAAAAABEAqoQQKEMGKm5MADUHoq0X+/0+5frcSBggAEAEYARoGCAAQARgAIAAqvQMKEBDv\
        jD5imk4WhSfUy1d9bW0R1SFpvX5RyEEYGCAHKPgPMhLoAwAAAAAAAAAA/38AAIA/AAA6gANZnW9CjsbvQgAAAABn8WNAtdSDQo7G70KA82g+cnpj\
        QFjpjELR/e5CHDm5Pvu2Y0DxWJdCr2HuQnAXDj9HFWNA/gKpQiny7ULigVs/vD1jQHkbuEJVbO1C/6uJP7h3Y0DDV8FCl6PsQu77nD8DimNArG3P\
        QnUH7EIxDbw/GyNjQDs420LZ2utCMV/SP5CjY0AFqutCGxLrQgU09D9Mw2NA07PzQl5J6kIC9QRACRhjQOc4AENeSepCEsoQQFCWY0ADgwVDoIDp\
        QuBvGkALoGNAk2QLQ6CA6UKMIyhAgzNjQKTxEkPit+hCKKY5QOd4Y0BuyRVDwBvoQuRYPkBgImNAWHEdQyTv50JONU1A5z9jQFEjIkNmJudCiJxW\
        QJStY0ANnChDh2zmQkj3Y0BfQWNARQ4wQ6ld5kKbuHNACCpjQH3MN0PrlOVC0KKCQC6UY0BHpDpDyfjkQpeBhkDoGGNAb79CQy3M5EIsRY5AwzNj\
        QLDfR0NvA+RCJqqTQMnZY0BAAUgWMhQNAABoQhUAAOJCHQAAEEMlAAAAQUCgmobC0wR6Hg0AAIA/FQAAAAAdAAAAACUAAIA+LQAAAAA1AAAAADoG\
        CAAQABgAQhBoFIrNrUlI0Lmtdazgd2al
        """

    /// The ink in each pixel column across the middle 60% of a near-horizontal stroke, rendered at about the iPad's
    /// page scale: mean in page points, and its coefficient of variation along the stroke.
    static func columnInk(_ stroke: PKStroke, scale: CGFloat = 2.55) -> (mean: Double, variation: Double) {
        let bounds = stroke.renderBounds.insetBy(dx: -4, dy: -4).integral
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: [stroke]).image(from: bounds, scale: scale)
        }
        guard let cg = image.cgImage else { return (0, 1) }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 1) }
        let columns = (Int(Double(width) * 0.2)..<Int(Double(width) * 0.8)).map { x in
            (0..<height).reduce(0.0) { $0 + Double(pixels[($1 * width + x) * 4 + 3]) / 255 } / Double(scale)
        }
        let mean = columns.reduce(0, +) / Double(max(columns.count, 1))
        let spread = (columns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(columns.count, 1))).squareRoot()
        return (mean, mean > 0 ? spread / mean : 1)
    }

    private static func undoManager(_ controller: PDFOverlayPageController) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return undo
    }

    /// Sets the canvas as a committed stroke would and registers the undo step PencilKit would for it.
    static func commit(_ drawing: PKDrawing, on canvas: PKCanvasView, _ controller: PDFOverlayPageController,
                               undo: UndoManager) {
        let before = canvas.drawing
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { canvas.drawing = before }
        }
        undo.endUndoGrouping()
        canvas.drawing = drawing
        controller.canvasViewDrawingDidChange(canvas)
    }

    /// Lets the swap that waits a turn of the main queue run.
    private static func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: 0))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    static func makeController() async throws -> (PDFOverlayPageController, DocumentSession) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Chem Group A", relativePath: "pen-feel-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: 1)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("pen-feel-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.PenFeel.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}
