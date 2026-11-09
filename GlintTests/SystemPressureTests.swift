import AVFoundation
import Testing
@testable import Glint

@Suite("System pressure")
struct SystemPressureTests {
    @Test func mapsEveryLevel() {
        #expect(SystemPressure(.nominal) == .nominal)
        #expect(SystemPressure(.fair) == .fair)
        #expect(SystemPressure(.serious) == .serious)
        #expect(SystemPressure(.critical) == .critical)
        #expect(SystemPressure(.shutdown) == .shutdown)
    }

    @Test func givesThingsUpInOrder() {
        #expect(SystemPressure.nominal.peakingInterval == 1)
        #expect(!SystemPressure.nominal.pausesViewfinderAids)

        #expect(SystemPressure.fair.peakingInterval == 2)
        #expect(!SystemPressure.fair.pausesViewfinderAids)

        #expect(SystemPressure.serious.pausesViewfinderAids)
        #expect(!SystemPressure.serious.reducesFrameRate)

        #expect(SystemPressure.critical.pausesViewfinderAids)
        #expect(SystemPressure.critical.reducesFrameRate)
    }
}
