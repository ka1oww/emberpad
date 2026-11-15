#if os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes one video file of a lesson (EP129): H.264 video of the presentation and AAC audio of the microphone, on one
/// clock, as a fragmented MP4. A fragment is closed every `fragmentInterval`, so when the Companion stops without
/// finishing (a crash, a forced quit, power loss) the file still plays up to its last fragment.
///
/// Audio arrives as 48 kHz linear PCM in `sourceAudioFormat`, unprocessed, and is encoded once. A gap in it (the
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
        /// 192 kbit/s per channel: transparent for speech, above what Voice Memos keeps.
        public var audioBitRatePerChannel = 192_000
        public var fragmentInterval: Double = 2

        public init() {}

        public var audioBitRate: Int { audioBitRatePerChannel * max(1, min(2, channels)) }
    }

    public enum Failure: Error, Equatable {
        case cannotStart(String)
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
