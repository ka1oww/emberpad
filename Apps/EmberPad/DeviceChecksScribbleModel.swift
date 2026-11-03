#if DEBUG
import Foundation
import PencilKit

/// EP-27 debug scribble sample recorder: non-UI core.
///
/// A sample is one PencilKit drawing the captain labelled `erase` (a scribble
/// meant to rub something out) or `keep` (real writing or a chemistry drawing).
/// Samples export as one versioned JSON document for tuning the EP-28
/// recogniser. Nothing here touches the network.

enum ScribbleLabel: String, Codable, CaseIterable, Equatable {
    case erase
    case keep
}

struct ScribblePoint: Codable, Equatable {
    var x: Double
    var y: Double
    /// Seconds since the first point of the stroke.
    var timeOffset: Double
    var force: Double
    /// Radians.
    var azimuth: Double
    /// Radians.
    var altitude: Double
}

struct ScribbleStroke: Codable, Equatable {
    var points: [ScribblePoint]
}

struct ScribbleSample: Codable, Equatable {
    var id: String
    var label: ScribbleLabel
    var strokes: [ScribbleStroke]

    init(id: String = UUID().uuidString, label: ScribbleLabel, strokes: [ScribbleStroke]) {
        self.id = id
        self.label = label
        self.strokes = strokes
    }

    /// Captures raw points from a drawing. Timestamps become offsets from each
    /// stroke's first point so exports carry no wall-clock time.
    init(id: String = UUID().uuidString, label: ScribbleLabel, drawing: PKDrawing) {
        let strokes = drawing.strokes.map { stroke -> ScribbleStroke in
            let start = stroke.path.first?.timeOffset ?? 0
            let points = stroke.path.map { point in
                ScribblePoint(
                    x: Double(point.location.x), y: Double(point.location.y),
                    timeOffset: point.timeOffset - start,
                    force: Double(point.force),
                    azimuth: Double(point.azimuth), altitude: Double(point.altitude))
            }
            return ScribbleStroke(points: points)
        }
        self.init(id: id, label: label, strokes: strokes)
    }
}

struct ScribbleSampleSet: Codable, Equatable {
    static let schema = "ember.scribble-samples/v1"

    var schema: String
    var samples: [ScribbleSample]

    init(samples: [ScribbleSample]) {
        self.schema = Self.schema
        self.samples = samples
    }
}

enum ScribbleSampleCodec {
    enum CodecError: Error, Equatable {
        case unsupportedSchema(String)
    }

    static let fileName = "scribble-samples.json"

    static func encode(_ set: ScribbleSampleSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(set)
    }

    static func decode(_ data: Data) throws -> ScribbleSampleSet {
        let set = try JSONDecoder().decode(ScribbleSampleSet.self, from: data)
        guard set.schema == ScribbleSampleSet.schema else { throw CodecError.unsupportedSchema(set.schema) }
        return set
    }

    /// Writes the export into a fresh temporary file for the Files share sheet.
    static func writeExport(_ set: ScribbleSampleSet, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        try encode(set).write(to: url, options: .atomic)
        return url
    }
}
#endif
