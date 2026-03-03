import Foundation

/// The current phase of the app's audio pipeline.
enum AppPhase: String, Equatable, Sendable {
    case detecting   // Listening for distress sounds (classifier running)
    case directing   // Distress confirmed → finding direction of arrival
}

struct DirectionSample: Equatable, Sendable {
    // ── Phase information ───────────────────────────────────
    var phase: AppPhase = .detecting

    // ── Detection fields (phase == .detecting) ──────────────
    var distressConfidence: Double = 0     // 0…1 classifier output
    var bufferProgress: Double = 0         // 0…1 how full the 3s buffer is
    var isDistressConfirmed: Bool = false   // consecutive-hit confirmed

    // ── Direction fields (phase == .directing) ──────────────
    let phoneHeading: Double
    let targetBearing: Double
    let confidence: Double
    let isLocked: Bool
    var isStereoMode: Bool = false
}
