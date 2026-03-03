import Foundation
import Accelerate

// ═══════════════════════════════════════════════════════════════
// MARK: - MelSpectrogram
// ═══════════════════════════════════════════════════════════════
//
//  Computes a log-mel spectrogram from raw Float32 PCM audio.
//
//  Parameters (matching training pipeline):
//    Input sample rate : 48 000 Hz (downsampled internally to 16 000)
//    Target sample rate: 16 000 Hz
//    n_fft             : 1024
//    hop_length        : 256
//    n_mels            : 64
//    fmin              : 0 Hz
//    fmax              : 8000 Hz
//    Output            : log10(mel_power + 1e-10) * 10  (dB)
//
//  Output shape: [n_mels, n_frames] = [64, 188]  (for 3.0 s input)
//
//  All computation uses Accelerate / vDSP for real-time performance.

final class MelSpectrogram: @unchecked Sendable {

    // ── Public configuration ────────────────────────────────
    let inputSampleRate:  Double = 48_000
    let targetSampleRate: Double = 16_000
    let nFFT     = 1024
    let hopLength = 256
    let nMels     = 64
    let fMin: Double = 0
    let fMax: Double = 8000

    /// Number of input frames at 48 kHz for 3.0 s
    var inputFramesNeeded: Int { Int(inputSampleRate * 3.0) }   // 144 000

    /// Number of target frames at 16 kHz for 3.0 s
    var targetFramesNeeded: Int { Int(targetSampleRate * 3.0) } // 48 000

    /// Number of STFT time frames (with center padding, librosa-style)
    var numTimeFrames: Int { 188 }

    // ── FFT setup ───────────────────────────────────────────
    private let fftOrder: vDSP_Length = 10  // 2^10 = 1024
    private let fftSetup: FFTSetup
    private let halfFFT: Int  // 513 = nFFT/2 + 1

    // ── Pre-allocated buffers ───────────────────────────────
    private var window:     [Float]
    private var paddedBuf:  [Float]   // center-padded 16kHz audio
    private var frameBuf:   [Float]   // one windowed frame
    private var fftRealBuf: [Float]
    private var fftImagBuf: [Float]
    private var powerBuf:   [Float]   // |FFT|^2 for one frame
    private var melBuf:     [Float]   // mel energies for one frame

    // ── Mel filterbank ──────────────────────────────────────
    //  Stored as sparse: for each mel bin, a start FFT bin,
    //  an end FFT bin, and filter weights.
    private var melFilters: [[Float]]  // [nMels][variable length]
    private var melStarts:  [Int]      // [nMels]
    private var melEnds:    [Int]      // [nMels]

    // ── Resampler ───────────────────────────────────────────
    //  Simple 3:1 decimation with a low-pass FIR (order 48).
    private let decimationFactor = 3
    private var antiAliasFIR: [Float]
    private let firLen = 49  // odd length

