import Foundation

final class SensorDirectionEngine: DirectionEngine {
    private let updateInterval: TimeInterval = 0.05
    private let headingProvider = HeadingProvider()

    func stream() -> AsyncStream<DirectionSample> {
        AsyncStream { continuation in
            let headingState = HeadingState()
            var time: Double = 0
            var targetBearing: Double = 180
            var lockStreak: Double = 0

            let headingTask = Task {
                for await heading in headingProvider.stream() {
                    await headingState.update(heading)
                }
            }

            let simulationTask = Task {
                while !Task.isCancelled {
                    time += updateInterval
                    targetBearing = Self.normalizedDegrees(200 + sin(time * 0.22) * 85 + sin(time * 0.07) * 35)

                    let phoneHeading = await headingState.value
                    let error = Self.shortestAngle(from: phoneHeading, to: targetBearing)
                    let alignmentBoost = max(0, 1 - abs(error) / 90)
                    let baseConfidence = 0.25 + 0.45 * (sin(time * 0.45) + 1) / 2
                    var confidence = baseConfidence + alignmentBoost * 0.35 + Double.random(in: -0.03...0.03)
                    confidence = min(max(confidence, 0), 1)

                    if confidence > 0.92 && abs(error) < 7 {
                        lockStreak += updateInterval
                    } else {
                        lockStreak = max(lockStreak - updateInterval * 2.2, 0)
                    }

                    let isLocked = lockStreak > 1.0

                    continuation.yield(
                        DirectionSample(
                            phoneHeading: phoneHeading,
                            targetBearing: targetBearing,
                            confidence: confidence,
                            isLocked: isLocked
                        )
                    )

                    try? await Task.sleep(nanoseconds: UInt64(updateInterval * 1_000_000_000))
                }
            }

            continuation.onTermination = { _ in
                headingTask.cancel()
                simulationTask.cancel()
            }
        }
    }

    static func isSupported() -> Bool {
        HeadingProvider.isHeadingAvailable()
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func shortestAngle(from heading: Double, to target: Double) -> Double {
        let normalized = normalizedDegrees(target - heading)
        return normalized > 180 ? normalized - 360 : normalized
    }
}

private actor HeadingState {
    var value: Double = 0

    func update(_ heading: Double) {
        value = heading
    }
}
