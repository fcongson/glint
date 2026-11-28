import Foundation

/// AF squares: which parts of the picture are in focus while autofocus runs. iOS doesn't say what autofocus chose,
/// so this shows what came out sharp instead, the way a camera lights up its AF points.
///
/// The frame is split into square cells, about `cellsAcross` along its long side, each a whole number of the
/// renderer's 16 × 16 tiles. A cell gets a square when enough of its pixels pass focus peaking's crisp-edge test
/// (at peaking's sensitivity): a crisp line across a cell marks about 0.3% of it, a soft area next to none. A phone
/// keeps most of a detailed scene crisp, so a cell also has to come close to the frame's crispest cell
/// (`onShare` of it), which leaves the squares on what's sharpest. A cell comes on at `onDensity` and `onShare`
/// and goes off only below `offDensity` or `offShare`, so squares don't flicker on the threshold.
struct FocusAreas: Equatable, Sendable {
    static let cellsAcross = 20
    static let onDensity: Float = 0.003
    static let offDensity: Float = 0.0015
    static let onShare: Float = 0.6
    static let offShare: Float = 0.45
    /// sRGB, 0…1: green, a camera's focus confirmation.
    static let color = SIMD3<Float>(52, 199, 89) / 255

    /// The cells and which of them are in focus, row by row along the frame's long side.
    struct Grid: Equatable, Sendable {
        let across: Int
        let down: Int
        let tilesPerCell: Int
        var inFocus: [Bool]

        /// What Viewfinder.metal's `onFocusSquare` takes, for a frame analysed at `width` × `height`: one cell's
        /// size in frame coordinates (0…1) and the grid, then the colour with half the line width as a fraction of a
        /// cell, so lines are three drawable pixels (about a point) however large a cell is on screen.
        func shaderUniforms(width: Int, height: Int, screenPixelsPerFramePixel: Float)
            -> (areas: SIMD4<Float>, color: SIMD4<Float>)
        {
            let pixels = Float(tilesPerCell * FocusAreas.tileSize)
            let halfLine = 1.5 / max(pixels * screenPixelsPerFramePixel, 1)
            return (
                SIMD4(pixels / Float(width), pixels / Float(height), Float(across), Float(down)),
                SIMD4(FocusAreas.color, halfLine)
            )
        }
    }

    static let tileSize = 16
    private(set) var grid: Grid?

    /// Whether the squares are wanted. Switched off, the old ones are dropped so they can't flash up when they're next
    /// on, and a frame counted before they went off can't bring them back.
    var isOn = true {
        didSet { if !isOn { grid = nil } }
    }

    /// Takes each tile's count of crisp pixels, row by row, and returns the cells now in focus.
    @discardableResult
    mutating func update(counts: [Float], tilesAcross: Int, tilesDown: Int) -> Grid? {
        guard isOn, tilesAcross > 0, tilesDown > 0, counts.count == tilesAcross * tilesDown else { return nil }
        let perCell = (tilesAcross + Self.cellsAcross - 1) / Self.cellsAcross
        let across = (tilesAcross + perCell - 1) / perCell, down = (tilesDown + perCell - 1) / perCell
        var sums = [Float](repeating: 0, count: across * down)
        var tiles = [Int](repeating: 0, count: across * down)
        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                let cell = (ty / perCell) * across + tx / perCell
                sums[cell] += counts[ty * tilesAcross + tx]
                tiles[cell] += 1
            }
        }
        let previous = grid?.across == across && grid?.down == down ? grid?.inFocus : nil
        let pixelsPerTile = Float(Self.tileSize * Self.tileSize)
        let densities = sums.indices.map { sums[$0] / (Float(tiles[$0]) * pixelsPerTile) }
        let crispest = densities.max() ?? 0
        let inFocus = densities.indices.map { i in
            let wasOn = previous?[i] == true
            let floor = wasOn ? Self.offDensity : Self.onDensity
            let share = wasOn ? Self.offShare : Self.onShare
            return densities[i] >= max(floor, share * crispest)
        }
        grid = Grid(across: across, down: down, tilesPerCell: perCell, inFocus: inFocus)
        return grid
    }
}
