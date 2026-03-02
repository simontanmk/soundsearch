import Foundation
import Combine

@MainActor
final class RescueDirectionViewModel: ObservableObject {
    @Published private(set) var phoneHeading: Double = 0
    @Published private(set) var targetBearing: Double = 0
    @Published private(set) var confidence: Double = 0
    @Published private(set) var isLocked: Bool = false
    @Published private(set) var angularError: Double = 0
    @Published private(set) var showLockConfirmation: Bool = false

    // TODO: Replace simulated target/confidence with live AVAudioEngine/beamforming/ML source.
    private let engine: DirectionEngine

    init() {
        if AudioDirectionEngine.isSupported() {
            engine = AudioDirectionEngine()
        } else if SensorDirectionEngine.isSupported() {
            engine = SensorDirectionEngine()
        } else {
            engine = SimulatedDirectionEngine()
        }
    }
    private let haptics = HapticsManager()
    private var simulationTask: Task<Void, Never>?
    private var filteredError: Double = 0
    private var filteredConfidence: Double = 0
    private var lastLockState: Bool = false
    private var lockHoldUntil: Date?

    var arrowRotation: Double {
        angularError
    }

    var statusText: String {
        if showLockConfirmation {
            return ""
        }
        if isLocked {
            return "Locked"
        }
        if confidence > 0.55 {
            return "Signal detected"
        }
        return "Listening..."
    }

    func start() {
        stop()
        simulationTask = Task {
            for await sample in engine.stream() {
                apply(sample)
            }
        }
    }

    func stop() {
        simulationTask?.cancel()
        simulationTask = nil
        haptics.stop()
    }

    private func apply(_ sample: DirectionSample) {
        phoneHeading = sample.phoneHeading
        targetBearing = sample.targetBearing
        isLocked = sample.isLocked

        let rawError = Self.shortestAngle(from: sample.phoneHeading, to: sample.targetBearing)
        let errorSmoothing = 0.18
        filteredError += (rawError - filteredError) * errorSmoothing
        angularError = filteredError

        let confidenceSmoothing = 0.14
        filteredConfidence += (sample.confidence - filteredConfidence) * confidenceSmoothing
        confidence = filteredConfidence

        updateLockConfirmationIfNeeded(error: angularError, confidence: confidence, isLocked: isLocked)
        haptics.update(confidence: confidence, angularError: angularError, isLocked: isLocked)
    }

    private func updateLockConfirmationIfNeeded(error: Double, confidence: Double, isLocked: Bool) {
        let now = Date()
        if isLocked && confidence > 0.94 && abs(error) < 6 {
            if !lastLockState {
                lockHoldUntil = now.addingTimeInterval(1.6)
                showLockConfirmation = true
            }
        } else if let holdUntil = lockHoldUntil, now < holdUntil {
            showLockConfirmation = true
        } else {
            showLockConfirmation = false
            lockHoldUntil = nil
        }
        lastLockState = isLocked
    }

    private static func shortestAngle(from heading: Double, to target: Double) -> Double {
        let normalized = normalizedDegrees(target - heading)
        return normalized > 180 ? normalized - 360 : normalized
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}
