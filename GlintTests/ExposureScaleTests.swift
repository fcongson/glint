import Testing
@testable import Glint

struct ExposureScaleTests {
    @Test func shutterFullStopsAreEveryThirdStep() {
        let stops = ExposureScale.shutterDenominators
        let full = stops.indices.filter(ExposureScale.isFullStopShutter(index:)).map { stops[$0] }
        #expect(full == [8, 15, 30, 60, 125, 250, 500, 1000, 2000, 4000, 8000])
    }

    @Test func isoFullStopsAreDoublings() {
        let full = ExposureScale.allISOStops.filter(ExposureScale.isFullStopISO)
        #expect(full == [50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25000, 50000])
    }

    @Test func isoStopsAreLimitedToTheLensRange() {
        let stops = ExposureScale.isoStops(min: 25, max: 1600)
        #expect(stops.first == 50)
        #expect(stops.last == 1600)
    }

    @Test func isoStopsFallBackToTheMinimumWhenNoneFit() {
        #expect(ExposureScale.isoStops(min: 33, max: 40) == [33])
    }

    @Test func whiteBalanceRunsFrom2000To10000In100KSteps() {
        let kelvins = ExposureScale.whiteBalanceKelvins
        #expect(kelvins.count == 81)
        #expect(kelvins.first == 2000)
        #expect(kelvins.last == 10000)
        #expect(kelvins.filter(ExposureScale.isMajorWhiteBalance) == stride(from: 2000, through: 10000, by: 1000).map { Float($0) })
    }

    @Test(arguments: [
        (Float(5520), Float(5500)),
        (5560, 5600),
        (5550, 5600),    // exactly half-way rounds up
        (1500, 2000),    // clamps below the range
        (12000, 10000),  // and above it
    ])
    func nearestWhiteBalanceStop(temperature: Float, expected: Float) {
        #expect(ExposureScale.nearest(temperature, in: ExposureScale.whiteBalanceKelvins) == expected)
    }

    @Test func everyStopIsItsOwnNearest() {
        let shutter = ExposureScale.shutterDenominators
        let iso = ExposureScale.allISOStops
        #expect(shutter.indices.allSatisfy { ExposureScale.nearestIndex(of: shutter[$0], in: shutter) == $0 })
        #expect(iso.indices.allSatisfy { ExposureScale.nearestIndex(of: iso[$0], in: iso) == $0 })
    }

    @Test func offScaleValuesSnapToTheClosestStop() {
        let iso = ExposureScale.allISOStops
        #expect(iso[ExposureScale.nearestIndex(of: 33, in: iso)] == 50)
        #expect(iso[ExposureScale.nearestIndex(of: 12000, in: iso)] == 12800)
    }

    @Test func nearestInAnEmptyListReturnsTheValue() {
        #expect(ExposureScale.nearest(Float(42), in: []) == 42)
    }
}
