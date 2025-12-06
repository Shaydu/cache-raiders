import SwiftUI
import CoreLocation

// MARK: - AR Object Detail View
/// 2D sheet view that displays detailed information about an AR object
/// Triggered by long-pressing an object in AR mode
struct ARObjectDetailView: View {
    let objectDetail: ARObjectDetail
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Object Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(objectDetail.name)
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundColor(.primary)

                        Text(objectDetail.itemType)
                            .font(.system(.title3, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 10)

                    Divider()

                    // Basic Information
                    DetailSection(title: "Basic Information") {
                        DetailRow(label: "UUID", value: objectDetail.id)
                        DetailRow(label: "Item Type", value: objectDetail.itemType)
                        DetailRow(label: "Name", value: objectDetail.name)
                    }

                    Divider()

                    // Placement Information
                    DetailSection(title: "Placement Information") {
                        DetailRow(label: "Placed By", value: objectDetail.placerName ?? "Unknown")
                        DetailRow(label: "Date Placed", value: objectDetail.datePlacedString)
                    }

                    Divider()

                    // GPS Coordinates
                    DetailSection(title: "GPS Coordinates") {
                        if let coords = objectDetail.gpsCoordinates {
                            DetailRow(label: "Latitude", value: String(format: "%.8f", coords.latitude))
                            DetailRow(label: "Longitude", value: String(format: "%.8f", coords.longitude))
                            DetailRow(label: "Combined", value: objectDetail.gpsCoordinateString)
                        } else {
                            Text("No GPS coordinates available")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // AR Coordinates
                    DetailSection(title: "AR Coordinates") {
                        if let coords = objectDetail.arCoordinates {
                            DetailRow(label: "X", value: String(format: "%.4f m", coords.x))
                            DetailRow(label: "Y", value: String(format: "%.4f m", coords.y))
                            DetailRow(label: "Z", value: String(format: "%.4f m", coords.z))
                            DetailRow(label: "Combined", value: objectDetail.arCoordinateString)
                        } else {
                            Text("No AR coordinates available")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // AR Origin (GPS location where AR session originated)
                    DetailSection(title: "AR Origin") {
                        if let origin = objectDetail.arOrigin {
                            DetailRow(label: "Origin Latitude", value: String(format: "%.8f", origin.latitude))
                            DetailRow(label: "Origin Longitude", value: String(format: "%.8f", origin.longitude))
                            DetailRow(label: "Combined", value: objectDetail.arOriginString)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No AR origin available")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("AR origin data is only available for objects manually placed in AR")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                    }

                    Divider()

                    // AR Offsets (from AR origin)
                    DetailSection(title: "AR Offsets (from origin)") {
                        if let offsets = objectDetail.arOffsets {
                            DetailRow(label: "X Offset", value: String(format: "%.4f m", offsets.x))
                            DetailRow(label: "Y Offset", value: String(format: "%.4f m", offsets.y))
                            DetailRow(label: "Z Offset", value: String(format: "%.4f m", offsets.z))
                            DetailRow(label: "Combined", value: objectDetail.arOffsetString)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No AR offsets available")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("AR offset data is only available for objects manually placed in AR")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                    }

                    Divider()

                    // AR Anchors
                    DetailSection(title: "AR Anchors") {
                        if !objectDetail.anchors.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(objectDetail.anchors, id: \.self) { anchorInfo in
                                    Text(anchorInfo)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            Text("No anchor information available")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Object Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Detail Section
/// Container for a section of details with a title
private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

// MARK: - Detail Row
/// Single row of label-value pair
private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label + ":")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled) // Allow copying values
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview
#Preview {
    ARObjectDetailView(
        objectDetail: ARObjectDetail(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Ancient Chalice",
            itemType: "Chalice",
            placerName: "Admin",
            datePlaced: Date(),
            gpsCoordinates: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            arCoordinates: SIMD3<Float>(1.5, 0.2, -2.3),
            arOrigin: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            arOffsets: SIMD3<Double>(1.5, 0.2, -2.3),
            anchors: [
                "ID: 123e4567-e89b-12d3-a456-426614174000",
                "Type: ARPlaneAnchor",
                "Position: 1.50, 0.20, -2.30"
            ]
        )
    )
}
