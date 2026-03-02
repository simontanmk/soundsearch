import Foundation
import AVFoundation
import Accelerate
import UIKit

/// Uses the iPhone microphone input and GCC-PHAT to estimate coarse
/// left/center/right direction with a smoothed bearing proxy.
final class AudioDirectionEngine: DirectionEngine {
    static let debugNotification = Notification.Name("AudioDirectionEngineDebugNotification")
    private let audioEngine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()

    private let bufferSize: AVAudioFrameCount = 1024
    private let frameSize: Int = 1024
    private let hopSize: Int = 512

    static func isSupported() -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.isInputAvailable
    }

    func stream() -> AsyncStream<DirectionSample> {
        AsyncStream { continuation in
            requestRecordPermissionIfNeeded { [weak self] granted in
                guard let self, granted else {
                    continuation.finish()
                    return
                }

                do {
                    try self.configureSession()
                } catch {
                    continuation.finish()
                    return
                }

                guard let stereoFormat = AVAudioFormat(
                    standardFormatWithSampleRate: self.session.sampleRate,
                    channels: 2
                ) else {
                    continuation.finish()
                    return
                }

                let audioEngine = self.audioEngine
                let inputNode = audioEngine.inputNode
                let channelCount = 2
                let sampleRate = stereoFormat.sampleRate
                self.logInputConfiguration(format: stereoFormat, channelCount: channelCount)

                let inputManager = AudioInputManager(frameSize: self.frameSize, hopSize: self.hopSize)
                let estimator = GCCPHATEstimator(frameSize: self.frameSize, sampleRate: sampleRate)
                let smoother = DOASmoother()

                inputNode.installTap(onBus: 0, bufferSize: self.bufferSize, format: stereoFormat) { buffer, _ in
                    guard let estimator else {
                        return
                    }

                    inputManager.append(buffer: buffer, channelCount: channelCount) { left, right in
                        let estimate = estimator.processStereoFrame(left: left, right: right)
                        let smoothed = smoother.apply(estimate)

                        let bearingScale: Double = 70
                        let bearingDegrees = smoothed.bearing * bearingScale
                        let isLocked = smoothed.isReliable && smoothed.label == .center && smoothed.confidence > 0.8

                        let sample = DirectionSample(
                            phoneHeading: 0,
                            targetBearing: bearingDegrees,
                            confidence: smoothed.confidence,
                            isLocked: isLocked
                        )

                        continuation.yield(sample)
                    }
                }

                do {
                    try audioEngine.start()
                } catch {
                    continuation.finish()
                    return
                }

                continuation.onTermination = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleTermination()
                    }
                }
            }
        }
    }

    @MainActor
    private func handleTermination() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureSession() throws {
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true, options: [])
        try? session.setPreferredInputNumberOfChannels(2)
        try? configureStereoInput()
    }

    private func requestRecordPermissionIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch session.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            session.requestRecordPermission { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }

    private func configureStereoInput() throws {
        guard let preferredInput = session.preferredInput,
              let dataSources = preferredInput.dataSources else {
            return
        }

        guard let stereoSource = dataSources.first(where: { $0.supportedPolarPatterns?.contains(.stereo) == true }) else {
            return
        }

        try stereoSource.setPreferredPolarPattern(.stereo)
        try preferredInput.setPreferredDataSource(stereoSource)
        try session.setPreferredInputOrientation(currentStereoOrientation())
    }

    private func currentStereoOrientation() -> AVAudioSession.StereoOrientation {
        let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait

        switch interfaceOrientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }

    private func logInputConfiguration(format: AVAudioFormat, channelCount: Int) {
        let route = session.currentRoute
        let inputNames = route.inputs.map { $0.portName }.joined(separator: ", ")
        let inputChannels = route.inputs.first?.channels?.count ?? channelCount
        let dataSourceName = session.preferredInput?.selectedDataSource?.dataSourceName ?? "unknown"
        let polarPattern = session.preferredInput?.selectedDataSource?.selectedPolarPattern?.rawValue ?? "unknown"
        let availableSources = session.inputDataSources?
            .map { source in
                let patterns = source.supportedPolarPatterns?.map { $0.rawValue }.joined(separator: ",") ?? "none"
                return "\(source.dataSourceName)(\(patterns))"
            }
            .joined(separator: " | ") ?? "none"
        let summary = [
            "route=\(inputNames)",
            "channels=\(inputChannels)",
            "dataSource=\(dataSourceName)",
            "polarPattern=\(polarPattern)",
            "tapChannels=\(format.channelCount)",
            "sources=\(availableSources)"
        ].joined(separator: " | ")
        NotificationCenter.default.post(
            name: Self.debugNotification,
            object: nil,
            userInfo: ["summary": summary]
        )
    }

    private enum DOALabel: String {
        case left
        case center
        case right
    }

    private struct DOAEstimate {
        let label: DOALabel
        let delaySamples: Int
        let delaySeconds: Double
        let bearing: Double
        let confidence: Double
        let isReliable: Bool
    }

    private final class DOASmoother {
        private let bearingAlpha: Double
        private let confidenceAlpha: Double
        private let switchFrames: Int
        private let switchConfidence: Double

        private var smoothedBearing: Double = 0
        private var smoothedConfidence: Double = 0
        private var currentLabel: DOALabel = .center
        private var pendingLabel: DOALabel?
        private var pendingCount: Int = 0

        init(bearingAlpha: Double = 0.22, confidenceAlpha: Double = 0.2, switchFrames: Int = 3, switchConfidence: Double = 0.45) {
            self.bearingAlpha = bearingAlpha
            self.confidenceAlpha = confidenceAlpha
            self.switchFrames = switchFrames
            self.switchConfidence = switchConfidence
        }

        func apply(_ estimate: DOAEstimate) -> DOAEstimate {
            let targetBearing = estimate.isReliable ? estimate.bearing : 0
            smoothedBearing += (targetBearing - smoothedBearing) * bearingAlpha
            smoothedConfidence += (estimate.confidence - smoothedConfidence) * confidenceAlpha

            let resolvedLabel = resolveLabel(from: estimate)

            return DOAEstimate(
                label: resolvedLabel,
                delaySamples: estimate.delaySamples,
                delaySeconds: estimate.delaySeconds,
                bearing: smoothedBearing,
                confidence: smoothedConfidence,
                isReliable: estimate.isReliable
            )
        }

        private func resolveLabel(from estimate: DOAEstimate) -> DOALabel {
            guard estimate.isReliable else {
                pendingLabel = nil
                pendingCount = 0
                return currentLabel
            }

            if estimate.label == currentLabel {
                pendingLabel = nil
                pendingCount = 0
                return currentLabel
            }

            if estimate.confidence < switchConfidence {
                pendingLabel = nil
                pendingCount = 0
                return currentLabel
            }

            if pendingLabel != estimate.label {
                pendingLabel = estimate.label
                pendingCount = 1
            } else {
                pendingCount += 1
            }

            if pendingCount >= switchFrames, let pendingLabel {
                currentLabel = pendingLabel
                self.pendingLabel = nil
                pendingCount = 0
            }

            return currentLabel
        }
    }

    private final class AudioInputManager {
        private let frameSize: Int
        private let hopSize: Int
        private let capacity: Int

        private var leftRing: [Float]
        private var rightRing: [Float]
        private var leftFrame: [Float]
        private var rightFrame: [Float]
        private var writeIndex: Int = 0
        private var readIndex: Int = 0
        private var availableCount: Int = 0

        init(frameSize: Int, hopSize: Int, capacityMultiplier: Int = 6) {
            self.frameSize = frameSize
            self.hopSize = hopSize
            self.capacity = frameSize * max(2, capacityMultiplier)
            self.leftRing = Array(repeating: 0, count: capacity)
            self.rightRing = Array(repeating: 0, count: capacity)
            self.leftFrame = Array(repeating: 0, count: frameSize)
            self.rightFrame = Array(repeating: 0, count: frameSize)
        }

        func append(buffer: AVAudioPCMBuffer, channelCount: Int, handler: (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) -> Void) {
            guard let channelData = buffer.floatChannelData else {
                return
            }

            let frameLength = Int(buffer.frameLength)
            let leftSamples = channelData[0]
            let rightSamples: UnsafePointer<Float> = channelCount > 1 ? UnsafePointer(channelData[1]) : UnsafePointer(channelData[0])

            for index in 0..<frameLength {
                leftRing[writeIndex] = leftSamples[index]
                rightRing[writeIndex] = rightSamples[index]

                writeIndex += 1
                if writeIndex == capacity {
                    writeIndex = 0
                }

                if availableCount < capacity {
                    availableCount += 1
                } else {
                    readIndex += 1
                    if readIndex == capacity {
                        readIndex = 0
                    }
                }
            }

            while availableCount >= frameSize {
                for offset in 0..<frameSize {
                    let ringIndex = (readIndex + offset) % capacity
                    leftFrame[offset] = leftRing[ringIndex]
                    rightFrame[offset] = rightRing[ringIndex]
                }

                leftFrame.withUnsafeBufferPointer { leftBuffer in
                    rightFrame.withUnsafeBufferPointer { rightBuffer in
                        handler(leftBuffer, rightBuffer)
                    }
                }

                readIndex += hopSize
                if readIndex >= capacity {
                    readIndex -= capacity
                }
                availableCount -= hopSize
            }
        }
    }

    private final class GCCPHATEstimator {
        private let frameSize: Int
        private let sampleRate: Double
        private let maxLagSamples: Int
        private let centerThresholdSamples: Int
        private let minConfidence: Double

        private let window: [Float]
        private let forwardTransform: vDSP.DiscreteFourierTransform<Float>
        private let inverseTransform: vDSP.DiscreteFourierTransform<Float>

        private var leftWork: [Float]
        private var rightWork: [Float]
        private var leftInputImag: [Float]
        private var rightInputImag: [Float]
        private var leftReal: [Float]
        private var leftImag: [Float]
        private var rightReal: [Float]
        private var rightImag: [Float]
        private var crossReal: [Float]
        private var crossImag: [Float]
        private var correlation: [Float]
        private var inverseImag: [Float]
        private var realSq: [Float]
        private var imagSq: [Float]
        private var magnitude: [Float]

        init?(frameSize: Int, sampleRate: Double, maxLagSeconds: Double = 0.0007, minConfidence: Double = 0.35) {
            guard frameSize > 0 else {
                return nil
            }

            self.frameSize = frameSize
            self.sampleRate = sampleRate
            self.maxLagSamples = min(Int(maxLagSeconds * sampleRate), frameSize / 2)
            self.centerThresholdSamples = max(1, Int(Double(self.maxLagSamples) * 0.2))
            self.minConfidence = minConfidence

            guard let forward = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: frameSize,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            ),
                  let inverse = try? vDSP.DiscreteFourierTransform(
                    previous: nil,
                    count: frameSize,
                    direction: .inverse,
                    transformType: .complexComplex,
                    ofType: Float.self
                  ) else {
                return nil
            }

            self.forwardTransform = forward
            self.inverseTransform = inverse
            self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)

            self.leftWork = Array(repeating: 0, count: frameSize)
            self.rightWork = Array(repeating: 0, count: frameSize)
            self.leftInputImag = Array(repeating: 0, count: frameSize)
            self.rightInputImag = Array(repeating: 0, count: frameSize)
            self.leftReal = Array(repeating: 0, count: frameSize)
            self.leftImag = Array(repeating: 0, count: frameSize)
            self.rightReal = Array(repeating: 0, count: frameSize)
            self.rightImag = Array(repeating: 0, count: frameSize)
            self.crossReal = Array(repeating: 0, count: frameSize)
            self.crossImag = Array(repeating: 0, count: frameSize)
            self.correlation = Array(repeating: 0, count: frameSize)
            self.inverseImag = Array(repeating: 0, count: frameSize)
            self.realSq = Array(repeating: 0, count: frameSize)
            self.imagSq = Array(repeating: 0, count: frameSize)
            self.magnitude = Array(repeating: 0, count: frameSize)
        }

        func processStereoFrame(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> DOAEstimate {
            prepareChannel(left, into: &leftWork)
            prepareChannel(right, into: &rightWork)

            forwardTransform.transform(inputReal: leftWork, inputImaginary: leftInputImag, outputReal: &leftReal, outputImaginary: &leftImag)
            forwardTransform.transform(inputReal: rightWork, inputImaginary: rightInputImag, outputReal: &rightReal, outputImaginary: &rightImag)

            for index in 0..<frameSize {
                let aReal = leftReal[index]
                let aImag = leftImag[index]
                let bReal = rightReal[index]
                let bImag = rightImag[index]

                crossReal[index] = aReal * bReal + aImag * bImag
                crossImag[index] = aImag * bReal - aReal * bImag
            }

            vDSP_vsq(crossReal, 1, &realSq, 1, vDSP_Length(frameSize))
            vDSP_vsq(crossImag, 1, &imagSq, 1, vDSP_Length(frameSize))
            vDSP_vadd(realSq, 1, imagSq, 1, &magnitude, 1, vDSP_Length(frameSize))

            for index in 0..<frameSize {
                magnitude[index] = sqrt(magnitude[index])
            }

            let eps: Float = 1e-8
            for index in 0..<frameSize {
                let denom = magnitude[index] + eps
                crossReal[index] /= denom
                crossImag[index] /= denom
            }

            inverseTransform.transform(inputReal: crossReal, inputImaginary: crossImag, outputReal: &correlation, outputImaginary: &inverseImag)

            let scale = Float(1.0 / Double(frameSize))
            vDSP_vsmul(correlation, 1, [scale], &correlation, 1, vDSP_Length(frameSize))

            return analyzeCorrelation(correlation)
        }

        private func prepareChannel(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) {
            output.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: input.baseAddress!, count: frameSize)
            }

            var mean: Float = 0
            vDSP_meanv(output, 1, &mean, vDSP_Length(frameSize))
            var negativeMean = -mean
            vDSP_vsadd(output, 1, &negativeMean, &output, 1, vDSP_Length(frameSize))
            vDSP_vmul(output, 1, window, 1, &output, 1, vDSP_Length(frameSize))
        }

        private func analyzeCorrelation(_ correlation: [Float]) -> DOAEstimate {
            let lagWindow = max(1, maxLagSamples)
            let upperIndex = min(lagWindow, frameSize - 1)
            let lowerStart = max(frameSize - lagWindow, 0)

            var peakIndex = 0
            var peakValue: Float = 0
            var secondPeak: Float = 0
            var sumAbs: Float = 0
            var count: Int = 0

            func inspect(index: Int) {
                let value = abs(correlation[index])
                sumAbs += value
                count += 1
                if value > peakValue {
                    secondPeak = peakValue
                    peakValue = value
                    peakIndex = index
                } else if value > secondPeak {
                    secondPeak = value
                }
            }

            for index in 0...upperIndex {
                inspect(index: index)
            }
            if lowerStart < frameSize {
                for index in lowerStart..<frameSize {
                    inspect(index: index)
                }
            }

            let average = sumAbs / Float(max(1, count))
            let ratio = peakValue / max(secondPeak, 1e-6)
            let peakToAverage = peakValue / max(average, 1e-6)

            let ratioScore = clamp01((Double(ratio) - 1.0) / 2.0)
            let avgScore = clamp01((Double(peakToAverage) - 1.0) / 5.0)
            let confidence = 0.6 * ratioScore + 0.4 * avgScore

            var lagSamples = peakIndex
            if peakIndex > frameSize / 2 {
                lagSamples = peakIndex - frameSize
            }

            if abs(lagSamples) > maxLagSamples {
                lagSamples = 0
            }

            let delaySeconds = Double(lagSamples) / sampleRate
            let bearing = maxLagSamples > 0 ? clamp(Double(lagSamples) / Double(maxLagSamples), min: -1, max: 1) : 0

            let label: DOALabel
            if abs(lagSamples) <= centerThresholdSamples {
                label = .center
            } else if lagSamples < 0 {
                label = .left
            } else {
                label = .right
            }

            let isReliable = confidence >= minConfidence && peakValue > 1e-5

            return DOAEstimate(
                label: label,
                delaySamples: lagSamples,
                delaySeconds: delaySeconds,
                bearing: bearing,
                confidence: confidence,
                isReliable: isReliable
            )
        }

        private func clamp01(_ value: Double) -> Double {
            clamp(value, min: 0, max: 1)
        }

        private func clamp(_ value: Double, min: Double, max: Double) -> Double {
            Swift.max(min, Swift.min(value, max))
        }
    }
}
