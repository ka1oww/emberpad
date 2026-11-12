import CoreGraphics
import Foundation

/// EP90 synthetic fixtures for scribble to erase: handwritten words, scribbles as an Apple Pencil samples them, and
/// handwriting that must stay ink. Pure geometry in page points (x-height about 20 pt at 1x), so the detector can be
/// tested without touches or views. Nothing here comes from a real page.
enum ScribbleFixtures {
    // MARK: - The Pencil

    /// Apple Pencil's sample rate, in hertz.
    static let pencilRate: CGFloat = 240

    /// The points an Apple Pencil reports along the path through `corners`, drawn at `speed` points a second: the
    /// turns rounded over `rounding` points as a moving hand rounds them, the Pencil slowing to a third of its speed
    /// into each turn, a sample every 1/240 s, and the hand's tremor of up to `tremor` points. `seed` makes the
    /// tremor repeatable.
    static func pencil(_ corners: [CGPoint], speed: CGFloat = 600, rounding: Int = 3, tremor: CGFloat = 0.4,
                       seed: UInt64 = 1) -> [CGPoint] {
        let path = smoothed(dense(corners), radius: rounding)
        guard path.count > 1 else { return path }
        // Distance along the path to the nearest corner, for slowing into turns.
        var arc = [CGFloat](repeating: 0, count: path.count)
        for i in path.indices.dropFirst() { arc[i] = arc[i - 1] + distance(path[i - 1], path[i]) }
        let cornerArcs = cornerPositions(corners, along: path, arc: arc)
        var random = SplitMix(seed: seed)
        var samples = [jittered(path[0], tremor, &random)]
        var travelled: CGFloat = 0
        var index = 1
        while index < path.count {
            let nearest = cornerArcs.map { abs($0 - travelled) }.min() ?? .infinity
            let step = speed / pencilRate * min(1, 0.33 + nearest / 20)
            travelled += step
            while index < path.count - 1, arc[index] < travelled { index += 1 }
            if arc[index] < travelled { break }
            let t = (travelled - arc[index - 1]) / max(arc[index] - arc[index - 1], 0.0001)
            let a = path[index - 1], b = path[index]
            samples.append(jittered(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), tremor, &random))
        }
        samples.append(path[path.count - 1])
        return samples
    }

    // MARK: - Scribbles

    /// A zigzag of `peaks` up-and-down strokes from `x0` to `x1` between `top` and `bottom`; `lean` slants each
    /// stroke by that many points, as a quick hand does.
    static func zigzag(from x0: CGFloat, to x1: CGFloat, top: CGFloat, bottom: CGFloat, peaks: Int, lean: CGFloat = 0,
                       uneven: CGFloat = 0) -> [CGPoint] {
        let turns = 2 * peaks
        return (0...turns).map { i in
            let t = CGFloat(i) / CGFloat(turns)
            let x = x0 + (x1 - x0) * t + (i % 2 == 0 ? -lean : lean) / 2 + uneven * sin(CGFloat(i) * 2.3)
            let y = (i % 2 == 0 ? bottom : top) + (i % 2 == 0 ? 1 : -1) * uneven * 0.6 * sin(CGFloat(i) * 1.7)
            return CGPoint(x: x, y: y)
        }
    }

    /// A scrub of `passes` lines back and forth from `x0` to `x1`, starting at `y` and moving down `drop` points a
    /// pass, each turn overshooting or falling short by up to `uneven` points.
    static func scrub(from x0: CGFloat, to x1: CGFloat, y: CGFloat, passes: Int, drop: CGFloat, uneven: CGFloat = 0)
        -> [CGPoint] {
        (0...passes).map { i in
            let x = (i % 2 == 0 ? x0 : x1) + uneven * sin(CGFloat(i) * 2.9)
            return CGPoint(x: x, y: y + CGFloat(i) * drop)
        }
    }

    /// Joined loops along a line from `x0` to `x1`, centred on `y`, `radius` high, as a cursive "llllll".
    static func loops(from x0: CGFloat, to x1: CGFloat, y: CGFloat, radius: CGFloat, count: Int) -> [CGPoint] {
        let advance = (x1 - x0) / CGFloat(count)
        return (0...count * 24).map { i in
            let t = CGFloat(i) / 24 * 2 * .pi
            return CGPoint(x: x0 + advance * t / (2 * .pi) - radius * 0.5 * sin(t), y: y + radius * cos(t))
        }
    }

    /// An untidy scrub over `box`: back and forth `passes` times, each pass at its own slant and length, as a hand
    /// rubbing something out in a hurry. Repeatable from `seed`.
    static func messy(over box: CGRect, passes: Int, seed: UInt64) -> [CGPoint] {
        var random = SplitMix(seed: seed)
        return (0...passes).map { i in
            let side: CGFloat = i % 2 == 0 ? box.minX : box.maxX
            let x = side + (random.unit() - 0.5) * 0.3 * box.width
            let y = box.minY + random.unit() * box.height
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: - Handwriting

    /// A handwritten letter: its strokes as corner points, x-height 20 with the top of the x-height at 0, ascenders
    /// up to -16 and descenders down to 36; and how far the pen moves on to the next letter.
    struct Letter {
        let strokes: [[CGPoint]]
        let advance: CGFloat
    }

    static let letters: [Character: Letter] = [
        "a": Letter(strokes: [pts([(14, 4), (8, 0), (2, 3), (0, 10), (2, 17), (8, 20), (14, 15), (14, 0), (14, 20)])], advance: 19),
        "d": Letter(strokes: [pts([(14, 4), (8, 0), (2, 3), (0, 10), (2, 17), (8, 20), (14, 15), (14, -16), (14, 20)])], advance: 19),
        "e": Letter(strokes: [pts([(0, 10), (14, 10), (13, 4), (8, 0), (3, 1), (0, 6), (0, 13), (3, 18), (8, 20), (14, 17)])], advance: 18),
        "g": Letter(strokes: [pts([(14, 4), (8, 0), (2, 3), (0, 10), (2, 17), (8, 20), (14, 15), (14, 0), (14, 30), (10, 36),
                                    (3, 34), (0, 30)])], advance: 19),
        "h": Letter(strokes: [pts([(0, -16), (0, 20), (0, 8), (4, 2), (9, 1), (12, 5), (12, 20)])], advance: 17),
        "i": Letter(strokes: [pts([(0, 0), (0, 20)]), pts([(0, -9), (0.5, -8.5)])], advance: 6),
        "l": Letter(strokes: [pts([(0, 20), (6, 8), (8, -16), (5, -18), (2, -14), (3, 8), (8, 20)])], advance: 11),
        "m": Letter(strokes: [pts([(0, 0), (0, 20), (0, 4), (2, 1), (5.5, 0), (9, 1), (11, 5), (11, 20), (11, 4), (13, 1),
                                    (16.5, 0), (20, 1), (22, 5), (22, 20)])], advance: 27),
        "n": Letter(strokes: [pts([(0, 0), (0, 20), (0, 4), (2, 1), (5.5, 0), (9, 1), (11, 5), (11, 20)])], advance: 16),
        "o": Letter(strokes: [pts([(8, 0), (2, 3), (0, 10), (2, 17), (8, 20), (14, 17), (16, 10), (14, 3), (8, 0)])], advance: 20),
        "r": Letter(strokes: [pts([(0, 0), (0, 20), (0, 8), (4, 2), (10, 0)])], advance: 13),
        "s": Letter(strokes: [pts([(12, 2), (6, 0), (1, 3), (2, 8), (11, 12), (12, 17), (6, 20), (0, 18)])], advance: 16),
        "t": Letter(strokes: [pts([(5, -10), (5, 17), (8, 20), (11, 18)]), pts([(0, 0), (11, 0)])], advance: 14),
        "u": Letter(strokes: [pts([(0, 0), (0, 14), (2, 19), (6, 20), (10, 18), (12, 14), (12, 0), (12, 20)])], advance: 17),
        "w": Letter(strokes: [pts([(0, 0), (5, 20), (10, 5), (15, 20), (20, 0)])], advance: 25),
        "x": Letter(strokes: [pts([(0, 0), (14, 20)]), pts([(14, 0), (0, 20)])], advance: 19),
        "z": Letter(strokes: [pts([(0, 0), (16, 0), (0, 20), (17, 20)])], advance: 21),
    ]

    /// `text` handwritten from `origin` (the top of its x-height) at `scale`: in print, a stroke per letter stroke;
    /// joined up, each word one stroke, with only dots and crossbars lifted. Each stroke as points every 2 pt.
    static func handwriting(_ text: String, at origin: CGPoint, scale: CGFloat = 1, joined: Bool = false) -> [[CGPoint]] {
        var strokes: [[CGPoint]] = []
        var x: CGFloat = 0
        var running: [CGPoint] = []
        for character in text {
            guard let letter = letters[character] else {
                if !running.isEmpty { strokes.append(running); running = [] }
                x += 12
                continue
            }
            let placed = letter.strokes.map { $0.map { CGPoint(x: origin.x + (x + $0.x) * scale, y: origin.y + $0.y * scale) } }
            if joined {
                running += placed[0]
                strokes += placed.dropFirst()
            } else {
                strokes += placed
            }
            x += letter.advance
        }
        if !running.isEmpty { strokes.append(running) }
        return strokes.map { resample(smoothed(dense($0), radius: 1), spacing: 2) }
    }

    /// The box round `strokes`.
    static func box(_ strokes: [[CGPoint]]) -> CGRect {
        strokes.flatMap { $0 }.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    // MARK: - Geometry helpers

    static func pts(_ xy: [(CGFloat, CGFloat)]) -> [CGPoint] { xy.map { CGPoint(x: $0.0, y: $0.1) } }

    /// Points every 1 pt along the polyline through `corners`.
    static func dense(_ corners: [CGPoint]) -> [CGPoint] {
        guard var last = corners.first else { return [] }
        var points = [last]
        for corner in corners.dropFirst() {
            let steps = max(1, Int(distance(last, corner).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: last.x + (corner.x - last.x) * t, y: last.y + (corner.y - last.y) * t))
            }
            last = corner
        }
        return points
    }

    /// The points averaged over `radius` points either side, so corners are rounded.
    static func smoothed(_ points: [CGPoint], radius: Int) -> [CGPoint] {
        guard radius > 0 else { return points }
        return points.indices.map { i in
            let window = points[max(0, i - radius)...min(points.count - 1, i + radius)]
            let n = CGFloat(window.count)
            return CGPoint(x: window.reduce(0) { $0 + $1.x } / n, y: window.reduce(0) { $0 + $1.y } / n)
        }
    }

    static func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        var last = first
        for point in points.dropFirst() where distance(last, point) >= spacing {
            result.append(point)
            last = point
        }
        if let end = points.last, result.last != end { result.append(end) }
        return result
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    private static func cornerPositions(_ corners: [CGPoint], along path: [CGPoint], arc: [CGFloat]) -> [CGFloat] {
        corners.dropFirst().dropLast().map { corner in
            let nearest = path.indices.min { distance(path[$0], corner) < distance(path[$1], corner) } ?? 0
            return arc[nearest]
        }
    }

    private static func jittered(_ point: CGPoint, _ tremor: CGFloat, _ random: inout SplitMix) -> CGPoint {
        CGPoint(x: point.x + (random.unit() - 0.5) * 2 * tremor, y: point.y + (random.unit() - 0.5) * 2 * tremor)
    }

    /// A small repeatable random number generator.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// A number in 0..<1.
        mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    }
}

