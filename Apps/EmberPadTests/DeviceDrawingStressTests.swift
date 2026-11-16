import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import EmberPad

/// EP110: the drawing stress test firstmate runs on the teacher's own iPad (`scripts/device-stress-test.sh`). It
/// writes fast with every tool, as a teacher does in class, and checks on every display frame that ink once drawn
/// stays on the screen, and in the model that no stroke is lost or doubled, each undo takes one stroke, and the
/// erasers take exactly what they cover. It times pen to ink and the main thread's stalls against `StressBounds`.
///
/// It runs only when `EMBERPAD_STRESS=1` reaches the test process and only in the stress test's own host app (bundle
/// id ending `.stresstest`, its own sandbox and Keychain), so a normal test run, the CI shards, and the installed
/// Ember Slate are never touched. Each scenario writes in a temporary library of its own. The scenarios run in name
/// order; `test99` writes the summary (also written after each scenario, so a run cut short leaves one).
@MainActor
final class DeviceDrawingStressTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(StressGate.enabled, "the device stress test runs only from scripts/device-stress-test.sh "
                          + "(\(StressGate.environmentKey)=1)")
        try XCTSkipUnless(StressGate.hostIsSeparate, "refusing to run inside \(StressGate.hostBundleID): the stress test "
                          + "runs only in its own host app (bundle id ending \(StressGate.hostSuffix)), never in Ember Slate")
        continueAfterFailure = true
    }

    // MARK: - The sampler

    /// The frame sampler can see the page's ink where it is, and reads nothing missing from still ink. If this fails,
    /// the pixel checks after it are not to be trusted (the model checks still are).
    func test01_SamplerSelfCheck() throws {
        let scenario = try StressScenario(tool: "sampler", title: "Frame sampler self-check", self)
        let ids = scenario.markBystanders()
        let blank = scenario.sampler.add("bare paper", page: 0, points: (0..<8).map { CGPoint(x: 80 + CGFloat($0) * 50, y: 640) },
                                         lifted: true)
        scenario.sampler.expectGone(blank)
        StressPage.pump(1.2)
        func seenAll() -> Bool { ids.allSatisfy { id in scenario.sampler.mark(id)?.firstSeen.allSatisfy { $0 != nil } ?? false } }
        var seen = seenAll()
        // Which points the first look never read as ink, so a failure on a device can be told apart
        // from a page drawn blank (EP113: on the iPad the trial flip after it read the page's ink as missing).
        let firstRows = StressRun.rowsTopDown ? "top down" : "bottom up"
        let unseen = ids.compactMap { id -> String? in
            guard let mark = scenario.sampler.mark(id) else { return nil }
            let missed = mark.firstSeen.indices.filter { mark.firstSeen[$0] == nil }
            guard !missed.isEmpty else { return nil }
            return "\(mark.label): points \(missed.map { String($0 + 1) }.joined(separator: ",")) of \(mark.points.count) at "
                + missed.map { String(format: "(%.0f, %.0f)", mark.points[$0].x, mark.points[$0].y) }.joined(separator: " ")
        }
        if !seen {
            // Rows bottom to top on this GPU: read them the other way round and look again.
            StressRun.rowsTopDown.toggle()
            scenario.restartMarks(ids)
            StressPage.pump(1.0)
            seen = seenAll()
            if !seen { StressRun.rowsTopDown.toggle() }
        }
        let phantom = scenario.sampler.mark(blank)?.firstSeen.contains { $0 != nil } ?? true
        let frames = scenario.sampler.frames
        StressRun.samplerWorks = seen && !phantom && frames > 30
        StressRun.samplerSelfCheck = StressRun.samplerWorks
            ? "pass (\(frames) frames read; rows \(StressRun.rowsTopDown ? "top down" : "bottom up"))"
            : "FAIL (ink seen \(seen), ink read on bare paper \(phantom), frames \(frames))"
        scenario.check("sees the page's ink", seen, "every point of the handwriting already on the page reads as ink"
                       + (unseen.isEmpty ? "" : "; first look (rows \(firstRows)) missed "
                          + unseen.joined(separator: "; ")))
        scenario.check("reads no ink on bare paper", !phantom, "points on bare paper read as bare")
        scenario.check("reads every display frame", frames > 30, "\(frames) frames read in about 1.2 s")
        _ = scenario.sampler.picture(page: 0, name: "sampler-page.png")
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount])
    }

    // MARK: - The pen

    /// The class's vanishing bracket: 24 brackets at a time, 5, 10 and 20 ms apart, in the fountain pen.
    func test02_FountainPenFastBrackets() throws {
        let scenario = try StressScenario(tool: "fountainPen.brackets", title: "Fountain pen, fast brackets", self)
        var written = 0
        for (row, gap) in [0.005, 0.01, 0.02].enumerated() {
            for n in 0..<24 {
                let origin = CGPoint(x: 40 + CGFloat(n % 12) * 44, y: 170 + CGFloat(row * 2 + n / 12) * 62)
                scenario.pen(StressInk.samples(StressInk.bracket(at: origin), speed: 520, seed: UInt64(row * 100 + n)),
                             "bracket \(Int(gap * 1000)) ms #\(n + 1)")
                written += 1
                StressPage.pump(gap)
            }
        }
        scenario.note("writing ended")
        scenario.settle()
        scenario.note("settled")
        scenario.checkUndoTakesOneStrokeEach(written)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + written])
    }

    /// Long writing: a line in print (a stroke per letter stroke) and one joined up (a stroke per word), at a hand's
    /// pace, with a hand's short lifts between strokes.
    func test03_LongWriting() throws {
        let scenario = try StressScenario(tool: "fountainPen.longWriting", title: "Fountain pen, long writing", self)
        var written = 0
        let lines: [(String, Bool, CGFloat)] = [("the quick brown fox jumps", false, 180), ("over the lazy dogs", true, 260),
                                                ("now write some more words", false, 340), ("and keep on writing", true, 420),
                                                ("one two three four", false, 500), ("five six seven eight", true, 580)]
        for (n, line) in lines.enumerated() {
            for (k, stroke) in ScribbleFixtures.handwriting(line.0, at: CGPoint(x: 50, y: line.2), joined: line.1).enumerated() {
                scenario.pen(StressInk.samples(stroke, speed: line.1 ? 320 : 240, seed: UInt64(n * 1000 + k)),
                             "\(line.1 ? "joined" : "print") line \(n + 1) stroke \(k + 1)")
                written += 1
                StressPage.pump([0.03, 0.06, 0.012, 0.09][k % 4])
            }
        }
        scenario.settle()
        scenario.checkUndoTakesOneStrokeEach(written)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + written])
    }

    /// Strokes begun while the one before is still landing: 0 to 16 ms between a lift and the next pen-down.
    func test04_OverlappingStrokes() throws {
        let scenario = try StressScenario(tool: "fountainPen.overlapping", title: "Strokes begun while the last one lands", self)
        let gaps: [TimeInterval] = [0, 0.002, 0.004, 0.008, 0.016]
        var written = 0
        for n in 0..<50 {
            let origin = CGPoint(x: 40 + CGFloat(n % 10) * 54, y: 170 + CGFloat(n / 10) * 80)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: origin, seed: n), speed: 420, seed: UInt64(n)),
                         "squiggle \(Int(gaps[n % gaps.count] * 1000)) ms #\(n + 1)")
            written += 1
            if gaps[n % gaps.count] > 0 { StressPage.pump(gaps[n % gaps.count]) }
        }
        scenario.settle()
        scenario.checkUndoTakesOneStrokeEach(written)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + written])
    }

    /// Every pen colour and width, switched between strokes written 10 ms apart: each stroke keeps the colour and
    /// width it was written in.
    func test05_PenColoursAndWidths() throws {
        let scenario = try StressScenario(tool: "fountainPen.coloursAndWidths", title: "Pen colours and widths", self)
        var expected: [(color: Int, width: Int)] = []
        for color in 0..<3 {
            for width in 0..<3 {
                scenario.tools.selectPenColor(color)
                scenario.tools.selectPenWidth(width)
                for k in 0..<2 {
                    let n = expected.count
                    let origin = CGPoint(x: 40 + CGFloat(n % 6) * 90, y: 180 + CGFloat(n / 6) * 90)
                    scenario.pen(StressInk.samples(StressInk.squiggle(at: origin, width: 50, seed: n), speed: 400, seed: UInt64(n)),
                                 "colour \(color) width \(width) #\(k + 1)")
                    expected.append((color, width))
                    StressPage.pump(0.01)
                }
            }
        }
        scenario.settle()
        let saved = Array(scenario.page.saved(0).dropFirst(scenario.bystanderCount))
        // Each stroke is matched to the one written at its time, wherever it sits in the page's drawing.
        let written = saved.sorted { $0.path.creationDate < $1.path.creationDate }
        scenario.checkWritingOrder(saved)
        var wrongColour: [String] = [], wrongWidth: [Int] = []
        if written.count == expected.count {
            let palette = scenario.tools.settings.penColors.map { UIColor(stressHex: $0) }
            for (n, stroke) in written.enumerated() {
                if !stroke.ink.color.stressMatches(palette[expected[n].color]) {
                    wrongColour.append("\(n + 1) in \(stroke.ink.color.stressHex), not \(palette[expected[n].color].stressHex)")
                }
                let size = stroke.path.map(\.size.width).max() ?? 0
                let target = Theme.penWidths[expected[n].width]
                if size < target * 0.5 || size > target * 2.5 { wrongWidth.append(n + 1) }
            }
        }
        scenario.check("each stroke keeps its colour", written.count == expected.count && wrongColour.isEmpty,
                       wrongColour.isEmpty ? "all \(written.count) in the colour chosen" : "strokes " + wrongColour.joined(separator: ", "))
        scenario.check("each stroke keeps its width", written.count == expected.count && wrongWidth.isEmpty,
                       wrongWidth.isEmpty ? "all \(written.count) at the width chosen" : "strokes \(wrongWidth) at another width")
        scenario.checkUndoTakesOneStrokeEach(expected.count)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + expected.count])
    }

    /// The pen's draw and hold: a wobbly line held still at its end becomes straight, four in quick succession.
    func test06_PenHoldToStraightLine() throws {
        let scenario = try StressScenario(tool: "fountainPen.holdToLine", title: "Pen, hold to straight line", self)
        scenario.tools.setPenDrawAndHold(true)
        for n in 0..<4 {
            let y = 200 + CGFloat(n) * 90
            scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: 70, y: y), to: CGPoint(x: 470, y: y + 30), wobble: 0.6),
                                           speed: 500, seed: UInt64(n)),
                         "held line #\(n + 1)", hold: HoldTracker.duration + 0.25)
            StressPage.pump(0.02)
        }
        scenario.settle()
        let lines = Array(scenario.page.saved(0).dropFirst(scenario.bystanderCount))
        let bent = lines.enumerated().filter { StressInk.straightness(of: $0.element) > 1.0 }.map { $0.offset + 1 }
        scenario.check("held lines are straight", lines.count == 4 && bent.isEmpty,
                       bent.isEmpty ? "all \(lines.count) straight" : "lines \(bent) still bend")
        scenario.checkUndoTakesOneStrokeEach(4)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + 4])
    }

    /// The pen's draw and hold makes shapes (EP116): a square, a triangle, a circle and a curve, each held still at its
    /// end straight after the last, become their clean shapes in the pen's ink, one stroke and one undo step each.
    func test06b_PenHoldToShape() throws {
        let scenario = try StressScenario(tool: "fountainPen.holdToShape", title: "Pen, hold to shape", self)
        scenario.tools.setPenDrawAndHold(true)
        let arc = (0...40).map { k -> CGPoint in
            let angle = CGFloat.pi * (200 + 140 * CGFloat(k) / 40) / 180
            return CGPoint(x: 420 + 130 * cos(angle), y: 560 + 130 * sin(angle))
        }
        let shapes: [(String, ShapeKind, [CGPoint])] = [
            ("square", .square, ShapeToolTests.hand([CGPoint(x: 80, y: 180), CGPoint(x: 230, y: 180), CGPoint(x: 230, y: 330),
                                                     CGPoint(x: 80, y: 330)], closed: true)),
            ("triangle", .triangle, ShapeToolTests.hand([CGPoint(x: 360, y: 320), CGPoint(x: 450, y: 180), CGPoint(x: 540, y: 320)],
                                                        closed: true)),
            ("circle", .circle, ShapeToolTests.handEllipse(center: CGPoint(x: 160, y: 470), radii: CGSize(width: 80, height: 80))),
            ("curve", .curve, arc),
        ]
        for (n, shape) in shapes.enumerated() {
            // A held shape is redrawn clean the moment the hold latches, so the hand's own path is not judged after it.
            let id = scenario.pen(StressInk.samples(shape.2, speed: 600, seed: UInt64(n)), "held \(shape.0)",
                                  hold: HoldTracker.duration + 0.25)
            scenario.sampler.release(id)
            StressPage.pump(0.03)
        }
        scenario.settle()
        let clean = Array(scenario.page.saved(0).dropFirst(scenario.bystanderCount))
        scenario.check("each held shape is one stroke", clean.count == shapes.count,
                       "\(clean.count) strokes for \(shapes.count) shapes")
        scenario.check("each held shape is in the pen's ink", clean.allSatisfy { $0.ink.inkType == .fountainPen },
                       clean.map { "\($0.ink.inkType.rawValue)" }.joined(separator: ", "))
        // Each stroke kept is the clean shape the hand drew: on the recognised outline, not on the hand's path.
        // The comparison is the test's own work on the main thread, so it is not charged to the app as a stall (EP124).
        let off: [String] = StressHarnessTime.measure {
            var off: [String] = []
            for (n, shape) in shapes.enumerated() {
                guard let ideal = ShapeRecognizer.heldShape(shape.2, lineLike: StrokeSnap.isLineLike(shape.2)), ideal.kind == shape.1 else {
                    off.append("\(shape.0) is not recognised from the hand")
                    continue
                }
                guard n < clean.count else { continue }
                let outline = ideal.outline(spacing: 1)
                let stray = clean[n].path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(clean[n].transform) }
                    .map { p in outline.map { StressInk.distance($0, p) }.min() ?? .infinity }.max() ?? .infinity
                if stray > 3 { off.append("\(shape.0) strays " + String(format: "%.1f", stray) + " pt from its clean \(ideal.kind) outline") }
            }
            return off
        }
        scenario.check("each held shape is drawn clean", off.isEmpty,
                       off.isEmpty ? "all \(shapes.count) on their clean outlines" : off.joined(separator: "; "))
        scenario.markStrokes(clean, label: "held shape")
        StressPage.pump(0.8)
        scenario.checkUndoTakesOneStrokeEach(shapes.count)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + shapes.count])
    }

    // MARK: - Highlighter

    /// The highlighter: straight on its own (the default), freehand with that off, and straightened by a hold.
    func test07_Highlighter() throws {
        let scenario = try StressScenario(tool: "highlighter", title: "Highlighter, straight, freehand and held", self)
        scenario.tools.select(.highlighter)
        scenario.tools.setHighlighterAlwaysStraight(true)
        var written = 0
        for n in 0..<6 {
            let y = 170 + CGFloat(n) * 40
            scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: 60, y: y), to: CGPoint(x: 420, y: y + 4), wobble: 1.5),
                                           speed: 700, seed: UInt64(n)),
                         "straight highlight #\(n + 1)", timesInk: false)
            written += 1
            StressPage.pump(0.01)
        }
        scenario.tools.setHighlighterAlwaysStraight(false)
        for n in 0..<4 {
            let origin = CGPoint(x: 60 + CGFloat(n) * 120, y: 450)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: origin, width: 80, seed: n), speed: 500, seed: UInt64(n + 10)),
                         "freehand highlight #\(n + 1)", timesInk: false)
            written += 1
            StressPage.pump(0.008)
        }
        scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: 60, y: 560), to: CGPoint(x: 420, y: 566), wobble: 1.5),
                                       speed: 600, seed: 99),
                     "held highlight", hold: HoldTracker.duration + 0.25, timesInk: false)
        written += 1
        scenario.settle()
        let strokes = Array(scenario.page.saved(0).dropFirst(scenario.bystanderCount))
        let markers = strokes.filter { $0.ink.inkType == .marker }.count
        scenario.check("all in the highlighter's ink", markers == written, "\(markers) of \(strokes.count) are highlighter ink")
        let straight = strokes.count == written ? (Array(strokes.prefix(6)) + [strokes[written - 1]]) : []
        let bent = straight.enumerated().filter { StressInk.straightness(of: $0.element) > 1.0 }.map { $0.offset + 1 }
        scenario.check("straight highlights are straight", !straight.isEmpty && bent.isEmpty,
                       bent.isEmpty ? "the 6 straight and the held one are straight" : "\(bent) bend")
        scenario.checkUndoTakesOneStrokeEach(written)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + written])
    }

    // MARK: - Shapes

    /// The shape tool: a rectangle, a triangle and an ellipse drawn one straight after the other become clean shapes.
    func test08_Shapes() throws {
        let scenario = try StressScenario(tool: "shape", title: "Shapes", self)
        scenario.tools.select(.shape)
        let shapes: [(String, [CGPoint])] = [
            ("rectangle", ShapeToolTests.hand([CGPoint(x: 80, y: 180), CGPoint(x: 260, y: 180), CGPoint(x: 260, y: 300),
                                               CGPoint(x: 80, y: 300)], closed: true)),
            ("triangle", ShapeToolTests.hand([CGPoint(x: 360, y: 300), CGPoint(x: 450, y: 170), CGPoint(x: 540, y: 300)], closed: true)),
            ("ellipse", ShapeToolTests.handEllipse(center: CGPoint(x: 200, y: 450), radii: CGSize(width: 110, height: 60))),
        ]
        for (n, shape) in shapes.enumerated() {
            // A shape is redrawn clean on lift, so the hand's own path is not judged after it.
            let id = scenario.pen(StressInk.samples(shape.1, speed: 600, seed: UInt64(n)), shape.0)
            scenario.sampler.release(id)
            StressPage.pump(0.03)
        }
        scenario.settle()
        let clean = Array(scenario.page.saved(0).dropFirst(scenario.bystanderCount))
        scenario.check("each shape is one stroke", clean.count == 3, "\(clean.count) strokes for 3 shapes")
        // Each stroke kept is the clean shape the hand drew: on the recognised outline, not on the hand's path.
        // The comparison is the test's own work on the main thread, so it is not charged to the app as a stall (EP124).
        let off: [String] = StressHarnessTime.measure {
            var off: [String] = []
            for (n, shape) in shapes.enumerated() {
                guard let ideal = ShapeRecognizer.recognize(shape.1) else { off.append("\(shape.0) is not recognised from the hand"); continue }
                guard n < clean.count else { continue }
                let outline = ideal.outline(spacing: 1)
                let stray = clean[n].path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(clean[n].transform) }
                    .map { p in outline.map { StressInk.distance($0, p) }.min() ?? .infinity }.max() ?? .infinity
                if stray > 2.5 { off.append("\(shape.0) strays " + String(format: "%.1f", stray) + " pt from its clean \(ideal.kind) outline") }
            }
            return off
        }
        scenario.check("each shape is drawn clean", off.isEmpty, off.isEmpty ? "all 3 on their clean outlines" : off.joined(separator: "; "))
        // The clean shapes stay on the screen.
        scenario.markStrokes(clean, label: "clean shape")
        StressPage.pump(0.8)
        scenario.checkUndoTakesOneStrokeEach(3)
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + 3])
    }

    // MARK: - Erasers

    /// The whole-stroke eraser at each size, straight after the strokes it erases were written: it takes exactly the
    /// strokes it touches, in one undo step, and redo takes them again.
    func test09_WholeStrokeEraser() throws {
        let scenario = try StressScenario(tool: "eraser.wholeStroke", title: "Whole-stroke eraser, every size", self)
        var kept = scenario.bystanderCount
        for size in 0..<Theme.eraserSizes.count {
            scenario.tools.select(.pen)
            let y = 200 + CGFloat(size) * 150
            var row: [Int] = []
            for n in 0..<6 {
                row.append(scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 60 + CGFloat(n) * 90, y: y), seed: n),
                                                          speed: 450, seed: UInt64(size * 10 + n)),
                                        "size \(size) stroke \(n + 1)"))
                StressPage.pump(0.012)
            }
            kept += 6
            StressPage.pump(0.03)
            scenario.tools.select(.eraser)
            scenario.tools.setEraserMode(.wholeStroke)
            scenario.tools.selectEraserSize(size)
            let before = scenario.page.saved(0).count
            // Through the first three strokes; the fourth starts 64 pt past the sweep's end, beyond the largest eraser.
            scenario.erase(StressInk.line(from: CGPoint(x: 40, y: y + 4), to: CGPoint(x: 236, y: y + 4), steps: 60),
                           removing: Array(row.prefix(3)), "whole-stroke eraser size \(size)")
            scenario.settle()
            kept -= 3
            let after = scenario.page.saved(0).count
            scenario.check("size \(size) erases exactly the strokes it touches", after == kept,
                           "\(before) strokes before, \(after) after, \(kept) expected")
            scenario.checkOneUndoRestores(3, "size \(size) erase")
        }
        scenario.finish(expectedStrokes: [0: kept])
    }

    /// PencilKit's partial (pixel) eraser at each size, across vertical lines just written: it clears its band and
    /// leaves the ends, and one undo puts the lines back.
    func test10_PartialEraser() throws {
        let scenario = try StressScenario(tool: "eraser.partial", title: "Partial eraser, every size", self)
        for size in 0..<Theme.eraserSizes.count {
            scenario.tools.select(.pen)
            let top = 160 + CGFloat(size) * 170
            var band: [Int] = []
            for n in 0..<4 {
                let x = 110 + CGFloat(n) * 110
                let id = scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: x, y: top), to: CGPoint(x: x + 2, y: top + 120)),
                                                        speed: 500, seed: UInt64(size * 10 + n)),
                                      "size \(size) line \(n + 1)")
                // The line's middle goes; its ends must stay.
                scenario.sampler.release(id)
                scenario.sampler.add("size \(size) line \(n + 1) top end", page: 0,
                                     points: (0..<4).map { CGPoint(x: x + 0.1 * CGFloat($0), y: top + 3 + CGFloat($0) * 2) }, lifted: true)
                scenario.sampler.add("size \(size) line \(n + 1) bottom end", page: 0,
                                     points: (0..<4).map { CGPoint(x: x + 2, y: top + 117 - CGFloat($0) * 2) }, lifted: true)
                band.append(scenario.sampler.add("size \(size) line \(n + 1) middle", page: 0,
                                                 points: (0..<4).map { CGPoint(x: x + 1, y: top + 56 + CGFloat($0) * 2) }, lifted: true))
                StressPage.pump(0.012)
            }
            scenario.settle()
            let before = scenario.page.saved(0).count
            scenario.tools.select(.eraser)
            scenario.tools.setEraserMode(.partial)
            scenario.tools.selectEraserSize(size)
            scenario.erase(StressInk.line(from: CGPoint(x: 60, y: top + 60), to: CGPoint(x: 520, y: top + 61), steps: 90),
                           removing: band, "partial eraser size \(size)")
            scenario.settle()
            let radius = Theme.eraserSizes[size] / 2
            let through = scenario.page.saved(0).filter { stroke in
                StressInk.inkedPoints(of: stroke).contains { abs($0.y - (top + 60)) < radius * 0.4 && $0.x > 80 && $0.x < 500 }
            }.count
            scenario.check("size \(size) clears its band", through == 0, "\(through) strokes still cross the eraser's path")
            let after = scenario.page.saved(0).count
            scenario.check("size \(size) leaves both ends of each line", after >= before + 4,
                           "\(before) strokes before, \(after) after (each line cut in two)")
            scenario.checkOneUndoRestores(-(after - before), "size \(size) partial erase")
        }
        scenario.finish(expectedStrokes: nil)
    }

    /// "Erase highlighter only": the eraser over a highlighted line takes the highlight and leaves the pen's ink.
    func test11_EraseHighlighterOnly() throws {
        let scenario = try StressScenario(tool: "eraser.highlighterOnly", title: "Erase highlighter only", self)
        var kept = scenario.bystanderCount
        for (n, mode) in [EraserMode.wholeStroke, .partial].enumerated() {
            let y = 220 + CGFloat(n) * 200
            scenario.tools.select(.pen)
            scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: 80, y: y), to: CGPoint(x: 460, y: y)), speed: 500,
                                           seed: UInt64(n)), "pen line \(n + 1)")
            StressPage.pump(0.015)
            scenario.tools.select(.highlighter)
            let highlight = scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: 80, y: y + 11), to: CGPoint(x: 460, y: y + 11)),
                                                           speed: 600, seed: UInt64(n + 5)), "highlight \(n + 1)", timesInk: false)
            StressPage.pump(0.03)
            kept += 2
            scenario.tools.select(.eraser)
            scenario.tools.setEraserMode(mode)
            scenario.tools.selectEraserSize(1)
            scenario.tools.setEraseHighlighterOnly(true)
            // The partial eraser takes the highlight's middle and leaves its ends, so that mark is not judged.
            if mode == .partial { scenario.sampler.release(highlight) }
            scenario.erase(StressInk.line(from: CGPoint(x: 120, y: y + 6), to: CGPoint(x: 420, y: y + 6), steps: 60),
                           removing: mode == .wholeStroke ? [highlight] : [], "\(mode) highlighter-only eraser")
            scenario.settle()
            let strokes = scenario.page.saved(0)
            let pens = strokes.filter { $0.ink.inkType == .fountainPen }.count
            let markers = strokes.filter { $0.ink.inkType == .marker }
            let crossing = markers.filter { StressInk.inkedPoints(of: $0).contains { $0.x > 160 && $0.x < 380 } }.count
            // Everything kept but this row's highlight is the pen's.
            scenario.check("\(mode): the pen's ink stays", pens == kept - 1,
                           "\(pens) pen strokes, \(kept - 1) expected")
            scenario.check("\(mode): the highlight under the eraser goes", crossing == 0,
                           "\(crossing) highlighter strokes still under the eraser's path")
            if mode == .wholeStroke { kept -= 1 } else { kept = strokes.count }
            scenario.tools.setEraseHighlighterOnly(false)
        }
        scenario.finish(expectedStrokes: [0: kept])
    }

    /// "Back to last tool on lift": the eraser hands back the highlighter, then the pen, and writing straight after
    /// the lift is in that tool.
    func test12_EraserBackToLastTool() throws {
        let scenario = try StressScenario(tool: "eraser.backToLastTool", title: "Eraser back to last tool", self)
        scenario.tools.setEraserBackToLastTool(true)
        scenario.tools.setEraserMode(.wholeStroke)
        var kept = scenario.bystanderCount
        for (n, tool) in [WorksheetTool.highlighter, .pen].enumerated() {
            let y = 220 + CGFloat(n) * 200
            scenario.tools.select(tool)
            let first = scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 80, y: y), width: 60, seed: n), speed: 450,
                                                       seed: UInt64(n)), "\(tool) before", timesInk: tool == .pen)
            StressPage.pump(0.02)
            scenario.tools.select(.eraser)
            scenario.erase(StressInk.line(from: CGPoint(x: 70, y: y + 2), to: CGPoint(x: 150, y: y + 2), steps: 30), removing: [first],
                           "eraser after \(tool)")
            let back = scenario.tools.current
            scenario.check("the eraser hands back the \(tool)", back == tool, "the tool after the lift is \(back)")
            StressPage.pump(0.005)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 300, y: y), width: 60, seed: n + 3), speed: 450,
                                           seed: UInt64(n + 3)), "\(tool) after", timesInk: tool == .pen)
            scenario.settle()
            kept += 1
            let newest = scenario.page.saved(0).last
            scenario.check("writing just after the lift is in the \(tool)",
                           newest?.ink.inkType == (tool == .pen ? .fountainPen : .marker),
                           "the newest stroke is \(String(describing: newest?.ink.inkType.rawValue))")
        }
        scenario.finish(expectedStrokes: [0: kept])
    }

    // MARK: - Selection

    /// The toolbar lasso round three strokes just written, then a move: the strokes go with the drag, nothing else
    /// moves, and one undo puts them back.
    func test13_LassoSelectAndMove() throws {
        let scenario = try StressScenario(tool: "lasso", title: "Lasso select and move", self)
        var word: [Int] = []
        for n in 0..<3 {
            word.append(scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 140 + CGFloat(n) * 40, y: 300), seed: n),
                                                       speed: 450, seed: UInt64(n)), "word stroke \(n + 1)"))
            StressPage.pump(0.01)
        }
        scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 140, y: 560), width: 80, seed: 9), speed: 450, seed: 9),
                     "elsewhere")
        StressPage.pump(0.03)
        scenario.tools.select(.lasso)
        scenario.lasso(StressInk.samples(StressInk.circle(center: CGPoint(x: 200, y: 304), radius: 95), speed: 900, seed: 3))
        StressPage.pump(0.2)
        let selection = scenario.controller.inkSelection.selection
        scenario.check("the lasso selects the three strokes", selection?.indices.count == 3,
                       "selected \(selection?.indices.count ?? 0) strokes")
        let moved = CGVector(dx: 60, dy: 120)
        if let selection {
            // The old place must clear, the new must show.
            for id in word { scenario.sampler.release(id) }
            let old = word.map { scenario.sampler.add("old place", page: 0, points: scenario.sampler.mark($0)?.points ?? [], lifted: true) }
            scenario.dragSelection(from: CGPoint(x: selection.box.rect.midX, y: selection.box.rect.midY), by: moved, removing: old)
            scenario.settle()
            let strokes = scenario.page.saved(0)
            let shifted = strokes.filter { abs($0.transform.tx - moved.dx) < 3 && abs($0.transform.ty - moved.dy) < 3 }.count
            scenario.check("the drag moves the three strokes and nothing else", shifted == 3,
                           "\(shifted) strokes moved by (\(Int(moved.dx)), \(Int(moved.dy)))")
            scenario.markStrokes(strokes.filter { $0.transform != .identity }, label: "moved stroke")
            StressPage.pump(0.5)
            for id in old { scenario.sampler.release(id) }
            let undo = scenario.undoManager
            scenario.check("the move is one undo step", undo?.undoActionName == "Move", "the top undo step is \(undo?.undoActionName ?? "none")")
            scenario.sampler.releaseAll()
            scenario.controller.undo()
            scenario.settle()
            let back = scenario.page.saved(0).filter { $0.transform != .identity }.count
            scenario.check("one undo puts them back", back == 0, "\(back) strokes still moved after one undo")
        }
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + 4])
    }

    /// EP126: the toolbar lasso on a page full of ink, as a worked page in class is (rows of long writing, highlights
    /// and boxes round answers). The outline is drawn, the ink inside is selected at the lift, the selection is dragged
    /// and then resized, and each part is timed on its own. While the outline is drawn, and through the steady part of
    /// the drag and of the resize, no display frame may wait longer than `StressBounds.lassoFrameGap`; selecting,
    /// picking the selection up and dropping it are single moments, held to `StressBounds.lassoMoment`. The drag still
    /// moves exactly the selected strokes, by the drag, as one undo step, and so does the resize; ink far from the lasso
    /// and the moved ink stay on the screen.
    func test13b_LassoOnAHeavyPage() throws {
        let heavy = StressInk.heavyPage()
        let scenario = try StressScenario(tool: "lasso.heavyPage", title: "Lasso on a page full of ink", self, ink: heavy)
        let total = scenario.bystanderCount + heavy.count
        scenario.note("\(heavy.count) strokes of writing, highlights and boxes on the page")
        scenario.tools.select(.lasso)
        StressPage.pump(0.3)
        let centre = scenario.visibleCentre(page: 0)
        let radius: CGFloat = 90
        // Ink well clear of the lasso and of where the selection goes, which must stay on the screen throughout.
        let far = scenario.page.saved(0).dropFirst(scenario.bystanderCount).filter { stroke in
            StressInk.points(of: stroke, count: 3).allSatisfy { StressInk.distance($0, centre) > 340 }
        }
        let step = max(1, far.count / 8)
        scenario.markStrokes(Array(stride(from: 0, to: far.count, by: step).prefix(8).map { far[$0] }), label: "ink far from the lasso")
        // The outline, then the lift that selects.
        var pencil = StressPencil(page: scenario.page, pageIndex: 0)
        let loop = StressInk.samples(StressInk.circle(center: centre, radius: radius), speed: 900, seed: 5)
        let outline = scenario.frameGaps {
            pencil.down(at: loop[0])
            for point in loop.dropFirst() { pencil.move(to: point) }
            StressPage.pump(0.05)
        }
        let select = scenario.frameGaps {
            pencil.lift()
            StressPage.pump(0.3)
        }
        let selected = scenario.controller.inkSelection.selection?.indices.sorted() ?? []
        scenario.check("the lasso selects the ink inside it", !selected.isEmpty && selected.count < total,
                       "selected \(selected.count) of \(total) strokes")
        var timed: [(key: String, name: String, gaps: StressPhase, bound: Double)] = [
            ("outline", "the outline is drawn", outline, StressBounds.lassoFrameGap),
            ("select", "the lift selects", select, StressBounds.lassoMoment),
        ]
        if let box = scenario.controller.inkSelection.selection?.box {
            // The drag.
            let moved = CGVector(dx: 50, dy: 70)
            let saved = scenario.page.saved(0)
            let picked = Set(selected)
            // A quick drag, as a selection is carried across a page: out past where it goes, 8.6 points a move, and back.
            let out = (1...20).map { CGVector(dx: 5 * CGFloat($0), dy: 7 * CGFloat($0)) }
            let back = (1...10).map { CGVector(dx: 100 - 5 * CGFloat($0), dy: 140 - 7 * CGFloat($0)) }
            let drag = scenario.timedSelectionDrag(from: CGPoint(x: box.rect.midX, y: box.rect.midY).applying(box.transform),
                                                   through: out + back,
                                                   probes: (selected.map { saved[$0] }, saved.indices.filter { !picked.contains($0) }.map { saved[$0] }))
            scenario.checkDrag(drag, "drag")
            timed += [("dragPickUp", "the drag picks the selection up", drag.pickUp, StressBounds.lassoMoment),
                      ("drag", "the selection is dragged", drag.steady, StressBounds.lassoFrameGap),
                      ("dragDrop", "the drag drops it", drag.drop, StressBounds.lassoMoment)]
            scenario.settle()
            let afterMove = scenario.page.saved(0)
            let shifted = afterMove.indices.filter { n in
                let t = afterMove[n].transform
                return abs(t.tx - moved.dx) < 1 && abs(t.ty - moved.dy) < 1 && abs(t.a - 1) < 0.001 && abs(t.d - 1) < 0.001
            }
            scenario.check("the drag moves exactly the selected strokes", shifted == selected,
                           "\(shifted.count) strokes moved by (\(Int(moved.dx)), \(Int(moved.dy))), \(selected.count) selected")
            scenario.check("the move is one undo step", scenario.undoManager?.undoActionName == "Move",
                           "the top undo step is \(scenario.undoManager?.undoActionName ?? "none")")
            // The moved ink stays on the screen once dropped.
            let movedStep = max(1, selected.count / 10)
            let movedMarks = stride(from: 0, to: selected.count, by: movedStep).prefix(10).map { n in
                scenario.sampler.add("moved stroke #\(n + 1)", page: 0, points: StressInk.points(of: afterMove[selected[n]], count: 6),
                                     lifted: true)
            }
            StressPage.pump(0.5)
            movedMarks.forEach(scenario.sampler.release)
            // The resize, from the handle.
            scenario.controller.inkSelection.beginResize()
            StressPage.pump(0.1)
            let overlay = scenario.controller.inkSelection.overlay
            if let handle = overlay.handleCenter, let canvas = scenario.page.canvas(0) {
                let resize = scenario.timedSelectionDrag(from: canvas.pageSpace.convert(handle, from: overlay), by: CGVector(dx: 40, dy: 30))
                scenario.checkDrag(resize, "resize")
                timed += [("resizePickUp", "the resize picks the selection up", resize.pickUp, StressBounds.lassoMoment),
                          ("resize", "the selection is resized", resize.steady, StressBounds.lassoFrameGap),
                          ("resizeDrop", "the resize drops it", resize.drop, StressBounds.lassoMoment)]
                scenario.settle()
                let afterResize = scenario.page.saved(0)
                let scaled = afterResize.indices.filter { abs(afterResize[$0].transform.a - 1) > 0.01 }
                scenario.check("the resize changes exactly the selected strokes", scaled == selected,
                               "\(scaled.count) strokes scaled, \(selected.count) selected")
                scenario.check("the resize is one undo step", scenario.undoManager?.undoActionName == "Resize",
                               "the top undo step is \(scenario.undoManager?.undoActionName ?? "none")")
                let resizedMarks = stride(from: 0, to: selected.count, by: movedStep).prefix(10).map { n in
                    scenario.sampler.add("resized stroke #\(n + 1)", page: 0,
                                         points: StressInk.points(of: afterResize[selected[n]], count: 6), lifted: true)
                }
                StressPage.pump(0.5)
                resizedMarks.forEach(scenario.sampler.release)
            } else {
                scenario.check("the resize handle shows", false, "no handle after Resize")
            }
            // Two undos put everything back where it was.
            scenario.sampler.releaseAll()
            scenario.controller.undo()
            StressPage.pump(0.05)
            scenario.controller.undo()
            scenario.settle()
            let still = scenario.page.saved(0).filter { $0.transform != .identity }.count
            scenario.check("two undos put the selection back", still == 0, "\(still) strokes still moved after two undos")
        }
        for part in timed {
            let worst = part.gaps.worst
            scenario.metrics["lasso.\(part.key).longestFrameGapMs"] = worst * 1000
            scenario.metrics["lasso.\(part.key).frames"] = Double(part.gaps.gaps.count)
            scenario.check("no stall while \(part.name)", !part.gaps.gaps.isEmpty && worst <= part.bound,
                           String(format: "longest frame gap %.0f ms at %.2f s over %d frames (bound %.0f ms)", worst * 1000,
                                  part.gaps.worstEnd - scenario.sampler.scenarioStart, part.gaps.gaps.count, part.bound * 1000))
        }
        scenario.finish(expectedStrokes: [0: total])
    }

    /// EP128: the toolbar lasso closed round more and more of a page full of ink, as a teacher rings a whole worked
    /// answer: a small loop, a medium one and a big one drawn slowly (about 2000 Pencil samples). Closing each loop is
    /// a single moment held to `StressBounds.lassoMoment`: before EP128 the big loop froze the page for about a second
    /// while every sample of every stroke inside was tested against every edge of the loop. Each loop still selects
    /// exactly the strokes the old every-edge test selects.
    func test13c_BigLassoOnAHeavyPage() throws {
        let heavy = StressInk.heavyPage()
        let scenario = try StressScenario(tool: "lasso.bigLoop", title: "Big lassos on a page full of ink", self, ink: heavy)
        let total = scenario.bystanderCount + heavy.count
        scenario.note("\(heavy.count) strokes of writing, highlights and boxes on the page")
        scenario.tools.select(.lasso)
        StressPage.pump(0.3)
        let centre = scenario.visibleCentre(page: 0)
        let loops: [(key: String, radius: CGFloat, speed: CGFloat, seed: UInt64, fewest: Int)] = [
            ("small", 90, 720, 5, 10), ("medium", 160, 720, 6, 80), ("big", 230, 360, 7, 250),
        ]
        for loop in loops {
            var pencil = StressPencil(page: scenario.page, pageIndex: 0)
            let points = StressInk.samples(StressInk.circle(center: centre, radius: loop.radius), speed: loop.speed, seed: loop.seed)
            pencil.down(at: points[0])
            for point in points.dropFirst() { pencil.move(to: point) }
            StressPage.pump(0.05)
            // The lift's gesture ends on the next turn of the run loop, so the select runs inside the wait after it,
            // which goes on until frames are drawn again after the selection shows.
            var shown = 0.0
            let select = scenario.frameGaps {
                let lift = CACurrentMediaTime()
                pencil.lift()
                while scenario.controller.inkSelection.selection == nil, CACurrentMediaTime() - lift < 5 { StressPage.pump(0.002) }
                shown = CACurrentMediaTime() - lift
                StressPage.pump(0.3)
            }
            let selection = scenario.controller.inkSelection.selection
            let selected = selection?.indices.sorted() ?? []
            let lasso = selection?.outline ?? []
            let drawing = scenario.page.canvas(0)?.drawing ?? PKDrawing()
            // The hit-test alone, as the app runs it and as testing every edge does, outside the frame timing.
            // The harness's own work, so it is not taken for the app stalling.
            let (compute, everyEdge, before) = StressHarnessTime.measure {
                let computeStart = CACurrentMediaTime()
                _ = LassoGeometry.selectedIndices(in: drawing, lasso: lasso)
                let compute = CACurrentMediaTime() - computeStart
                let everyEdgeStart = CACurrentMediaTime()
                let before = LassoSelectionBefore.selectedIndices(in: drawing, lasso: lasso)
                return (compute, CACurrentMediaTime() - everyEdgeStart, before)
            }
            scenario.metrics["lasso.\(loop.key).hitTestMs"] = compute * 1000
            scenario.metrics["lasso.\(loop.key).everyEdgeHitTestMs"] = everyEdge * 1000
            scenario.note(String(format: "%@ loop: %d points, %d strokes selected, lift to selection %.1f ms, hit-test %.1f ms (every edge %.1f ms)",
                                 loop.key, lasso.count, selected.count, shown * 1000, compute * 1000, everyEdge * 1000))
            scenario.check("the \(loop.key) loop selects the ink inside it", selected.count >= loop.fewest && selected.count < total,
                           "selected \(selected.count) of \(total) strokes with a loop of \(lasso.count) points (at least \(loop.fewest))")
            scenario.check("the \(loop.key) loop selects the same strokes as testing every edge", selected == before,
                           "selected \(selected.count) strokes, every edge selects \(before.count)")
            scenario.metrics["lasso.\(loop.key).loopPoints"] = Double(lasso.count)
            scenario.metrics["lasso.\(loop.key).selected"] = Double(selected.count)
            scenario.metrics["lasso.\(loop.key).liftToSelectionMs"] = shown * 1000
            scenario.metrics["lasso.\(loop.key).longestFrameGapMs"] = select.worst * 1000
            scenario.check("no stall while the \(loop.key) loop selects",
                           !select.gaps.isEmpty && select.worst <= StressBounds.lassoMoment && shown <= StressBounds.lassoMoment,
                           String(format: "longest frame gap %.0f ms at %.2f s over %d frames, the selection showed %.0f ms after the lift (bound %.0f ms)",
                                  select.worst * 1000, select.worstEnd - scenario.sampler.scenarioStart, select.gaps.count,
                                  shown * 1000, StressBounds.lassoMoment * 1000))
            scenario.controller.inkSelection.dismiss()
            StressPage.pump(0.2)
        }
        scenario.finish(expectedStrokes: [0: total])
    }

    /// Circle to lasso: a loop drawn round ink just written, then a long press on its line, selects the ink and leaves
    /// the loop off the page.
    func test14_CircleToLasso() throws {
        let scenario = try StressScenario(tool: "circleToLasso", title: "Circle to lasso", self)
        scenario.tools.setCircleToLasso(true)
        for n in 0..<3 {
            scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 270 + CGFloat(n) * 22, y: 296), width: 18, seed: n), speed: 400,
                                           seed: UInt64(n)), "word stroke \(n + 1)")
            StressPage.pump(0.01)
        }
        StressPage.pump(0.05)
        let loop = scenario.pen(StressInk.samples(StressInk.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 350), speed: 700,
                                                  seed: 7), "loop")
        scenario.sampler.release(loop)
        StressPage.pump(0.3)
        // The press, on the loop's line at its right-hand side.
        scenario.press(at: CGPoint(x: 370, y: 300), for: HoldTracker.duration + 0.3)
        StressPage.pump(0.3)
        let selection = scenario.controller.inkSelection.selection
        scenario.check("the press selects the ink inside the loop", selection?.indices.count == 3,
                       "selected \(selection?.indices.count ?? 0) strokes")
        scenario.settle()
        scenario.check("the loop is not kept as ink", scenario.page.saved(0).count == scenario.bystanderCount + 3,
                       "\(scenario.page.saved(0).count) strokes, \(scenario.bystanderCount + 3) expected")
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + 3])
    }

    // MARK: - Scribble to erase

    /// Scribble to erase straight after writing: the word and the scribble go within `StressBounds.removal` of the
    /// lift, the toolbar-lasso outline never flickers while the scribble is written, one undo brings the word back,
    /// and a stroke begun 10 ms after the scribble's lift is kept.
    func test15_ScribbleToErase() throws {
        let scenario = try StressScenario(tool: "scribbleToErase", title: "Scribble to erase", self)
        scenario.tools.setScribbleToErase(true)
        scenario.sampler.watchScribbleOutline = true
        var kept = scenario.bystanderCount
        var flickers = 0
        for n in 0..<3 {
            let top = 220 + CGFloat(n) * 140
            let letters = ScribbleEraseTests.word(at: CGPoint(x: 100, y: top))
            var word: [Int] = []
            for (k, letter) in letters.enumerated() {
                word.append(scenario.pen(StressInk.samples(letter, speed: 300, seed: UInt64(n * 10 + k)), "word \(n + 1) letter \(k + 1)"))
                StressPage.pump(0.03)
            }
            StressPage.pump(0.04)
            scenario.sampler.resetScribbleOutline()
            let corners = ScribbleEraseTests.zigzagCorners(top: top - 10, bottom: top + 26, wobble: true)
            scenario.scribble(StressInk.samples(corners, speed: 900, seed: UInt64(50 + n)), removing: word, "scribble \(n + 1)")
            flickers += scenario.sampler.scribbleOutlineFlickers
            StressPage.pump(0.01)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 330, y: top + 4), width: 40, seed: n), speed: 450,
                                           seed: UInt64(80 + n)), "stroke after scribble \(n + 1)")
            scenario.settle()
            kept += 1
            let undo = scenario.undoManager
            let count = scenario.page.saved(0).count
            scenario.check("scribble \(n + 1) erases the word and itself", count == kept,
                           "\(count) strokes after, \(kept) expected")
            // The step under the stroke written after it.
            if undo?.undoActionName == PendingInkEdit.inkActionName || undo?.undoActionName == "Ink" {
                // The undo brings the word back on purpose.
                scenario.sampler.releaseAll()
                undo?.undo(); undo?.undo()
                let restored = scenario.page.saved(0).count
                scenario.check("scribble \(n + 1) is one undo step", restored == kept - 1 + letters.count,
                               "\(restored) strokes after undoing the stroke after it and the scribble, \(kept - 1 + letters.count) expected")
                undo?.redo(); undo?.redo()
                scenario.check("redo erases it again", scenario.page.saved(0).count == kept,
                               "\(scenario.page.saved(0).count) strokes after redo, \(kept) expected")
            } else {
                scenario.check("scribble \(n + 1) is one undo step", false, "the top undo step is \(undo?.undoActionName ?? "none")")
            }
        }
        scenario.check("the scribble outline never flickers", flickers == 0, "\(flickers) times it went and came back mid-scribble")
        scenario.finish(expectedStrokes: [0: kept])
    }

    // MARK: - Laser

    /// The laser in dot and trail mode: it draws no ink, shows while the Pencil is down, and the pen writes straight
    /// after it.
    func test16_LaserPointer() throws {
        let scenario = try StressScenario(tool: "laser", title: "Laser pointer, dot and trail", self)
        var kept = scenario.bystanderCount
        // The pen's rows; each laser runs 60 pt above its pen.
        let rows = scenario.fit([320, 470])
        for (n, mode) in [LaserMode.dot, .trail].enumerated() {
            scenario.tools.select(.laser)
            scenario.tools.setLaserMode(mode)
            var shownWhileDown = 0, samples = 0
            scenario.drive(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 100, y: rows[n] - 60), width: 300, seed: n),
                                             speed: 600, seed: UInt64(n))) { k in
                guard k > 10, k % 6 == 0 else { return }
                samples += 1
                if mode == .dot ? scenario.controller.laserDotVisible : scenario.controller.laserTrailVisible { shownWhileDown += 1 }
            }
            scenario.check("\(mode) shows while the Pencil is down", samples > 0 && shownWhileDown == samples,
                           "shown on \(shownWhileDown) of \(samples) checks")
            StressPage.pump(0.005)
            scenario.tools.select(.pen)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 100, y: rows[n]), seed: n), speed: 450,
                                           seed: UInt64(n + 10)), "pen after the \(mode) laser")
            kept += 1
            scenario.settle()
            scenario.check("the \(mode) laser draws no ink", scenario.page.saved(0).count == kept,
                           "\(scenario.page.saved(0).count) strokes, \(kept) expected")
        }
        StressPage.pump(2)
        scenario.check("the laser fades after the lift", !scenario.controller.laserDotVisible && !scenario.controller.laserTrailVisible,
                       "dot shown \(scenario.controller.laserDotVisible), trail shown \(scenario.controller.laserTrailVisible) 2 s on")
        scenario.finish(expectedStrokes: [0: kept])
    }

    // MARK: - Undo and redo

    /// Undo and redo in bursts straight after writing (as the two- and three-finger double taps call them): each undo
    /// takes exactly one stroke off the screen, each redo puts it back, and writing after an undo ends redo.
    func test17_UndoRedoBursts() throws {
        let scenario = try StressScenario(tool: "undoRedo", title: "Undo and redo bursts", self)
        var ids: [Int] = []
        // Two rows of six, and the stroke written after the undos below them.
        let rows = scenario.fit([220, 310, 480])
        for n in 0..<12 {
            ids.append(scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 50 + CGFloat(n % 6) * 90, y: rows[n / 6]),
                                                                         width: 50, seed: n), speed: 450, seed: UInt64(n)),
                                    "stroke \(n + 1)"))
            StressPage.pump(0.012)
        }
        let base = scenario.bystanderCount
        var wrong: [String] = []
        // Undo at once, before the strokes have landed, six taps 40 ms apart.
        for k in 0..<6 {
            let before = scenario.page.shown(0).count
            let target = ids[11 - k]
            scenario.undoTap(removing: target)
            let after = scenario.page.shown(0).count
            if k > 0 || before == base + 12, after != before - 1 { wrong.append("undo \(k + 1): \(before) to \(after)") }
            StressPage.pump(0.04)
        }
        scenario.settle()
        scenario.check("each undo takes one stroke", wrong.isEmpty && scenario.page.saved(0).count == base + 6,
                       wrong.isEmpty ? "6 taps took 6 strokes" : wrong.joined(separator: "; "))
        wrong = []
        for k in 0..<6 {
            let before = scenario.page.shown(0).count
            scenario.redoTap(restoring: ids[6 + k])
            let after = scenario.page.shown(0).count
            if after != before + 1 { wrong.append("redo \(k + 1): \(before) to \(after)") }
            StressPage.pump(0.04)
        }
        scenario.settle()
        scenario.check("each redo puts one back", wrong.isEmpty && scenario.page.saved(0).count == base + 12,
                       wrong.isEmpty ? "6 taps put back 6 strokes" : wrong.joined(separator: "; "))
        // The strokes put back are on the screen again.
        scenario.markStrokes(Array(scenario.page.saved(0).suffix(6)), label: "redone stroke")
        StressPage.pump(0.4)
        // These undos take redone strokes off on purpose.
        scenario.sampler.releaseAll()
        for k in 0..<3 {
            scenario.undoTap(removing: nil)
            _ = k
            StressPage.pump(0.03)
        }
        scenario.sampler.releaseAll()
        scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 60, y: rows[2]), width: 50, seed: 30), speed: 450, seed: 30),
                     "stroke after undo")
        scenario.settle()
        scenario.check("writing after an undo ends redo", !(scenario.undoManager?.canRedo ?? true),
                       "redo is \(scenario.undoManager?.canRedo == true ? "still" : "no longer") offered")
        scenario.finish(expectedStrokes: [0: base + 12 - 3 + 1])
    }

    // MARK: - Tool switches and the palette

    /// Rapid tool switches, each 60 to 200 ms after the stroke before it (as fast as a hand taps the palette and comes
    /// back to the page): pen, highlighter, eraser and the pen's colours.
    func test18_RapidToolSwitches() throws {
        let scenario = try StressScenario(tool: "toolSwitches", title: "Rapid tool switches", self)
        scenario.tools.setEraserMode(.wholeStroke)
        var kept = scenario.bystanderCount
        var inks: [PKInk.InkType] = []
        var eraserInk: [String] = []
        let gaps: [TimeInterval] = [0.06, 0.1, 0.15, 0.2]
        let rows = scenario.fit((0..<8).map { 170 + CGFloat($0) * 66 })
        for n in 0..<8 {
            let y = rows[n]
            scenario.tools.select(.pen)
            scenario.tools.selectPenColor(n % 3)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 50, y: y), width: 60, seed: n), speed: 450, seed: UInt64(n)),
                         "pen \(n + 1)")
            inks.append(.fountainPen)
            StressPage.pump(gaps[n % 4])
            scenario.tools.select(.highlighter)
            let highlight = scenario.pen(StressInk.samples(StressInk.line(from: CGPoint(x: 160, y: y + 10), to: CGPoint(x: 300, y: y + 10)),
                                                           speed: 650, seed: UInt64(n + 20)), "highlight \(n + 1)", timesInk: false)
            inks.append(.marker)
            StressPage.pump(gaps[(n + 1) % 4])
            scenario.tools.select(.pen)
            scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 360, y: y), width: 60, seed: n + 40), speed: 450,
                                           seed: UInt64(n + 40)), "pen \(n + 1) again")
            inks.append(.fountainPen)
            StressPage.pump(gaps[(n + 2) % 4])
            kept += 3
            if n % 2 == 1 {
                scenario.tools.select(.eraser)
                scenario.erase(StressInk.line(from: CGPoint(x: 180, y: y + 10), to: CGPoint(x: 280, y: y + 10), steps: 24),
                               removing: [highlight], "eraser on highlight \(n + 1)")
                kept -= 1
                scenario.settle()
                let shown = scenario.page.shown(0).count
                if shown != kept { eraserInk.append("eraser \(n / 2 + 1): \(shown) strokes after it, \(kept) expected") }
                inks.remove(at: inks.count - 2)
                StressPage.pump(gaps[(n + 3) % 4])
            }
        }
        scenario.settle()
        scenario.check("the eraser chosen just after writing erases, and draws nothing", eraserInk.isEmpty,
                       eraserInk.isEmpty ? "each of 4 sweeps took its highlight" : eraserInk.joined(separator: "; "))
        let saved = Array(scenario.page.saved(0).dropFirst(scenario.bystanderCount))
        let byTime = saved.sorted { $0.path.creationDate < $1.path.creationDate }
        let wrongTool = zip(byTime, inks).enumerated().filter { $0.element.0.ink.inkType != $0.element.1 }
            .map { "stroke \($0.offset + 1) in \($0.element.0.ink.inkType.rawValue), not \($0.element.1.rawValue)" }
        scenario.check("each stroke is in the tool chosen just before it", byTime.count == inks.count && wrongTool.isEmpty,
                       wrongTool.isEmpty ? "\(byTime.count) strokes for \(inks.count), each in its tool" : wrongTool.prefix(6).joined(separator: "; "))
        scenario.checkWritingOrder(saved)
        scenario.finish(expectedStrokes: [0: kept])
    }

    /// The palette carried to each dock and along it between strokes written 5 ms apart: no stroke is lost or leaves
    /// the screen while the palette moves.
    func test19_ToolbarDrag() throws {
        let scenario = try StressScenario(tool: "toolbarDrag", title: "Palette moved between strokes", self)
        var written = 0
        let places: [(ToolbarDock, Double)] = [(.leading, 0.3), (.bottom, 0.7), (.trailing, 0.5), (.top, 0.2), (.top, 0.8), (.bottom, 0.1)]
        let rows = scenario.fit(places.indices.map { 170 + CGFloat($0) * 80 })
        for (n, place) in places.enumerated() {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                scenario.tools.settingsTool = nil
                scenario.tools.setToolbarPosition(place.0, along: place.1)
            }
            for k in 0..<3 {
                let origin = CGPoint(x: 80 + CGFloat(k) * 150, y: rows[n])
                scenario.pen(StressInk.samples(StressInk.squiggle(at: origin, width: 60, seed: n * 3 + k), speed: 450,
                                               seed: UInt64(n * 3 + k)), "after palette move \(n + 1) #\(k + 1)")
                written += 1
                StressPage.pump(0.005)
            }
        }
        scenario.settle()
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + written])
    }

    // MARK: - After moving the page

    /// Writing at once after a zoom to 2 and 3 times, and back, before the ink is redrawn for the new scale.
    func test20_AfterZoom() throws {
        let scenario = try StressScenario(tool: "afterZoom", title: "Writing right after a zoom", self)
        let pdfView = scenario.controller.pdfView
        let fit = pdfView.scaleFactor
        var written = 0
        for (n, zoom) in [2.0, 3.0, 1.0, 2.0].enumerated() {
            pdfView.scaleFactor = fit * zoom
            StressPage.pump(0.016)
            let centre = scenario.visibleCentre(page: 0)
            for k in 0..<5 {
                // Small handwriting at the zoom (the squiggle scaled with it, apart from the others and from each round's),
                // so no stroke crosses another and reads as a scribble to erase.
                let origin = CGPoint(x: centre.x - 90 / zoom + CGFloat(k % 3) * 50 / zoom,
                                     y: centre.y - 60 / zoom + CGFloat(k / 3) * 40 / zoom + CGFloat(n) * 14)
                let squiggle = StressInk.squiggle(at: origin, width: 30 / zoom, seed: n * 5 + k)
                    .map { CGPoint(x: $0.x, y: origin.y + ($0.y - origin.y) / zoom) }
                scenario.pen(StressInk.samples(squiggle, speed: 300 / zoom,
                                               seed: UInt64(n * 5 + k)), "zoom \(zoom)x #\(k + 1)")
                written += 1
                StressPage.pump(0.01)
            }
            scenario.settle()
        }
        pdfView.scaleFactor = fit
        scenario.settle()
        scenario.finish(expectedStrokes: [0: scenario.bystanderCount + written])
    }

    /// Writing at once after a scroll, and while a scroll is still animating.
    func test21_AfterScroll() throws {
        let scenario = try StressScenario(tool: "afterScroll", title: "Writing right after a scroll", self)
        var written: [Int: Int] = [:]
        guard let scroll = scenario.scrollView else {
            scenario.check("finds the pages' scroll view", false, "no scroll view in the PDF view")
            return scenario.finish(expectedStrokes: nil)
        }
        for (n, step) in [(CGFloat(300), false), (CGFloat(260), true), (CGFloat(-420), false), (CGFloat(200), true)].enumerated() {
            let target = CGPoint(x: scroll.contentOffset.x, y: max(0, scroll.contentOffset.y + step.0))
            scroll.setContentOffset(target, animated: step.1)
            StressPage.pump(step.1 ? 0.05 : 0.016)
            let (page, centre) = scenario.visibleCentre()
            for k in 0..<5 {
                // Each scroll writes in its own column of the page, so no stroke crosses one written after another
                // scroll to the same place (that would be a scribble to erase).
                let origin = CGPoint(x: 40 + CGFloat(n) * 140 + CGFloat(k) * 24, y: centre.y + CGFloat(k % 2) * 30)
                scenario.pen(StressInk.samples(StressInk.squiggle(at: origin, width: 20, seed: n * 5 + k), speed: 420, seed: UInt64(n * 5 + k)),
                             "scroll \(n + 1) #\(k + 1)", page: page)
                written[page, default: 0] += 1
                StressPage.pump(0.01)
            }
            scenario.settle()
        }
        var expected = written
        expected[0, default: 0] += scenario.bystanderCount
        scenario.finish(expectedStrokes: expected)
    }

    /// Writing at once on a page just turned to, on pages 2 and 3 and back on page 1.
    func test22_AfterPageChange() throws {
        let scenario = try StressScenario(tool: "afterPageChange", title: "Writing right after a page change", self)
        var written: [Int: Int] = [:]
        var waits: [Double] = []
        for (n, index) in [1, 2, 0, 1].enumerated() {
            scenario.controller.goToPage(index)
            let start = CACurrentMediaTime()
            while scenario.page.canvas(index)?.window == nil, CACurrentMediaTime() - start < 2 { StressPage.pump(0.004) }
            waits.append((CACurrentMediaTime() - start) * 1000)
            let centre = scenario.visibleCentre(page: index)
            for k in 0..<5 {
                // Each visit writes on its own line, so no stroke crosses one from an earlier visit (a scribble to erase).
                let origin = CGPoint(x: centre.x - 100 + CGFloat(k) * 45, y: centre.y - 120 + CGFloat(k % 2) * 30 + CGFloat(n) * 70)
                scenario.pen(StressInk.samples(StressInk.squiggle(at: origin, seed: n * 5 + k), speed: 420, seed: UInt64(n * 5 + k)),
                             "page \(index + 1) visit \(n + 1) #\(k + 1)", page: index)
                written[index, default: 0] += 1
                StressPage.pump(0.01)
            }
            scenario.settle()
        }
        scenario.metrics["pageReadyMaxMs"] = waits.max() ?? 0
        var expected = written
        expected[0, default: 0] += scenario.bystanderCount
        scenario.finish(expectedStrokes: expected)
    }

    /// Erasing and writing straight on, as in a lesson: a row of pen ink, three of its strokes erased with the
    /// whole-stroke eraser while the row may still be landing, and the pen back at once for fresh strokes just below
    /// them on the same tiles; then more fresh strokes after a scroll away and back, and after a page change and back.
    /// What was erased never shows again (EP113: old ink the eraser took came back while writing went on).
    func test23_EraseThenKeepWriting() throws {
        let scenario = try StressScenario(tool: "eraser.thenKeepWriting", title: "Erase, then keep writing", self)
        var kept = scenario.bystanderCount
        guard let scroll = scenario.scrollView else {
            scenario.check("finds the pages' scroll view", false, "no scroll view in the PDF view")
            return scenario.finish(expectedStrokes: nil)
        }
        var seed = 0
        // Fresh strokes 45 pt below the row: clear of the erased ink and the eraser's path, and never crossing other
        // ink (a scribble to erase).
        func fresh(_ xs: [CGFloat], y: CGFloat, _ label: String) {
            scenario.tools.select(.pen)
            for (k, x) in xs.enumerated() {
                seed += 1
                scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: x, y: y + 45), seed: seed), speed: 420,
                                               seed: UInt64(500 + seed)), "\(label) #\(k + 1)")
                kept += 1
                StressPage.pump([0.012, 0.03, 0.06][k % 3])
            }
        }
        for (cycle, y) in scenario.fit([190, 360, 530]).enumerated() {
            scenario.tools.select(.pen)
            var row: [Int] = []
            for n in 0..<6 {
                seed += 1
                row.append(scenario.pen(StressInk.samples(StressInk.squiggle(at: CGPoint(x: 60 + CGFloat(n) * 90, y: y), seed: seed),
                                                          speed: 450, seed: UInt64(seed)), "row \(cycle + 1) stroke \(n + 1)"))
                kept += 1
                StressPage.pump([0.03, 0.012, 0.06][n % 3])
            }
            // Through the first three strokes, with the default eraser, while the row is still landing.
            scenario.tools.select(.eraser)
            scenario.tools.setEraserMode(.wholeStroke)
            scenario.tools.selectEraserSize(Theme.eraserDefaultSizeIndex)
            scenario.erase(StressInk.line(from: CGPoint(x: 40, y: y + 4), to: CGPoint(x: 236, y: y + 4), steps: 60),
                           removing: Array(row.prefix(3)), "row \(cycle + 1) erase")
            kept -= 3
            // Straight back to the pen, under the ink just erased.
            fresh([60, 120, 180, 240], y: y, "row \(cycle + 1) fresh")
            scenario.note("row \(cycle + 1) scroll away and back")
            let home = scroll.contentOffset
            scroll.setContentOffset(CGPoint(x: home.x, y: home.y + 400), animated: cycle % 2 == 1)
            StressPage.pump(cycle % 2 == 1 ? 0.4 : 0.05)
            scroll.setContentOffset(home, animated: cycle % 2 == 1)
            StressPage.pump(cycle % 2 == 1 ? 0.4 : 0.05)
            fresh([330, 390], y: y, "row \(cycle + 1) after scroll")
            scenario.note("row \(cycle + 1) page change and back")
            scenario.controller.goToPage(1)
            StressPage.pump(0.15)
            scenario.controller.goToPage(0)
            let start = CACurrentMediaTime()
            while scenario.page.canvas(0)?.window == nil, CACurrentMediaTime() - start < 2 { StressPage.pump(0.004) }
            fresh([450, 510], y: y, "row \(cycle + 1) after page change")
            scenario.settle()
        }
        scenario.finish(expectedStrokes: [0: kept])
    }

    // MARK: - Summary

    func test99_Summary() throws {
        try StressRun.write()
        let json = XCTAttachment(data: try StressRun.summaryJSON(), uniformTypeIdentifier: "public.json")
        json.name = "stress-summary.json"
        json.lifetime = .keepAlways
        add(json)
        let markdown = XCTAttachment(string: StressRun.markdown())
        markdown.name = "stress-summary.md"
        markdown.lifetime = .keepAlways
        add(markdown)
        print("EP110 STRESS SUMMARY: \(StressRun.directory.path)\n\(StressRun.markdown())")
    }
}

