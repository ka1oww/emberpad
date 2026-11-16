import Accelerate
import CoreVideo
import Metal
import QuartzCore

/// Draws a canvas's layers into the lesson recording's pixel buffers on the GPU (EP141), as the window server draws the
/// projector. `CALayer.render(in:)` draws on the CPU and scales the page bitmaps pixel by pixel: about 180 ms for each
/// 1920x1080 frame on the main thread, which held the recording to 5 or 6 frames a second while the teacher scrolled
/// or wrote, and held up the projector's drawing with it. This takes 2 to 4 ms. Used on the main thread, as the
/// layers it draws are.
final class PresentFrameRenderer {
    let width: Int
    let height: Int
    private let queue: MTLCommandQueue
    private let renderer: CARenderer
    /// What the renderer draws into. Core Animation draws its bottom row first, a video frame its top row first, so
    /// each frame is copied out turned over.
    private let target: CVPixelBuffer

    /// A renderer of `layer`, whose bounds are `width` by `height` points at one pixel each. Nil without a GPU.
    init?(layer: CALayer, width: Int, height: Int) {
        guard width > 0, height > 0, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                            &made)
        guard let target = made, let surface = CVPixelBufferGetIOSurface(target)?.takeUnretainedValue() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             kCARendererMetalCommandQueue: queue])
        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        self.width = width
        self.height = height
        self.queue = queue
        self.target = target
        // The first frame loads the GPU's shaders, about 100 ms: paid here, before the recording starts, and not by its first frame.
        _ = render()
    }

    /// Draws the layers as they are now and keeps nothing: the GPU takes in the page bitmaps they hold (about 2448x3168
    /// pixels each), so the first frame to show a new page does not pay for it.
    func prepare() { _ = render() }

    /// Draws the layers as they are now into `buffer`, a 32-bit BGRA buffer of the renderer's size.
    func draw(into buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return false }
        guard render() else { return false }
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

    /// Draws the layers into `target` and waits until the GPU has finished.
    private func render() -> Bool {
        // The layers' latest changes reach the renderer before it draws.
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The renderer's work is on `queue`: an empty buffer after it finishes once the frame is drawn.
        guard let done = queue.makeCommandBuffer() else { return false }
        done.commit()
        done.waitUntilCompleted()
        return true
    }
}
