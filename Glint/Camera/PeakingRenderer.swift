import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// Draws the viewfinder while focus peaking is on, each camera frame with its own outlines, on the GPU.
///
/// Peaking drawn over the system preview from separately analysed frames always trails the picture, so outlines
/// ghost when the phone moves. Cameras draw peaking into the viewfinder image itself; this does the same. The
/// system preview stays underneath (it's what taps and the rotation coordinator use), and shows through until the
/// first frame is drawn, or if frames stop (some ProRes configurations can't run alongside a video data output).
///
/// Per frame, all on the GPU (Viewfinder.metal), the way cameras peak:
/// 1. Analyse at full resolution, up to a long side of 4096 (12 MP frames as they are; 48 MP ones shrunk by
///    averaging 2×2 blocks). Shrinking a frame shrinks its blur too, so a slightly soft edge would look crisp;
///    at full size the test matches what you'll see zoomed into the photo.
/// 2. Blur lightly (3×3 binomial, its own pass to keep reads down at full resolution) and high-pass with a Laplacian, which responds to the finest detail and falls
///    away fast as an edge blurs, where a gradient filter like Sobel keeps responding to big, soft edges.
/// 3. Average that response over 3×3, so outlines run as lines rather than breaking into dots, and noise spikes
///    are diluted.
/// 4. Mark pixels above the frame's mean plus 4, 3 or 2 standard deviations (the sensitivity), and above
///    `relativeFloor` times the mean (in a frame with little detail, the mean is mostly noise), with at least two
///    marked neighbours. The statistics come back from the GPU after each frame and set the next frame's
///    threshold, eased over frames (`PeakingThreshold`) so outlines don't flicker.
/// 5. Shrink the mask to about screen resolution, keeping every mark, and draw the frame upright and fitted like
///    the preview, with the outlines in the chosen colour and weight.
///
/// `render` is called on the analysis queue, one frame at a time. The target layer is set from the main thread
/// and the threshold from Metal's completion handlers, so both sit behind `lock`.
final class PeakingRenderer: @unchecked Sendable {
    /// Lowest smoothed response (in luma steps) ever marked, so a featureless frame isn't outlined at all.
    static let minimumStrength: Float = 4
    /// Nothing is marked below this multiple of the frame's mean response, which keeps noise out of frames that
    /// have little else in them.
    static let relativeFloor = 2.5
    /// Frames are shrunk until their long side is at most this.
    static let targetSize = 4096
    private static let framesInFlight = 3

    /// The threshold a frame's statistics call for, before easing.
    static func level(mean: Double, deviation: Double, sensitivity: PeakingSensitivity) -> Double {
        max(relativeFloor * mean, mean + sensitivity.deviations * deviation)
    }

    /// The whole factor a frame is shrunk by.
    static func scale(width: Int, height: Int) -> Int {
        max(1, (max(width, height) + targetSize - 1) / targetSize)
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let downscalePipeline: any MTLComputePipelineState
    private let blurPipeline: any MTLComputePipelineState
    private let responsePipeline: any MTLComputePipelineState
    private let poolPipeline: any MTLComputePipelineState
    private let edgesPipeline: any MTLComputePipelineState
    private let maskPipeline: any MTLComputePipelineState
    private let drawPipeline: any MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: framesInFlight)

    private let lock = NSLock()
    private var target: (layer: CAMetalLayer, size: CGSize)?   // behind `lock`
    private var threshold = PeakingThreshold()                  // behind `lock`
    private var thresholdGeneration = 0                         // behind `lock`; bumped when it starts over

    // Only touched by whoever is rendering (the analysis queue, or a test).
    private var sensitivity = PeakingSensitivity.medium
    private var work: Work?
    private var slot = 0
    private var colorSpaceName: CFString?
    private var pooled: (factor: Int, texture: any MTLTexture)?

    /// Scratch textures for one frame size, and a ring of buffers for the statistics coming back.
    private struct Work {
        let frameWidth: Int, frameHeight: Int
        let factor: Int
        let small: any MTLTexture, blurred: any MTLTexture, response: any MTLTexture, edges: any MTLTexture
        let mask: any MTLTexture
        let groups: MTLSize
        let partials: [any MTLBuffer]
    }

