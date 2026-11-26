import CoreVideo

/// Turns the frames' Y′CbCr into RGB. Full range, as the frame output is asked for; which matrix depends on the
/// format (Rec. 709 for most, Rec. 601 for some photo previews, Rec. 2020 for wide-colour video).
struct YCbCrMatrix: Sendable, Equatable {
    let crToRed: Float
    let cbToGreen: Float
    let crToGreen: Float
    let cbToBlue: Float

    static let rec601 = YCbCrMatrix(crToRed: 1.402, cbToGreen: -0.344136, crToGreen: -0.714136, cbToBlue: 1.772)
    static let rec709 = YCbCrMatrix(crToRed: 1.5748, cbToGreen: -0.187324, crToGreen: -0.468124, cbToBlue: 1.8556)
    static let rec2020 = YCbCrMatrix(crToRed: 1.4746, cbToGreen: -0.164553, crToGreen: -0.571353, cbToBlue: 1.8814)

    /// The matrix a pixel buffer says it was encoded with; Rec. 709 if it doesn't say.
    static func of(_ pixelBuffer: CVPixelBuffer) -> YCbCrMatrix {
        guard let name = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else {
            return .rec709
        }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return .rec601 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return .rec2020 }
        return .rec709
    }

    /// Each 0 … 255, clamped: a saturated colour can fall outside what RGB holds.
    func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> RGBPixel {
        let luma = Float(y), blueDifference = Float(cb) - 128, redDifference = Float(cr) - 128
        func level(_ value: Float) -> Int { Int(min(max(value, 0), 255).rounded()) }
        return RGBPixel(
            red: level(luma + crToRed * redDifference),
            green: level(luma + cbToGreen * blueDifference + crToGreen * redDifference),
            blue: level(luma + cbToBlue * blueDifference))
    }
}

/// One pixel's red, green and blue, each 0 … 255.
struct RGBPixel: Sendable, Equatable {
    let red: Int
    let green: Int
    let blue: Int
}
