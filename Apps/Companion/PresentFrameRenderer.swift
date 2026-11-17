import Accelerate
import CoreVideo
import Metal
import QuartzCore

/// Draws a canvas's layers into the lesson recording's pixel buffers on the GPU (EP141), as the window server draws the
/// projector. `CALayer.render(in:)` draws on the CPU and scales the page bitmaps pixel by pixel: about 180 ms for each
/// 1920x1080 frame on the main thread, which held the recording to 5 or 6 frames a second while the teacher scrolled
/// or wrote, and held up the projector's drawing with it. This takes 2 to 4 ms. Used on the main thread, as the
/// layers it draws are.
final class PresentFrameRenderer: @unchecked Sendable {
    /// One render target: what the renderer draws into, and the texture over it.
    private struct Slot {
        /// Core Animation draws its bottom row first, a video frame its top row first, so each frame is copied out turned over.
        let target: CVPixelBuffer
        let texture: MTLTexture
    }

    /// What `submit` did.
    enum Submitted {
        /// Drawn, or on the GPU now; the completion runs when the buffer holds it.
        case drawing
        /// Every target is still on the GPU: nothing was drawn, and the caller draws afresh next tick.
        case busy
        /// Cannot draw at all (a buffer of the wrong size or format).
        case failed
    }

    let width: Int
    let height: Int
    private let queue: MTLCommandQueue
    private let renderer: CARenderer
    private let slots: [Slot]
    /// Slots not on the GPU. The main thread takes one without waiting, and the completion handler gives it back.
    private let freeSlots = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var free: [Int] = [0, 1, 2]

    /// A renderer of `layer`, whose bounds are `width` by `height` points at one pixel each. Nil without a GPU.
    init?(layer: CALayer, width: Int, height: Int) {
        guard width > 0, height > 0, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return nil }
        var slots: [Slot] = []
        for _ in 0..<3 {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                &made)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let target = made, let surface = CVPixelBufferGetIOSurface(target)?.takeUnretainedValue(),
                  let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
            slots.append(Slot(target: target, texture: texture))
        }
        renderer = CARenderer(mtlTexture: slots[0].texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                      kCARendererMetalCommandQueue: queue])
        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        self.width = width
        self.height = height
        self.queue = queue
        self.slots = slots
        // The first frame loads the GPU's shaders, about 100 ms: paid here, before the recording starts, and not by its first frame.
        prepare()
    }

    /// Draws the layers as they are now and keeps nothing, waiting for the GPU: the GPU takes in the page bitmaps they
    /// hold (about 2448x3168 pixels each), so the first frame to show a new page does not pay for it. Never in a timed frame.
    func prepare() { _ = drawAndWait(into: nil) }

    /// Draws the layers as they are now into `buffer` (a 32-bit BGRA buffer of the renderer's size) and waits for the GPU.
    /// Never in a timed frame.
    func drawAndWait(into buffer: CVPixelBuffer?) -> Bool {
        final class Result: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var ok = false
        }
        let result = Result()
        guard submit(into: buffer, waitForATarget: true, completion: { result.ok = $0; result.done.signal() }) == .drawing
        else { return false }
        result.done.wait()
        return result.ok
    }

    /// Hands the layers as they are now to the GPU and returns without waiting for it (the invariant of the recorder's
    /// timed frame): Core Animation's pass runs here, on the calling (main) thread, as it reads the layers, and the
    /// GPU's work and the copy into `buffer` finish on the GPU's own thread, where `completion` runs with whether
    /// `buffer` now holds the picture. Without a free target it draws nothing and says `.busy`.
    func submit(into buffer: CVPixelBuffer?, waitForATarget: Bool = false, completion: @escaping @Sendable (Bool) -> Void) -> Submitted {
        if let buffer, CVPixelBufferGetWidth(buffer) != width || CVPixelBufferGetHeight(buffer) != height
            || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA { return .failed }
        guard freeSlots.wait(timeout: waitForATarget ? .distantFuture : .now()) == .success else { return .busy }
        let index = lock.withLock { free.removeLast() }
        let slot = slots[index]
        let release = { [self] in
            lock.withLock { free.append(index) }
            freeSlots.signal()
        }
        // The layers' latest changes reach the renderer before it draws.
        CATransaction.flush()
        renderer.setDestination(slot.texture)
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The renderer's work is on `queue`: an empty buffer after it finishes once the frame is drawn.
        guard let done = queue.makeCommandBuffer() else {
            release()
            return .failed
        }
        done.addCompletedHandler { [self] _ in
            let ok = buffer.map { copy(slot.target, into: $0) } ?? true
            release()
            completion(ok)
        }
        done.commit()
        return .drawing
    }

    private func copy(_ target: CVPixelBuffer, into buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(target, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVPixelBufferUnlockBaseAddress(target, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(target), let to = CVPixelBufferGetBaseAddress(buffer) else { return false }
        var source = vImage_Buffer(data: from, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: CVPixelBufferGetBytesPerRow(target))
        var destination = vImage_Buffer(data: to, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                        rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        return vImageVerticalReflect_ARGB8888(&source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}
