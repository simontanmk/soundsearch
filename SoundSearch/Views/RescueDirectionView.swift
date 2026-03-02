import SwiftUI

struct RescueDirectionView: View {
    @StateObject private var viewModel = RescueDirectionViewModel()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                ZStack {
                    ConfidenceArc(
                        confidence: viewModel.confidence,
                        isLocked: viewModel.isLocked,
                        isSignalDetected: viewModel.confidence > 0.55 && !viewModel.isLocked
                    )
                        .frame(width: 280, height: 280)

                    ArrowIndicator(rotationDegrees: viewModel.arrowRotation)
                        .frame(width: 170, height: 170)
                }

                Text(viewModel.statusText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()
            }
            .opacity(viewModel.showLockConfirmation ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.25), value: viewModel.showLockConfirmation)

            if viewModel.showLockConfirmation {
                LockConfirmationView()
                    .transition(.opacity)
            }

            if !viewModel.debugInfo.isEmpty {
                VStack {
                    HStack {
                        Text(viewModel.debugInfo)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(8)
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(8)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

private struct ArrowIndicator: View {
    let rotationDegrees: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.15), radius: 12, x: 0, y: 0)
            .rotationEffect(.degrees(rotationDegrees))
            .animation(.easeInOut(duration: 0.18), value: rotationDegrees)
    }
}

private struct ConfidenceArc: View {
    let confidence: Double
    let isLocked: Bool
    let isSignalDetected: Bool

    var body: some View {
        let baseOpacity = 0.18
        let boostOpacity = 0.75 * confidence
        let arcColor: Color = {
            if isLocked {
                return .green
            }
            if isSignalDetected {
                let t = Self.normalized(value: confidence, min: 0.55, max: 0.94)
                let brightness = 0.45 + 0.55 * t
                return Color(hue: 0.14, saturation: 1.0, brightness: brightness)
            }
            return .white
        }()
        Circle()
            .trim(from: 0.08, to: 0.42)
            .stroke(
                arcColor.opacity(baseOpacity + boostOpacity),
                style: StrokeStyle(lineWidth: 12, lineCap: .round)
            )
            .rotationEffect(.degrees(180))
            .animation(.easeInOut(duration: 0.22), value: confidence)
            .animation(.easeInOut(duration: 0.2), value: isLocked)
    }

    private static func normalized(value: Double, min: Double, max: Double) -> Double {
        if max <= min { return 1 }
        let clamped = Swift.max(min, Swift.min(value, max))
        return (clamped - min) / (max - min)
    }
}

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

#Preview {
    RescueDirectionView()
}
