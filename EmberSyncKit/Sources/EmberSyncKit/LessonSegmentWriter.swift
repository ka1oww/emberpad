#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes one video file of a lesson (EP129): H.264 video of the presentation and AAC audio of the microphone, on one
/// clock, as a fragmented MP4. A fragment is closed every `fragmentInterval`, so when the Companion stops without
/// finishing (a crash, a forced quit, power loss) the file still plays up to its last fragment.
///
/// Audio arrives as linear PCM in `sourceAudioFormat` (48 kHz from the Companion), unprocessed, and is encoded once as
/// AAC at a bit rate the system encoder accepts for its channels and rate (`LessonAudioBitRate`). A gap in it (the
/// microphone unplugged, or a stall) is filled with digital silence, so the audio track stays continuous and in step
/// with the picture; `fillSilence(until:)` fills it while the microphone is gone. Video frames are written when the
/// picture changes and at least about once a second, so the frame rate varies up to the caller's maximum.
///
/// Thread-safe: video and audio may be appended from different threads.
public final class LessonSegmentWriter: @unchecked Sendable {
    public struct Settings: Equatable, Sendable {
        public var width = 1_920
        public var height = 1_080
        public var videoBitRate = 4_000_000
        public var keyFrameInterval: Double = 2
        public var sampleRate: Double = 48_000
        public var channels = 1
        /// 192 kbit/s per channel is the aim: transparent for speech, above what Voice Memos keeps. The file gets the
        /// highest rate the Mac's AAC encoder takes up to it (`LessonAudioBitRate`): 192 kbit/s mono, 320 kbit/s stereo.
        public var audioBitRatePerChannel = 192_000
        /// A bit rate used as given, even one the encoder refuses; tests use it to make the encoder fail.
        public var fixedAudioBitRate: Int?
        public var fragmentInterval: Double = 2

        public init() {}

        /// The AAC bit rate the file is encoded at.
        public var audioBitRate: Int {
            if let fixedAudioBitRate { return fixedAudioBitRate }
            let channels = max(1, min(2, channels))
            return LessonAudioBitRate.choose(target: audioBitRatePerChannel * channels, sampleRate: sampleRate, channels: channels)
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case cannotStart(String)

        public var errorDescription: String? {
            switch self {
            case .cannotStart(let what): "The video file could not be started (\(what))."
            }
        }
    }

    public let url: URL
    public let settings: Settings
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let lock = NSLock()
    private var started: CMTime?
    private var lastVideo: CMTime?
    /// Where the audio written so far ends.
    private var audioEnd: CMTime?
    /// Where the audio the encoder has taken ends; nil until it takes some.
    private var audioWritten: CMTime?
    private var finished = false
    public private(set) var videoFrames = 0
    public private(set) var silenceFilled: Double = 0

    /// Audio the writer takes: interleaved 32-bit float PCM at `settings.sampleRate`, `settings.channels` channels.
    public static func sourceAudioSettings(_ settings: Settings) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: settings.sampleRate, AVNumberOfChannelsKey: settings.channels,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }

