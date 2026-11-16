#if os(macOS)
import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import EmberSyncKit

/// EP134: the lesson's video file through the real AVAssetWriter, H.264 and the system AAC encoder, fed synthesized
/// PCM in each format a microphone delivers (stereo or mono, 48 or 44.1 kHz) and synthetic frames. EP129's first live
/// lesson with the stereo BOYA mini 2 wrote only empty files: 192 kbit/s per channel asked the AAC encoder for
/// 384 kbit/s, more than it takes for stereo, and it refused when the first audio arrived.
@Suite(.serialized)
struct LessonSegmentWriterTests {
    struct Format: CustomTestStringConvertible, Sendable {
        var channels: Int
        var sampleRate: Double
        var testDescription: String { "\(channels) ch \(Int(sampleRate)) Hz" }
    }

    static let formats = [Format(channels: 2, sampleRate: 48_000), Format(channels: 1, sampleRate: 48_000),
                          Format(channels: 2, sampleRate: 44_100), Format(channels: 1, sampleRate: 44_100)]

    /// Six seconds of a tone and frames: the file finishes, and holds one video and one AAC track of six seconds, in
    /// the microphone's channels and rate.
    @Test(.timeLimit(.minutes(1)), arguments: formats)
    func everyMicrophoneFormatRecordsPlayableAudioAndVideo(_ format: Format) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep134-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = LessonSegmentWriter.Settings()
        settings.width = 640
        settings.height = 360
        settings.fragmentInterval = 1
        settings.channels = format.channels
        settings.sampleRate = format.sampleRate
        let url = root.appendingPathComponent("lesson.mp4")
        let writer = try LessonSegmentWriter(url: url, settings: settings)
        let t0 = CMTime(seconds: 500, preferredTimescale: 48_000)
        try writer.start(at: t0)

        var t = 0.0
        while t < 6 {
            let time = t0 + CMTime(seconds: t, preferredTimescale: 48_000)
            if let frame = writer.makePixelBuffer() {
                LessonRecordingTests.fill(frame, shade: UInt8(Int(t * 40) % 255))
                writer.appendVideo(frame, at: time)
            }
            let frames = Int(format.sampleRate / 10)
            writer.appendAudio(try #require(Self.tone(frames: frames, channels: format.channels, rate: format.sampleRate,
                                                      at: time, writer: writer)))
            t += 0.1
        }
        let finished = await writer.finish(at: t0 + CMTime(seconds: 6, preferredTimescale: 48_000))
        #expect(finished, "the writer finished: \(String(describing: writer.error))")

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 10_000, "the file holds media: \(size) bytes")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 6) < 0.3, "\(duration) s")
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(abs(try await video.load(.timeRange).duration.seconds - 6) < 0.3)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await audio.load(.timeRange).duration.seconds - 6) < 0.2)
        let description = try #require(try await audio.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(Int(asbd.mChannelsPerFrame) == format.channels)
        #expect(asbd.mSampleRate == format.sampleRate)
        #expect(settings.audioBitRate == (format.channels == 2 ? 320_000 : 192_000))
    }

    /// The bit rate is always one the encoder lists for the format: 192 kbit/s per channel where it takes that, else the
    /// most it takes below (stereo tops out at 320 kbit/s).
    @Test(arguments: formats) func theBitRateIsOneTheEncoderTakes(_ format: Format) throws {
        let ranges = LessonAudioBitRate.applicable(sampleRate: format.sampleRate, channels: format.channels)
        #expect(!ranges.isEmpty, "the encoder lists its rates")
        let chosen = LessonAudioBitRate.choose(target: 192_000 * format.channels, sampleRate: format.sampleRate, channels: format.channels)
        #expect(ranges.contains { $0.contains(Double(chosen)) }, "\(chosen) is listed")
        #expect(chosen == (format.channels == 2 ? 320_000 : 192_000))
        #expect(!ranges.contains { $0.contains(384_000) }, "EP129's stereo rate is not one the encoder takes")
        // Below everything it lists: its lowest.
        let lowest = try #require(ranges.map(\.lowerBound).min())
        #expect(LessonAudioBitRate.choose(target: 1_000, sampleRate: format.sampleRate, channels: format.channels) == Int(lowest))
    }

    /// The encoder refusing its settings, as EP129's 384 kbit/s stereo did: the writer starts, then fails when the first
    /// audio arrives, writes nothing, and says why.
    @Test(.timeLimit(.minutes(1))) func aRefusedEncoderFailsTheFileAndSaysWhy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep134-refused-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = LessonSegmentWriter.Settings()
        settings.width = 640
        settings.height = 360
        settings.channels = 2
        settings.fixedAudioBitRate = 384_000
        let writer = try LessonSegmentWriter(url: root.appendingPathComponent("lesson.mp4"), settings: settings)
        let t0 = CMTime(seconds: 10, preferredTimescale: 48_000)
        try writer.start(at: t0)
        #expect(writer.failure == nil, "it starts as if all were well")
        var t = 0.0
        while t < 1, writer.failure == nil {
            let time = t0 + CMTime(seconds: t, preferredTimescale: 48_000)
            if let frame = writer.makePixelBuffer() { writer.appendVideo(frame, at: time) }
            if let sample = Self.tone(frames: 4_800, channels: 2, rate: 48_000, at: time, writer: writer) { writer.appendAudio(sample) }
            try await Task.sleep(for: .milliseconds(100))
            t += 0.1
        }
        let failure = try #require(writer.failure)
        #expect(failure.contains("-11861") && failure.contains("-12651"), "\(failure)")
        #expect(writer.written.audio == nil, "no audio was taken")
        #expect(writer.bytesOnDisk == 0)
        #expect(await writer.finish(at: t0 + CMTime(seconds: 1, preferredTimescale: 48_000)) == false)
    }

    /// `t` seconds into a lesson, `frames` of a 440 Hz tone at half scale in every channel, in the writer's PCM format.
    static func tone(frames: Int, channels: Int, rate: Double, at time: CMTime, writer: LessonSegmentWriter) -> CMSampleBuffer? {
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = Float(sin(Double(frame) / rate * 2 * .pi * 440) * 0.5)
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return nil }
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        return LessonSegmentWriter.audioSample(block: block, frames: frames, at: time, format: writer.sourceAudioFormat,
                                               sampleRate: rate)
    }
}
#endif
