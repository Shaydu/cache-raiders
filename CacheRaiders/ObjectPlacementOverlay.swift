import SwiftUI
import RealityKit

/// Overlay UI for object placement mode
/// Shows placement reticle, coordinates, height, and "Place Object" button
struct ObjectPlacementOverlay: View {
    @Binding var isPlacementMode: Bool
    @Binding var placementPosition: SIMD3<Float>?
    @Binding var placementDistance: Float?

    let objectType: LootBoxType
    let hasPlacedObject: Bool
    let onPlaceObject: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack {
                // Top info panel (removed XYZ coordinates display)
                VStack(spacing: 8) {
                    // Grounding status
                    Text("Placed on ground")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                }
                .padding(.top, 30)

                Spacer()


                Spacer()

                // Bottom: Action buttons
                VStack(spacing: 16) {
                    // Done button (shown when object is placed)
                    if hasPlacedObject {
                        Button(action: onDone) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Done")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.green.opacity(0.9))
                            .cornerRadius(25)
                            .shadow(color: .green.opacity(0.5), radius: 10, x: 0, y: 0)
                        }
                    }
                    
                    // Placement button
                    Button(action: onPlaceObject) {
                        VStack(spacing: 8) {
                            // Object icon/preview
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.8))
                                    .frame(width: 120, height: 120)

                                Circle()
                                    .stroke(Color.cyan, lineWidth: 3)
                                    .frame(width: 120, height: 120)

                                VStack(spacing: 4) {
                                    Text("Place")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)

                                    Text(objectType.displayName)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .shadow(color: .cyan.opacity(0.5), radius: 10, x: 0, y: 0)
                        }
                    }
                    .disabled(placementPosition == nil)
                    .opacity(placementPosition == nil ? 0.5 : 1.0)

                }
                .padding(.bottom, 40)
            }
        }
    }

}

/// Individual coordinate label component
struct CoordinateLabel: View {
    let title: String
    let value: Float
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(color)

            Text(String(format: "%.2f", value))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color, lineWidth: 1)
        )
    }
}

// MARK: - Preview
struct ObjectPlacementOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ObjectPlacementOverlay(
            isPlacementMode: .constant(true),
            placementPosition: .constant(SIMD3<Float>(2.5, -0.8, -3.2)),
            placementDistance: .constant(4.2),
            objectType: .sphere,
            hasPlacedObject: false,
            onPlaceObject: {},
            onDone: {},
            onCancel: {}
        )
    }
}