    public init(url: URL, settings: Settings) throws {
        self.url = url
        self.settings = settings
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        writer.movieFragmentInterval = CMTime(seconds: settings.fragmentInterval, preferredTimescale: 600)
        writer.movieTimeScale = 600
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitRate,
                AVVideoMaxKeyFrameIntervalDurationKey: settings.keyFrameInterval,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: settings.sampleRate,
            AVNumberOfChannelsKey: settings.channels,
            AVEncoderBitRateKey: settings.audioBitRate,
        ])
        audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        var description = AudioStreamBasicDescription(
            mSampleRate: settings.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * settings.channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * settings.channels), mChannelsPerFrame: UInt32(settings.channels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw Failure.cannotStart("audio format") }
        audioFormat = format
        guard writer.canAdd(video), writer.canAdd(audio) else { throw Failure.cannotStart("inputs") }
        writer.add(video)
        writer.add(audio)
    }

    /// Starts the file's timeline at `time`; media before it is dropped.
    public func start(at time: CMTime) throws {
        try lock.withLock {
            guard started == nil else { return }
            guard writer.startWriting() else {
                throw Failure.cannotStart(writer.error?.localizedDescription ?? "startWriting")
            }
            writer.startSession(atSourceTime: time)
            started = time
            audioEnd = time
        }
    }

    public var startTime: CMTime? { lock.withLock { started } }

    /// A pixel buffer to draw the next frame into, from the writer's pool.
    public func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = lock.withLock({ adaptor.pixelBufferPool }) {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, settings.width, settings.height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer)
        }
        return buffer
    }

    /// Appends one frame shown from `time` on. Returns false when it was dropped (too early, or the encoder is busy).
    @discardableResult
    public func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        lock.withLock {
            guard let started, !finished, writer.status == .writing, time >= started else { return false }
            if let lastVideo, time <= lastVideo { return false }
            guard video.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else { return false }
            lastVideo = time
            videoFrames += 1
            return true
        }
    }

    /// Appends microphone audio in `sourceAudioFormat`. A gap since the last audio is filled with silence first;
    /// audio that overlaps what is written is dropped.
    @discardableResult
    public func appendAudio(_ sample: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard let started, !finished, writer.status == .writing else { return false }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let frames = CMSampleBufferGetNumSamples(sample)
            let end = time + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(settings.sampleRate))
            guard end > started else { return false }
            if let audioEnd, time < audioEnd - CMTime(value: 1, timescale: 1_000) { return false }
            if let audioEnd, time - audioEnd > CMTime(value: 20, timescale: 1_000) { appendSilenceLocked(from: audioEnd, to: time) }
            guard audio.isReadyForMoreMediaData, audio.append(sample) else { return false }
            audioEnd = end
            audioWritten = end
            return true
        }
    }

    /// Fills the audio with silence up to `time`, while the microphone sends nothing.
    public func fillSilence(until time: CMTime) {
        lock.withLock {
            guard started != nil, !finished, writer.status == .writing, let audioEnd, time > audioEnd else { return }
            appendSilenceLocked(from: audioEnd, to: time)
        }
    }

    private func appendSilenceLocked(from start: CMTime, to end: CMTime) {
        let rate = settings.sampleRate
        var cursor = start
        while cursor < end {
            let remaining = Int(((end - cursor).seconds * rate).rounded())
            let frames = min(remaining, Int(rate) / 10)
            guard frames > 0, let sample = silence(frames: frames, at: cursor), audio.isReadyForMoreMediaData,
                  audio.append(sample) else { return }
            cursor = cursor + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
            audioEnd = cursor
            audioWritten = cursor
            silenceFilled += Double(frames) / rate
        }
    }

    private func silence(frames: Int, at time: CMTime) -> CMSampleBuffer? {
        let bytes = frames * 4 * settings.channels
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        return Self.audioSample(block: block, frames: frames, at: time, format: audioFormat, sampleRate: settings.sampleRate)
    }

    /// An audio sample buffer of `frames` packed frames in `format`.
    public static func audioSample(block: CMBlockBuffer, frames: Int, at time: CMTime, format: CMAudioFormatDescription,
                                   sampleRate: Double) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    /// The PCM format `appendAudio` takes.
    public var sourceAudioFormat: CMAudioFormatDescription { audioFormat }

    /// Finishes the file at `time` (the last video frame is held until then). Returns false when it could not be
    /// finished cleanly; the fragments written so far still play.
    public func finish(at time: CMTime? = nil) async -> Bool {
        let ready: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            guard writer.status == .writing else { return false }
            if let time, let audioEnd, time > audioEnd { appendSilenceLocked(from: audioEnd, to: time) }
            if let time { writer.endSession(atSourceTime: max(time, lastVideo ?? time)) }
            video.markAsFinished()
            audio.markAsFinished()
            return true
        }
        guard ready else { return false }
        await writer.finishWriting()
        return writer.status == .completed
    }

    public var error: Error? { lock.withLock { writer.error } }

    /// Why the file stopped taking media, once the writer has failed (the encoder refused its settings, the disk is
    /// full); nil while it writes.
    public var failure: String? {
        lock.withLock {
            switch writer.status {
            case .failed: writer.error.map(Self.describe) ?? "the writer failed"
            case .cancelled: "the writer was cancelled"
            default: nil
            }
        }
    }

    /// How far each track has been taken by the encoder, on the source clock; nil until its first sample.
    public var written: (audio: CMTime?, video: CMTime?) { lock.withLock { (audioWritten, lastVideo) } }

    /// The bytes on disk so far. The file type and the start of the media data can land before the first fragment
    /// closes (`holdsPlayableMedia`).
    public var bytesOnDisk: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// The file holds something a player can play.
    public var holdsPlayableMedia: Bool { Self.holdsPlayableMedia(at: url) }

    /// The MP4 at `url` holds something a player can play: its movie box (`moov`) is on disk. A fragmented MP4 writes
    /// it when its first fragment closes, or at the finish. Before that the file can already hold bytes that nothing
    /// plays: the file type and an open media box with the first frames, as when the picture reaches the disk before
    /// the encoder refuses the first sound (EP150).
    public static func holdsPlayableMedia(at url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        var offset: UInt64 = 0
        while (try? file.seek(toOffset: offset)) != nil {
            guard let header = try? file.read(upToCount: 16), header.count >= 8 else { return false }
            let bytes = [UInt8](header)
            if bytes[4..<8].elementsEqual("moov".utf8) { return true }
            let number = { (range: Range<Int>) in range.reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[$1]) } }
            var size = number(0..<4)
            // 1: the size follows as 64 bits. 0: the box runs to the end of the file, so no box comes after it.
            if size == 1 {
                guard bytes.count >= 16 else { return false }
                size = number(8..<16)
            }
            let (next, overflow) = offset.addingReportingOverflow(size)
            guard size >= 8, !overflow else { return false }
            offset = next
        }
        return false
    }

    /// An error in words, with the code that names it, for the log.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        var text = "\(error.localizedDescription) (\(error.domain) \(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += ", \(underlying.domain) \(underlying.code)"
        }
        return text + ")"
    }
}

