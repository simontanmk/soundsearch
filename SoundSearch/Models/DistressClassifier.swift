import Foundation
import CoreML
import Accelerate

// ═══════════════════════════════════════════════════════════════
// MARK: - DistressClassifier
// ═══════════════════════════════════════════════════════════════
//
//  Wraps the distress_classifier CoreML model.
//
//  Input : mel_spectrogram  [1, 1, 64, 188]  (Float32)
//  Output: class_probs      [non_distress_prob, distress_prob]
//
//  Usage:
//    1. Feed raw 48 kHz mono audio via `appendAudio(_:)`.
//    2. When 3 seconds have accumulated, call `classify()`.
//    3. Returns (distressProb: Double, nonDistressProb: Double).
//
//  The classifier manages a rolling buffer internally:
//    - Accumulates audio from the audio tap
//    - Slides by 0.5 s each classification (overlap for continuity)

final class DistressClassifier: @unchecked Sendable {

    struct ClassificationResult {
        let distressProb: Double
        let nonDistressProb: Double
        let isDistress: Bool
    }

    // ── Configuration ───────────────────────────────────────
    let melComputer = MelSpectrogram()
    private let threshold: Double = 0.65       // distress confidence threshold
    private let consecutiveRequired = 3        // consecutive hits to confirm
    private let bufferDuration: Double = 3.0   // seconds
    private let slideDuration: Double = 0.5    // slide window by this much
    private let silenceRmsThreshold: Float = 0.008  // below = too quiet, skip

    // ── CoreML model ────────────────────────────────────────
    private var model: MLModel?

    // ── Audio buffer (48 kHz mono) ──────────────────────────
    private let sampleRate: Double = 48_000
    private(set) var audioBuffer: [Float] = []
    private let bufferCapacity: Int  // 144000 = 48000 * 3
    private let slideFrames: Int     // 24000 = 48000 * 0.5

    // ── State ───────────────────────────────────────────────
    private var consecutiveHits = 0

    // ── Debug ───────────────────────────────────────────────
    nonisolated static let debugNotification =
        Notification.Name("DistressClassifierDebugNotification")