// MARK: - Cases

extension ScribbleFixtures {
    /// One page and one stroke drawn on it: the strokes already on the page, the new stroke as the Pencil sampled it,
    /// and the strokes it must erase (none for handwriting).
    struct Case {
        let name: String
        let page: [[CGPoint]]
        let stroke: [CGPoint]
        let erases: [Int]
    }

    /// Scribbles a teacher makes to rub out a word just written, over words in print and joined up, small and large,
    /// slow and fast. Each erases the whole word and nothing on the lines above and below or the word beside it.
    static var scribbles: [Case] {
        var cases: [Case] = []
        let words = ["hello", "mown", "dogs", "rule"]
        for (w, word) in words.enumerated() {
            for scale in [CGFloat(0.6), 1, 1.6] {
                for joined in [false, true] {
                    let origin = CGPoint(x: 120, y: 300)
                    let written = handwriting(word, at: origin, scale: scale, joined: joined)
                    let above = handwriting("such", at: CGPoint(x: 120, y: 300 - 46 * scale), scale: scale, joined: joined)
                    let below = handwriting("more", at: CGPoint(x: 120, y: 300 + 46 * scale), scale: scale, joined: joined)
                    let wordBox = box(written)
                    let beside = handwriting("an", at: CGPoint(x: wordBox.maxX + 16 * scale, y: 300), scale: scale, joined: joined)
                    let page = above + written + below + beside
                    let target = Array(above.count..<(above.count + written.count))
                    // The x-height band, with a little overshoot, as a hand scribbles over a word.
                    let x0 = wordBox.minX - 3 * scale, x1 = wordBox.maxX + 3 * scale
                    let top = 300 - 4 * scale, bottom = 300 + 24 * scale, mid = 300 + 10 * scale
                    let seed = UInt64(w * 100) + UInt64(scale * 10) + (joined ? 7 : 0)
                    let shapes: [(String, [CGPoint])] = [
                        ("tight zigzag", zigzag(from: x0, to: x1, top: top, bottom: bottom, peaks: 7, uneven: 2 * scale)),
                        ("loose zigzag", zigzag(from: x0, to: x1, top: top, bottom: bottom, peaks: 3, lean: 10 * scale, uneven: 3 * scale)),
                        ("two-peak zigzag", zigzag(from: x0, to: x1, top: top, bottom: bottom, peaks: 2, lean: 8 * scale)),
                        ("loops", loops(from: x0 + 6 * scale, to: x1 - 6 * scale, y: mid, radius: 13 * scale, count: 6)),
                        ("3-pass scrub", scrub(from: x0, to: x1, y: mid - 4 * scale, passes: 3, drop: 4 * scale, uneven: 4 * scale)),
                        ("flat 4-pass scrub", scrub(from: x0, to: x1, y: mid, passes: 4, drop: 0.5 * scale, uneven: 5 * scale)),
                        ("tall scrub", scrub(from: x0, to: x1, y: top, passes: 6, drop: 5 * scale, uneven: 4 * scale)),
                        ("messy scrub", messy(over: CGRect(x: x0, y: top + 2 * scale, width: x1 - x0, height: bottom - top - 4 * scale),
                                              passes: 6, seed: seed)),
                    ]
                    for (shape, corners) in shapes {
                        for speed in [CGFloat(350), 900, 1600] {
                            let stroke = pencil(corners, speed: speed * scale, rounding: Int(3 * scale + 1), seed: seed + UInt64(speed))
                            cases.append(Case(name: "\(shape) over \(joined ? "joined" : "print") \"\(word)\" at \(scale)x, \(Int(speed)) pt/s",
                                              page: page, stroke: stroke, erases: target))
                        }
                    }
                }
            }
        }
        // A quick scrub of three passes over one short word, and a small zigzag over one letter.
        for scale in [CGFloat(0.6), 1, 1.6] {
            let short = handwriting("on", at: CGPoint(x: 200, y: 300), scale: scale)
            let shortBox = box(short)
            let neighbours = handwriting("be", at: CGPoint(x: shortBox.maxX + 14 * scale, y: 300), scale: scale)
            let scrubbed = scrub(from: shortBox.minX - 2 * scale, to: shortBox.maxX + 2 * scale, y: 300 + 6 * scale, passes: 3,
                                 drop: 4 * scale)
            cases.append(Case(name: "3-pass scrub over \"on\" at \(scale)x", page: short + neighbours,
                              stroke: pencil(scrubbed, speed: 700 * scale), erases: Array(short.indices)))
            let letter = handwriting("a", at: CGPoint(x: 200, y: 300), scale: scale)
            let small = zigzag(from: 198, to: 200 + 16 * scale, top: 300 - 2 * scale, bottom: 300 + 22 * scale, peaks: 2)
            cases.append(Case(name: "small zigzag over \"a\" at \(scale)x", page: letter + neighbours,
                              stroke: pencil(small, speed: 500 * scale), erases: [0]))
        }
        return cases
    }

