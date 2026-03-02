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
    @Published private(set) var debugInfo: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStereoMode: Bool = false

    // TODO: Replace simulated target/confidence with live AVAudioEngine/beamforming/ML source.
    private let engine: DirectionEngine
    private var debugObserver: NSObjectProtocol?

    init() {
        if AudioDirectionEngine.isSupported() {
            engine = AudioDirectionEngine()
        } else if SensorDirectionEngine.isSupported() {
            engine = SensorDirectionEngine()
        } else {
            engine = SimulatedDirectionEngine()
        }

        debugObserver = NotificationCenter.default.addObserver(
            forName: AudioDirectionEngine.debugNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let summary = note.userInfo?["summary"] as? String else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.debugLines.append(summary)
                // Keep last 20 lines
                if self.debugLines.count > 20 {
                    self.debugLines.removeFirst(self.debugLines.count - 20)
                }
                self.debugInfo = self.debugLines.joined(separator: "\n")
            }
        }
    }
    private var debugLines: [String] = []
    private let haptics = HapticsManager()
    private var simulationTask: Task<Void, Never>?
    private var filteredError: Double = 0
    private var filteredConfidence: Double = 0
    private var lastLockState: Bool = false
    private var lockHoldUntil: Date?

    deinit {
        simulationTask?.cancel()
        simulationTask = nil
        haptics.stop()
        if let debugObserver {
            NotificationCenter.default.removeObserver(debugObserver)
        }
    }

    var arrowRotation: Double {
        angularError
    }

    var statusText: String {
        if showLockConfirmation {
            return ""
        }
        if isLocked {
            return "Direction locked"
        }
        if isStereoMode {
            // Stereo mode — no rotation needed
            if confidence > 0.3 {
                return "Tracking sound source"
            }
            return "Listening for sounds…"
        } else {
            // Mono mode — rotation required
            if confidence > 0.3 {
                return "Source detected — keep rotating"
            }
            return "Hold upright, rotate slowly"
        }
    }

    func start() {
        stop()
        errorMessage = nil
        simulationTask = Task {
            var receivedSample = false
            for await sample in engine.stream() {
                receivedSample = true
                apply(sample)
            }
            if !receivedSample {
                errorMessage = "Unable to start audio direction. Check microphone permissions and ensure no Bluetooth audio devices are connected."
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
        isStereoMode = sample.isStereoMode

        let rawError = DirectionMath.shortestAngle(from: sample.phoneHeading, to: sample.targetBearing)
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

}
