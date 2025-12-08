import SwiftUI
import CoreLocation

// MARK: - Location Configuration View
struct LocationConfigView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Binding var nearestObjectDirection: Double?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Large map view taking most of the screen
                ZStack {
                    if !locationManager.locations.isEmpty || userLocationManager.currentLocation != nil {
                        LootBoxMapView(locationManager: locationManager, userLocationManager: userLocationManager, nearestObjectDirection: $nearestObjectDirection)
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
                        Button("🔄 Refresh Nearby Objects") {
                            // Trigger refresh of nearby objects from API
                            Task {
                                await locationManager.loadLocationsFromAPI()
                            }
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Stats - use database stats when available (same as main view counter)
                    HStack {
                        let stats: (found: Int, total: Int) = {
                            // Use database stats if available (from API sync)
                            if let dbStats = locationManager.databaseStats {
                                return (found: dbStats.foundByYou, total: dbStats.totalVisible)
                            }
                            // Fallback to local data if API stats not available
                            let foundCount = locationManager.locations.filter { $0.collected }.count
                            let totalCount = locationManager.locations.count
                            return (found: foundCount, total: totalCount)
                        }()

                        Text("Found: \(stats.found)/\(stats.total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let location = userLocationManager.currentLocation {
                            Text("📍 \(location.coordinate.latitude, specifier: "%.8f"), \(location.coordinate.longitude, specifier: "%.8f")")
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
            
            // Load ALL items from API when map is displayed (no distance filter, include found items)
            // This ensures all database items are visible on the map, matching the admin panel
            Task {
                print("🗺️ Map view appeared - loading ALL items from database (no distance filter, including found items)")
                await locationManager.loadLocationsFromAPI(userLocation: nil, includeFound: true)
                print("🗺️ Loaded \(locationManager.locations.count) items for map display")
                if let stats = locationManager.databaseStats {
                    print("🗺️ Database stats: \(stats.foundByYou) found / \(stats.totalVisible) total")
                }
            }
        }
        .onChange(of: locationManager.selectedDatabaseObjectId) { oldValue, newValue in
            // Reload items when selection changes so map can filter properly
            Task {
                if let newValue = newValue {
                    print("🗺️ Selection changed to: \(newValue) - reloading to show only selected item")
                } else {
                    print("🗺️ Selection cleared - reloading ALL items")
                }
                // Load all items (no distance filter) so map can show selected item or all items
                await locationManager.loadLocationsFromAPI(userLocation: nil, includeFound: true)
            }
        }
    }
}