/// The AAC bit rate for a lesson's audio (EP134). The Mac's AAC encoder takes only some rates for a given channel count
/// and sample rate: at 44.1 and 48 kHz up to 256 kbit/s mono and 320 kbit/s stereo. A rate it does not take makes the
/// file fail when its first audio arrives (EP129's 384 kbit/s stereo did), so the rate is one the encoder lists.
public enum LessonAudioBitRate {
    /// The most the encoder takes at 44.1 and 48 kHz, for when it cannot be asked.
    static func fallback(channels: Int) -> Int { channels >= 2 ? 320_000 : 256_000 }
    /// A rate the encoder takes for mono and stereo at 44.1 and 48 kHz, for a file to try after one was refused.
    public static let safe = 128_000

    /// `target` when the encoder takes it; otherwise the highest rate it takes below `target`, or its lowest when
    /// every rate it takes is above.
    public static func choose(target: Int, sampleRate: Double, channels: Int) -> Int {
        let ranges = applicable(sampleRate: sampleRate, channels: channels)
        guard !ranges.isEmpty else { return min(target, fallback(channels: channels)) }
        let wanted = Double(target)
        if ranges.contains(where: { $0.lowerBound <= wanted && wanted <= $0.upperBound }) { return target }
        if let below = ranges.filter({ $0.lowerBound <= wanted }).map({ min($0.upperBound, wanted) }).max() { return Int(below) }
        return Int(ranges.map(\.lowerBound).min() ?? wanted)
    }

    /// The rates the system AAC encoder lists for float PCM at `sampleRate` with `channels` channels, in bits per
    /// second; empty when it cannot be asked.
    public static func applicable(sampleRate: Double, channels: Int) -> [ClosedRange<Double>] {
        let count = UInt32(max(1, channels))
        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * count, mFramesPerPacket: 1, mBytesPerFrame: 4 * count, mChannelsPerFrame: count,
            mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1_024, mBytesPerFrame: 0, mChannelsPerFrame: count, mBitsPerChannel: 0, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &made) == noErr, let converter = made else { return [] }
        defer { AudioConverterDispose(converter) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioValueRange>.stride) else { return [] }
        var values = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.stride)
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &values) == noErr else { return [] }
        return values.prefix(Int(size) / MemoryLayout<AudioValueRange>.stride)
            .filter { $0.mMaximum > 0 && $0.mMinimum <= $0.mMaximum }
            .map { $0.mMinimum...$0.mMaximum }
    }
}

/// The loudest sample in a buffer of interleaved 32-bit float PCM, for `LessonAudioHealth`.
public func lessonAudioPeak(_ sample: CMSampleBuffer) -> Float {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
    var length = 0
    var pointer: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                      dataPointerOut: &pointer) == noErr, let pointer else { return 0 }
    let count = length / 4
    return pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
        var peak: Float = 0
        for index in 0..<count { peak = max(peak, abs(floats[index])) }
        return peak
    }
}
#endif
