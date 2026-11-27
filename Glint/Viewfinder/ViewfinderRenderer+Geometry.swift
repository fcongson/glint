import CoreGraphics
import CoreVideo
import Metal

extension ViewfinderRenderer {
    /// The whole factor a frame is shrunk by.
    static func scale(width: Int, height: Int) -> Int {
        max(1, (max(width, height) + targetSize - 1) / targetSize)
    }

    /// The upright picture's size as a fraction of the view when fitted inside it (like `.resizeAspect`).
    static func fitScale(frameWidth: Int, frameHeight: Int, viewSize: CGSize) -> SIMD2<Float> {
        let picture = Float(frameHeight) / Float(frameWidth)  // upright: the landscape frame turned
        let view = Float(viewSize.width / viewSize.height)
        return picture > view ? SIMD2(1, view / picture) : SIMD2(picture / view, 1)
    }

    /// The frame's YCbCr matrix as Viewfinder.metal takes it, which subtracts green's two terms.
    static func matrix(for pixelBuffer: CVPixelBuffer) -> SIMD4<Float> {
        let m = YCbCrMatrix.of(pixelBuffer)
        return SIMD4(m.crToRed, -m.cbToGreen, -m.crToGreen, m.cbToBlue)
    }
}

extension MTLComputeCommandEncoder {
    /// One compute pass: `pipeline` with `textures` bound from index 0 in order, a thread per texel of `size`.
    /// Bytes and buffers are bound beforehand; Metal keeps them across pipeline changes.
    func run(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture], over size: MTLSize) {
        bind(pipeline, textures)
        dispatchThreads(size, threadsPerThreadgroup: threadgroup)
    }

    /// The same, in whole threadgroups, for kernels that sum over each one.
    func run(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture], groups: MTLSize) {
        bind(pipeline, textures)
        dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
    }

    /// The tiles Viewfinder.metal's edge kernel sums over are this size too.
    private var threadgroup: MTLSize { MTLSize(width: 16, height: 16, depth: 1) }

    private func bind(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture]) {
        setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { setTexture(texture, index: index) }
    }
}