// MARK: - A scenario

/// One scenario: a page, the Pencil, the frame sampler, and the checks every scenario makes at its end.
@MainActor
final class StressScenario {
    let tool: String
    let title: String
    let page: StressPage
    private weak var testCase: XCTestCase?
    var sampler: StressFrameSampler { page.sampler }
    var tools: ToolState { page.tools }
    var controller: PDFOverlayPageController { page.controller }
    let bystanderCount: Int
    private var checks: [StressCheck] = []
    var metrics: [String: Double] = [:]
    private var notes: [String] = []
    private var removals: [(id: Int, lift: CFTimeInterval, label: String, screen: [Double]?)] = []
    private var removalRecords: [StressRemoval] = []

    private func removal(_ id: Int, lift: CFTimeInterval, _ label: String) -> (id: Int, lift: CFTimeInterval, label: String, screen: [Double]?) {
        let mark = sampler.mark(id)
        return (id, lift, label, mark.flatMap { sampler.screenBox($0.points, page: $0.page) })
    }
    private let began = Date()

    /// `ink` is more ink on page 0 when the scenario begins, after the handwriting every scenario has there.
    init(tool: String, title: String, _ testCase: XCTestCase, ink: [PKStroke] = []) throws {
        self.tool = tool
        self.title = title
        self.testCase = testCase
        let bystanders = StressInk.bystanders()
        bystanderCount = bystanders.count
        page = try StressPage(pages: 3, ink: [0: bystanders + ink])
        sampler.scenario = tool
        sampler.scenarioStart = CACurrentMediaTime()
        notes.append(String(format: "began at %.3f (Unix time)", Date().timeIntervalSince1970))
        notes.append(String(format: "PencilKit replica record %.1f MB at the start", Double(StressRun.pencilKitReplicaBytes) / 1_000_000))
        if StressGate.landscape {
            let frame = page.window.frame
            notes.append("laid out in a landscape-shaped window, \(Int(frame.width)) by \(Int(frame.height)) points")
        }
        if StressPage.earlierStillAlive > 0 {
            notes.append("\(StressPage.earlierStillAlive) pages from earlier scenarios were still alive when this one began")
        }
        markBystanders()
        sampler.resetTiming()
    }

