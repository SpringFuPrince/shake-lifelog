import CoreLocation
import Combine
import ShakeCore

@MainActor
final class CaptureLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var samples: [CLLocation] = []
    private var isActive = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        isActive = true
        updateAuthorization()
    }

    func stop() {
        isActive = false
        manager.stopUpdatingLocation()
        samples.removeAll()
    }

    private var authorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    private func updateAuthorization() {
        guard isActive else { return }
        if authorized {
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.stopUpdatingLocation()
            samples.removeAll()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.updateAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, isActive, authorized else { return }
            samples = Array((samples + locations).suffix(24))
        }
    }

    func location(at shutterTime: Date) async -> CaptureLocation? {
        // A first fix can arrive just after the shutter. Ignore stale cached fixes.
        for step in 0...10 {
            guard isActive, authorized, !Task.isCancelled else { return nil }
            let acceptsApproximate = manager.accuracyAuthorization == .reducedAccuracy
            let sample = samples
                .filter {
                    let offset = $0.timestamp.timeIntervalSince(shutterTime)
                    let accuracy = $0.horizontalAccuracy
                    return (-10...3).contains(offset) && accuracy.isFinite && accuracy >= 0 &&
                        (accuracy <= 300 || acceptsApproximate)
                }
                .min {
                    abs($0.timestamp.timeIntervalSince(shutterTime)) < abs($1.timestamp.timeIntervalSince(shutterTime))
                }
            if let sample {
                return CaptureLocation(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude,
                                       horizontalAccuracy: sample.horizontalAccuracy)
            }
            if step < 10 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        return nil
    }
}
