import Foundation
import AVFoundation
import Accelerate

// ═══════════════════════════════════════════════════════════════
// MARK: - AudioDirectionEngine
// ═══════════════════════════════════════════════════════════════
//
//  Two-mode direction-of-arrival:
//
//    • STEREO (preferred): GCC-PHAT cross-correlation + ILD fusion
//      between L/R channels → instant direction, no rotation needed.
//      GCC-PHAT provides fine angular resolution (≈5°) in the
//      300–2400 Hz band; ILD covers higher frequencies.
//      Enabled via .videoRecording or .default session mode if
//      device provides 2+ channels.
//
//    • MONO (fallback): Front Cardioid in .measurement mode →
//      rotation-scan.  User sweeps phone to build energy map.
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
        //
        //  KEY FIX: AVAudioEngine.inputNode caches its format
        //  from the moment of FIRST ACCESS.  Our tearDown()
        //  accesses it before session config → it's stuck mono.
        //
        //  Solution: configure session FIRST, then create a
        //  brand-new AVAudioEngine.  The fresh engine's inputNode
        //  picks up the 2ch session automatically.

        var isStereo = false

        if configureStereoSession() {
            audioEngine = AVAudioEngine()
            let ch = audioEngine.inputNode.outputFormat(forBus: 0).channelCount
            let sr = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
            Self.post("STEREO engine: ch=\(ch) sr=\(Int(sr))")

            if ch >= 2 {
                isStereo = true
            } else {
                Self.post("Engine still mono — full fallback to measurement+cardioid")
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        // ── 4. Mono fallback with CORRECT session ───────────
        //
        //  CRITICAL: when stereo fails, reconfigure the session
        //  to .measurement + Front Cardioid.  Without this the
        //  mono tracker runs against .videoRecording + .stereo
        //  polar pattern = wrong AGC = instant false lock.

        if !isStereo {
            configureMonoSession()
            audioEngine = AVAudioEngine()
            let ch = audioEngine.inputNode.outputFormat(forBus: 0).channelCount
            let sr = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
            Self.post("MONO engine: ch=\(ch) sr=\(Int(sr))")
        }

        // ── 5. Install tap ──────────────────────────────────

        let node = audioEngine.inputNode
        node.removeTap(onBus: 0)

        let stereoTracker = isStereo ? StereoTracker() : nil
        let monoTracker   = isStereo ? nil : MonoScanTracker()
        let stereoMode = isStereo

        var frameCount: UInt64 = 0
        var lastYieldTime = CFAbsoluteTimeGetCurrent()
        let yieldInterval = 1.0 / 20.0

        node.installTap(
            onBus: 0, bufferSize: 1024, format: nil
        ) { buf, _ in
            let now = CFAbsoluteTimeGetCurrent()
            let heading = headingBox.get()
            let len = Int(buf.frameLength)
            guard len > 0 else { return }

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
                        phoneHeading:  heading,
                        targetBearing: result.bearing,
                        confidence:    result.confidence,
                        isLocked:      result.isLocked,
                        isStereoMode:  true
                    ))
                }

                frameCount += 1
                if frameCount % 40 == 0 {
                    Self.post(String(
                        format: "STEREO  hdg %.0f°  brg %.0f°  tdoa %.2f  ild %.1fdB  gccConf %.2f  conf %.2f",
                        heading, result.bearing, result.tdoa, result.ild,
                        result.gccPeak, result.confidence
                    ))
                }

            } else if let tracker = monoTracker {
                guard let ptr = buf.floatChannelData?[0] else { return }

                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(len))
                rms *= 10.0
                let db = Double(20 * log10f(max(rms, 1e-10)))

                let result = tracker.process(heading: heading, db: db)

                if now - lastYieldTime >= yieldInterval {
                    lastYieldTime = now
                    continuation.yield(DirectionSample(
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

        // ── 6. Cleanup ─────────────────────────────────────

        continuation.onTermination = { [weak self] _ in
            headingTask.cancel()
            self?.tearDown()
        }

        // ── 7. Start ────────────────────────────────────────

        do {
            try audioEngine.start()
        } catch {
            Self.post("ERROR engine: \(error.localizedDescription)")
            headingTask.cancel()
            continuation.finish()
            return
        }

        // ── 8. Post-start info ──────────────────────────────

        let routeFmt = node.outputFormat(forBus: 0)
        let inp = session.currentRoute.inputs.first
        let ds  = inp?.selectedDataSource?.dataSourceName ?? "—"
        let pp  = inp?.selectedDataSource?.selectedPolarPattern?.rawValue ?? "—"
        Self.post("RUN \(isStereo ? "STEREO" : "MONO") ch=\(routeFmt.channelCount) sr=\(Int(routeFmt.sampleRate)) ds=\(ds) pp=\(pp)")
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
        let tdoa:       Double  // in fractional samples
        let gccPeak:    Double  // peak height (0–1 quality)
    }

    // ── Physical constants ───────────────────────────────────
    private let micSpacing: Double = 0.063  // ~6.3 cm for iPhone 16 Pro Max
    private let speedOfSound: Double = 343.0

    // ── FFT setup (512-point) ────────────────────────────────
    private let fftOrder: vDSP_Length = 9        // 2^9 = 512
    private let fftSize = 512
    private let fftSetup: FFTSetup

    // Pre-allocated buffers (avoid alloc in audio callback)
    private var windowBuf: [Float]
    private var leftBuf:   [Float]
    private var rightBuf:  [Float]
    private var fftRealL:  [Float]
    private var fftImagL:  [Float]
    private var fftRealR:  [Float]
    private var fftImagR:  [Float]
    private var crossReal: [Float]
    private var crossImag: [Float]
    private var corrBuf:   [Float]

    // ── Tuning ──────────────────────────────────────────────
    private let ildScale:       Double = 15.0   // degrees per dB of ILD
    private let maxAngle:       Double = 90.0
    private let noiseFloor:     Float  = 0.0001 // RMS below = silence
    private let gccWeight:      Double = 0.7    // GCC contribution to fused angle
    private let ildWeight:      Double = 0.3    // ILD contribution
    private let lockThreshold:  Double = 0.40
    private let lockDuration:   Double = 0.8
    private let gccMinPeak:     Double = 0.05   // below = unreliable GCC

    // ── State ────────────────────────────────────────────────
    private var sampleRate:    Double = 48000
    private var smoothBearing: Double = .nan
    private var smoothConf:    Double = 0
    private var smoothIld:     Double = 0
    private var smoothTdoa:    Double = 0
    private var lockStreak:    Double = 0
    private var prevTime = CFAbsoluteTimeGetCurrent()
    private var maxTdoaSamples: Double = 0 // computed from sampleRate

    init() {
        fftSetup  = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!

        windowBuf = [Float](repeating: 0, count: 512)
        leftBuf   = [Float](repeating: 0, count: 512)
        rightBuf  = [Float](repeating: 0, count: 512)
        fftRealL  = [Float](repeating: 0, count: 256)
        fftImagL  = [Float](repeating: 0, count: 256)
        fftRealR  = [Float](repeating: 0, count: 256)
        fftImagR  = [Float](repeating: 0, count: 256)
        crossReal = [Float](repeating: 0, count: 256)
        crossImag = [Float](repeating: 0, count: 256)
        corrBuf   = [Float](repeating: 0, count: 512)

        // Hann window
        vDSP_hann_window(&windowBuf, vDSP_Length(512), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
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

        let n = min(frameCount, fftSize)

        // ── RMS for ILD + silence detection ─────────────────
        var rmsL: Float = 0, rmsR: Float = 0
        vDSP_rmsqv(left,  1, &rmsL, vDSP_Length(n))
        vDSP_rmsqv(right, 1, &rmsR, vDSP_Length(n))
        let level = max(rmsL, rmsR)
        let isSilent = level < noiseFloor

        // ── ILD ─────────────────────────────────────────────
        var ild: Double = 0
        if !isSilent && rmsL > 1e-10 && rmsR > 1e-10 {
            ild = 20.0 * Double(log10f(rmsR / rmsL))
        }
        smoothIld += (ild - smoothIld) * (isSilent ? 0.02 : 0.35)
        let ildAngle = max(-maxAngle, min(maxAngle, smoothIld * ildScale))

        // ── GCC-PHAT ────────────────────────────────────────
        var tdoa:    Double = 0
        var gccPeak: Double = 0
        var gccAngle: Double = 0

        if !isSilent {
            let (td, pk) = computeGCCPHAT(left: left, right: right, n: n)
            tdoa    = td
            gccPeak = pk

            // TDOA → angle:  θ = arcsin(τ · c / (d · fs))
            if maxTdoaSamples < 1 {
                maxTdoaSamples = micSpacing * sampleRate / speedOfSound
            }
            let sinArg = tdoa / maxTdoaSamples
            let clampedSin = max(-1.0, min(1.0, sinArg))
            gccAngle = asin(clampedSin) * 180.0 / .pi  // degrees
        }

        smoothTdoa += (tdoa - smoothTdoa) * (isSilent ? 0.02 : 0.30)

        // ── Fuse GCC + ILD ──────────────────────────────────
        //  If GCC peak is strong, trust it more.
        //  If GCC is unreliable (noisy, reverberant), lean on ILD.
        let gccReliable = gccPeak > gccMinPeak
        let wGcc = gccReliable ? gccWeight : 0.1
        let wIld = gccReliable ? ildWeight : 0.9
        let totalW = wGcc + wIld
        let fusedAngle = (gccAngle * wGcc + ildAngle * wIld) / totalW

        let rawBearing = DirectionMath.normalizedDegrees(heading + fusedAngle)

        // ── Confidence ──────────────────────────────────────
        var rawConf: Double = 0
        if !isSilent {
            let levelDb    = 20.0 * Double(log10f(max(level, 1e-10)))
            let signalConf = max(0, min(1, (levelDb + 40) / 30))
            let dirConf: Double
            if gccReliable {
                // GCC peak height is a direct quality measure (0–1)
                dirConf = min(1, gccPeak * 3.0)
            } else {
                dirConf = min(1, abs(smoothIld) / 4.0)
            }
            rawConf = signalConf * (0.3 + 0.7 * dirConf)
        }

        // ── Smooth bearing + confidence ─────────────────────
        if smoothBearing.isNaN { smoothBearing = rawBearing }
        let diff = DirectionMath.shortestAngle(from: smoothBearing, to: rawBearing)
        smoothBearing = DirectionMath.normalizedDegrees(
            smoothBearing + diff * (isSilent ? 0.01 : 0.25)
        )
        smoothConf += (rawConf - smoothConf) * (isSilent ? 0.02 : 0.20)

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
            gccPeak:    gccPeak
        )
    }

    // ── GCC-PHAT core ───────────────────────────────────────
    //
    //  1. Window + FFT both channels
    //  2. Cross-power spectrum:  G = L(f) · R*(f)
    //  3. PHAT whitening:        Ĝ = G / |G|
    //  4. IFFT → correlation
    //  5. Parabolic interpolation around peak → sub-sample TDOA
    //
    //  All done in-place with pre-allocated buffers.
    //  512-point FFT → 0.05 ms on A17 Pro.

    private func computeGCCPHAT(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        n: Int
    ) -> (tdoa: Double, peak: Double) {

        let N = fftSize
        let halfN = N / 2

        // ── Copy + zero-pad + window ────────────────────────
        let copyLen = min(n, N)
        leftBuf.withUnsafeMutableBufferPointer { lb in
            lb.baseAddress!.initialize(repeating: 0, count: N)
            for i in 0..<copyLen { lb[i] = left[i] * windowBuf[i] }
        }
        rightBuf.withUnsafeMutableBufferPointer { rb in
            rb.baseAddress!.initialize(repeating: 0, count: N)
            for i in 0..<copyLen { rb[i] = right[i] * windowBuf[i] }
        }

        // ── Forward FFT (packed split-complex) ──────────────
        leftBuf.withUnsafeMutableBufferPointer { lb in
            var splitL = DSPSplitComplex(
                realp: &fftRealL, imagp: &fftImagL
            )
            lb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                vDSP_ctoz(cPtr, 2, &splitL, 1, vDSP_Length(halfN))
            }
            vDSP_fft_zrip(fftSetup, &splitL, 1, fftOrder, FFTDirection(kFFTDirection_Forward))
        }

        rightBuf.withUnsafeMutableBufferPointer { rb in
            var splitR = DSPSplitComplex(
                realp: &fftRealR, imagp: &fftImagR
            )
            rb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                vDSP_ctoz(cPtr, 2, &splitR, 1, vDSP_Length(halfN))
            }
            vDSP_fft_zrip(fftSetup, &splitR, 1, fftOrder, FFTDirection(kFFTDirection_Forward))
        }

        // ── Cross-power spectrum: G = L · conj(R) ───────────
        //    G_real = Lr·Rr + Li·Ri
        //    G_imag = Li·Rr - Lr·Ri
        for i in 0..<halfN {
            let lr = fftRealL[i], li = fftImagL[i]
            let rr = fftRealR[i], ri = fftImagR[i]
            crossReal[i] = lr * rr + li * ri
            crossImag[i] = li * rr - lr * ri
        }

        // ── PHAT whitening: Ĝ = G / |G| ────────────────────
        let epsilon: Float = 1e-10
        for i in 0..<halfN {
            let mag = sqrtf(crossReal[i] * crossReal[i] + crossImag[i] * crossImag[i]) + epsilon
            crossReal[i] /= mag
            crossImag[i] /= mag
        }

        // ── Inverse FFT ─────────────────────────────────────
        var splitC = DSPSplitComplex(
            realp: &crossReal, imagp: &crossImag
        )
        vDSP_fft_zrip(fftSetup, &splitC, 1, fftOrder, FFTDirection(kFFTDirection_Inverse))

        // Unpack split-complex → interleaved real correlation
        corrBuf.withUnsafeMutableBufferPointer { cb in
            cb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                vDSP_ztoc(&splitC, 1, cPtr, 2, vDSP_Length(halfN))
            }
        }

        // Scale (vDSP convention: IFFT result is scaled by N/2)
        var scale = Float(1.0 / Float(halfN))
        vDSP_vsmul(corrBuf, 1, &scale, &corrBuf, 1, vDSP_Length(N))

        // ── Find peak within plausible TDOA range ───────────
        //  Max TDOA ≈ micSpacing / speedOfSound * sampleRate ≈ 9 samples
        //  Search ±12 samples around lag=0 (wrap-around aware).
        let searchRadius = 12
        var bestVal: Float = -1
        var bestIdx = 0

        for lag in -searchRadius...searchRadius {
            let idx = (lag + N) % N
            let val = corrBuf[idx]
            if val > bestVal {
                bestVal = val
                bestIdx = lag
            }
        }

        // ── Parabolic interpolation for sub-sample accuracy ─
        let prevIdx = (bestIdx - 1 + N) % N
        let nextIdx = (bestIdx + 1 + N) % N
        let yPrev = Double(corrBuf[prevIdx])
        let yCurr = Double(bestVal)
        let yNext = Double(corrBuf[nextIdx])
        var fracLag = Double(bestIdx)
        let denom = yPrev - 2 * yCurr + yNext
        if abs(denom) > 1e-10 {
            fracLag += 0.5 * (yPrev - yNext) / denom
        }

        // ── Normalize peak (peak / mean of correlation) ─────
        var sumAbs: Float = 0
        for lag in -searchRadius...searchRadius {
            let idx = (lag + N) % N
            sumAbs += abs(corrBuf[idx])
        }
        let meanAbs = Double(sumAbs) / Double(2 * searchRadius + 1)
        let normPeak = meanAbs > 1e-10 ? Double(bestVal) / meanAbs : 0

        return (tdoa: fracLag, peak: min(normPeak, 1.0))
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
