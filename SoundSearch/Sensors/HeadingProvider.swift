import CoreLocation
import CoreMotion
import Foundation

/// Provides compass heading optimized for phone held flat (screen up).
/// Uses CMDeviceMotion yaw as primary (works in any orientation).
/// Falls back to CLHeading only if device motion is unavailable.
final class HeadingProvider: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var continuation: AsyncStream<Double>.Continuation?
    private var usingDeviceMotion = false

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

        // Prefer device motion — gives yaw that works when phone is flat
        if motionManager.isDeviceMotionAvailable {
            usingDeviceMotion = true
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.showsDeviceMovementDisplay = true
            motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQueue) { [weak self] motion, _ in
                guard let motion else { return }
                // Yaw = rotation around gravity axis = compass-like heading
                // when phone is flat.  Convert from [-π, π] → [0, 360).
                let yawDeg = motion.attitude.yaw * 180 / .pi
                let heading = Self.normalizedDegrees(-yawDeg)  // negate: yaw is CCW, compass is CW
                self?.continuation?.yield(heading)
            }
        } else if CLLocationManager.headingAvailable() {
            // Fallback only — heading is unreliable when flat
            usingDeviceMotion = false
            locationManager.startUpdatingHeading()
        }
    }

    private func stopUpdates() {
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard !usingDeviceMotion else { return }  // ignore if device motion active
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
