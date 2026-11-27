import CoreVideo
import Metal

/// What comes back from the GPU after a frame: the resources kept alive until then, and the per-tile results read
/// out of them.
extension ViewfinderRenderer {
    /// Keeps a frame's resources alive until the GPU is done with it, across the completion handler.
    final class InFlight: @unchecked Sendable {
        let textures: [CVMetalTexture]
        let partials: any MTLBuffer
        let groups: MTLSize
        let pixelCount: Int
        var groupCount: Int { groups.width * groups.height }
        init(textures: [CVMetalTexture], partials: any MTLBuffer, groups: MTLSize, pixelCount: Int) {
            self.textures = textures
            self.partials = partials
            self.groups = groups
            self.pixelCount = pixelCount
        }
    }

    /// Each tile's average high-pass response and brightness, for sweep peaking.
    static func tiles(_ frame: InFlight) -> (sharpness: [Float], luma: [Float]) {
        let values = frame.partials.contents().bindMemory(to: SIMD4<Float>.self, capacity: frame.groupCount)
        var sharpness = [Float](repeating: 0, count: frame.groupCount)
        var luma = [Float](repeating: 0, count: frame.groupCount)
        for i in 0..<frame.groupCount {
            sharpness[i] = values[i].x / 256
            luma[i] = values[i].z / 256
        }
        return (sharpness, luma)
    }

    /// Each tile's count of crisp pixels, for AF squares (which write them where sweep's statistics would go).
    static func focusCounts(_ frame: InFlight) -> [Float] {
        let counts = frame.partials.contents().bindMemory(to: Float.self, capacity: frame.groupCount)
        return Array(UnsafeBufferPointer(start: counts, count: frame.groupCount))
    }

    /// A Metal buffer handed to a completion handler.
    struct UncheckedBuffer: @unchecked Sendable {
        let buffer: any MTLBuffer
        init(_ buffer: any MTLBuffer) { self.buffer = buffer }
    }
}
