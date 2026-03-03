import Foundation
import AVFoundation
import Accelerate

// ═══════════════════════════════════════════════════════════════
// MARK: - AudioDirectionEngine
// ═══════════════════════════════════════════════════════════════
//
//  Two-phase audio pipeline:
//
//  Phase 1 — DETECTION:
//    Captures stereo (or mono) audio, mixes to mono, feeds
//    DistressClassifier.  Yields detection-phase DirectionSamples
//    with classifier progress/confidence.  No direction tracking.
//
//  Phase 2 — DIRECTION (after distress confirmed):
//    Same audio tap switches to GCC-PHAT + ILD (stereo) or
//    rotation-scan (mono) direction-of-arrival tracking.
//    Yields direction-phase DirectionSamples with bearing.
//
//  Uses Accelerate vDSP FFT for GCC-PHAT (512-point, <0.1 ms).

final class AudioDirectionEngine: DirectionEngine {

    nonisolated static let debugNotification =
        Notification.Name("AudioDirectionEngineDebugNotification")

    nonisolated static func isSupported() -> Bool {
        AVAudioSession.sharedInstance().isInputAvailable
    }

    func stream() -> AsyncStream<DirectionSample> {
        tearDown()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.launchPipeline(continuation: continuation)
        }
    }

    // ─────────────────────────────────────────────────────────
    private var audioEngine      = AVAudioEngine()
    private let session          = AVAudioSession.sharedInstance()
    private let headingProvider  = HeadingProvider()
    private var interruptionToken: (any NSObjectProtocol)?

    // ─────────────────────────────────────────────────────────
    // MARK: Permission
    // ─────────────────────────────────────────────────────────

    private func launchPipeline(
        continuation: AsyncStream<DirectionSample>.Continuation
    ) {
        switch session.recordPermission {
        case .granted:
            buildAndStart(continuation: continuation)
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                guard let self, granted else {
                    Self.post("ERROR: mic permission denied")
                    continuation.finish()
                    return
                }
                self.buildAndStart(continuation: continuation)
            }
        default:
            Self.post("ERROR: mic permission denied")
            continuation.finish()
        }
    }

    // ─────────────────────────────────────────────────────────
    // MARK: Pipeline
    // ─────────────────────────────────────────────────────────

    private func buildAndStart(
        continuation: AsyncStream<DirectionSample>.Continuation
    ) {
        // ── 1. Heading ──────────────────────────────────────

        let headingBox = SharedHeading()
        let headingTask = Task {
            for await h in self.headingProvider.stream() {
                headingBox.set(h)
            }
        }

        // ── 2. Interruption handling ────────────────────────

        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: nil
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            if kind == .ended { try? self.audioEngine.start() }
        }

        // ── 3. Attempt stereo ───────────────────────────────

        var isStereo = false

        if configureStereoSession() {
            audioEngine = AVAudioEngine()
            let ch = audioEngine.inputNode.outputFormat(forBus: 0).channelCount
            let sr = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
            Self.post("STEREO engine: ch=\(ch) sr=\(Int(sr))")
            if ch >= 2 {
                isStereo = true
            } else {
                Self.post("Engine still mono — fallback")
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        if !isStereo {
            configureMonoSession()
            audioEngine = AVAudioEngine()
            let ch = audioEngine.inputNode.outputFormat(forBus: 0).channelCount
            let sr = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
            Self.post("MONO engine: ch=\(ch) sr=\(Int(sr))")
        }

        // ── 4. Install tap (two-phase) ──────────────────────
        //
        //  Phase 1: Feed mono audio to DistressClassifier.
        //           Yield detection samples (progress, confidence).
        //  Phase 2: Once distress confirmed, activate direction
        //           trackers.  Yield direction samples (bearing).

        let node = audioEngine.inputNode
        node.removeTap(onBus: 0)

        let classifier    = DistressClassifier()
        let stereoTracker = isStereo ? StereoTracker() : nil
        let monoTracker   = isStereo ? nil : MonoScanTracker()
        let stereoMode    = isStereo
        let bufferNeeded  = classifier.melComputer.inputFramesNeeded

        // Mutable state captured by tap
        var currentPhase: AppPhase = .detecting
        var frameCount: UInt64 = 0
        var lastYieldTime = CFAbsoluteTimeGetCurrent()
        let yieldInterval = 1.0 / 20.0

        node.installTap(
            onBus: 0, bufferSize: 4096, format: nil
        ) { buf, _ in
            let now = CFAbsoluteTimeGetCurrent()
            let heading = headingBox.get()
            let len = Int(buf.frameLength)
            guard len > 0, let ch0 = buf.floatChannelData?[0] else { return }

            // ═══════════════════════════════════════════════════
            // PHASE 1: DETECTION
            // ═══════════════════════════════════════════════════
            if currentPhase == .detecting {

                // Mix to mono if stereo (L+R)/2, else just use ch0
                var result: DistressClassifier.ClassificationResult?

                if stereoMode, let ch1 = buf.floatChannelData?[1] {
                    var mixed = [Float](repeating: 0, count: len)
                    vDSP_vadd(ch0, 1, ch1, 1, &mixed, 1, vDSP_Length(len))
                    var half: Float = 0.5
                    vDSP_vsmul(mixed, 1, &half, &mixed, 1, vDSP_Length(len))
                    result = mixed.withUnsafeBufferPointer { ptr in
                        classifier.feedAudio(ptr.baseAddress!, count: len)
                    }
                } else {
                    result = classifier.feedAudio(ch0, count: len)
                }

                // Yield detection progress
                if now - lastYieldTime >= yieldInterval {
                    lastYieldTime = now

                    let progress = Double(classifier.audioBufferCount) / Double(bufferNeeded)

                    if let result {
                        continuation.yield(DirectionSample(
                            phase: .detecting,
                            distressConfidence: result.distressProb,
                            bufferProgress: 1.0,
                            isDistressConfirmed: result.isDistress,
                            phoneHeading: heading,
                            targetBearing: 0,
                            confidence: 0,
                            isLocked: false,
                            isStereoMode: stereoMode
                        ))

                        // Transition to direction phase!
                        if result.isDistress {
                            currentPhase = .directing
                            classifier.reset()
                            Self.post("═══ DISTRESS CONFIRMED — switching to DIRECTION mode ═══")
                        }
                    } else {
                        continuation.yield(DirectionSample(
                            phase: .detecting,
                            distressConfidence: 0,
                            bufferProgress: min(progress, 1.0),
                            isDistressConfirmed: false,
                            phoneHeading: heading,
                            targetBearing: 0,
                            confidence: 0,
                            isLocked: false,
                            isStereoMode: stereoMode
                        ))
                    }
                }

                frameCount += 1
                if frameCount % 80 == 0 {
                    let progress = Double(classifier.audioBufferCount) / Double(bufferNeeded)
                    Self.post(String(format: "DETECT  buf %.0f%%  %@",
                                     progress * 100,
                                     stereoMode ? "stereo→mono" : "mono"))
                }
                return
            }

            // ═══════════════════════════════════════════════════
            // PHASE 2: DIRECTION
            // ═══════════════════════════════════════════════════
            if stereoMode, let tracker = stereoTracker {
                guard let L = buf.floatChannelData?[0],
                      let R = buf.floatChannelData?[1] else { return }

                let result = tracker.process(
                    heading: heading,
                    left: L, right: R, frameCount: len
                )

                if now - lastYieldTime >= yieldInterval {
                    lastYieldTime = now
                    continuation.yield(DirectionSample(
                        phase: .directing,
                        isDistressConfirmed: true,
                        phoneHeading:  heading,
                        targetBearing: result.bearing,
                        confidence:    result.confidence,
                        isLocked:      result.isLocked,
                        isStereoMode:  true
                    ))
                }

                frameCount += 1
                if frameCount % 40 == 0 {
                    let voice = result.rmsL > 0.012 || result.rmsR > 0.012
                    Self.post(String(
                        format: "STEREO brg %.0f° gcc∠%.0f° ild∠%.0f° fuse∠%.0f° tdR %.2f tdC %.2f pk %.2f conf %.2f L %.4f R %.4f %@",
                        result.bearing,
                        result.gccAngle,
                        result.ildAngle,
                        result.fusedAngle,
                        result.tdoaRaw,
                        result.tdoa,
                        result.gccPeak,
                        result.confidence,
                        result.rmsL,
                        result.rmsR,
                        voice ? "VOICE" : "quiet"
                    ))
                }

            } else if let tracker = monoTracker {
                var rms: Float = 0
                vDSP_rmsqv(ch0, 1, &rms, vDSP_Length(len))
                rms *= 10.0
                let db = Double(20 * log10f(max(rms, 1e-10)))

                let result = tracker.process(heading: heading, db: db)

                if now - lastYieldTime >= yieldInterval {
                    lastYieldTime = now
                    continuation.yield(DirectionSample(
                        phase: .directing,
                        isDistressConfirmed: true,
                        phoneHeading:  heading,
                        targetBearing: result.bearing,
                        confidence:    result.confidence,
                        isLocked:      result.isLocked,
                        isStereoMode:  false
                    ))
                }

                frameCount += 1
                if frameCount % 40 == 0 {
                    Self.post(String(
                        format: "MONO %@  hdg %.0f°  brg %.0f°  conf %.2f  dB %.1f  amb %.1f  cov %.0f°",
                        result.phase.rawValue, heading, result.bearing,
                        result.confidence, db, result.ambientDb, result.coverage
                    ))
                }
            }
        }

        // ── 5. Cleanup ─────────────────────────────────────

        continuation.onTermination = { [weak self] _ in
            headingTask.cancel()
            self?.tearDown()
        }

        // ── 6. Start ────────────────────────────────────────

        do {
            try audioEngine.start()
        } catch {
            Self.post("ERROR engine: \(error.localizedDescription)")
            headingTask.cancel()
            continuation.finish()
            return
        }

        // ── 7. Post-start info ──────────────────────────────

        let routeFmt = node.outputFormat(forBus: 0)
        let inp = session.currentRoute.inputs.first
        let ds  = inp?.selectedDataSource?.dataSourceName ?? "—"
        let pp  = inp?.selectedDataSource?.selectedPolarPattern?.rawValue ?? "—"
        Self.post("PHASE 1: DETECTING — \(isStereo ? "STEREO" : "MONO") ch=\(routeFmt.channelCount) sr=\(Int(routeFmt.sampleRate)) ds=\(ds) pp=\(pp)")
    }

    // ─────────────────────────────────────────────────────────
    // MARK: Session configuration
    // ─────────────────────────────────────────────────────────

    /// Brute-force try every category × mode × data source combo
    /// to get stereo (2+ channels).  Polar patterns are only
    /// visible AFTER applying a category+mode, so we must dump
    /// them inside each attempt.
    private func configureStereoSession() -> Bool {
        // .playAndRecord is required (we need speaker output).
        // .videoRecording and .default are the modes that expose .stereo.
        let modes: [AVAudioSession.Mode] = [.videoRecording, .default]
        for mode in modes {
            if tryStereoCombo(mode: mode) { return true }
        }
        return false
    }

    private func tryStereoCombo(mode: AVAudioSession.Mode) -> Bool {
        let label = mode.rawValue
        do {
            // 1. Category + mode — NO .allowBluetooth (deprecated + interferes)
            try session.setCategory(
                .playAndRecord, mode: mode,
                options: [.defaultToSpeaker]
            )

            // 2. Preferred input = built-in mic
            guard let mic = session.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) else {
                Self.post("[\(label)] no builtInMic")
                return false
            }
            try session.setPreferredInput(mic)

            // 3. Dump patterns (for diagnostics)
            if let dataSources = mic.dataSources {
                for ds in dataSources {
                    let pats = ds.supportedPolarPatterns?
                        .map(\.rawValue).joined(separator: ", ") ?? "none"
                    Self.post("[\(label)] \(ds.dataSourceName): [\(pats)]")
                }
            }

            // 4. Find and select .stereo polar pattern
            //    Prefer Front (better for flat-phone use), then Back
            var foundStereo = false
            if let dataSources = mic.dataSources {
                let ordered = dataSources.sorted {
                    ($0.dataSourceName == "Front" ? 0 : 1) <
                    ($1.dataSourceName == "Front" ? 0 : 1)
                }
                for ds in ordered {
                    if let pp = ds.supportedPolarPatterns, pp.contains(.stereo) {
                        try mic.setPreferredDataSource(ds)
                        try ds.setPreferredPolarPattern(.stereo)
                        Self.post("[\(label)] ✓ set '\(ds.dataSourceName)' → .stereo")
                        foundStereo = true
                        break
                    }
                }
            }

            if !foundStereo {
                Self.post("[\(label)] no .stereo pattern, skip")
                return false
            }

            // 5. Set sample rate + orientation BEFORE activation
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredInputOrientation(.portrait)

            // 6. Activate session FIRST (without requesting 2 channels)
            //    Apple docs: setPreferredInputNumberOfChannels is
            //    "only valid while the session is active"
            try session.setActive(true)
            Self.post("[\(label)] active! maxCh=\(session.maximumInputNumberOfChannels)")

            // 7. NOW request 2 channels (session is active)
            if session.maximumInputNumberOfChannels >= 2 {
                try session.setPreferredInputNumberOfChannels(2)
                Self.post("[\(label)] requested 2ch — session ready")
            } else {
                Self.post("[\(label)] maxCh=\(session.maximumInputNumberOfChannels), can't do stereo")
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }

            // NOTE: We do NOT touch audioEngine here.
            //   buildAndStart() creates a fresh AVAudioEngine after
            //   this returns, so its inputNode picks up the 2ch session.
            return true
        } catch {
            Self.post("[\(label)] error: \(error.localizedDescription)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
    }

    /// Mono fallback: .measurement + Front Cardioid for best directionality.
    private func configureMonoSession() {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker]
            )

            if let mic = session.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) {
                try? session.setPreferredInput(mic)
                if let ds = mic.dataSources {
                    // Front Cardioid gives ~20 dB front-to-back ratio
                    // when phone is held upright (screen toward user).
                    if let front = ds.first(where: { $0.dataSourceName == "Front" }) {
                        try? mic.setPreferredDataSource(front)
                        if let pp = front.supportedPolarPatterns, pp.contains(.cardioid) {
                            try? front.setPreferredPolarPattern(.cardioid)
                        }
                        Self.post("MIC: Front Cardioid (mono)")
                    } else if let bottom = ds.first(where: { $0.dataSourceName == "Bottom" }) {
                        try? mic.setPreferredDataSource(bottom)
                        Self.post("MIC: Bottom Omni (mono)")
                    }
                }
            }

            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            try? session.setInputGain(1.0)
            // NOTE: do NOT call audioEngine.reset() here.
            //   buildAndStart() creates a fresh AVAudioEngine after this.
        } catch {
            Self.post("ERROR mono session: \(error.localizedDescription)")
        }
    }

    // ─────────────────────────────────────────────────────────
    // MARK: Teardown
    // ─────────────────────────────────────────────────────────

    private func tearDown() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        if let tok = interruptionToken {
            NotificationCenter.default.removeObserver(tok)
            interruptionToken = nil
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func post(_ msg: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: debugNotification, object: nil,
                userInfo: ["summary": msg]
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - SharedHeading
// ═══════════════════════════════════════════════════════════════

private final class SharedHeading: @unchecked Sendable {
    private var _v: Double = 0
    private let lock = NSLock()
    func get() -> Double  { lock.lock(); defer { lock.unlock() }; return _v }
    func set(_ v: Double) { lock.lock(); _v = v; lock.unlock() }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - StereoTracker  (GCC-PHAT + ILD fusion)
// ═══════════════════════════════════════════════════════════════
//
//  Fuses two cues from stereo L/R channels:
//
//  1. GCC-PHAT (Generalized Cross-Correlation, Phase Transform)
//     - FFT both channels → cross-power spectrum → PHAT whitening
//     - IFFT → peak = TDOA in samples → angle via arcsin
//     - Best for 300–2400 Hz (below spatial aliasing limit)
//     - Gives ≈5° angular resolution with ~6 cm mic spacing
//
//  2. ILD (Interaural Level Difference)
//     - 20·log₁₀(R/L) → angle via linear scale
//     - Complements GCC at higher frequencies
//
//  Convention (with .portrait input orientation, phone flat screen-up):
//    L channel = phone's left,  R channel = phone's right.
//    Positive angle → sound from phone's right → bearing = heading + angle

private final class StereoTracker: @unchecked Sendable {

    struct Result {
        let bearing:    Double
        let confidence: Double
        let isLocked:   Bool
        let ild:        Double
        let tdoa:       Double  // in fractional samples (bias-corrected)
        let gccPeak:    Double  // peak height (0–1 quality)
        let rmsL:       Float   // raw left-channel RMS
        let rmsR:       Float   // raw right-channel RMS
        let gccAngle:   Double  // raw GCC-derived angle (degrees)
        let ildAngle:   Double  // raw ILD-derived angle (degrees)
        let fusedAngle: Double  // fused angle (degrees, + = right)
        let tdoaRaw:    Double  // TDOA before bias removal
    }

    // ── Physical constants ───────────────────────────────────
    private let micSpacing: Double = 0.063  // ~6.3 cm for iPhone 16 Pro Max
    private let speedOfSound: Double = 343.0

    // ── Cross-correlation setup ──────────────────────────────
    private let corrSize = 512   // samples to use for correlation
    private let searchRadius = 12 // ±12 lags

    // Pre-allocated buffers
    private var diffL: [Float]   // differentiated (high-passed) left
    private var diffR: [Float]   // differentiated (high-passed) right

    // ── Tuning ──────────────────────────────────────────────
    private let ildScale:       Double = 18.0   // degrees per dB of ILD
    private let maxAngle:       Double = 90.0
    private let noiseFloor:     Float  = 0.0001 // RMS below = dead silence
    private let voiceFloor:     Float  = 0.012  // RMS below = ambient noise (no voice)
    private let gccWeight:      Double = 0.15   // GCC contribution (secondary — hardware delay issue)
    private let ildWeight:      Double = 0.85   // ILD contribution (primary — clearly tracks direction)
    private let lockThreshold:  Double = 0.40
    private let lockDuration:   Double = 0.8
    private let gccMinPeak:     Double = 0.25   // quality must be genuinely good

    // ── State ────────────────────────────────────────────────
    private var sampleRate:    Double = 48000
    private var smoothBearing: Double = .nan
    private var smoothConf:    Double = 0
    private var smoothIld:     Double = 0
    private var smoothTdoa:    Double = 0
    private var lockStreak:    Double = 0
    private var prevTime = CFAbsoluteTimeGetCurrent()
    private var maxTdoaSamples: Double = 0

    // ── Auto bias calibration (EMA) ──────────────────────────
    //  Hardware/DSP may have a fixed TDOA offset between channels.
    //  We estimate it from quiet (non-voice) frames via exponential
    //  moving average and subtract from voice TDOA.
    private var tdoaBias:       Double = 0
    private var biasCount:      Int    = 0
    private let biasWarmup:     Int    = 10  // frames before bias is valid
    private let biasAlpha:      Double = 0.05 // EMA smoothing for bias
    private var biasReady:      Bool   = false

    init() {
        diffL = [Float](repeating: 0, count: corrSize)
        diffR = [Float](repeating: 0, count: corrSize)
    }

    // ── Main entry: called from audio tap ────────────────────
    func process(
        heading: Double,
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) -> Result {
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = min(now - prevTime, 0.1)
        prevTime = now

        let n = min(frameCount, corrSize)

        // ── RMS for ILD + silence/voice detection ───────────
        var rmsL: Float = 0, rmsR: Float = 0
        vDSP_rmsqv(left,  1, &rmsL, vDSP_Length(n))
        vDSP_rmsqv(right, 1, &rmsR, vDSP_Length(n))
        let level = max(rmsL, rmsR)
        let hasVoice = level >= voiceFloor

        // ── ILD ─────────────────────────────────────────────
        var ild: Double = 0
        if hasVoice && rmsL > 1e-10 && rmsR > 1e-10 {
            // Negated: iPhone stereo mic layout maps L-channel to phone's right
            ild = 20.0 * Double(log10f(rmsL / rmsR))
        }
        if hasVoice {
            smoothIld += (ild - smoothIld) * 0.35
        }
        let ildAngle = max(-maxAngle, min(maxAngle, smoothIld * ildScale))

        // ── Time-domain cross-correlation ────────────────────
        //
        //  1. Differentiate both channels (high-pass: removes DC/rumble)
        //  2. Normalized cross-correlation for lags ±12
        //  3. Peak → TDOA in samples
        //  4. Subtract auto-calibrated bias
        //  5. TDOA → angle
        //
        //  Simple, no FFT, no packed-format bugs.

        var tdoaRaw:  Double = 0
        var tdoa:     Double = 0
        var gccPeak:  Double = 0
        var gccAngle: Double = 0

        if level > noiseFloor {
            let (td, pk) = computeCrossCorrelation(left: left, right: right, n: n)
            tdoaRaw = td
            gccPeak = pk

            // ── Auto-bias: EMA from quiet frames ────────────
            //  Only accumulate when above noise floor (real signal)
            //  but below voice floor (no directional content).
            if !hasVoice {
                biasCount += 1
                if biasCount <= biasWarmup {
                    // Seed phase: simple running average
                    tdoaBias += (td - tdoaBias) / Double(biasCount)
                } else {
                    // EMA phase: smooth adaptation
                    tdoaBias += biasAlpha * (td - tdoaBias)
                }
                if biasCount >= biasWarmup {
                    biasReady = true
                }
            }

            // Subtract bias
            tdoa = td - (biasReady ? tdoaBias : 0)

            // TDOA → angle
            if maxTdoaSamples < 1 {
                maxTdoaSamples = micSpacing * sampleRate / speedOfSound
            }
            let sinArg = tdoa / maxTdoaSamples
            let clampedSin = max(-1.0, min(1.0, sinArg))
            // Positive TDOA = left leads = sound from right (iPhone mic layout inverted)
            gccAngle = asin(clampedSin) * 180.0 / .pi
        }

        if hasVoice {
            smoothTdoa += (tdoa - smoothTdoa) * 0.30
        }

        // ── Fuse GCC + ILD ──────────────────────────────────
        let gccReliable = gccPeak > gccMinPeak && hasVoice
        let wGcc = gccReliable ? gccWeight : 0.1
        let wIld = gccReliable ? ildWeight : 0.9
        let totalW = wGcc + wIld
        let fusedAngle = (gccAngle * wGcc + ildAngle * wIld) / totalW

        let rawBearing = DirectionMath.normalizedDegrees(heading + fusedAngle)

        // ── Confidence ──────────────────────────────────────
        var rawConf: Double = 0
        if hasVoice {
            let levelDb    = 20.0 * Double(log10f(max(level, 1e-10)))
            let signalConf = max(0, min(1, (levelDb + 40) / 30))
            // Direction confidence from ILD magnitude (primary signal)
            let dirConf = min(1.0, abs(smoothIld) / 3.0)
            rawConf = signalConf * (0.4 + 0.6 * dirConf)
        }

        // ── Smooth bearing + confidence ─────────────────────
        if smoothBearing.isNaN { smoothBearing = rawBearing }
        if hasVoice {
            let diff = DirectionMath.shortestAngle(from: smoothBearing, to: rawBearing)
            smoothBearing = DirectionMath.normalizedDegrees(
                smoothBearing + diff * 0.25
            )
            smoothConf += (rawConf - smoothConf) * 0.20
        } else {
            smoothConf *= 0.97
        }

        // ── Lock ────────────────────────────────────────────
        if smoothConf > lockThreshold {
            lockStreak += dt
        } else {
            lockStreak = max(lockStreak - dt * 3, 0)
        }

        return Result(
            bearing:    smoothBearing,
            confidence: smoothConf,
            isLocked:   lockStreak > lockDuration,
            ild:        smoothIld,
            tdoa:       smoothTdoa,
            gccPeak:    gccPeak,
            rmsL:       rmsL,
            rmsR:       rmsR,
            gccAngle:   gccAngle,
            ildAngle:   ildAngle,
            fusedAngle: fusedAngle,
            tdoaRaw:    tdoaRaw
        )
    }

    // ── Time-domain cross-correlation ───────────────────────
    //
    //  Differentiate both channels (acts as ~6 dB/oct high-pass,
    //  removing DC and low-frequency room noise), then compute
    //  normalized cross-correlation for lags ±searchRadius.
    //
    //  Cost: O(N × searchRadius) ≈ 512 × 25 = 12,800 ops.
    //  Eliminates all FFT packed-format complexity.

    private func computeCrossCorrelation(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        n: Int
    ) -> (tdoa: Double, peak: Double) {

        let N = min(n, corrSize)
        guard N > 2 else { return (0, 0) }

        // Differentiate (high-pass filter): d[i] = x[i+1] - x[i]
        let dN = N - 1
        for i in 0..<dN {
            diffL[i] = left[i + 1] - left[i]
            diffR[i] = right[i + 1] - right[i]
        }

        // Normalize each channel by RMS (approximates PHAT whitening)
        var rmsL: Float = 0, rmsR: Float = 0
        vDSP_rmsqv(diffL, 1, &rmsL, vDSP_Length(dN))
        vDSP_rmsqv(diffR, 1, &rmsR, vDSP_Length(dN))
        let invL = rmsL > 1e-8 ? 1.0 / rmsL : Float(0)
        let invR = rmsR > 1e-8 ? 1.0 / rmsR : Float(0)

        guard invL > 0 && invR > 0 else { return (0, 0) }

        // Cross-correlation for lags in [-searchRadius, +searchRadius]
        //   corr(τ) = (1/M) Σ diffL[i] × diffR[i + τ]   (normalized)
        let nLags = 2 * searchRadius + 1
        var corrValues = [Double](repeating: 0, count: nLags)
        var bestVal: Double = -1e30
        var bestIdx = 0

        for lagIdx in 0..<nLags {
            let lag = lagIdx - searchRadius  // -12 to +12
            var sum: Double = 0
            var count = 0
            for i in 0..<dN {
                let j = i + lag
                if j >= 0 && j < dN {
                    sum += Double(diffL[i] * invL) * Double(diffR[j] * invR)
                    count += 1
                }
            }
            let val = count > 0 ? sum / Double(count) : 0
            corrValues[lagIdx] = val
            if val > bestVal {
                bestVal = val
                bestIdx = lagIdx
            }
        }

        let bestLag = bestIdx - searchRadius

        // Parabolic interpolation
        var fracLag = Double(bestLag)
        if bestIdx > 0 && bestIdx < nLags - 1 {
            let yP = corrValues[bestIdx - 1]
            let yC = corrValues[bestIdx]
            let yN = corrValues[bestIdx + 1]
            let denom = yP - 2.0 * yC + yN
            if abs(denom) > 1e-10 {
                fracLag += 0.5 * (yP - yN) / denom
            }
        }

        // Peak quality: ratio of best peak to second-best peak.
        // A clear directional signal has one dominant peak.
        // Noise/hardware artifacts have multiple similar peaks.
        var secondBest: Double = -1e30
        for lagIdx in 0..<nLags {
            let val = corrValues[lagIdx]
            // Must be at least 3 lags away from the best to count as separate peak
            if abs(lagIdx - bestIdx) >= 3 && val > secondBest {
                secondBest = val
            }
        }
        let ratio = secondBest > 1e-10 ? bestVal / secondBest : (bestVal > 0.01 ? 1.0 : 0.0)
        // ratio ≈ 1.0–1.2 = ambiguous (noise), ≈ 2+ = clear directional peak
        let normPeak = min(1.0, max(0, (ratio - 1.0) / 1.5))

        return (tdoa: fracLag, peak: normPeak)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - MonoScanTracker  (rotation scan, simple RMS, no FFT)
// ═══════════════════════════════════════════════════════════════
//
//  Lightweight rotation scan: user sweeps phone while sound plays.
//  Simple RMS energy is deposited into a circular map (72 bins × 5°).
//  Peak energy heading = source direction.  No FFT overhead.

private final class MonoScanTracker: @unchecked Sendable {

    enum Phase: String { case waiting, scanning, found }

    struct Result {
        let bearing:   Double
        let confidence: Double
        let isLocked:  Bool
        let phase:     Phase
        let coverage:  Double
        let ambientDb: Double
    }

    // Map
    private let binCount = 72
    private let binWidth = 5.0
    private var energy:  [Double]
    private var visited: [Bool]

    // Noise floor
    private var ambientDb:       Double = -50
    private let ambientAlpha:    Double = 0.003
    private let minAboveAmbient: Double = 10.0

    // Thresholds
    private let minCoverage: Double = 90.0
    private let decay:       Double = 0.997

    // State
    private var phase:         Phase  = .waiting
    private var smoothBearing: Double = .nan
    private var smoothConf:    Double = 0
    private var lockStreak:    Double = 0
    private var prevTime = CFAbsoluteTimeGetCurrent()

    init() {
        energy  = [Double](repeating: 0, count: 72)
        visited = [Bool](repeating: false, count: 72)
    }

    func process(heading: Double, db: Double) -> Result {
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = min(now - prevTime, 0.1)
        prevTime = now

        // ── Adaptive noise floor ────────────────────────────
        if db < ambientDb + 3 {
            ambientDb += (db - ambientDb) * ambientAlpha
        }
        let activeDb = ambientDb + minAboveAmbient

        // ── Decay ───────────────────────────────────────────
        for i in 0..<binCount { energy[i] *= decay }

        // ── Deposit energy ──────────────────────────────────
        let soundActive = db > activeDb
        if db > ambientDb + 3 {
            let linear = max(0, (db - ambientDb) / 30.0)
            let e = linear * linear
            let c = Int(heading / binWidth) % binCount
            let weights: [(Int, Double)] = [
                (0, 1.0), (1, 0.5), (-1, 0.5), (2, 0.12), (-2, 0.12)
            ]
            for (off, w) in weights {
                energy[(c + off + binCount) % binCount] += e * w
            }
            visited[c] = true
        }

        // ── Phase ───────────────────────────────────────────
        let cov = coverage()
        switch phase {
        case .waiting:  if soundActive { phase = .scanning }
        case .scanning: if cov >= minCoverage { phase = .found }
        case .found:    break
        }

        // ── Peak ────────────────────────────────────────────
        var maxE: Double = 0, maxI = 0, total: Double = 0
        for i in 0..<binCount {
            total += energy[i]
            if energy[i] > maxE { maxE = energy[i]; maxI = i }
        }

        let peakBin = refine(maxI)
        let rawBearing = DirectionMath.normalizedDegrees(
            (peakBin + 0.5) * binWidth
        )

        // ── Confidence ──────────────────────────────────────
        let mean = total / Double(binCount)
        var rawConf: Double = 0
        if mean > 0.001 {
            let ratio = maxE / mean
            rawConf = max(0, min(1, (ratio - 1.2) / 4.0))
        }
        if phase == .scanning { rawConf *= min(1, cov / minCoverage) }
        if phase == .waiting  { rawConf = 0 }
        if !soundActive       { rawConf *= 0.3 }

        // ── Smooth ──────────────────────────────────────────
        if smoothBearing.isNaN { smoothBearing = rawBearing }
        let diff = DirectionMath.shortestAngle(from: smoothBearing, to: rawBearing)
        let alpha = (phase == .found) ? 0.08 : 0.25
        smoothBearing = DirectionMath.normalizedDegrees(
            smoothBearing + diff * alpha
        )
        smoothConf += (rawConf - smoothConf) * 0.18

        // ── Lock ────────────────────────────────────────────
        if phase == .found && smoothConf > 0.5 {
            lockStreak += dt
        } else {
            lockStreak = max(lockStreak - dt * 2, 0)
        }

        return Result(
            bearing:   smoothBearing,
            confidence: smoothConf,
            isLocked:  lockStreak > 1.2,
            phase:     phase,
            coverage:  cov,
            ambientDb: ambientDb
        )
    }

    private func refine(_ i: Int) -> Double {
        let prev = energy[(i - 1 + binCount) % binCount]
        let curr = energy[i]
        let next = energy[(i + 1) % binCount]
        var rBin = Double(i)
        let d = prev - 2 * curr + next
        if abs(d) > 1e-10 { rBin += 0.5 * (prev - next) / d }
        return rBin
    }

    private func coverage() -> Double {
        var count = 0
        for v in visited where v { count += 1 }
        return Double(count) * binWidth
    }
}