    var undoManager: UndoManager? { page.canvas(0)?.undoManager }
    var scrollView: UIScrollView? {
        func first(in view: UIView) -> UIScrollView? {
            for subview in view.subviews {
                if let scroll = subview as? UIScrollView { return scroll }
                if let nested = first(in: subview) { return nested }
            }
            return nil
        }
        return first(in: controller.pdfView)
    }

    /// The handwriting already on the page: it must never leave the screen.
    @discardableResult
    func markBystanders() -> [Int] {
        page.saved(0).prefix(bystanderCount).enumerated().map { n, stroke in
            sampler.add("handwriting already on the page #\(n + 1)", page: 0, points: StressInk.points(of: stroke, count: 6), lifted: true)
        }
    }

    func markStrokes(_ strokes: [PKStroke], label: String, page index: Int = 0) {
        for (n, stroke) in strokes.enumerated() {
            sampler.add("\(label) #\(n + 1)", page: index, points: StressInk.points(of: stroke, count: 6), lifted: true)
        }
    }

    /// Marks read again from scratch (the self-check's second try).
    func restartMarks(_ ids: [Int]) {
        for id in ids {
            guard let mark = sampler.mark(id) else { continue }
            mark.firstSeen = Array(repeating: nil, count: mark.points.count)
            mark.landedAt = nil
        }
    }

