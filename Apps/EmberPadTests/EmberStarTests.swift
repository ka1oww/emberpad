import SwiftUI
import XCTest
@testable import EmberPad

final class EmberStarTests: XCTestCase {
    func testHomeScreenNameIsEmberSlate() {
        XCTAssertEqual(Bundle(for: LibraryController.self).object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                       "Ember Slate")
    }

    func testStarFillsHeightAndKeepsCanonicalProportions() {
        let bounds = EmberStar().path(in: CGRect(x: 0, y: 0, width: 200, height: 100)).boundingRect
        XCTAssertEqual(bounds.height, 100, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 81.24, accuracy: 0.001)
        XCTAssertEqual(bounds.midX, 100, accuracy: 0.001)
        XCTAssertEqual(bounds.midY, 50, accuracy: 0.001)
    }

    func testTopPointIsAtTopOfFrame() {
        let path = EmberStar().path(in: CGRect(x: 0, y: 0, width: 81.24, height: 100))
        XCTAssertTrue(path.contains(CGPoint(x: 40.62, y: 2)))
        XCTAssertFalse(path.contains(CGPoint(x: 5, y: 5)))
    }
}
