import Foundation

enum DirectionMath {
    static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    static func shortestAngle(from heading: Double, to target: Double) -> Double {
        let normalized = normalizedDegrees(target - heading)
        return normalized > 180 ? normalized - 360 : normalized
    }
}