    /// The part of page `index` the screen shows, in page points, as the frame sampler reads it.
    func shownPart(page index: Int = 0) -> CGRect {
        guard let canvas = page.canvas(index), let window = canvas.window else { return .null }
        let pdfView = controller.pdfView
        let shown = pdfView.convert(pdfView.bounds, to: window).intersection(window.bounds)
        return shown.isNull ? .null : canvas.pageSpace.convert(shown, from: window).intersection(canvas.pageSpace.bounds)
    }

    /// The heights `ys` of a scenario's rows of writing, kept on the part of page 0 the screen shows (`StressGate.fit`).
    func fit(_ ys: [CGFloat]) -> [CGFloat] {
        let shown = shownPart()
        return shown.isNull ? ys : StressGate.fit(ys, above: shown.maxY - StressGate.rowMargin)
    }

    /// The centre of what the screen shows of `index`, in page points.
    func visibleCentre(page index: Int) -> CGPoint {
        guard let canvas = page.canvas(index) else { return CGPoint(x: 306, y: 396) }
        let pdfView = controller.pdfView
        let centre = canvas.pageSpace.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), from: pdfView)
        let bounds = canvas.pageSpace.bounds.insetBy(dx: 120, dy: 80)
        return CGPoint(x: min(max(centre.x, bounds.minX), bounds.maxX), y: min(max(centre.y, bounds.minY), bounds.maxY))
    }

    /// The page under the screen's centre, and that centre on it.
    func visibleCentre() -> (Int, CGPoint) {
        let pdfView = controller.pdfView
        let mid = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        for index in controller.canvases.keys.sorted() {
            guard let canvas = page.canvas(index), canvas.window != nil else { continue }
            let point = canvas.pageSpace.convert(mid, from: pdfView)
            if canvas.pageSpace.bounds.contains(point) { return (index, visibleCentre(page: index)) }
        }
        return (0, visibleCentre(page: 0))
    }

    // MARK: Writing

    /// Writes `samples` with the tool chosen, tracking it on screen. Returns its mark.
    @discardableResult
    func pen(_ samples: [CGPoint], _ label: String, page index: Int = 0, hold: TimeInterval = 0, timesInk: Bool = true) -> Int {
        let picks = Self.picks(samples.count)
        let id = sampler.add(label, page: index, points: picks.map { samples[$0] }, timesInk: timesInk)
        var pencil = StressPencil(page: page, pageIndex: index)
        let slot = Dictionary(uniqueKeysWithValues: picks.enumerated().map { ($0.element, $0.offset) })
        if let first = slot[0] { sampler.drawn(id, point: first, at: CACurrentMediaTime()) }
        pencil.down(at: samples[0])
        for k in samples.indices.dropFirst() {
            if let point = slot[k] { sampler.drawn(id, point: point, at: CACurrentMediaTime()) }
            pencil.move(to: samples[k])
        }
        if hold > 0 { pencil.hold(hold) }
        pencil.lift()
        sampler.lifted(id)
        return id
    }

    /// Moves the Pencil along `samples` with the tool chosen, tracking no ink (the laser).
    func drive(_ samples: [CGPoint], page index: Int = 0, each: (Int) -> Void = { _ in }) {
        var pencil = StressPencil(page: page, pageIndex: index)
        pencil.down(at: samples[0])
        for k in samples.indices.dropFirst() {
            pencil.move(to: samples[k])
            each(k)
        }
        pencil.lift()
    }

    /// A sweep with the eraser chosen; `removing` must leave the screen, within `StressBounds.removal` of the lift.
    func erase(_ path: [CGPoint], removing: [Int], _ label: String) {
        for id in removing { sampler.expectGone(id) }
        drive(StressInk.samples(path, speed: 500, seed: 77))
        let lift = CACurrentMediaTime()
        removals += removing.map { removal($0, lift: lift, label) }
    }

    /// A scribble with the pen; it and `removing` must leave the screen within `StressBounds.removal` of the lift.
    func scribble(_ samples: [CGPoint], removing: [Int], _ label: String) {
        for id in removing { sampler.expectGone(id) }
        let id = pen(samples, label, timesInk: true)
        let lift = CACurrentMediaTime()
        sampler.expectGone(id, since: lift)
        removals += (removing + [id]).map { removal($0, lift: lift, label) }
    }

    func lasso(_ samples: [CGPoint]) { drive(samples) }

    /// The app's own frame gaps while `body` runs (EP126): each gap a frame ends inside it, and when it ended.
    func frameGaps(_ body: () -> Void) -> StressPhase {
        let start = sampler.appFrameGaps.count
        body()
        return StressPhase(gaps: Array(sampler.appFrameGaps.dropFirst(start)), ends: Array(sampler.appFrameTimes.dropFirst(start)))
    }

    /// A finger drag on the selection from `start` (page points) by `delta`, in `steps` even moves 120 a second as the
    /// selection's pan delivers them on a ProMotion iPad, timed as `timedSelectionDrag(from:through:)` times it.
    func timedSelectionDrag(from start: CGPoint, by delta: CGVector, steps: Int = 90) -> StressDrag {
        timedSelectionDrag(from: start, through: (1...steps).map { k in
            CGVector(dx: delta.dx * CGFloat(k) / CGFloat(steps), dy: delta.dy * CGFloat(k) / CGFloat(steps))
        })
    }

    /// A finger drag on the selection from `start` (page points) through `shifts` (one move each, from `start`), 120
    /// moves a second, timed in three parts (EP126): the pick-up (the touch down, its first two moves and a frame or
    /// two after), the steady drag after it, and the drop at the last shift (the lift and the frames after it). It
    /// counts the drawings the page is given through the whole gesture.
    ///
    /// With `probes` (the selected strokes and the rest of the page's ink when the drag begins), at every `probeEvery`th
    /// move of the steady drag up to four points of the selected ink where the move puts it are watched until the
    /// screen shows ink there: each on bare paper, clear of the other ink and of everywhere the selection was before
    /// that move, so only the dragged ink arriving can read as ink. Their waits are the drag's move to ink. A probed
    /// move is held for two 60 Hz frames, so a screen slower than the moves still gets to show it.
    func timedSelectionDrag(from start: CGPoint, through shifts: [CGVector], probes: (selected: [PKStroke], others: [PKStroke])? = nil,
                            probeEvery: Int = 3) -> StressDrag {
        var result = StressDrag()
        guard let canvas = page.canvas(0), shifts.count >= 3, let last = shifts.last else { return result }
        let overlay = controller.inkSelection.overlay
        func onOverlay(_ p: CGPoint) -> CGPoint { overlay.convert(p, from: canvas.pageSpace) }
        let finder = probes.map { probes in StressHarnessTime.measure { StressDragProbes(selected: probes.selected, others: probes.others) } }
        var probeMarks: [Int] = []
        func move(_ k: Int) {
            let t = shifts[k]
            overlay.continueDrag(to: onOverlay(CGPoint(x: start.x + t.dx, y: start.y + t.dy)))
            let now = CACurrentMediaTime()
            guard let finder, k >= 2, k % probeEvery == 0 else { return StressPage.pump(1.0 / 120) }
            let points = StressHarnessTime.measure { finder.points(at: t, after: Array(shifts.prefix(k)), shown: shownPart()) }
            if !points.isEmpty {
                probeMarks.append(sampler.add("drag probe at move \(k + 1)", page: 0, points: points,
                                              drawnAt: Array(repeating: now, count: points.count)))
            }
            StressPage.pump(1.0 / 30)
        }
        let revisions = controller.scribbleRevisions[0, default: 0]
        result.pickUp = frameGaps {
            overlay.beginDrag(at: onOverlay(start), to: onOverlay(start))
            move(0)
            move(1)
            StressPage.pump(0.05)
        }
        result.steady = frameGaps { for k in 2..<shifts.count { move(k) } }
        result.drop = frameGaps {
            overlay.endDrag(at: onOverlay(CGPoint(x: start.x + last.dx, y: start.y + last.dy)))
            StressPage.pump(0.3)
        }
        result.pageDrawings = controller.scribbleRevisions[0, default: 0] - revisions
        for id in probeMarks {
            guard let mark = sampler.mark(id) else { continue }
            for (drawn, seen) in zip(mark.drawnAt, mark.firstSeen) {
                guard let drawn else { continue }
                if let seen { result.inkWaits.append(max(0, seen - drawn)) } else { result.probesNeverShown += 1 }
            }
            sampler.release(id)
        }
        return result
    }

    /// The Pencil held still at `point` for `seconds`.
    func press(at point: CGPoint, for seconds: TimeInterval) {
        var pencil = StressPencil(page: page, pageIndex: 0)
        pencil.down(at: point)
        pencil.hold(seconds)
        pencil.lift()
    }

    /// A finger drag on the selection from `start` (page points) by `delta`, as the selection's pan delivers it.
    func dragSelection(from start: CGPoint, by delta: CGVector, removing: [Int]) {
        guard let canvas = page.canvas(0) else { return }
        let overlay = controller.inkSelection.overlay
        func onOverlay(_ p: CGPoint) -> CGPoint { overlay.convert(p, from: canvas.pageSpace) }
        let steps = 24
        // The ink leaves its old place as the drag carries it.
        for id in removing { sampler.expectGone(id) }
        overlay.beginDrag(at: onOverlay(start), to: onOverlay(start))
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            overlay.continueDrag(to: onOverlay(CGPoint(x: start.x + delta.dx * t, y: start.y + delta.dy * t)))
            StressPage.pump(1.0 / 120)
        }
        overlay.endDrag(at: onOverlay(CGPoint(x: start.x + delta.dx, y: start.y + delta.dy)))
        removals += removing.map { removal($0, lift: CACurrentMediaTime(), "move") }
    }

    /// EP126: a selection's drag or resize leaves the page's drawing alone until the drop: before EP126 every move gave
    /// the page a new drawing, which PencilKit redrew whole and recorded, the stall on the iPad. And, where it was
    /// watched, the dragged ink keeps up with the finger as pen ink does with the Pencil.
    func checkDrag(_ drag: StressDrag, _ name: String) {
        metrics["lasso.\(name).pageDrawings"] = Double(drag.pageDrawings)
        check("the \(name) gives the page its drawing only to pick up and drop", drag.pageDrawings <= StressBounds.lassoPageDrawings,
              "the page was given \(drag.pageDrawings) drawings through the \(name) (at most \(StressBounds.lassoPageDrawings))")
        guard !drag.inkWaits.isEmpty || drag.probesNeverShown > 0 else { return }
        let waits = drag.inkWaits.sorted()
        let p50 = waits.isEmpty ? 0 : waits[waits.count / 2], p95 = waits.isEmpty ? 0 : waits[min(waits.count - 1, waits.count * 95 / 100)]
        let worst = waits.last ?? 0
        metrics["lasso.\(name).inkP50Ms"] = p50 * 1000
        metrics["lasso.\(name).inkP95Ms"] = p95 * 1000
        metrics["lasso.\(name).inkMaxMs"] = worst * 1000
        metrics["lasso.\(name).inkNeverShown"] = Double(drag.probesNeverShown)
        check("the dragged ink keeps up with the finger", drag.probesNeverShown == 0 && p95 <= StressBounds.penToInkP95
                && worst <= StressBounds.penToInkMax,
              String(format: "move to ink p50 %.0f ms, p95 %.0f ms, max %.0f ms over %d points", p50 * 1000, p95 * 1000, worst * 1000,
                     waits.count) + (drag.probesNeverShown > 0 ? "; \(drag.probesNeverShown) points the dragged ink never showed at" : ""))
    }

    /// The two-finger double tap's undo. `removing` must then leave the screen.
    func undoTap(removing id: Int?) {
        if let id { sampler.expectGone(id) }
        controller.undo()
        if let id { removals.append(removal(id, lift: CACurrentMediaTime(), "undo")) }
    }

    /// The three-finger double tap's redo. `restoring` comes back on purpose, so it is no longer judged.
    func redoTap(restoring id: Int? = nil) {
        if let id { sampler.release(id) }
        controller.redo()
    }

    func settle() { page.settle() }

    /// A moment in the scenario, for reading the hidden runs against.
    func note(_ text: String) { notes.append(String(format: "%@ at %.2f s", text, CACurrentMediaTime() - sampler.scenarioStart)) }

    /// The sample indices a mark watches: eight spread along the stroke, short of its tips.
    private static func picks(_ count: Int) -> [Int] {
        guard count > 6 else { return Array(0..<count) }
        let from = count / 8, to = count - 1 - count / 8
        return (0..<8).map { from + ($0 * (to - from)) / 7 }
    }

    // MARK: Checks

    func check(_ name: String, _ passed: Bool, _ detail: String, advisory: Bool = false, file: StaticString = #filePath,
               line: UInt = #line) {
        StressHarnessTime.measure { checks.append(StressCheck(name: name, passed: passed, detail: detail, advisory: advisory ? true : nil))
        if advisory { return }
        XCTAssertTrue(passed, "\(tool): \(name): \(detail)", file: file, line: line) }
    }

    /// The page draws strokes in the order they were written, so a later stroke lies over an earlier one.
    func checkWritingOrder(_ strokes: [PKStroke]) {
        let dates = strokes.map(\.path.creationDate)
        let swapped = zip(dates, dates.dropFirst()).filter { $0 > $1 }.count
        check("strokes stay in the order written", swapped == 0,
              swapped == 0 ? "all \(strokes.count) in writing order" : "\(swapped) places where a stroke sits below one written before it")
    }

    /// Each of the newest `count` undo steps takes exactly one stroke, and redo brings each back.
    func checkUndoTakesOneStrokeEach(_ count: Int, page index: Int = 0) {
        settle()
        guard let canvas = page.canvas(index), let undo = canvas.undoManager else { return check("undo", false, "no undo manager") }
        sampler.releaseAll()
        var wrong: [String] = []
        var steps = 0
        // An undo group opened outside undo and redo during the check registers a step, which empties redo: who
        // opened it is named with the first wrong step (EP118: on one Simulator run every redo found none left).
        var openers: [String] = []
        let opened = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidOpenUndoGroup, object: undo, queue: nil) { _ in
            guard !undo.isUndoing, !undo.isRedoing, openers.count < 3 else { return }
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(6)
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).dropLast(2).joined(separator: " ") }
            openers.append(frames.joined(separator: " < "))
        }
        defer { NotificationCenter.default.removeObserver(opened) }
        // Taps 50 ms apart, as fast as a two-finger double tap repeats.
        // Each wrong step names the undo step it was ("Ink" is EmberPad's own; PencilKit's own steps have no name).
        func named(_ name: String) -> String { name.isEmpty ? "unnamed" : "\"\(name)\"" }
        while undo.canUndo, steps < count {
            let before = canvas.drawing.strokes.count
            let name = undo.undoActionName
            controller.undo()
            steps += 1
            if canvas.drawing.strokes.count != before - 1 {
                wrong.append("undo \(steps) (\(named(name))): \(before) to \(canvas.drawing.strokes.count)")
            }
            StressPage.pump(0.05)
        }
        if steps < count { wrong.append("only \(steps) undo steps for \(count) strokes") }
        for k in 0..<steps {
            let before = canvas.drawing.strokes.count
            let name = undo.canRedo ? named(undo.redoActionName) : "none left"
            controller.redo()
            if canvas.drawing.strokes.count != before + 1 {
                wrong.append("redo \(k + 1) (\(name)): \(before) to \(canvas.drawing.strokes.count)")
            }
            StressPage.pump(0.05)
        }
        settle()
        if !wrong.isEmpty, !openers.isEmpty { wrong.insert("undo group opened during the check by " + openers.joined(separator: "; "), at: 0) }
        check("each undo takes one stroke and redo restores it", wrong.isEmpty,
              wrong.isEmpty ? "\(steps) undos took one stroke each; \(steps) redos put each back" : wrong.prefix(6).joined(separator: "; "))
    }

    /// One undo changes the page's stroke count by `count` (an erase undone brings its strokes back), and redo again.
    func checkOneUndoRestores(_ count: Int, _ label: String, page index: Int = 0) {
        guard let canvas = page.canvas(index) else { return }
        // The undo brings back what was removed on purpose, so nothing on the page is judged through it.
        sampler.releaseAll()
        let before = canvas.drawing.strokes.count
        controller.undo()
        let undone = canvas.drawing.strokes.count
        StressPage.pump(0.05)
        controller.redo()
        settle()
        let redone = canvas.drawing.strokes.count
        check("\(label) is one undo step", undone == before + count && redone == before,
              "\(before) strokes, \(undone) after one undo (\(before + count) expected), \(redone) after redo")
    }

    // MARK: The end

    /// The checks every scenario makes: stroke counts, ink on the screen, pen to ink, stalls, removals, landing.
    func finish(expectedStrokes: [Int: Int]?) {
        settle()
        StressPage.pump(0.3)
        sampler.finishRuns()
        if let expectedStrokes {
            for (index, count) in expectedStrokes.sorted(by: { $0.key < $1.key }) {
                let saved = page.saved(index), shown = page.shown(index)
                // The two pieces a partial erase leaves can share their stroke's ID, so where each begins tells them apart.
                let unique = Set(saved.map { stroke -> String in
                    let first = stroke.path.first.map { $0.location.applying(stroke.transform) } ?? .zero
                    // and the part each one shows.
                    let mask = stroke.mask?.bounds ?? .null
                    return "\(InkStrokeID(stroke).hashValue) \(Int(first.x * 10)) \(Int(first.y * 10)) \(mask)"
                }).count
                let clear = shown.filter { InkKeepsEveryStrokeTests.alpha($0.ink.color) == 0 }.count
                var detail = "\(saved.count) saved, \(shown.count) on the page, \(unique) distinct, \(count) expected"
                if saved.count < count {
                    // Names the strokes written here that no saved stroke passes near, so a loss says which one.
                    let removed = Set(removals.map(\.id))
                    let paths = saved.map { StressInk.points(of: $0, count: 64) }
                    let lost = sampler.allMarks.filter { mark in
                        mark.page == index && !removed.contains(mark.id) && mark.drawnAt.contains { $0 != nil }
                            && !paths.contains { path in
                                mark.points.allSatisfy { p in path.contains { hypot($0.x - p.x, $0.y - p.y) <= 12 } }
                            }
                    }.map(\.label)
                    if !lost.isEmpty { detail += "; not on the page: \(lost.prefix(6).joined(separator: ", "))" }
                }
                check("page \(index + 1): no stroke lost or doubled", saved.count == count && shown.count == count && unique == count,
                      detail)
                check("page \(index + 1): no stroke left clear", clear == 0, "\(clear) strokes left in the live pen's clear ink")
            }
        }
        let marks = sampler.allMarks
        // Ink once drawn stays drawn.
        let runs = sampler.hiddenRuns
        let longest = runs.map(\.durationMs).max() ?? 0
        metrics["hiddenRuns"] = Double(runs.count)
        metrics["hiddenFrames"] = Double(runs.reduce(0) { $0 + $1.frames })
        metrics["longestHiddenMs"] = longest
        let real = runs.filter { $0.durationMs > StressBounds.blip * 1000 }
        let blips = runs.filter { $0.durationMs <= StressBounds.blip * 1000 }
        func describe(_ runs: [StressHiddenRun]) -> String {
            let vanished = runs.filter { $0.worstHiddenFraction >= 0.5 }
            let first = runs.min { $0.start < $1.start }!
            return "\(runs.count) times (\(vanished.count) gone outright, \(runs.count - vanished.count) partly), longest "
                + String(format: "%.0f ms", runs.map(\.durationMs).max() ?? 0) + "; first: \(first.mark) at " + String(format: "%.2f s", first.start)
        }
        check("landed ink never leaves the screen", real.isEmpty,
              real.isEmpty ? "no landed ink missing for more than " + String(format: "%.0f ms", StressBounds.blip * 1000) : describe(real))
        check("no blips of landed ink", blips.isEmpty,
              blips.isEmpty ? "none" : describe(blips) + " (each " + String(format: "%.0f ms", StressBounds.blip * 1000)
                  + " or less: confirm on a recording)", advisory: true)
        // Pen to ink.
        let latencies = marks.filter(\.timesInk).flatMap { mark in
            mark.points.indices.compactMap { i -> Double? in
                guard let drawn = mark.drawnAt[i], let seen = mark.firstSeen[i] else { return nil }
                return max(0, seen - drawn)
            }
        }.sorted()
        let missed = marks.filter(\.timesInk).filter { if case .visible = $0.expect { return true } else { return false } }
            .reduce(0) { $0 + $1.firstSeen.filter { $0 == nil }.count }
        if !latencies.isEmpty {
            let p50 = latencies[latencies.count / 2], p95 = latencies[min(latencies.count - 1, latencies.count * 95 / 100)]
            let worst = latencies.last ?? 0
            metrics["penToInkP50Ms"] = p50 * 1000
            metrics["penToInkP95Ms"] = p95 * 1000
            metrics["penToInkMaxMs"] = worst * 1000
            metrics["penToInkSamples"] = Double(latencies.count)
            check("pen to ink is quick", p95 <= StressBounds.penToInkP95 && worst <= StressBounds.penToInkMax,
                  String(format: "p50 %.0f ms, p95 %.0f ms, max %.0f ms over %d points", p50 * 1000, p95 * 1000, worst * 1000, latencies.count))
        }
        if missed > 0 { notes.append("\(missed) pen points were never read as ink (off screen, or never drawn)") }
        // Landing.
        let lifted = marks.filter { mark in
            if case .visible = mark.expect, mark.liftedAt != nil, mark.drawnAt.contains(where: { $0 != nil }) { return true }
            return false
        }
        // Timed from the start of the pause that let it land (`StressBounds.landing`); from its own lift as well, reported.
        let landed = lifted.compactMap { mark -> (label: String, time: Double, sinceLift: Double)? in
            guard let lift = mark.liftedAt, let drawn = mark.pageDrawnAt, let pause = sampler.pauseStart(landing: mark) else { return nil }
            return (mark.label, max(0, drawn - pause), max(0, drawn - lift))
        }
        let landings = landed.map(\.time)
        let slowest = landed.max { $0.time < $1.time }
        let unlanded = lifted.filter { $0.pageDrawnAt == nil }.map(\.label)
        // A stroke the screen never showed was never read, so it cannot be seen to land: it still fails, named apart
        // from one the screen showed and the page never drew (EP122: written below a landscape screen).
        let unseen = lifted.filter { $0.pageDrawnAt == nil && !$0.everOnScreen }.map(\.label)
        let undrawn = lifted.filter { $0.pageDrawnAt == nil && $0.everOnScreen }.map(\.label)
        var missing: [String] = []
        if !undrawn.isEmpty {
            missing.append("\(undrawn.count) of \(lifted.count) never drawn by the page itself: " + undrawn.prefix(4).joined(separator: ", "))
        }
        if !unseen.isEmpty {
            missing.append("\(unseen.count) of \(lifted.count) written where the screen does not show them, so never seen to land: "
                           + unseen.prefix(4).joined(separator: ", "))
        }
        if !lifted.isEmpty {
            let worst = landings.max() ?? 0
            metrics["landingMaxMs"] = worst * 1000
            metrics["landingP50Ms"] = landings.isEmpty ? 0 : landings.sorted()[landings.count / 2] * 1000
            if let longest = landed.max(by: { $0.sinceLift < $1.sinceLift }) {
                metrics["landingSinceLiftMaxMs"] = longest.sinceLift * 1000
                notes.append(String(format: "longest wait to land from its own lift %.0f ms (%@): the pen waits for a pause on purpose",
                                    longest.sinceLift * 1000, longest.label))
            }
            check("every stroke lands on the page", unlanded.isEmpty && worst <= StressBounds.landing,
                  unlanded.isEmpty ? String(format: "slowest landing %.0f ms after the pause began", worst * 1000) + " (\(slowest?.label ?? "-"))"
                      : missing.joined(separator: "; "))
        }
        // Removal.
        if !removals.isEmpty {
            var slow: [String] = [], stayed: [String] = [], back: [String] = [], unseen: [String] = []
            var times: [Double] = []
            for removal in removals {
                guard let mark = sampler.mark(removal.id) else { continue }
                removalRecords.append(StressRemoval(mark: mark.label, how: removal.label, lift: removal.lift - sampler.scenarioStart,
                                                    goneMs: mark.goneAt.map { ($0 - removal.lift) * 1000 },
                                                    cameBackMs: mark.cameBackAt.map { ($0 - removal.lift) * 1000 },
                                                    screen: removal.screen))
                if let cameBack = mark.cameBackAt {
                    back.append("\(mark.label) (" + String(format: "%.0f ms", (cameBack - removal.lift) * 1000) + ")")
                }
                guard let gone = mark.goneAt else {
                    if mark.everShown { stayed.append(mark.label) } else { unseen.append(mark.label) }
                    continue
                }
                let time = max(0, gone - removal.lift)
                times.append(time)
                if time > StressBounds.removal { slow.append("\(mark.label) " + String(format: "%.0f ms", time * 1000)) }
            }
            metrics["removalMaxMs"] = (times.max() ?? 0) * 1000
            if !unseen.isEmpty { notes.append("removal not judged (never on the screen before it went): \(unseen.joined(separator: ", "))") }
            check("removed ink leaves the screen at once", slow.isEmpty && stayed.isEmpty,
                  slow.isEmpty && stayed.isEmpty ? String(format: "all gone within %.0f ms of the lift", (times.max() ?? 0) * 1000)
                      : (stayed.isEmpty ? "" : "still shown: \(stayed.prefix(4).joined(separator: ", ")). ")
                        + (slow.isEmpty ? "" : "late: \(slow.prefix(4).joined(separator: ", "))"))
            check("removed ink stays gone", back.isEmpty, back.isEmpty ? "none came back" : "came back: \(back.prefix(4).joined(separator: ", "))")
        }
        // Stalls.
        let gaps = sampler.appFrameGaps.sorted()
        if !gaps.isEmpty {
            let worst = gaps.last ?? 0
            let raw = sampler.frameGaps.sorted()
            metrics["longestFrameGapMs"] = worst * 1000
            metrics["longestFrameGapAtS"] = sampler.longestGapAt
            metrics["frameGapP95Ms"] = gaps[min(gaps.count - 1, gaps.count * 95 / 100)] * 1000
            metrics["longestFrameGapWithSamplerMs"] = (raw.last ?? 0) * 1000
            metrics["frames"] = Double(gaps.count + 1)
            metrics["metalFrames"] = Double(sampler.metalFrames)
            let costs = sampler.costs.sorted()
            if !costs.isEmpty {
                metrics["samplerCostP95Ms"] = costs[min(costs.count - 1, costs.count * 95 / 100)] * 1000
                metrics["samplerCostMaxMs"] = (costs.last ?? 0) * 1000
            }
            // On a simulator the load is the Mac's: other simulators running beside this one stall it too.
            var load = [Double](repeating: 0, count: 3)
            let loadRead = getloadavg(&load, 3) == 3
            if loadRead { metrics["loadAverage1m"] = load[0] }
            // PencilKit's record of every drawing the app has made, which it rewrites on its own queue while
            // `PKDrawing(strokes:)` on the main thread waits for it; it only grows, and with it the stalls.
            let replicas = StressRun.pencilKitReplicaBytes
            metrics["pencilKitReplicaBytes"] = Double(replicas)
            check("the main thread never stalls", worst <= StressBounds.longestFrameGap,
                  String(format: "longest frame gap %.0f ms at %.2f s, the sampler's own work taken off (p95 %.0f ms) over %d frames",
                         worst * 1000, sampler.longestGapAt, (metrics["frameGapP95Ms"] ?? 0), gaps.count)
                      + (loadRead ? String(format: "; load average %.1f on %d cores", load[0], ProcessInfo.processInfo.activeProcessorCount) : "")
                      + String(format: "; PencilKit replica record %.1f MB", Double(replicas) / 1_000_000))
        }
        if !StressRun.samplerWorks { notes.append("the frame sampler's self-check failed, so the screen checks may be wrong") }
        if sampler.offScreenSamples > 0 { notes.append("\(sampler.offScreenSamples) point reads skipped as off the screen") }
        let evidence = sampler.evidence
        for name in evidence {
            let url = StressRun.directory.appendingPathComponent(name)
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = name
            attachment.lifetime = .keepAlways
            testCase?.add(attachment)
        }
        let result = StressToolResult(tool: tool, title: title, passed: checks.allSatisfy(\.holds), checks: checks, metrics: metrics,
                                      hiddenRuns: runs, removals: removalRecords, notes: notes, evidence: evidence,
                                      durationSeconds: Date().timeIntervalSince(began))
        StressRun.record(result)
        page.close()
    }
}

