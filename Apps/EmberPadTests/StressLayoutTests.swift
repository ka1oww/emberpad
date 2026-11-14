import XCTest
@testable import EmberPad

/// EP122: on the teacher's iPad, standing in landscape, the stress test wrote the lower rows of four scenarios below
/// the bottom of the screen, where they could never be seen to land, and reported them as strokes the page never drew.
/// The rows are now kept on the part of the page the screen shows.
final class StressLayoutTests: XCTestCase {
    /// The iPad Air in landscape (1180 by 820 points, ink scale 1.79) shows the page down to about 458 points. The
    /// rows that failed there (the tool switches' rows 6 to 8 at 500 to 632, the palette's moves 5 and 6 at 490 and
    /// 570, the pen after the trail laser at 470, the stroke after the undos at 480) all end up on the screen, in order,
    /// still apart, and the first row stays where it was.
    func testRowsBelowALandscapeScreenCloseUpOntoIt() {
        let floor: CGFloat = 458 - StressGate.rowMargin
        let layouts: [[CGFloat]] = [(0..<8).map { 170 + CGFloat($0) * 66 }, (0..<6).map { 170 + CGFloat($0) * 80 },
                                    [320, 470], [220, 310, 480]]
        for ys in layouts {
            let fitted = StressGate.fit(ys, above: floor)
            XCTAssertEqual(fitted.first, ys.first, "the first row stays put: \(ys)")
            XCTAssertLessThanOrEqual(fitted.max() ?? .infinity, floor, "every row is on the screen: \(fitted)")
            XCTAssertEqual(fitted, fitted.sorted(), "the rows keep their order")
            let gaps = zip(fitted.dropFirst(), fitted).map { $0 - $1 }
            XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 30, "the rows stay clear of each other: \(fitted)")
        }
    }

    /// Where the screen shows the whole page (an iPad in portrait, as the Simulator runs), the scenarios are unchanged.
    func testRowsThatFitAreKept() {
        let ys = (0..<8).map { 170 + CGFloat($0) * 66 }
        XCTAssertEqual(StressGate.fit(ys, above: 900), ys)
    }

    /// The landscape-shaped window a portrait Simulator lays the page out in: the screen's width, and the height the
    /// screen turned on its side has at that width; a screen already wide is used as it is.
    func testLandscapeWindowHasTheScreenTurnedOnItsSide() {
        let portrait = CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = StressGate.windowFrame(in: portrait, landscape: true)
        XCTAssertEqual(window.width, 834)
        XCTAssertEqual(window.height, 575)
        XCTAssertEqual(StressGate.windowFrame(in: portrait, landscape: false), portrait)
        let wide = CGRect(x: 0, y: 0, width: 1180, height: 820)
        XCTAssertEqual(StressGate.windowFrame(in: wide, landscape: true), wide)
    }
}