    // ─────────────────────────────────────────────────────────
    init() {
        halfFFT = nFFT / 2 + 1  // 513

        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!

        // Hann window (nFFT)
        window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))

        paddedBuf  = []
        frameBuf   = [Float](repeating: 0, count: nFFT)
        fftRealBuf = [Float](repeating: 0, count: nFFT / 2)
        fftImagBuf = [Float](repeating: 0, count: nFFT / 2)
        powerBuf   = [Float](repeating: 0, count: halfFFT)
        melBuf     = [Float](repeating: 0, count: nMels)

        melFilters = []
        melStarts  = []
        melEnds    = []

        // Build low-pass FIR for anti-aliasing before decimation
        antiAliasFIR = MelSpectrogram.buildLowPassFIR(
            taps: 49, cutoff: 0.95 / 3.0  // Nyquist fraction
        )

        // Build mel filterbank
        buildMelFilterbank()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Public API
    // ═══════════════════════════════════════════════════════════

    /// Compute log-mel spectrogram from raw 48 kHz mono audio.
    ///
    /// - Parameter audio48k: Float array, expected length = `inputFramesNeeded` (144000).
    /// - Returns: Flat Float array of shape [nMels × numTimeFrames] = [64 × 188] = [12032],
    ///            stored row-major (mel bin 0 first, then mel bin 1, etc.).
    func compute(audio48k: [Float]) -> [Float] {
        // 1. Downsample 48 kHz → 16 kHz
        let audio16k = downsample(audio48k)

        // 2. Center-pad (librosa style: nFFT/2 on each side)
        let pad = nFFT / 2
        let paddedLen = audio16k.count + 2 * pad
        if paddedBuf.count < paddedLen {
            paddedBuf = [Float](repeating: 0, count: paddedLen)
        } else {
            vDSP_vclr(&paddedBuf, 1, vDSP_Length(paddedLen))
        }
        for i in 0..<audio16k.count {
            paddedBuf[pad + i] = audio16k[i]
        }

        // 3. STFT → power spectrum → mel → log
        let nFrames = numTimeFrames
        var output = [Float](repeating: 0, count: nMels * nFrames)

        for t in 0..<nFrames {
            let start = t * hopLength

            // Extract windowed frame
            for i in 0..<nFFT {
                let idx = start + i
                frameBuf[i] = (idx < paddedLen) ? paddedBuf[idx] * window[i] : 0
            }

            // FFT (packed split-complex)
            frameBuf.withUnsafeMutableBufferPointer { fb in
                fftRealBuf.withUnsafeMutableBufferPointer { realBuf in
                    fftImagBuf.withUnsafeMutableBufferPointer { imagBuf in
                        var split = DSPSplitComplex(
                            realp: realBuf.baseAddress!,
                            imagp: imagBuf.baseAddress!
                        )
                        fb.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: nFFT / 2
                        ) { ptr in
                            vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(nFFT / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, fftOrder,
                                      FFTDirection(kFFTDirection_Forward))

                        // Power spectrum: |X(k)|^2
                        // DC component
                        powerBuf[0] = split.realp[0] * split.realp[0]
                        // Nyquist component
                        powerBuf[nFFT / 2] = split.imagp[0] * split.imagp[0]
                        // Remaining bins
                        for k in 1..<(nFFT / 2) {
                            let re = split.realp[k]
                            let im = split.imagp[k]
                            powerBuf[k] = re * re + im * im
                        }
                    }
                }
            }

            // Scale: vDSP fft_zrip returns 2·DFT, so |result|² = 4·|DFT|².
            // Divide by 4 to match librosa/numpy (unscaled forward DFT).
            var scale: Float = 1.0 / 4.0
            vDSP_vsmul(powerBuf, 1, &scale, &powerBuf, 1, vDSP_Length(halfFFT))

            // Mel filterbank application
            applyMelFilters(power: powerBuf, melOut: &melBuf)

            // Log-mel (dB) → normalized [0, 1]
            // Training pipeline: (dB + 100) / 100, clamped to [0, 1]
            //   -100 dB (silence floor) → 0.0
            //      0 dB (max signal)    → 1.0
            let dbFloor: Float = 100.0
            for m in 0..<nMels {
                let val = melBuf[m]
                let dB = 10.0 * log10f(max(val, 1e-10))
                output[m * nFrames + t] = min(1.0, max(0.0, (dB + dbFloor) / dbFloor))
            }
        }

        return output
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Downsampler  (48 kHz → 16 kHz, factor 3)
    // ═══════════════════════════════════════════════════════════

    private func downsample(_ input: [Float]) -> [Float] {
        // vDSP_desamp needs (outLen-1)*stride + filterLen input samples.
        // Clamp outLen so we never read past the input buffer.
        let maxOut = (input.count - firLen) / decimationFactor + 1
        let outLen = max(0, min(input.count / decimationFactor, maxOut))
        var output = [Float](repeating: 0, count: outLen)

        // Apply anti-alias FIR then decimate
        // vDSP_desamp: y[n] = Σ filter[k] * x[n*stride + k]
        input.withUnsafeBufferPointer { inPtr in
            antiAliasFIR.withUnsafeBufferPointer { firPtr in
                vDSP_desamp(
                    inPtr.baseAddress!, vDSP_Stride(decimationFactor),
                    firPtr.baseAddress!, &output,
                    vDSP_Length(outLen), vDSP_Length(firLen)
                )
            }
        }

        return output
    }

    /// Build a windowed-sinc low-pass FIR filter.
    private static func buildLowPassFIR(taps: Int, cutoff: Double) -> [Float] {
        var fir = [Float](repeating: 0, count: taps)
        let mid = taps / 2
        var sum: Float = 0
        for i in 0..<taps {
            let n = Double(i - mid)
            if n == 0 {
                fir[i] = Float(2.0 * cutoff)
            } else {
                let sinc = sin(2.0 * .pi * cutoff * n) / (.pi * n)
                // Hamming window
                let w = 0.54 - 0.46 * cos(2.0 * .pi * Double(i) / Double(taps - 1))
                fir[i] = Float(sinc * w)
            }
            sum += fir[i]
        }
        // Normalize
        for i in 0..<taps { fir[i] /= sum }
        return fir
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Mel Filterbank
    // ═══════════════════════════════════════════════════════════

    private func buildMelFilterbank() {
        // Mel scale (HTK formula): mel = 2595 * log10(1 + f/700)
        func hzToMel(_ f: Double) -> Double { 2595.0 * log10(1.0 + f / 700.0) }
        func melToHz(_ m: Double) -> Double { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)

        // nMels + 2 equally spaced points in mel scale
        let nPoints = nMels + 2
        var melPoints = [Double](repeating: 0, count: nPoints)
        for i in 0..<nPoints {
            melPoints[i] = melMin + Double(i) * (melMax - melMin) / Double(nPoints - 1)
        }

        // Convert mel points → Hz → FFT bin indices
        let binSpacing = targetSampleRate / Double(nFFT)
        var binIndices = [Int](repeating: 0, count: nPoints)
        for i in 0..<nPoints {
            let hz = melToHz(melPoints[i])
            binIndices[i] = Int(floor(hz / binSpacing))
        }

        // Build triangular filters
        melFilters = [[Float]](repeating: [], count: nMels)
        melStarts  = [Int](repeating: 0, count: nMels)
        melEnds    = [Int](repeating: 0, count: nMels)

        for m in 0..<nMels {
            let left   = binIndices[m]
            let center = binIndices[m + 1]
            let right  = binIndices[m + 2]

            melStarts[m] = left
            melEnds[m]   = right

            let filterLen = right - left + 1
            var filt = [Float](repeating: 0, count: max(filterLen, 1))

            for k in left...max(left, right) {
                let idx = k - left
                if idx >= filt.count { break }
                if k <= center && center > left {
                    filt[idx] = Float(k - left) / Float(center - left)
                } else if k > center && right > center {
                    filt[idx] = Float(right - k) / Float(right - center)
                }
            }

            melFilters[m] = filt
        }
    }

    private func applyMelFilters(power: [Float], melOut: inout [Float]) {
        for m in 0..<nMels {
            let start = melStarts[m]
            let filt  = melFilters[m]
            var sum: Float = 0
            for k in 0..<filt.count {
                let bin = start + k
                if bin < halfFFT {
                    sum += power[bin] * filt[k]
                }
            }
            melOut[m] = sum
        }
    }
}
