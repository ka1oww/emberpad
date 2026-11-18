import AppKit
import EmberSyncKit
import Metal
import PencilKit
import QuartzCore
import XCTest
@testable import EmberPadCompanion

/// EP156: a stroke the Mac shows must not go soft when the Pencil lifts.
///
/// While the Pencil is down the Mac draws the stroke as a vector path, sharp at any zoom. Once it lifts, the stroke
/// arrives as committed ink and is drawn from a bitmap. That bitmap used to be made at the paper's `rasterScale`, about
/// one bitmap pixel per screen pixel on a 1080p projector or recording (coarser still zoomed in past the paper's cap),
/// and placed at a fractional pixel offset, so
/// the GPU's resampling doubled its edge: in the captain's lesson recording of 18 Nov 2026 every stroke visibly
/// blurred on lift. These tests draw the canvas on the GPU, as the lesson recorder does, at the recording's page scale,
/// and measure one stroke before and after it lands, against the live stroke and against PencilKit drawing the same
/// ink straight onto the canvas's pixels. A thin line's look depends on where it falls between pixels, so each
/// measure is the mean over four sub-pixel placements.
@MainActor
final class PresentInkSharpnessTests: XCTestCase {
    private let a4 = CGSize(width: 595, height: 842)
    private let canvasSize = CGSize(width: 1_920, height: 1_080)
    private let session = UUID()
    private let documentID = UUID()
    private lazy var paper = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: a4))
    /// The pen's drawn width in page points: `PenFeel.widthPerToolWidth` (0.51) × pen width 1.5, the captain's pen.
    private let drawn: CGFloat = 0.51 * 1.5
    private let rgba: [CGFloat] = [0.13, 0.22, 0.52, 1]
    /// Where each bar falls within a canvas pixel, in pixels.
    private let placements: [CGFloat] = [0, 0.25, 0.5, 0.75]
    /// A committed edge may be this much wider (mean 10–90 % ramp, canvas pixels) than the live stroke's.
    private let rampSlack = 0.35
    /// The darkest point across each bar, as a share of the darkest point of the same ink drawn straight onto the
    /// canvas's pixels: across the pen's thin direction, a blurred bitmap spreads the line and loses darkness.
    private let leastPeak = 0.8

    /// 4.9 canvas pixels per page point: the page scale of the captain's recording of 18 Nov 2026, where the ink's
    /// bitmap was at its coarsest (about one bitmap pixel per canvas pixel).
    func testCommittedInkStaysAsSharpAsTheLiveStrokeAtTheRecordingsScale() throws {
        try checkSharpness(k: 4.9)
    }

    /// 6.5 pixels per point, zoomed in further, where the paper's bitmap (capped at `maxRasterSide`) is coarser than
    /// the canvas.
    func testCommittedInkStaysAsSharpAsTheLiveStrokeZoomedIn() throws {
        try checkSharpness(k: 6.5)
    }

    /// A bitmap of committed ink is drawn at twice the page's shown scale (rounded up to a power of two), even past the
    /// paper's cap, but never beyond `maxRasterSide` on its longest side or `maxInkPixels` in area; when that cap binds
    /// it falls back towards the paper's scale, never below it.
    func testInkScaleIsTwiceThePagesUntilItsBitmapReachesTheCap() {
        let bucket = PresentGeometry.rasterBucket(pageSize: a4, displayedPoints: a4.width * 4.9, screenScale: 1)
        let paper = PresentGeometry.rasterScale(pageSize: a4, bucket: bucket)
        XCTAssertEqual(bucket, 8)
        XCTAssertEqual(paper, PresentGeometry.maxRasterSide / a4.height, accuracy: 1e-9, "an A4 page at 4.9 px/pt is at the paper's cap")
        XCTAssertEqual(paper, PresentGeometry.rasterScale(pageSize: a4, displayedPoints: a4.width * 4.9, screenScale: 1))
        // A stroke: twice the bucket.
        XCTAssertEqual(PresentGeometry.inkScale(bounds: CGSize(width: 80, height: 60), bucket: bucket, rasterScale: paper), 16)
        XCTAssertEqual(PresentGeometry.inkScale(bounds: CGSize(width: 80, height: 60), bucket: 1, rasterScale: 1), 2)
        // All the page's ink in one bitmap (as merged segments are): at the cap, the paper's scale, as before EP156.
        XCTAssertEqual(PresentGeometry.inkScale(bounds: a4, bucket: bucket, rasterScale: paper), paper, accuracy: 1e-9)
        // Long and thin: its longest side caps it.
        let long = PresentGeometry.inkScale(bounds: CGSize(width: 400, height: 20), bucket: bucket, rasterScale: paper)
        XCTAssertEqual(400 * long, PresentGeometry.maxRasterSide, accuracy: 1e-6)
        XCTAssertGreaterThan(long, paper)
        // Wide and tall, short of the side cap: its area caps it.
        let square = CGSize(width: 300, height: 300)
        let big = PresentGeometry.inkScale(bounds: square, bucket: bucket, rasterScale: paper)
        XCTAssertLessThan(300 * big, PresentGeometry.maxRasterSide)
        XCTAssertEqual(square.width * square.height * big * big, PresentGeometry.maxInkPixels, accuracy: 1)
        XCTAssertGreaterThan(big, paper)
        XCTAssertLessThan(big, 16)
    }

    /// Once a page holds more than `maxSegmentLayers` segments, all its ink is drawn again together. It stays as sharp
    /// as the live line: drawn at the paper's scale, as merged ink was before, every older stroke on the page went
    /// soft at each merge, about every 24 strokes.
    func testMergedInkStaysAsSharpAsTheLiveStrokeAtTheRecordingsScale() throws {
        try checkSharpness(k: 4.9, merged: true)
    }

    /// A page's merged ink is cut into tiles where it has ink, each within `maxRasterSide` a side, at up to twice the
    /// page's scale within the page's budget of `pageInkPixels`, less room for the strokes written after it, which stay
    /// as sharp as before; it is drawn off the main thread, the page's own layers staying until it lands.
    func testMergedInkIsTiledWithinThePagesBudget() throws {
        let budget = PresentInkBudget(total: 96_000_000)
        let layers = PresentPageLayers(budget: budget)
        let bucket = PresentGeometry.rasterBucket(pageSize: a4, displayedPoints: a4.width * 4.9, screenScale: 1)
        let scale = PresentGeometry.rasterScale(pageSize: a4, bucket: bucket)
        let k: CGFloat = 4.9
        let held = try pageFullOfInk()
        // One segment's layer at a time, as written, up to one more than a page keeps.
        for n in 1...PresentPageLayers.maxSegmentLayers + 1 {
            layers.update(ink: held[n - 1], pageSize: a4, scale: scale, bucket: bucket, frame: CGRect(x: 0, y: 0, width: a4.width * k, height: a4.height * k))
        }
        XCTAssertTrue(layers.isMerging, "merging off the main thread")
        XCTAssertEqual(layers.ink.sublayers?.count, PresentPageLayers.maxSegmentLayers + 1, "its own layers stay until the merged ink lands")
        wait(for: layers)
        let sublayers = try XCTUnwrap(layers.ink.sublayers)
        XCTAssertGreaterThan(sublayers.count, 1, "tiles")
        XCTAssertLessThan(sublayers.count, PresentPageLayers.maxSegmentLayers, "merged")
        var pixels: CGFloat = 0
        for layer in sublayers {
            let image = try XCTUnwrap(layer.contents.map { $0 as! CGImage })
            XCTAssertLessThanOrEqual(max(image.width, image.height), Int(PresentGeometry.maxRasterSide) + 1)
            let pointsWide = layer.frame.width / k
            XCTAssertGreaterThan(CGFloat(image.width) / pointsWide, scale * 1.8, "near twice the paper's scale")
            pixels += CGFloat(image.width * image.height)
        }
        let merged = PresentGeometry.pageInkPixels - PresentGeometry.newInkPixels
        XCTAssertLessThanOrEqual(layers.boostedPixels, merged + 1)
        XCTAssertLessThanOrEqual(pixels, merged * 1.01, "within the page's budget, less room for new strokes")
        XCTAssertEqual(budget.used, layers.boostedPixels, accuracy: 1)
        // The next stroke written is as sharp as any before the page filled.
        layers.update(ink: try XCTUnwrap(held.last), pageSize: a4, scale: scale, bucket: bucket, frame: CGRect(x: 0, y: 0, width: a4.width * k, height: a4.height * k))
        let newest = try XCTUnwrap(layers.ink.sublayers?.last)
        let image = try XCTUnwrap(newest.contents.map { $0 as! CGImage })
        XCTAssertEqual(CGFloat(image.width) / (newest.frame.width / k), bucket * PresentGeometry.inkSupersample, accuracy: 0.2,
                       "a new stroke at twice the page's scale")
        XCTAssertEqual(budget.used, layers.boostedPixels, accuracy: 1)
    }

    /// The Companion's ink budget bounds every page it holds at once: a page beyond it is drawn at its paper's scale,
    /// as before EP156, and a page let go gives its pixels back.
    func testAPageBeyondTheCompanionsInkBudgetIsDrawnAtThePapersScale() throws {
        let budget = PresentInkBudget(total: PresentGeometry.pageInkPixels + 1_000_000)
        let bucket = PresentGeometry.rasterBucket(pageSize: a4, displayedPoints: a4.width * 4.9, screenScale: 1)
        let scale = PresentGeometry.rasterScale(pageSize: a4, bucket: bucket)
        let frame = CGRect(x: 0, y: 0, width: a4.width * 4.9, height: a4.height * 4.9)
        let held = try XCTUnwrap(try pageFullOfInk().dropLast().last)
        var first: PresentPageLayers? = PresentPageLayers(budget: budget)
        first?.update(ink: held, pageSize: a4, scale: scale, bucket: bucket, frame: frame)
        try wait(for: XCTUnwrap(first))
        let firstPixels = try XCTUnwrap(first?.boostedPixels)
        XCTAssertGreaterThan(firstPixels, (PresentGeometry.pageInkPixels - PresentGeometry.newInkPixels) * 0.9, "the first page is drawn sharp")
        let second = PresentPageLayers(budget: budget)
        second.update(ink: held, pageSize: a4, scale: scale, bucket: bucket, frame: frame)
        wait(for: second)
        XCTAssertLessThanOrEqual(budget.used, budget.total)
        XCTAssertEqual(second.boostedPixels, 0, "no room above the paper's scale")
        let sublayers = try XCTUnwrap(second.ink.sublayers)
        XCTAssertEqual(sublayers.count, 1, "one bitmap, as before EP156")
        let image = try XCTUnwrap(sublayers[0].contents.map { $0 as! CGImage })
        XCTAssertEqual(CGFloat(image.width) / (sublayers[0].frame.width / 4.9), scale, accuracy: 0.05, "at the paper's scale")
        first = nil
        XCTAssertEqual(budget.used, 0, accuracy: 1, "the page let go gives its pixels back")
    }

    /// A page's ink after each of `maxSegmentLayers` + 1 strokes, written one at a time, reaching across the page,
    /// then after one more, a word's.
    private func pageFullOfInk() throws -> [PresentScene.Ink] {
        var scene = PresentScene()
        scene.linkOpened()
        var first = frame(seq: 1, visible: CGRect(origin: .zero, size: a4))
        first.reset = true
        first.assets = [paper]
        _ = scene.apply(first)
        var held: [PresentScene.Ink] = []
        for i in 0...PresentPageLayers.maxSegmentLayers {
            let y = CGFloat(i) * 30 + 10
            let line = stroke(.fountainPen, size: 2 + drawn / 2, through: [CGPoint(x: 5, y: y), CGPoint(x: 590, y: y + 20),
                                                                           CGPoint(x: 590, y: 832)])
            var update = frame(seq: UInt64(2 + i), visible: CGRect(origin: .zero, size: a4))
            update.ink = [PresentInkChange(pageIndex: 0, revision: UInt64(i + 1), mode: i == 0 ? .replace : .append,
                                           base: i == 0 ? nil : UInt64(i), drawing: PKDrawing(strokes: [line]).dataRepresentation())]
            _ = scene.apply(update)
            held.append(try XCTUnwrap(scene.ink[0]))
        }
        var update = frame(seq: UInt64(3 + PresentPageLayers.maxSegmentLayers), visible: CGRect(origin: .zero, size: a4))
        let word = stroke(.fountainPen, size: 2 + drawn / 2, through: (0...20).map { CGPoint(x: 200 + CGFloat($0) * 1.5, y: 400 + 8 * sin(CGFloat($0))) })
        update.ink = [PresentInkChange(pageIndex: 0, revision: UInt64(PresentPageLayers.maxSegmentLayers + 2), mode: .append,
                                       base: UInt64(PresentPageLayers.maxSegmentLayers + 1), drawing: PKDrawing(strokes: [word]).dataRepresentation())]
        _ = scene.apply(update)
        held.append(try XCTUnwrap(scene.ink[0]))
        XCTAssertEqual(held.last?.segments.count, PresentPageLayers.maxSegmentLayers + 2)
        return held
    }

    private func wait(for layers: PresentPageLayers, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while layers.isMerging, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertFalse(layers.isMerging, "the merged ink landed", file: file, line: line)
    }

    // MARK: The measurement

    /// `merged`: each look lands as the newest of more than `maxSegmentLayers` segments, and is measured once they
    /// are merged.
    private func checkSharpness(k: CGFloat, merged: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let visible = CGRect(x: 100, y: 300, width: canvasSize.width / k, height: canvasSize.height / k)
        // Since EP156 the iPad sends, on lift, the fountain-pen stroke that lands at the pause; PencilKit's monoline
        // copy, made visible, is what it sends when the live stroke is not known. (A synthetic monoline renders on the
        // Mac only from about 3 pt: its width is not the iPad's, its edges are what is measured.)
        let looks: [(name: String, ink: ([CGPoint]) -> PKStroke)] = [
            ("fountain pen", { self.stroke(.fountainPen, size: 2 + self.drawn / 2, through: $0) }),
            ("monoline", { self.stroke(.monoline, size: 3, through: $0) }),
        ]
        var live: [Bars] = []
        var committed: [[Bars]] = looks.map { _ in [] }
        var sharp: [[Bars]] = looks.map { _ in [] }
        for placement in placements {
            let points = barPoints(k: k, visible: visible, placement: placement)
            let canvas = PresentCanvasView(frame: CGRect(origin: .zero, size: canvasSize))
            canvas.wantsLayer = true
            canvas.scaleOverride = 1
            canvas.inkBudget = PresentInkBudget(total: 96_000_000)
            var revision: UInt64 = 0
            var seq: UInt64 = 2
            var scene = PresentScene()
            scene.linkOpened()
            var first = frame(seq: 1, visible: visible)
            first.reset = true
            first.assets = [paper]
            _ = scene.apply(first)
            // Pencil down: the live stroke, a vector path.
            var down = frame(seq: 2, visible: visible)
            down.live = [.begin(id: 1, pageIndex: 0, rgba: rgba, width: drawn, points: PresentPoints(points))]
            _ = scene.apply(down)
            canvas.render(scene, status: .connected)
            live.append(bars(try gpuPixels(canvas), points: points, visible: visible))
            // Lifted: the live stroke ends and the stroke lands as committed ink.
            for (index, look) in looks.enumerated() {
                let ink = PKDrawing(strokes: [look.ink(points)])
                if merged {
                    // Strokes written before it, elsewhere on the page, each landing on its own.
                    for i in 0..<PresentPageLayers.maxSegmentLayers {
                        let y = 40 + CGFloat(i) * 9
                        let earlier = PKDrawing(strokes: [look.ink([CGPoint(x: 20, y: y), CGPoint(x: 60, y: y + 4), CGPoint(x: 90, y: y)])])
                        seq += 1
                        var update = frame(seq: seq, visible: visible)
                        update.ink = [PresentInkChange(pageIndex: 0, revision: revision + 1, mode: i == 0 ? .replace : .append,
                                                       base: i == 0 ? nil : revision, drawing: earlier.dataRepresentation())]
                        revision += 1
                        _ = scene.apply(update)
                        canvas.render(scene, status: .connected)
                    }
                }
                seq += 1
                var lift = frame(seq: seq, visible: visible)
                if index == 0 { lift.live = [.end(id: 1)] }
                lift.ink = [PresentInkChange(pageIndex: 0, revision: revision + 1, mode: merged ? .append : .replace,
                                             base: merged ? revision : nil, drawing: ink.dataRepresentation())]
                revision += 1
                _ = scene.apply(lift)
                canvas.render(scene, status: .connected)
                if merged {
                    let layers = try XCTUnwrap(canvas.pages[0])
                    XCTAssertTrue(layers.isMerging, "more segments than a page keeps: merging", file: file, line: line)
                    wait(for: layers, file: file, line: line)
                    XCTAssertLessThan(layers.ink.sublayers?.count ?? 0, PresentPageLayers.maxSegmentLayers, "merged", file: file, line: line)
                }
                committed[index].append(bars(try gpuPixels(canvas), points: points, visible: visible))
                sharp[index].append(bars(try straightPixels(ink, k: k, visible: visible), points: points, visible: visible))
            }
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let liveRamp = (across: mean(live.map(\.across.ramp)), down: mean(live.map(\.down.ramp)))
        for (index, look) in looks.enumerated() {
            let ramp = (across: mean(committed[index].map(\.across.ramp)), down: mean(committed[index].map(\.down.ramp)))
            let peak = (across: mean(committed[index].map(\.across.peak)), down: mean(committed[index].map(\.down.peak)))
            let best = (across: mean(sharp[index].map(\.across.peak)), down: mean(sharp[index].map(\.down.peak)))
            let summary = String(format: "k %.1f %@%@: ramp live %.2f / %.2f px, committed %.2f / %.2f px; peak committed %.2f / %.2f of sharp %.2f / %.2f",
                                 k, look.name, merged ? " merged" : "", liveRamp.across, liveRamp.down, ramp.across, ramp.down,
                                 peak.across, peak.down, best.across, best.down)
            print("EP156 \(summary)")
            for (bar, before, after, dark, ideal) in [("vertical", liveRamp.across, ramp.across, peak.across, best.across),
                                                      ("horizontal", liveRamp.down, ramp.down, peak.down, best.down)] {
                XCTAssertFalse(after.isNaN, "\(bar) bar measured: \(summary)", file: file, line: line)
                XCTAssertLessThanOrEqual(after, before + rampSlack, "\(bar) bar's edges as sharp as live: \(summary)",
                                         file: file, line: line)
                XCTAssertGreaterThanOrEqual(dark, leastPeak * ideal, "\(bar) bar keeps its darkness: \(summary)",
                                            file: file, line: line)
            }
        }
    }

    /// A vertical bar (measured across, left to right), then a horizontal one (measured top to bottom), in page points,
    /// each centred `placement` canvas pixels past a pixel's centre.
    private func barPoints(k: CGFloat, visible: CGRect, placement: CGFloat) -> [CGPoint] {
        let x0 = visible.midX + (0.5 + placement) / k, y0 = visible.minY + 30 + (0.5 + placement) / k
        var points: [CGPoint] = []
        for i in 0...60 { points.append(CGPoint(x: x0, y: y0 + CGFloat(i))) }
        for i in 1...60 { points.append(CGPoint(x: x0 + CGFloat(i), y: y0 + 60)) }
        return points
    }

    private func frame(seq: UInt64, visible: CGRect) -> PresentUpdate {
        let view = PresentedView(screen: .page(.init(
            documentID: documentID, framing: "presenterPage", focusedPageIndex: 0,
            visibleRect: visible, margin: 0,
            pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: a4), inkRevision: 0)],
            liveStrokes: [], laser: nil, laserTrail: [])))
        var update = PresentUpdate(seq: seq)
        update.frame = PresentFrame(view: view, session: session, pages: [PresentPageRef(pageIndex: 0, asset: paper.hash, size: a4)])
        return update
    }

    private func stroke(_ type: PKInk.InkType, size: CGFloat, through points: [CGPoint]) -> PKStroke {
        let color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: 1)
        let controls = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.008, size: CGSize(width: size, height: size), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(type, color: color),
                        path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000)))
    }

    /// One line of darkness across a bar (0 white … 1 full ink): its 10–90 % edge ramp, both edges averaged, in
    /// canvas pixels, and its darkest point.
    private struct Profile { let ramp: Double; let peak: Double }
    private struct Bars { let across: Profile; let down: Profile }

    /// A canvas-sized picture's red channel, rows top first.
    private struct Pixels { let width: Int; let red: (_ x: Int, _ yTop: Int) -> Double }

    /// Darkness across the vertical bar (along a canvas row) and across the horizontal bar (along a column).
    private func bars(_ pixels: Pixels, points: [CGPoint], visible: CGRect) -> Bars {
        // The visible rect fills the canvas (same aspect).
        let s = canvasSize.width / visible.width
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - visible.minX) * s, y: (p.y - visible.minY) * s) }
        let top = px(points[0]), corner = px(points[60]), end = px(points[points.count - 1])
        func measure(_ line: [Double]) -> Profile {
            let dark = line.map { max(0, (255 - $0) / (255 - 255 * Double(rgba[0]))) }
            let peak = dark.max() ?? 0
            func crossings(_ level: Double) -> [Double] {
                var found: [Double] = []
                for i in 1..<dark.count where (dark[i - 1] - level) * (dark[i] - level) < 0 {
                    found.append(Double(i - 1) + (level - dark[i - 1]) / (dark[i] - dark[i - 1]))
                }
                return found
            }
            let low = crossings(peak * 0.1), high = crossings(peak * 0.9)
            guard low.count >= 2, high.count >= 2 else { return Profile(ramp: .nan, peak: peak) }
            return Profile(ramp: ((high[0] - low[0]) + (low[low.count - 1] - high[high.count - 1])) / 2, peak: peak)
        }
        let row = Int(((top.y + corner.y) / 2).rounded())
        let across = measure((Int(top.x) - 15...Int(top.x) + 15).map { pixels.red($0, row) })
        let column = Int(((corner.x + end.x) / 2).rounded())
        let down = measure((Int(corner.y) - 15...Int(corner.y) + 15).map { pixels.red(column, $0) })
        return Bars(across: across, down: down)
    }

    /// `ink` drawn by PencilKit straight onto white at the canvas's own pixels: as sharp as the ink can be drawn.
    private func straightPixels(_ ink: PKDrawing, k: CGFloat, visible: CGRect) throws -> Pixels {
        var made: CGImage?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            made = ink.image(from: visible, scale: k).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let image = try XCTUnwrap(made)
        let w = image.width, h = image.height
        XCTAssertEqual(w, Int(canvasSize.width))
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(context.data)
        let rgba = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        // A bitmap context's memory runs top row first.
        return Pixels(width: w) { x, yTop in Double(rgba[(yTop * w + x) * 4]) }
    }

    /// Draws the canvas's layers on the GPU, as the lesson recorder (`PresentFrameRenderer`) does.
    private func gpuPixels(_ canvas: PresentCanvasView) throws -> Pixels {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                 kCARendererMetalCommandQueue: queue])
        renderer.layer = try XCTUnwrap(canvas.layer)
        renderer.bounds = CGRect(origin: .zero, size: canvasSize)
        for _ in 0..<2 {
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            let done = try XCTUnwrap(queue.makeCommandBuffer())
            done.commit()
            done.waitUntilCompleted()
        }
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // The texture's rows run bottom up here; red is a BGRA pixel's third byte.
        return Pixels(width: w) { x, yTop in Double(bgra[((h - 1 - yTop) * w + x) * 4 + 2]) }
    }
}
