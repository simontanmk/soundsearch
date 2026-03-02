import CoreLocation
import CoreMotion
import Foundation

final class HeadingProvider: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var continuation: AsyncStream<Double>.Continuation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.headingFilter = 1
        motionQueue.qualityOfService = .userInitiated
    }

    func stream() -> AsyncStream<Double> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.startUpdates()

            continuation.onTermination = { _ in
                self.stopUpdates()
            }
        }
    }

    static func isHeadingAvailable() -> Bool {
        CLLocationManager.headingAvailable() || CMMotionManager().isDeviceMotionAvailable
    }

    private func startUpdates() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.showsDeviceMovementDisplay = true
            motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQueue) { [weak self] motion, _ in
                guard let motion else { return }
                let yawDegrees = motion.attitude.yaw * 180 / .pi
                let normalized = Self.normalizedDegrees(yawDegrees)
                self?.continuation?.yield(normalized)
            }
        }
    }

    private func stopUpdates() {
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        continuation?.yield(newHeading.magneticHeading)
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}
