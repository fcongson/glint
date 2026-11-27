import Testing

@testable import Glint

/// AF squares: which cells of the frame count as in focus, from each 16 × 16 tile's count of crisp pixels.
@Suite("AF squares")
struct FocusAreasTests {
    /// A 12 MP frame's tile grid (4032 × 3024 at 16 pixels a tile).
    private let across = 252, down = 189

    private func counts(_ marked: (_ tx: Int, _ ty: Int) -> Float) -> [Float] {
        (0..<down).flatMap { ty in (0..<across).map { tx in marked(tx, ty) } }
    }

    /// Every tile at this density of crisp pixels.
    private func density(_ d: Float) -> [Float] {
        counts { _, _ in d * Float(FocusAreas.tileSize * FocusAreas.tileSize) }
    }

    private func step(_ areas: inout FocusAreas, _ counts: [Float]) throws -> FocusAreas.Grid {
        let grid = areas.update(counts: counts, tilesAcross: across, tilesDown: down)
        return try #require(grid)
    }

    @Test func aTwelveMegapixelFrameIsTwentySquareCellsAcross() throws {
        var areas = FocusAreas()
        let grid = try step(&areas, density(0))
        #expect(grid.across == 20 && grid.down == 15 && grid.tilesPerCell == 13)
        #expect(!grid.inFocus.contains(true))
    }

    @Test func onlyCellsWithEnoughCrispEdgesGetASquare() throws {
        var areas = FocusAreas()
        // The top-left cell (13 × 13 tiles) has a crisp line through every tile: 16 marks a tile, 6%.
        let grid = try step(&areas, counts { tx, ty in tx < 13 && ty < 13 ? 16 : 0.1 })
        #expect(grid.inFocus[0])
        #expect(grid.inFocus.filter { $0 }.count == 1)
    }

    @Test func aCellStaysOnUntilItIsWellBelowTheThreshold() throws {
        var areas = FocusAreas()
        let between = (FocusAreas.onDensity + FocusAreas.offDensity) / 2
        #expect(try !step(&areas, density(between)).inFocus[0])
        #expect(try step(&areas, density(FocusAreas.onDensity * 1.01)).inFocus[0])
        #expect(try step(&areas, density(between)).inFocus[0])
        #expect(try !step(&areas, density(0)).inFocus[0])
    }

    /// A detailed scene is crisp almost everywhere; only the cells near the crispest get a square.
    @Test func inADetailedSceneOnlyTheCrispestCellsGetASquare() throws {
        var areas = FocusAreas()
        // Every cell well past the floor; the left-hand column of cells three times as crisp as the rest.
        let grid = try step(&areas, counts { tx, _ in tx < 13 ? 15 : 5 })
        #expect(grid.inFocus.enumerated().allSatisfy { i, on in on == i.isMultiple(of: 20) })
    }

    @Test func aCellStaysOnUntilItFallsWellBehindTheCrispest() throws {
        var areas = FocusAreas()
        func scene(_ rest: Float) -> [Float] { counts { tx, _ in tx < 13 ? 10 : rest } }
        let between = 10 * (FocusAreas.onShare + FocusAreas.offShare) / 2
        #expect(try !step(&areas, scene(between)).inFocus[1])
        #expect(try step(&areas, scene(10)).inFocus[1])
        #expect(try step(&areas, scene(between)).inFocus[1])
        #expect(try !step(&areas, scene(1)).inFocus[1])
    }

    @Test func aMismatchedCountIsIgnored() {
        var areas = FocusAreas()
        #expect(areas.update(counts: [1, 2, 3], tilesAcross: 2, tilesDown: 2) == nil)
        #expect(areas.grid == nil)
    }

    @Test func squareLinesAreAboutAPointWhateverTheCellSize() throws {
        var areas = FocusAreas()
        let u = try step(&areas, density(0))
            .shaderUniforms(width: 4032, height: 3024, screenPixelsPerFramePixel: 0.4)
        #expect(u.areas.z == 20 && u.areas.w == 15)
        #expect(abs(u.areas.x - 208 / 4032) < 1e-6 && abs(u.areas.y - 208 / 3024) < 1e-6)
        #expect(abs(u.color.w * 208 * 0.4 - 1.5) < 1e-4)  // half of three drawable pixels
    }
}
