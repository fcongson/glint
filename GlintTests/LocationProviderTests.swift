import CoreLocation
import Foundation
import Testing
@testable import Glint

struct LocationProviderTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func location(age: TimeInterval = 0, accuracy: CLLocationAccuracy = 10) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: -41.33, longitude: 174.79), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
    }

    @Test func freshAccurateFixIsUsable() {
        #expect(LocationProvider.isUsable(location(), now: now))
    }

    @Test func fixAtTheLimitsIsUsable() {
        #expect(LocationProvider.isUsable(location(age: LocationProvider.maxAge, accuracy: LocationProvider.maxHorizontalAccuracy), now: now))
    }

    @Test func staleFixIsRejected() {
        #expect(!LocationProvider.isUsable(location(age: LocationProvider.maxAge + 1), now: now))
    }

    @Test func vagueFixIsRejected() {
        #expect(!LocationProvider.isUsable(location(accuracy: LocationProvider.maxHorizontalAccuracy + 1), now: now))
    }

    @Test func invalidFixIsRejected() {
        #expect(!LocationProvider.isUsable(location(accuracy: -1), now: now))
    }
}