    /// Writing and drawing near, beside, round or touching ink, which must stay as ink and erase nothing: letters a
    /// scribble's shape (m, n, u, w, joined-up "minimum"), underlines, a word crossed out with one line, a lasso loop,
    /// shading and writing across a ruled line.
    static var handwritingNearInk: [Case] {
        var cases: [Case] = []
        for scale in [CGFloat(0.6), 1, 1.6] {
            for speed in [CGFloat(150), 400] {
                let origin = CGPoint(x: 120, y: 300)
                let first = handwriting("rat", at: origin, scale: scale, joined: true)
                let firstBox = box(first)
                // A word written next on the line, a little apart, and one whose first stroke starts on the last word's
                // last letter (joined writing).
                for text in ["minimum", "mum", "www", "nun", "mow", "zoo", "unwound"] {
                    for (gap, label) in [(CGFloat(10), "apart"), (CGFloat(-4), "touching")] {
                        let next = handwriting(text, at: CGPoint(x: firstBox.maxX + gap * scale, y: 300), scale: scale, joined: true)
                        cases.append(Case(name: "\"\(text)\" written \(label) after a word at \(scale)x, \(Int(speed)) pt/s",
                                          page: first, stroke: pencil(next[0], speed: speed * scale, rounding: 1), erases: []))
                    }
                    // The same on the line below, its tall letters reaching into the descenders above.
                    let under = handwriting("gag", at: CGPoint(x: 120, y: 300), scale: scale, joined: true)
                    let below = handwriting(text, at: CGPoint(x: 116, y: 300 + 34 * scale), scale: scale, joined: true)
                    cases.append(Case(name: "\"\(text)\" written under descenders at \(scale)x, \(Int(speed)) pt/s",
                                      page: under, stroke: pencil(below[0], speed: speed * scale, rounding: 1), erases: []))
                }
                // "m" after a "t" whose bar reaches into it.
                let t = handwriting("t", at: origin, scale: scale)
                let m = handwriting("m", at: CGPoint(x: origin.x + 9 * scale, y: 300), scale: scale)
                cases.append(Case(name: "\"m\" through a t's bar at \(scale)x, \(Int(speed)) pt/s", page: t,
                                  stroke: pencil(m[0], speed: speed * scale, rounding: 1), erases: []))
                // A word written across a long ruled line.
                let rule = dense([CGPoint(x: 80, y: 310 * 1), CGPoint(x: 480, y: 310)])
                let across = handwriting("minimum", at: CGPoint(x: 140, y: 300), scale: scale, joined: true)
                cases.append(Case(name: "\"minimum\" written across a ruled line at \(scale)x, \(Int(speed)) pt/s", page: [rule],
                                  stroke: pencil(across[0], speed: speed * scale, rounding: 1), erases: []))
                // Underlines: once, there and back, and there, back and there again under descenders.
                let words = handwriting("gap dog", at: origin, scale: scale)
                let wordsBox = box(words)
                let line = 300 + 28 * scale
                for passes in [1, 2, 3] {
                    let underline = scrub(from: wordsBox.minX - 4, to: wordsBox.maxX + 4, y: line, passes: passes, drop: 1.5 * scale)
                    cases.append(Case(name: "underline of \(passes) pass(es) through descenders at \(scale)x, \(Int(speed)) pt/s",
                                      page: words, stroke: pencil(underline, speed: speed * 2 * scale), erases: []))
                }
                // One line crossing a word out.
                let strike = dense([CGPoint(x: wordsBox.minX - 4, y: 300 + 10 * scale), CGPoint(x: wordsBox.maxX + 4, y: 300 + 11 * scale)])
                cases.append(Case(name: "a word crossed out with one line at \(scale)x, \(Int(speed)) pt/s", page: words,
                                  stroke: pencil(strike, speed: speed * 2 * scale), erases: []))
                // A lasso loop round the words, going on past where it started.
                let center = CGPoint(x: wordsBox.midX, y: wordsBox.midY)
                let loop = (0...100).map { i -> CGPoint in
                    let angle = CGFloat(i) / 100 * 2 * .pi * 1.35
                    return CGPoint(x: center.x + (wordsBox.width / 2 + 14 * scale) * cos(angle),
                                   y: center.y + (wordsBox.height / 2 + 14 * scale) * sin(angle))
                }
                cases.append(Case(name: "a lasso loop and a quarter round words at \(scale)x, \(Int(speed)) pt/s", page: words,
                                  stroke: pencil(loop, speed: speed * 3 * scale), erases: []))
                // Joined-up m's written over a full stop.
                let stop = dense([CGPoint(x: 160, y: 318 * 1), CGPoint(x: 161, y: 318)])
                let mmm = handwriting("mmm", at: CGPoint(x: 140, y: 300), scale: scale, joined: true)
                cases.append(Case(name: "\"mmm\" over a full stop at \(scale)x, \(Int(speed)) pt/s", page: [stop],
                                  stroke: pencil(mmm[0], speed: speed * scale, rounding: 1), erases: []))
            }
        }
        // A skeletal formula: a zigzag chain of bonds drawn on from a ring, and shading under a curve that touches it.
        for scale in [CGFloat(0.6), 1, 1.6] {
            let ring = (0...6).map { i -> CGPoint in
                let angle = CGFloat(i) / 6 * 2 * .pi + .pi / 6
                return CGPoint(x: 200 + 20 * scale * cos(angle), y: 400 + 20 * scale * sin(angle))
            }
            let start = ring[0]
            let chain = (0...6).map { i in
                CGPoint(x: start.x + CGFloat(i) * 17 * scale, y: start.y + (i % 2 == 0 ? 0 : -10 * scale))
            }
            cases.append(Case(name: "a carbon chain drawn on from a ring at \(scale)x", page: [dense(ring)],
                              stroke: pencil(chain, speed: 300 * scale, rounding: 1), erases: []))
        }
        let curve = (0...100).map { i in CGPoint(x: 100 + CGFloat(i) * 1.6, y: 700 - 60 * sin(CGFloat(i) / 100 * .pi)) }
        let underCurve = (0...16).map { i -> CGPoint in
            let x = 104 + CGFloat(i) * 9.5
            return CGPoint(x: x, y: i % 2 == 0 ? 700 : 702 - 60 * sin((x - 100) / 160 * .pi))
        }
        cases.append(Case(name: "shading under a curve up to it", page: [dense(curve)], stroke: pencil(underCurve, speed: 900),
                          erases: []))
        // Shading inside a box in a diagram: the box is only touched at the turns.
        let box = dense([CGPoint(x: 100, y: 500), CGPoint(x: 220, y: 500), CGPoint(x: 220, y: 580), CGPoint(x: 100, y: 580),
                         CGPoint(x: 100, y: 500)])
        let shading = zigzag(from: 104, to: 216, top: 504, bottom: 576, peaks: 9)
        cases.append(Case(name: "shading inside a box", page: [box], stroke: pencil(shading, speed: 900), erases: []))
        return cases
    }

    /// Scribbles over empty paper, away from any ink: they stay as ink.
    static var scribblesOverEmptyPaper: [Case] {
        let ink = handwriting("hello", at: CGPoint(x: 120, y: 600))
        return [
            Case(name: "zigzag over empty paper", page: ink,
                 stroke: pencil(zigzag(from: 120, to: 220, top: 296, bottom: 324, peaks: 6), speed: 900), erases: []),
            Case(name: "scrub over empty paper", page: ink,
                 stroke: pencil(scrub(from: 120, to: 220, y: 306, passes: 3, drop: 4), speed: 900), erases: []),
            Case(name: "zigzag on a blank page", page: [],
                 stroke: pencil(zigzag(from: 120, to: 220, top: 296, bottom: 324, peaks: 6), speed: 900), erases: []),
        ]
    }
}
