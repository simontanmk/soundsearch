import Foundation

struct DirectionSample: Equatable, Sendable {
    let phoneHeading: Double
    let targetBearing: Double
    let confidence: Double
    let isLocked: Bool
    var isStereoMode: Bool = false
}