// MARK: - Shapes and colours

/// One timed drag on a selection (EP126): its three parts, the drawings the page was given through it, and the waits
/// from a move to the frame showing the dragged ink there.
struct StressDrag {
    var pickUp = StressPhase()
    var steady = StressPhase()
    var drop = StressPhase()
    var pageDrawings = 0
    var inkWaits: [Double] = []
    var probesNeverShown = 0
}

/// Finds the points `timedSelectionDrag` watches for the dragged ink (EP126): points along the selected strokes, moved
/// by the drag so far, that lie on bare paper, clear of the page's other ink and of everywhere the selection was
/// before, so that nothing but the dragged ink arriving there can read as ink.
struct StressDragProbes {
    static let clearance: CGFloat = 3.5
    private struct Cell: Hashable { let x: Int, y: Int }
    private let candidates: [CGPoint]
    private let selection: [Cell: [CGPoint]]
    private let others: [Cell: [CGPoint]]

    init(selected: [PKStroke], others: [PKStroke]) {
        candidates = selected.flatMap { StressInk.points(of: $0, count: 8) }
        selection = Self.grid(selected.flatMap(Self.dense))
        self.others = Self.grid(others.flatMap(Self.dense))
    }

    private static func dense(_ stroke: PKStroke) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
    }

    private static func cell(_ p: CGPoint) -> Cell { Cell(x: Int((p.x / clearance).rounded(.down)), y: Int((p.y / clearance).rounded(.down))) }

    private static func grid(_ points: [CGPoint]) -> [Cell: [CGPoint]] { Dictionary(grouping: points, by: cell) }

    private static func near(_ q: CGPoint, _ grid: [Cell: [CGPoint]]) -> Bool {
        let c = cell(q)
        for dx in -1...1 {
            for dy in -1...1 {
                for p in grid[Cell(x: c.x + dx, y: c.y + dy)] ?? [] where hypot(p.x - q.x, p.y - q.y) <= clearance { return true }
            }
        }
        return false
    }

    /// Up to four points of the selected ink moved by `shift`, inside `shown`, clear of the other ink and of the
    /// selection at its place before the drag and at each of the `earlier` moves.
    func points(at shift: CGVector, after earlier: [CGVector], shown: CGRect) -> [CGPoint] {
        let past = [CGVector.zero] + earlier
        let inside = shown.isNull ? CGRect.infinite : shown.insetBy(dx: 8, dy: 8)
        var found: [CGPoint] = []
        for c in candidates {
            let q = CGPoint(x: c.x + shift.dx, y: c.y + shift.dy)
            guard inside.contains(q), !Self.near(q, others),
                  !past.contains(where: { Self.near(CGPoint(x: q.x - $0.dx, y: q.y - $0.dy), selection) }) else { continue }
            found.append(q)
            if found.count == 4 { break }
        }
        return found
    }
}