    /// Keeps a frame's resources alive until the GPU is done with it, across the completion handler.
    private final class InFlight: @unchecked Sendable {
        let textures: [CVMetalTexture]
        let partials: any MTLBuffer
        let groupCount: Int
        let pixelCount: Int
        init(textures: [CVMetalTexture], partials: any MTLBuffer, groupCount: Int, pixelCount: Int) {
            self.textures = textures
            self.partials = partials
            self.groupCount = groupCount
            self.pixelCount = pixelCount
        }
    }

    enum SetupError: Error { case unavailable }

    /// Nil if the device has no Metal, which every supported iPhone does.
    static func make() -> PeakingRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? PeakingRenderer(device: device)
    }

    init(device: any MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw SetupError.unavailable }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw SetupError.unavailable
        }
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: PeakingRenderer.self))
        func function(_ name: String) throws -> any MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw SetupError.unavailable }
            return f
        }
        let draw = MTLRenderPipelineDescriptor()
        draw.vertexFunction = try function("viewfinderVertex")
        draw.fragmentFunction = try function("viewfinderFragment")
        draw.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.device = device
        commandQueue = queue
        textureCache = cache
        downscalePipeline = try device.makeComputePipelineState(function: try function("peakingDownscale"))
        blurPipeline = try device.makeComputePipelineState(function: try function("peakingBlur"))
        responsePipeline = try device.makeComputePipelineState(function: try function("peakingResponse"))
        poolPipeline = try device.makeComputePipelineState(function: try function("peakingPool"))
        edgesPipeline = try device.makeComputePipelineState(function: try function("peakingEdges"))
        maskPipeline = try device.makeComputePipelineState(function: try function("peakingMask"))
        drawPipeline = try device.makeRenderPipelineState(descriptor: draw)
    }

    // MARK: Target

    @MainActor
    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false   // see-through until the first frame, so the system preview shows
    }

    @MainActor
    func attach(_ layer: CAMetalLayer, drawableSize: CGSize) {
        lock.withLock { target = (layer, drawableSize) }
    }

    @MainActor
    func detach(_ layer: CAMetalLayer) {
        lock.withLock {
            if target?.layer === layer { target = nil }
        }
    }

    // MARK: Rendering

    /// Draws one camera frame (420YpCbCr8 full range) with its peaking outlines. Does nothing while no view is
    /// attached.
    func render(_ pixelBuffer: CVPixelBuffer, sensitivity: PeakingSensitivity, appearance: PeakingAppearance) {
        guard let target = lock.withLock({ self.target }), target.size.width > 0, target.size.height > 0 else { return }
        let level = prepare(sensitivity)
        inFlight.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let luma = texture(pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = texture(pixelBuffer, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma),
              let work = workspace(width: lumaTexture.width, height: lumaTexture.height)
        else {
            inFlight.signal()
            return
        }
        let partials = work.partials[slot]
        slot = (slot + 1) % work.partials.count
        encodeAnalysis(commandBuffer, luma: lumaTexture, work: work, partials: partials, level: level)
        let scale = Self.fitScale(frameWidth: lumaTexture.width, frameHeight: lumaTexture.height,
                                  viewSize: target.size)
        let outlineMask = encodePool(commandBuffer, work: work,
                                     pictureWidthOnScreen: Float(target.size.width) * scale.x)

        updateColorSpace(of: target.layer, for: pixelBuffer)
        if let drawable = target.layer.nextDrawable() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                var uniforms = Uniforms(
                    scale: scale,
                    matrix: Self.matrix(for: pixelBuffer),
                    color: SIMD4(appearance.color.rgb, 1),
                    lines: SIMD4(1 / Float(outlineMask.width), 1 / Float(outlineMask.height), appearance.lines.reach, 0))
                encoder.setRenderPipelineState(drawPipeline)
                encoder.setFragmentTexture(lumaTexture, index: 0)
                encoder.setFragmentTexture(chromaTexture, index: 1)
                encoder.setFragmentTexture(outlineMask, index: 2)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
        }

        let frame = InFlight(textures: [luma, chroma], partials: partials,
                             groupCount: work.groups.width * work.groups.height,
                             pixelCount: work.small.width * work.small.height)
        let generation = lock.withLock { thresholdGeneration }
        commandBuffer.addCompletedHandler { [self] _ in
            let stats = Self.statistics(frame)
            lock.withLock {
                // A frame from before a sensitivity change mustn't pull the new threshold back.
                if thresholdGeneration == generation {
                    _ = threshold.update(Self.level(mean: stats.mean, deviation: stats.deviation, sensitivity: sensitivity))
                }
            }
            inFlight.signal()
        }
        commandBuffer.commit()
    }

    /// The threshold for this frame: the one the previous frames' statistics settled on. A change of sensitivity
    /// starts over, so it jumps straight to the new level.
    private func prepare(_ sensitivity: PeakingSensitivity) -> Double? {
        if sensitivity != self.sensitivity {
            self.sensitivity = sensitivity
            lock.withLock {
                threshold.reset()
                thresholdGeneration += 1
            }
        }
        return lock.withLock { threshold.level }
    }

    /// Steps 1–4: shrink, high-pass, smooth (with statistics into `partials`), and mark against `level`. With no level
    /// yet (the first frame), nothing is marked.
    private func encodeAnalysis(_ commandBuffer: any MTLCommandBuffer, luma: any MTLTexture, work: Work,
                                partials: any MTLBuffer, level: Double?) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let size = MTLSize(width: work.small.width, height: work.small.height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)

        var factor = UInt32(work.factor)
        encoder.setComputePipelineState(downscalePipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(work.small, index: 1)
        encoder.setBytes(&factor, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(work.small, index: 0)
        encoder.setTexture(work.blurred, index: 1)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        encoder.setComputePipelineState(responsePipeline)
        encoder.setTexture(work.blurred, index: 0)
        encoder.setTexture(work.response, index: 1)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        encoder.setComputePipelineState(edgesPipeline)
        encoder.setTexture(work.response, index: 0)
        encoder.setTexture(work.edges, index: 1)
        encoder.setBuffer(partials, offset: 0, index: 0)
        encoder.dispatchThreadgroups(work.groups, threadsPerThreadgroup: group)   // whole groups, for the sums

        var cutoff = level.map { max(Self.minimumStrength, Float($0)) } ?? .infinity
        encoder.setComputePipelineState(maskPipeline)
        encoder.setTexture(work.edges, index: 0)
        encoder.setTexture(work.mask, index: 1)
        encoder.setBytes(&cutoff, length: MemoryLayout<Float>.size, index: 0)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > plane else { return nil }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, format,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    private func workspace(width: Int, height: Int) -> Work? {
        if let work, work.frameWidth == width, work.frameHeight == height { return work }
        let factor = Self.scale(width: width, height: height)
        let w = width / factor, h = height / factor
        guard w >= 3, h >= 3 else { return nil }
        func make(_ format: MTLPixelFormat) -> (any MTLTexture)? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        let partialsLength = groups.width * groups.height * MemoryLayout<SIMD2<Float>>.stride
        let partials = (0..<Self.framesInFlight).compactMap { _ in
            device.makeBuffer(length: partialsLength, options: .storageModeShared)
        }
        guard let small = make(.r16Float), let blurred = make(.r16Float), let response = make(.r16Float),
              let edges = make(.r16Float),
              let mask = make(.r8Unorm),
              partials.count == Self.framesInFlight else { return nil }
        let new = Work(frameWidth: width, frameHeight: height, factor: factor, small: small, blurred: blurred,
                       response: response, edges: edges, mask: mask, groups: groups, partials: partials)
        work = new
        slot = 0
        return new
    }

    /// Step 5's shrink: pools the mask by the number of mask texels per screen pixel (rounded up), so outlines keep
    /// their weight on screen. Returns the mask to draw from.
    private func encodePool(_ commandBuffer: any MTLCommandBuffer, work: Work,
                            pictureWidthOnScreen: Float) -> any MTLTexture {
        let perPixel = Float(work.mask.height) / max(1, pictureWidthOnScreen)   // the mask's upright width
        let factor = max(1, Int(perPixel.rounded(.up)))
        guard factor > 1 else { return work.mask }
        let w = (work.mask.width + factor - 1) / factor, h = (work.mask.height + factor - 1) / factor
        if pooled == nil || pooled?.factor != factor || pooled?.texture.width != w || pooled?.texture.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let texture = device.makeTexture(descriptor: d) else { return work.mask }
            pooled = (factor, texture)
        }
        guard let texture = pooled?.texture, let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return work.mask
        }
        var poolFactor = UInt32(factor)
        encoder.setComputePipelineState(poolPipeline)
        encoder.setTexture(work.mask, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBytes(&poolFactor, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return texture
    }

    private static func statistics(_ frame: InFlight) -> (mean: Double, deviation: Double) {
        let values = frame.partials.contents().bindMemory(to: SIMD2<Float>.self, capacity: frame.groupCount)
        var sum = 0.0, sumOfSquares = 0.0
        for i in 0..<frame.groupCount {
            sum += Double(values[i].x)
            sumOfSquares += Double(values[i].y)
        }
        let n = Double(max(frame.pixelCount, 1))
        let mean = sum / n
        return (mean, max(0, sumOfSquares / n - mean * mean).squareRoot())
    }

    // MARK: Drawing details

    private struct Uniforms {
        var scale: SIMD2<Float>
        var matrix: SIMD4<Float>
        var color: SIMD4<Float>
        var lines: SIMD4<Float>
    }

    /// The upright picture's size as a fraction of the view when fitted inside it (like `.resizeAspect`).
    static func fitScale(frameWidth: Int, frameHeight: Int, viewSize: CGSize) -> SIMD2<Float> {
        let picture = Float(frameHeight) / Float(frameWidth)   // upright: the landscape frame turned
        let view = Float(viewSize.width / viewSize.height)
        return picture > view ? SIMD2(1, view / picture) : SIMD2(picture / view, 1)
    }

    /// Full-range YCbCr to RGB coefficients for the frame's matrix (BT.709 unless it says otherwise).
    static func matrix(for pixelBuffer: CVPixelBuffer) -> SIMD4<Float> {
        let name = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        if name == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { return SIMD4(1.402, 0.344136, 0.714136, 1.772) }
        if name == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return SIMD4(1.4746, 0.16455, 0.57135, 1.8814) }
        return SIMD4(1.5748, 0.1873, 0.4681, 1.8556)
    }

    /// Wide-colour frames are Display P3; show them as such, as the system preview does.
    private func updateColorSpace(of layer: CAMetalLayer, for pixelBuffer: CVPixelBuffer) {
        let primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String
        let name = primaries == (kCVImageBufferColorPrimaries_P3_D65 as String) ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        guard name != colorSpaceName else { return }
        colorSpaceName = name
        let space = CGColorSpace(name: name)
        nonisolated(unsafe) let layer = layer   // only touched on the main queue from here
        DispatchQueue.main.async { layer.colorspace = space }
    }

    // MARK: Testing

    /// What one frame's analysis produced, read back from the GPU.
    struct Analysis {
        let width: Int
        let height: Int
        let mean: Double
        let deviation: Double
        let mask: [UInt8]   // 255 where outlined, row by row
    }

    /// Runs steps 1–4 on a frame and waits for the result: with no `level`, only the statistics are meaningful.
    func analyse(_ pixelBuffer: CVPixelBuffer, level: Double?) -> Analysis? {
        guard let luma = texture(pixelBuffer, plane: 0, format: .r8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let work = workspace(width: lumaTexture.width, height: lumaTexture.height),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let partials = work.partials[0]
        encodeAnalysis(commandBuffer, luma: lumaTexture, work: work, partials: partials, level: level)

        // Copy the private mask texture somewhere readable.
        let w = work.mask.width, h = work.mask.height
        guard let readback = device.makeBuffer(length: w * h, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: work.mask, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: w, destinationBytesPerImage: w * h)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let stats = Self.statistics(InFlight(textures: [luma], partials: partials,
                                             groupCount: work.groups.width * work.groups.height, pixelCount: w * h))
        let bytes = readback.contents().bindMemory(to: UInt8.self, capacity: w * h)
        return Analysis(width: w, height: h, mean: stats.mean, deviation: stats.deviation,
                        mask: Array(UnsafeBufferPointer(start: bytes, count: w * h)))
    }
}

/// The Metal view the renderer draws into, laid over the system preview while peaking is on. It never takes
/// touches (taps go through to the preview, which turns them into focus points) and VoiceOver skips it.
struct PeakingViewfinder: UIViewRepresentable {
    let renderer: PeakingRenderer

    final class MetalView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
        var renderer: PeakingRenderer?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            let scale = traitCollection.displayScale
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = size
            renderer?.attach(metalLayer, drawableSize: size)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                renderer?.detach(metalLayer)
            } else {
                setNeedsLayout()
            }
        }
    }

    func makeUIView(context: Context) -> MetalView {
        let view = MetalView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.renderer = renderer
        renderer.configure(view.metalLayer)
        return view
    }

    func updateUIView(_ view: MetalView, context: Context) {}

    static func dismantleUIView(_ view: MetalView, coordinator: ()) {
        view.renderer?.detach(view.metalLayer)
    }
}
