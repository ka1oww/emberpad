#if DEBUG
import PencilKit
import XCTest
@testable import EmberPad

/// EP-27 coverage: the exported scribble JSON round-trips into a fixture.
final class ScribbleSampleTests: XCTestCase {
    /// Small synthetic fixture: no real handwriting.
    static let fixtureJSON = """
    {
      "samples" : [
        {
          "id" : "fixture-erase",
          "label" : "erase",
          "strokes" : [
            { "points" : [
              { "altitude" : 0.8, "azimuth" : 1.5, "force" : 0.4, "timeOffset" : 0, "x" : 10, "y" : 10 },
              { "altitude" : 0.8, "azimuth" : 1.5, "force" : 0.5, "timeOffset" : 0.01, "x" : 30, "y" : 12 },
              { "altitude" : 0.8, "azimuth" : 1.5, "force" : 0.5, "timeOffset" : 0.02, "x" : 12, "y" : 14 }
            ] }
          ]
        },
        {
          "id" : "fixture-keep",
          "label" : "keep",
          "strokes" : [
            { "points" : [
              { "altitude" : 1.0, "azimuth" : 0.5, "force" : 0.3, "timeOffset" : 0, "x" : 50, "y" : 50 },
              { "altitude" : 1.0, "azimuth" : 0.5, "force" : 0.3, "timeOffset" : 0.015, "x" : 70, "y" : 50 }
            ] }
          ]
        }
      ],
      "schema" : "ember.scribble-samples/v1"
    }
    """

    func testFixtureDecodesAndReencodesToSameModel() throws {
        let decoded = try ScribbleSampleCodec.decode(Data(Self.fixtureJSON.utf8))
        XCTAssertEqual(decoded.samples.map(\.label), [.erase, .keep])
        XCTAssertEqual(decoded.samples[0].strokes[0].points.count, 3)
        let again = try ScribbleSampleCodec.decode(ScribbleSampleCodec.encode(decoded))
        XCTAssertEqual(again, decoded)
    }

    func testExportedFileRoundTripsIntoFixture() throws {
        let fixture = try ScribbleSampleCodec.decode(Data(Self.fixtureJSON.utf8))
        let url = try ScribbleSampleCodec.writeExport(fixture)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "scribble-samples.json")
        XCTAssertEqual(try ScribbleSampleCodec.decode(Data(contentsOf: url)), fixture)
    }

    func testDrawingCapturesPointsWithOffsetsRelativeToStrokeStart() throws {
        let ink = PKInk(.pen, color: .black)
        let points = (0..<3).map { i in
            PKStrokePoint(location: CGPoint(x: Double(i) * 10, y: 5), timeOffset: 100 + Double(i) * 0.01,
                          size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 1.2, altitude: 0.9)
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
        let sample = ScribbleSample(id: "s", label: .keep, drawing: PKDrawing(strokes: [stroke]))
        let first = try XCTUnwrap(sample.strokes.first?.points.first)
        XCTAssertEqual(sample.strokes.count, 1)
        XCTAssertEqual(first.timeOffset, 0, accuracy: 1e-9)
        XCTAssertEqual(first.force, 0.5, accuracy: 1e-6)
        XCTAssertEqual(first.azimuth, 1.2, accuracy: 1e-3)
        XCTAssertEqual(first.altitude, 0.9, accuracy: 1e-3)
        let roundTrip = try ScribbleSampleCodec.decode(ScribbleSampleCodec.encode(ScribbleSampleSet(samples: [sample])))
        XCTAssertEqual(roundTrip.samples, [sample])
    }

    func testUnknownSchemaIsRejected() {
        let json = Self.fixtureJSON.replacingOccurrences(of: "ember.scribble-samples/v1", with: "ember.scribble-samples/v9")
        XCTAssertThrowsError(try ScribbleSampleCodec.decode(Data(json.utf8)))
    }
}
#endif