/// The app's frame gaps through one part of a scenario (EP126), and when each ended.
struct StressPhase {
    var gaps: [Double] = []
    var ends: [CFTimeInterval] = []
    var worst: Double { gaps.max() ?? 0 }
    var worstEnd: CFTimeInterval { gaps.indices.max { gaps[$0] < gaps[$1] }.map { ends[$0] } ?? 0 }
}

extension StressInk {
    /// A page full of ink (EP126), as a worked page in class is: 18 rows of long writing in two columns, a highlight
    /// across every third row, and a box round every sixth row's answer and a ring round the next. About 600 strokes.
    static func heavyPage() -> [PKStroke] {
        let words = ["the warm sun rose", "under a tall mountain", "data notes and laws", "she drew a long line",
                     "now add the moles", "write it down slowly"]
        var strokes: [PKStroke] = []
        var date = 1_700_000_100.0
        func stroke(_ points: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
            date += 1
            let control = points.enumerated().map { k, p in
                PKStrokePoint(location: p, timeOffset: Double(k) / 240, size: CGSize(width: width, height: width), opacity: 1,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: control, creationDate: Date(timeIntervalSince1970: date)))
        }
        let pen = PKInk(.fountainPen, color: .black)
        let marker = PKInk(.marker, color: UIColor.emberHighlighterYellow.withAlphaComponent(Theme.highlighterDefaultOpacity))
        for row in 0..<18 {
            let y = 150 + CGFloat(row) * 34
            for column in 0..<2 {
                let text = words[(row * 2 + column) % words.count]
                for points in ScribbleFixtures.handwriting(text, at: CGPoint(x: 40 + CGFloat(column) * 290, y: y), scale: 0.6) {
                    strokes.append(stroke(points, ink: pen, width: 2.5))
                }
            }
            if row % 3 == 1 {
                strokes.append(stroke(line(from: CGPoint(x: 36, y: y + 6), to: CGPoint(x: 560, y: y + 7), wobble: 0.5), ink: marker, width: 14))
            }
            if row % 6 == 2 {
                let box = [CGPoint(x: 32, y: y - 14), CGPoint(x: 270, y: y - 14), CGPoint(x: 270, y: y + 22), CGPoint(x: 32, y: y + 22),
                           CGPoint(x: 32, y: y - 14)]
                strokes.append(stroke(zip(box, box.dropFirst()).flatMap { line(from: $0, to: $1, steps: 20, wobble: 0) }, ink: pen, width: 2))
            }
            if row % 6 == 3 {
                strokes.append(stroke(circle(center: CGPoint(x: 440, y: y + 4), radius: 26), ink: pen, width: 2))
            }
        }
        return strokes
    }
}

