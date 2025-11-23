import SwiftUI
import RealityKit

/// Overlay UI for object placement mode
/// Shows placement reticle, coordinates, height, and "Place Object" button
struct ObjectPlacementOverlay: View {
    @Binding var isPlacementMode: Bool
    @Binding var placementPosition: SIMD3<Float>?
    @Binding var placementDistance: Float?
    @Binding var groundHeight: Float?

    let objectType: LootBoxType
    let onPlaceObject: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack {
                // Top info panel
                VStack(spacing: 8) {
                    Text("Object Placement Mode")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(8)

                    // Coordinates and height display
                    if let position = placementPosition {
                        VStack(spacing: 4) {
                            HStack(spacing: 12) {
                                CoordinateLabel(title: "X", value: position.x, color: .red)
                                CoordinateLabel(title: "Y", value: position.y, color: .green)
                                CoordinateLabel(title: "Z", value: position.z, color: .blue)
                            }

                            if let distance = placementDistance {
                                Text("Distance: \(String(format: "%.2f", distance))m")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(6)
                            }

                            if let height = groundHeight {
                                Text("Height from ground: \(String(format: "%.2f", abs(height)))m")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(6)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(12)
                    }
                }
                .padding(.top, 60)

                Spacer()

                // Center crosshair/reticle indicator
                VStack {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.cyan)
                        .opacity(0.7)

                    Text("Point camera at placement location")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                }

                Spacer()

                // Bottom: Circular placement button with object preview
                VStack(spacing: 16) {
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
                                    // Object type icon
                                    Image(systemName: objectTypeIcon(for: objectType))
                                        .font(.system(size: 40))
                                        .foregroundColor(.white)

                                    Text("Place")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)

                                    Text(objectType.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .shadow(color: .cyan.opacity(0.5), radius: 10, x: 0, y: 0)
                        }
                    }
                    .disabled(placementPosition == nil)
                    .opacity(placementPosition == nil ? 0.5 : 1.0)

                    // Cancel button
                    Button(action: onCancel) {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                            Text("Cancel")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(25)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    /// Returns appropriate SF Symbol icon for object type
    private func objectTypeIcon(for type: LootBoxType) -> String {
        switch type {
        case .sphere:
            return "circle.fill"
        case .cube:
            return "cube.fill"
        case .chalice:
            return "cup.and.saucer.fill"
        case .treasureChest, .lootChest:
            return "shippingbox.fill"
        case .templeRelic:
            return "building.columns.fill"
        case .lootCart:
            return "cart.fill"
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
            groundHeight: .constant(0.8),
            objectType: .sphere,
            onPlaceObject: {},
            onCancel: {}
        )
    }
}
