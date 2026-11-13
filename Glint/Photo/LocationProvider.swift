import CoreLocation

/// Keeps the most recent location fix so a photo can be tagged the moment it's taken.
/// Location is optional: if access is denied, `latest` stays nil and photos are saved untagged.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private var isPaused = false

    /// A fix older or vaguer than this would put a photo in the wrong place, so it's better to leave the photo untagged.
    nonisolated static let maxAge: TimeInterval = 5 * 60
    nonisolated static let maxHorizontalAccuracy: CLLocationAccuracy = 300   // metres

    /// The best location to tag a photo with right now, or nil if none is recent and accurate enough.
    /// `manager.location` is the system's cached fix, which can exist before the first live update arrives.
    var current: CLLocation? {
        let now = Date()
        return [latest, manager.location].compactMap { $0 }
            .filter { Self.isUsable($0, now: now) }
            .max { $0.timestamp < $1.timestamp }
    }

    /// A negative accuracy means the fix is invalid.
    nonisolated static func isUsable(_ location: CLLocation, now: Date) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return age <= maxAge
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= maxHorizontalAccuracy
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Asks for permission the first time, then starts updates once it's granted.
    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()   // the delegate starts updates once the user answers
        } else {
            startIfAuthorized()
        }
    }

    /// Stops the fixes while no photo can be taken (the review screen), and starts them again after: at this
    /// accuracy the GPS receiver runs for as long as updates do. A shot still arriving uses the last fix, which
    /// `current` accepts for a few minutes.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused { manager.stopUpdatingLocation() } else { startIfAuthorized() }
    }

    private func startIfAuthorized() {
        guard !isPaused else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in startIfAuthorized() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in latest = location }
    }

    /// A short place name ("Houghton Bay, Wellington"), or nil when the lookup fails (e.g. offline).
    nonisolated static func placeName(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let parts = [placemark.areasOfInterest?.first ?? placemark.subLocality, placemark.locality].compactMap { $0 }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}
