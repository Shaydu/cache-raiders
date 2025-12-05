import SwiftUI
import Combine

// MARK: - Precise Positioning Overlay
/// Shows the seamless transition from GPS macro → NFC micro → AR precision
struct PrecisePositioningOverlay: View {
    @StateObject private var positioningService = NFCARIntegrationService.shared
    @State private var currentGuidance: PreciseARPositioningService.PositioningGuidance?
    @State private var showPrecisionIndicator = false
    @State private var lastPrecision: Double?

    var body: some View {
        ZStack {
            // Main positioning display
            VStack {
                Spacer()

                if let guidance = currentGuidance {
                    PositioningGuidanceView(guidance: guidance)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Precision indicator (shows when locked in)
                if showPrecisionIndicator, let precision = lastPrecision {
                    PrecisionIndicatorView(precision: precision)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.bottom, 50)

            // State indicator in top-right
            VStack {
                HStack {
                    Spacer()
                    PositioningStateIndicator(state: positioningService.currentPositioningState)
                        .padding(.top, 60)
                        .padding(.trailing, 20)
                }
                Spacer()
            }
        }
        .onReceive(positioningService.guidanceUpdate) { guidance in
            withAnimation(.easeInOut) {
                self.currentGuidance = guidance
            }
        }
        .onReceive(positioningService.precisionAchieved) { result in
            withAnimation(.spring()) {
                self.lastPrecision = result.precision
                self.showPrecisionIndicator = true
            }

            // Hide precision indicator after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                withAnimation {
                    self.showPrecisionIndicator = false
                }
            }
        }
        .onAppear {
            // Initialize with current guidance
            currentGuidance = positioningService.getCurrentGuidance()
        }
    }
}

// MARK: - Positioning Guidance View
struct PositioningGuidanceView: View {
    let guidance: PreciseARPositioningService.PositioningGuidance

    var body: some View {
        VStack(spacing: 12) {
            // Accuracy indicator
            HStack {
                Image(systemName: guidance.accuracy.icon)
                    .foregroundColor(guidance.accuracy.color)
                Text(guidance.accuracy.title)
                    .font(.caption)
                    .foregroundColor(guidance.accuracy.color)
                    .fontWeight(.semibold)
            }

            // Distance and direction
            HStack(spacing: 16) {
                // Distance
                VStack {
                    Text(String(format: "%.0f", guidance.distance))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("meters")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                // Direction arrow
                DirectionArrow(bearing: guidance.bearing)
                    .frame(width: 40, height: 40)
            }

            // Instruction text
            Text(guidance.instruction)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.8))
                .shadow(color: guidance.accuracy.color.opacity(0.3), radius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(guidance.accuracy.color.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Direction Arrow
struct DirectionArrow: View {
    let bearing: Double // degrees

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 40, height: 40)

            Image(systemName: "location.north.line.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .rotationEffect(.degrees(bearing))
        }
    }
}

// MARK: - Precision Indicator
struct PrecisionIndicatorView: View {
    let precision: Double // meters

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(String(format: "Locked to ±%.0f cm", precision * 100))
                .font(.caption)
                .foregroundColor(.green)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.green.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Positioning State Indicator
struct PositioningStateIndicator: View {
    let state: NFCARIntegrationService.PositioningState

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Circle()
                    .fill(state.color)
                    .frame(width: 8, height: 8)
                Text(state.title)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
            }

            Text(state.description)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.trailing)
        }
        .padding(8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
    }
}

// MARK: - Extensions
extension PreciseARPositioningService.PositioningGuidance.AccuracyLevel {
    var icon: String {
        switch self {
        case .macro: return "location"
        case .micro: return "dot.scope"
        case .precise: return "scope"
        }
    }

    var color: Color {
        switch self {
        case .macro: return .orange
        case .micro: return .yellow
        case .precise: return .green
        }
    }

    var title: String {
        switch self {
        case .macro: return "GPS GUIDANCE"
        case .micro: return "AR TRACKING"
        case .precise: return "PRECISION LOCK"
        }
    }
}

extension NFCARIntegrationService.PositioningState {
    var color: Color {
        switch self {
        case .gpsGuidance: return .orange
        case .nfcDiscovery: return .yellow
        case .arGrounding: return .blue
        case .lockedIn: return .green
        }
    }

    var title: String {
        switch self {
        case .gpsGuidance: return "GPS"
        case .nfcDiscovery: return "NFC"
        case .arGrounding: return "AR"
        case .lockedIn: return "LOCKED"
        }
    }

    var description: String {
        switch self {
        case .gpsGuidance: return "Finding area"
        case .nfcDiscovery: return "Scan NFC tag"
        case .arGrounding: return "Grounding AR"
        case .lockedIn: return "Precise lock"
        }
    }
}

// MARK: - Preview
struct PrecisePositioningOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.opacity(0.3)
            PrecisePositioningOverlay()
        }
    }
}
