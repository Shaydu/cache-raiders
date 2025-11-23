import SwiftUI
import CoreLocation

// MARK: - Location Configuration View
struct LocationConfigView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @StateObject private var userLocationManager = UserLocationManager()
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Large map view taking most of the screen
                ZStack {
                    if !locationManager.locations.isEmpty || userLocationManager.currentLocation != nil {
                        LootBoxMapView(locationManager: locationManager, userLocationManager: userLocationManager)
                            .ignoresSafeArea(edges: [.leading, .trailing])
                    } else {
                        VStack {
                            Image(systemName: "map")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No locations to display")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                }

                // Bottom controls
                VStack(spacing: 12) {
                    if let userLocation = userLocationManager.currentLocation {
                        HStack(spacing: 20) {
                            Button("🔄 Regenerate Loot Boxes") {
                                locationManager.regenerateLocations(near: userLocation)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)

                            Button("❌ Reset All Found") {
                                locationManager.resetAllLocations()
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }

                    // Stats - count both GPS boxes and AR spheres
                    HStack {
                        let gpsCollected = locationManager.locations.filter { $0.collected }.count
                        let arSpheresFound = 0 // We'll need to pass this from ARCoordinator
                        let totalFound = gpsCollected // + arSpheresFound (when we add that)
                        let totalAvailable = locationManager.locations.count // + arSpheresFound (when we add that)

                        Text("Found: \(totalFound)/\(totalAvailable)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let location = userLocationManager.currentLocation {
                            Text("📍 \(location.coordinate.latitude, specifier: "%.4f"), \(location.coordinate.longitude, specifier: "%.4f")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
                .shadow(radius: 2)
            }
            .navigationTitle("Loot Box Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            userLocationManager.requestLocationPermission()
        }
    }
}

