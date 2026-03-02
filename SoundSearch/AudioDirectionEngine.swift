import Foundation
import AVFoundation

/// Uses the iPhone microphone input as a simple live signal source.
/// For now this only measures overall loudness and maps it to a confidence
/// value so the existing UI and haptics can react to real audio.
final class AudioDirectionEngine: DirectionEngine {
    private let audioEngine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()

    private let bufferSize: AVAudioFrameCount = 1024

    static func isSupported() -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.isInputAvailable
    }

    func stream() -> AsyncStream<DirectionSample> {
        AsyncStream { continuation in
            do {
                try configureSession()
            } catch {
                continuation.finish()
                return
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.inputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                guard let level = Self.rootMeanSquareLevel(from: buffer) else {
                    return
                }

                let confidence = Self.mapLevelToConfidence(level)

                // Until the CoreML DOA model is available, we do not estimate a real
                // bearing from audio. The arrow will simply point “forward” with
                // confidence driven by loudness.
                let sample = DirectionSample(
                    phoneHeading: 0,
                    targetBearing: 0,
                    confidence: confidence,
                    isLocked: false
                )

                continuation.yield(sample)
            }

            do {
                try audioEngine.start()
            } catch {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.audioEngine.stop()
                try? self.session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        }
    }

    private func configureSession() throws {
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true, options: [])
    }

    private static func rootMeanSquareLevel(from buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        if channelCount == 0 || frameLength == 0 {
            return nil
        }

        var total: Float = 0
        var totalSamples: Int = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var sum: Float = 0
            vDSP_svesq(samples, 1, &sum, vDSP_Length(frameLength))
            total += sum
            totalSamples += frameLength
        }

        if totalSamples == 0 {
            return nil
        }

        let meanSquare = total / Float(totalSamples)
        let rms = sqrtf(meanSquare)
        return rms
    }

    private static func mapLevelToConfidence(_ level: Float) -> Double {
        // Simple mapping: ignore very low levels, compress louder ones into 0...1.
        let noiseFloor: Float = 0.001
        let maxUseful: Float = 0.05
        let clamped = max(0, min((level - noiseFloor) / (maxUseful - noiseFloor), 1))
        return Double(clamped)
    }
}

