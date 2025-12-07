import SwiftUI
import CoreLocation

// MARK: - Info Row Component
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text("\(label):")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - Object Info Panel
struct ObjectInfoPanel: View {
    let location: LootBoxLocation
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            // Info panel
            VStack(spacing: 20) {
                // Header
                Text("Object Information")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                // Object details
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(label: "Name", value: location.name)
                    InfoRow(label: "Type", value: location.type.displayName)

                    if let createdBy = location.created_by {
                        let placerDisplay: String = {
                            if createdBy == APIService.shared.currentUserID {
                                return "You"
                            } else if createdBy == "admin-web-ui" {
                                return "Admin"
                            } else {
                                return "Another user"
                            }
                        }()
                        InfoRow(label: "Placed by", value: placerDisplay)
                    }

                    // Placement method
                    if let placementMethod = location.id.hasPrefix("nfc_") ? "NFC Token" : "AR Placement" {
                        InfoRow(label: "Method", value: placementMethod)
                    }

                    // Location coordinates (if available)
                    if location.latitude != 0 || location.longitude != 0 {
                        InfoRow(label: "Coordinates",
                               value: String(format: "%.6f, %.6f", location.latitude, location.longitude))
                    }

                    // Distance if close enough
                    let distance = location.location.distance(from: UserLocationManager().currentLocation ?? CLLocation(latitude: 0, longitude: 0))
                    if distance < 1000 { // Only show if within 1km
                        InfoRow(label: "Distance", value: formatDistance(distance))
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .frame(maxWidth: .infinity)

                // Dismiss button
                Button(action: onDismiss) {
                    Text("Close")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return String(format: "%.0f meters", meters)
        } else {
            return String(format: "%.1f km", meters / 1000)
        }
    }
}

// MARK: - Preview
struct ObjectInfoPanel_Previews: PreviewProvider {
    static var previews: some View {
        let sampleLocation = LootBoxLocation(
            id: "sample_1",
            name: "Golden Chalice",
            type: .chalice,
            latitude: 37.7749,
            longitude: -122.4194,
            radius: 5.0,
            collected: false,
            source: .map,
            created_by: "user123"
        )

        ObjectInfoPanel(location: sampleLocation) {
            print("Dismissed")
        }
    }
}