extension StressInk {
    static func line(from a: CGPoint, to b: CGPoint, steps: Int = 40, wobble: CGFloat) -> [CGPoint] {
        (0...steps).map { k in
            let t = CGFloat(k) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + wobble * sin(t * 11))
        }
    }

    static func circle(center: CGPoint, radius: CGFloat, degrees: CGFloat = 370) -> [CGPoint] {
        let count = Int(degrees / 4)
        return (0...count).map { k in
            let angle = CGFloat(k) / CGFloat(count) * degrees * .pi / 180 - .pi / 2
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    /// How far, at most, a stroke strays from the straight line between its ends, in points.
    static func straightness(of stroke: PKStroke) -> CGFloat {
        let points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
        guard let a = points.first, let b = points.last, distance(a, b) > 1 else { return .infinity }
        let length = distance(a, b)
        return points.map { abs((b.x - a.x) * (a.y - $0.y) - (a.x - $0.x) * (b.y - a.y)) / length }.max() ?? 0
    }
}

extension UIColor {
    convenience init(stressHex hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var stressHex: String {
        var c: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&c.0, green: &c.1, blue: &c.2, alpha: &c.3)
        return String(format: "#%02X%02X%02X", Int(c.0 * 255), Int(c.1 * 255), Int(c.2 * 255))
    }

    func stressMatches(_ other: UIColor) -> Bool {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        let light = UITraitCollection(userInterfaceStyle: .light)
        resolvedColor(with: light).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        other.resolvedColor(with: light).getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        return abs(a.0 - b.0) < 0.06 && abs(a.1 - b.1) < 0.06 && abs(a.2 - b.2) < 0.06
    }
}