    // ─────────────────────────────────────────────────────────
    init() {
        bufferCapacity = Int(sampleRate * bufferDuration)   // 144000
        slideFrames    = Int(sampleRate * slideDuration)    // 24000
        audioBuffer.reserveCapacity(bufferCapacity + 4096)  // extra for tap overshoot

        loadModel()
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Public API
    // ═══════════════════════════════════════════════════════════

    /// Append raw 48 kHz mono audio frames (from tap callback).
    /// Returns a classification result if enough audio has accumulated.
    func feedAudio(_ samples: UnsafePointer<Float>, count: Int) -> ClassificationResult? {
        audioBuffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        guard audioBuffer.count >= bufferCapacity else { return nil }

        // Take exactly bufferCapacity frames
        let chunk = Array(audioBuffer.prefix(bufferCapacity))

        // Slide forward
        if audioBuffer.count > slideFrames {
            audioBuffer.removeFirst(slideFrames)
        } else {
            audioBuffer.removeAll(keepingCapacity: true)
        }

        return classify(audio: chunk)
    }

    /// Check if the buffer has enough audio for classification.
    var isReady: Bool { audioBuffer.count >= bufferCapacity }

    /// Current buffer count (for progress reporting).
    var audioBufferCount: Int { audioBuffer.count }

    /// Reset the audio buffer and consecutive hit counter.
    func reset() {
        audioBuffer.removeAll(keepingCapacity: true)
        consecutiveHits = 0
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Classification
    // ═══════════════════════════════════════════════════════════

    private func classify(audio: [Float]) -> ClassificationResult {
        guard let model else {
            Self.post("ERROR: model not loaded")
            return ClassificationResult(distressProb: 0, nonDistressProb: 1, isDistress: false)
        }

        // 1. Compute mel spectrogram  [64 × 188] flat array (normalized to [0,1])
        let melFlat = melComputer.compute(audio48k: audio)

        // Diagnostic: log mel statistics (first classification only, then every 10th)
        let melMin = melFlat.min() ?? 0
        let melMax = melFlat.max() ?? 0
        let melSum = melFlat.reduce(0, +)
        let melMean = melFlat.isEmpty ? 0 : melSum / Float(melFlat.count)

        // Audio RMS for diagnostics
        var audioRms: Float = 0
        audio.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &audioRms, vDSP_Length(audio.count))
        }

        Self.post(String(
            format: "MEL  min=%.3f  max=%.3f  mean=%.3f  audioRMS=%.5f  samples=%d",
            melMin, melMax, melMean, audioRms, melFlat.count
        ))

        // ── Silence gate ───────────────────────────────────
        // Quiet room noise (RMS < 0.008) can’t contain real distress.
        // Skip model inference to avoid false positives from mic self-noise.
        if audioRms < silenceRmsThreshold {
            consecutiveHits = max(0, consecutiveHits - 1)
            Self.post(String(
                format: "CLASSIFY  SILENT (rms=%.5f < %.3f)  hits=%d/%d",
                audioRms, silenceRmsThreshold, consecutiveHits, consecutiveRequired
            ))
            return ClassificationResult(distressProb: 0, nonDistressProb: 1, isDistress: false)
        }

        // 2. Create MLMultiArray  [1, 1, 64, 188]
        guard let mlArray = try? MLMultiArray(
            shape: [1, 1, 64, 188] as [NSNumber],
            dataType: .float32
        ) else {
            Self.post("ERROR: failed to create MLMultiArray")
            return ClassificationResult(distressProb: 0, nonDistressProb: 1, isDistress: false)
        }

        // Copy mel data into MLMultiArray
        let ptr = mlArray.dataPointer.bindMemory(to: Float.self, capacity: 64 * 188)
        melFlat.withUnsafeBufferPointer { src in
            ptr.update(from: src.baseAddress!, count: min(src.count, 64 * 188))
        }

        // 3. Run inference
        let featureProvider = try? MLDictionaryFeatureProvider(
            dictionary: ["mel_spectrogram": MLFeatureValue(multiArray: mlArray)]
        )

        guard let featureProvider,
              let output = try? model.prediction(from: featureProvider) else {
            Self.post("ERROR: inference failed")
            return ClassificationResult(distressProb: 0, nonDistressProb: 1, isDistress: false)
        }

        // 4. Extract probabilities
        var distressProb: Double = 0
        var nonDistressProb: Double = 1

        if let probs = output.featureValue(for: "class_probs")?.multiArrayValue {
            nonDistressProb = Double(truncating: probs[0])
            distressProb    = Double(truncating: probs[1])
        } else if let probs = output.featureValue(for: "class_probs")?.dictionaryValue {
            // Some CoreML models output as dictionary
            if let dp = probs["distress"] as? Double { distressProb = dp }
            if let ndp = probs["non_distress"] as? Double { nonDistressProb = ndp }
        }

        // 5. Consecutive-hit logic
        if distressProb >= threshold {
            consecutiveHits += 1
        } else {
            consecutiveHits = max(0, consecutiveHits - 1)
        }
        let confirmed = consecutiveHits >= consecutiveRequired

        Self.post(String(
            format: "CLASSIFY  distress=%.3f  non_distress=%.3f  hits=%d/%d  %@",
            distressProb, nonDistressProb,
            consecutiveHits, consecutiveRequired,
            confirmed ? "✓ CONFIRMED" : ""
        ))

        return ClassificationResult(
            distressProb: distressProb,
            nonDistressProb: nonDistressProb,
            isDistress: confirmed
        )
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Model Loading
    // ═══════════════════════════════════════════════════════════

    private func loadModel() {
        // CoreML compiles .mlmodel → .mlmodelc at build time.
        // The compiled model is in the app bundle.
        guard let modelURL = Bundle.main.url(
            forResource: "distress_classifier",
            withExtension: "mlmodelc"
        ) else {
            Self.post("ERROR: distress_classifier.mlmodelc not found in bundle")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: modelURL, configuration: config)
            Self.post("Model loaded: distress_classifier (CPU+NE)")
        } catch {
            Self.post("ERROR loading model: \(error.localizedDescription)")
        }
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Debug
    // ═══════════════════════════════════════════════════════════

    nonisolated private static func post(_ msg: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: debugNotification, object: nil,
                userInfo: ["summary": msg]
            )
        }
    }
}
