import SwiftUI

// ═══════════════════════════════════════════════════════════════
// MARK: - RescueDirectionView  (Find My–style)
// ═══════════════════════════════════════════════════════════════

struct RescueDirectionView: View {
    @StateObject private var viewModel = RescueDirectionViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ── Primary layout ──────────────────────────────
            mainContent
                .opacity(viewModel.showLockConfirmation ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: viewModel.showLockConfirmation)

            // ── Debug overlay (top) ─────────────────────────
            if !viewModel.debugInfo.isEmpty {
                debugOverlay
            }

            // ── Lock flash ──────────────────────────────────
            if viewModel.showLockConfirmation {
                LockConfirmationView()
                    .transition(.opacity)
            }

            // ── Error banner ────────────────────────────────
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // ── Main content stack ──────────────────────────────────

    private var mainContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)
            headerSection
            Spacer()
            centerSection
            Spacer()
            bottomSection
            Spacer().frame(height: 20)
        }
    }

    // ── Header ──────────────────────────────────────────────

    private var headerSection: some View {
        let detecting = viewModel.phase == .detecting
        return VStack(spacing: 6) {
            Text(detecting ? "DETECTING" : "LOCATING")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .kerning(1.5)
                .foregroundStyle(detecting ? Color.gray : Color.green)

            Text(detecting ? "Distress Sounds" : "Sound Source")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    // ── Center (ring + arrow + info) ────────────────────────

    private var centerSection: some View {
        ZStack {
            ParticleRingView(
                phase: viewModel.phase,
                angularError: viewModel.angularError,
                confidence: viewModel.confidence,
                isLocked: viewModel.isLocked,
                distressConfidence: viewModel.distressConfidence
            )

            if viewModel.phase == .directing {
                ArrowIndicator(rotationDegrees: viewModel.arrowRotation)
                    .frame(width: 120, height: 120)
            }

            centerInfoText
                .offset(y: viewModel.phase == .directing ? 100 : 0)
        }
        .frame(width: 300, height: 300)
    }

    private var centerInfoText: some View {
        Group {
            if viewModel.phase == .detecting {
                if viewModel.bufferProgress < 1.0 {
                    Text("Listening…")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Text(String(format: "%.0f%%", viewModel.distressConfidence * 100))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            } else if viewModel.confidence > 0.1 {
                Text(String(format: "%.0f%%", viewModel.confidence * 100))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // ── Bottom (proximity word + status + buttons) ──────────

    private var bottomSection: some View {
        VStack(spacing: 18) {
            Text(proximityWord)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(proximityColor)
                .animation(.easeInOut(duration: 0.4), value: proximityWord)

            Text(viewModel.statusText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(height: 36)

            // Buttons removed for cleaner UI
        }
    }

    private var proximityWord: String {
        if viewModel.phase == .detecting { return "" }
        if viewModel.isLocked || viewModel.confidence > 0.7 { return "here" }
        if viewModel.confidence > 0.3 { return "near" }
        return "far"
    }

    private var proximityColor: Color {
        if viewModel.phase == .detecting { return .cyan.opacity(0.6) }
        if viewModel.isLocked || viewModel.confidence > 0.7 { return .green }
        if viewModel.confidence > 0.3 { return .yellow }
        return .white.opacity(0.35)
    }

    // ── Overlays ────────────────────────────────────────────

    private var debugOverlay: some View {
        VStack {
            ScrollView {
                HStack {
                    Text(viewModel.debugInfo)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(Color.black.opacity(0.5))
            .cornerRadius(8)
            Spacer()
        }
        .padding(12)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - ParticleRingView
// ═══════════════════════════════════════════════════════════════
/// Hero visual — a loose ring of scattered dots that animates
/// continuously. During direction phase the arc nearest the sound
/// source glows brighter.  Turns green when locked.

private struct ParticleRingView: View {
    let phase: AppPhase
    let angularError: Double
    let confidence: Double
    let isLocked: Bool
    let distressConfidence: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawRing(in: &ctx, size: size, time: t)
            }
        }
        .frame(width: 300, height: 300)
    }

    // ── Drawing ─────────────────────────────────────────────

    private func drawRing(in ctx: inout GraphicsContext,
                          size: CGSize, time: Double) {
        let cx = size.width / 2
        let cy = size.height / 2
        let baseRadius: Double = 130

        for p in RingParticles.all {
            // Gentle floating motion
            let dr = sin(time * 0.6 + p.animPhase) * 3.5
            let dx = cos(time * 0.4 + p.animPhase * 1.3) * 2.5
            let r  = baseRadius + p.radiusOffset + dr

            // 0° = top, clockwise
            let rad = (p.angle - 90) * .pi / 180
            let x = cx + cos(rad) * r + dx
            let y = cy + sin(rad) * r

            let (red, green, blue, alpha) = colorForParticle(p, time: time)

            let rect = CGRect(x: x - p.size / 2,
                              y: y - p.size / 2,
                              width: p.size,
                              height: p.size)
            ctx.fill(Circle().path(in: rect),
                     with: .color(Color(red: red, green: green, blue: blue)
                                    .opacity(alpha)))
        }
    }

    // ── Per-particle color ──────────────────────────────────

    private func colorForParticle(_ p: RingParticle,
                                  time: Double)
        -> (Double, Double, Double, Double) {

        // ── Detecting phase: pulsing cyan ───────────────────
        if phase == .detecting {
            let pulse = 0.5 + 0.5 * sin(time * 1.0 + p.animPhase)
            let a = p.baseOpacity * (0.3 + 0.7 * pulse)
            // Shift warmer as distressConfidence rises
            let w = distressConfidence * 0.35
            return (w, 0.78 + w * 0.1, 1.0 - w * 0.5, a)
        }

        // ── Directing phase: directional glow ───────────────
        let diff = abs(shortestAngle(p.angle, angularError))
        let spread: Double = 45
        let directional = exp(-(diff * diff) / (2 * spread * spread))
        let heat = directional * min(confidence * 1.5, 1.0)

        if isLocked {
            let pulse = 0.5 + 0.5 * sin(time * 0.8 + p.animPhase)
            let a = p.baseOpacity * (0.4 + 0.6 * heat)
            return (0.1,
                    0.85 * (0.6 + 0.4 * pulse),
                    0.2,
                    max(a, p.baseOpacity * 0.3))
        }

        // dim cyan-gray → bright white
        let red   = 0.25 + 0.75 * heat
        let green = 0.35 + 0.65 * heat
        let blue  = 0.50 + 0.50 * heat
        let a     = p.baseOpacity * (0.15 + 0.85 * max(heat, 0.05))
        return (red, green, blue, a)
    }

    private func shortestAngle(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d >  180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - Ring particle data (generated once)
// ═══════════════════════════════════════════════════════════════

private struct RingParticle: Identifiable {
    let id: Int
    let angle: Double        // degrees, 0 = top, clockwise
    let radiusOffset: Double // px from base radius
    let size: Double         // 2…6 pt
    let baseOpacity: Double  // 0.3…0.8
    let animPhase: Double    // 0…2π
}

private enum RingParticles {
    static let all: [RingParticle] = {
        let count = 100
        var result = [RingParticle]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let base = Double(i) / Double(count) * 360
            result.append(RingParticle(
                id: i,
                angle:        base + seed(i, 7)  * 12 - 6,
                radiusOffset: seed(i, 13) * 22 - 11,
                size:         2.0 + seed(i, 17)  * 4.0,
                baseOpacity:  0.3 + seed(i, 23)  * 0.5,
                animPhase:    seed(i, 31) * .pi * 2
            ))
        }
        return result
    }()

    /// Deterministic pseudo-random value in [0, 1).
    private static func seed(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i &* salt &+ salt) * 12.9898 + 78.233) * 43758.5453
        return x - floor(x)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - ArrowIndicator
// ═══════════════════════════════════════════════════════════════

private struct ArrowIndicator: View {
    let rotationDegrees: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.15), radius: 12)
            .rotationEffect(.degrees(rotationDegrees))
            .animation(.easeInOut(duration: 0.18), value: rotationDegrees)
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - LockConfirmationView
// ═══════════════════════════════════════════════════════════════

private struct LockConfirmationView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.green.opacity(0.85), Color.green.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 14, x: 0, y: 6)
        }
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - Preview
// ═══════════════════════════════════════════════════════════════

#Preview {
    RescueDirectionView()
}
