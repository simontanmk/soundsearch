import Foundation
import UIKit
import CoreHaptics

final class HapticsManager {
    private var engine: CHHapticEngine?
    private var pulseTask: Task<Void, Never>?
    private var lockTask: Task<Void, Never>?
    private var currentPulseInterval: TimeInterval?
    private var lastLockState: Bool = false
    private var supportsHaptics: Bool = false
    private let fallbackGenerator = UIImpactFeedbackGenerator(style: .light)

    init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        if supportsHaptics {
            do {
                engine = try CHHapticEngine()
                try engine?.start()
            } catch {
                supportsHaptics = false
                engine = nil
            }
        }
    }

    func update(confidence: Double, angularError: Double, isLocked: Bool) {
        if isLocked && confidence > 0.94 && abs(angularError) < 6 {
            if !lastLockState {
                playLockConfirmation()
            }
        }
        lastLockState = isLocked

        if confidence < 0.35 {
            stopPulses()
            return
        }

        let interval = pulseInterval(for: abs(angularError))
        startPulses(interval: interval)
    }

    func stop() {
        stopPulses()
        lockTask?.cancel()
        lockTask = nil
    }

    private func startPulses(interval: TimeInterval) {
        if let current = currentPulseInterval, abs(current - interval) < 0.02, pulseTask != nil {
            return
        }
        stopPulses()
        currentPulseInterval = interval
        pulseTask = Task {
            while !Task.isCancelled {
                playPulse()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopPulses() {
        pulseTask?.cancel()
        pulseTask = nil
        currentPulseInterval = nil
    }

    private func pulseInterval(for error: Double) -> TimeInterval {
        let clamped = min(max(error, 0), 90)
        let minInterval = 0.12
        let maxInterval = 0.6
        let t = clamped / 90
        return maxInterval - (maxInterval - minInterval) * (1 - t)
    }

    private func playPulse() {
        if supportsHaptics {
            playCoreHaptic(intensity: 0.6, sharpness: 0.75)
        } else {
            fallbackGenerator.impactOccurred()
        }
    }

    private func playLockConfirmation() {
        stopPulses()
        lockTask?.cancel()
        lockTask = Task {
            let intervals: [TimeInterval] = [0.0, 0.12, 0.22]
            for delay in intervals {
                if Task.isCancelled { return }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                playCoreHaptic(intensity: 0.9, sharpness: 0.9)
            }
        }
    }

    private func playCoreHaptic(intensity: Double, sharpness: Double) {
        guard supportsHaptics, let engine else {
            fallbackGenerator.impactOccurred()
            return
        }

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness))
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: 0)
        } catch {
            fallbackGenerator.impactOccurred()
        }
    }
}
