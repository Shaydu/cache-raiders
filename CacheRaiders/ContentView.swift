import SwiftUI
import CoreLocation

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var locationManager = LootBoxLocationManager()
    @StateObject private var userLocationManager = UserLocationManager()
    @State private var showLocationConfig = false
    @State private var showARPlacement = false
    @State private var showSettings = false
    @State private var showLeaderboard = false
    @State private var nearbyLocations: [LootBoxLocation] = []
    @State private var distanceToNearest: Double?
    @State private var temperatureStatus: String?
    @State private var collectionNotification: String?
    @State private var nearestObjectDirection: Double?
    
    // Computed property for loot box counter - uses database stats when available
    // Shows: X items found by you / Y items visible to you in database
    private var lootBoxCounter: (found: Int, total: Int) {
        // Use database stats if available (from API sync)
        if let stats = locationManager.databaseStats {
            return (found: stats.foundByYou, total: stats.totalVisible)
        }
        // Fallback to local data if API stats not available
        let findableLocations = locationManager.findableLocations
        let foundCount = findableLocations.filter { $0.collected }.count
        let totalCount = findableLocations.count
        return (found: foundCount, total: totalCount)
    }
    
    var body: some View {
        ZStack {
            ARLootBoxView(
                locationManager: locationManager,
                userLocationManager: userLocationManager,
                nearbyLocations: $nearbyLocations,
                distanceToNearest: $distanceToNearest,
                temperatureStatus: $temperatureStatus,
                collectionNotification: $collectionNotification,
                nearestObjectDirection: $nearestObjectDirection
            )
            .ignoresSafeArea()
            
            VStack {
                HStack {
                    HStack(spacing: 8) {
                        Button(action: { showLocationConfig = true }) {
                            Image(systemName: "map")
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(10)
                        }
                        
                        Button(action: { showARPlacement = true }) {
                            Image(systemName: "plus")
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(10)
                        }
                    }
                    .padding(.top)
                    
                    Spacer()
                    
                    // Arrows and distance to nearest box
                    if let distance = distanceToNearest {
                        HStack(spacing: 8) {
                            // Rotated pointer icon pointing to nearest object
                            if let direction = nearestObjectDirection {
                                Image(systemName: "location.north.line.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .rotationEffect(.degrees(direction))
                            } else {
                                Image(systemName: "location.north.line.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            
                            Text(String(format: "%.1fm", distance))
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                        }
                        .padding(.top)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Button(action: { showLeaderboard = true }) {
                            Image(systemName: "trophy.fill")
                                .foregroundColor(.yellow)
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(10)
                        }
                        
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(10)
                        }
                    }
                    .padding(.top)
                }
                
                if let currentLocation = userLocationManager.currentLocation {
                    Text("📍 Location: \(currentLocation.coordinate.latitude, specifier: "%.8f"), \(currentLocation.coordinate.longitude, specifier: "%.8f")")
                        .font(.caption)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .padding(.top)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    if nearbyLocations.isEmpty && !locationManager.locations.isEmpty {
                        Text("Walk to a loot box location!")
                            .font(.headline)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    } else {
                        Text("🎯 \(nearbyLocations.count) loot box\(nearbyLocations.count == 1 ? "" : "es") nearby!")
                            .font(.headline)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    
                    // Collection notification
                    if let notification = collectionNotification {
                        Text(notification)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                            .transition(.opacity)
                            .animation(.easeInOut, value: collectionNotification)
                    }
                    
                    // Temperature indicator with distance
                    if let status = temperatureStatus {
                        Text(status)
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    
                    if !locationManager.locations.isEmpty {
                        // Use computed property to ensure reactive updates when locations change
                        let counter = lootBoxCounter
                        Text("Loot Boxes Found: \(counter.found)/\(counter.total)")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showLocationConfig) {
            LocationConfigView(locationManager: locationManager)
        }
        .sheet(isPresented: $showARPlacement) {
            ARPlacementView(locationManager: locationManager, userLocationManager: userLocationManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(locationManager: locationManager, userLocationManager: userLocationManager)
        }
        .sheet(isPresented: $showLeaderboard) {
            NavigationView {
                LeaderboardView()
                    .navigationTitle("Leaderboard")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showLeaderboard = false
                            }
                        }
                    }
            }
        }
        .onAppear {
            userLocationManager.requestLocationPermission()
            
            // Auto-connect WebSocket on app start
            WebSocketService.shared.connect()
        }
        .onChange(of: userLocationManager.currentLocation) { _, newLocation in
            // When we get a GPS fix, automatically load shared objects from API
            if let location = newLocation {
                // Check if we have a valid GPS fix
                guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else {
                    return
                }
                
                // Auto-load shared objects from API
                Task {
                    await locationManager.loadLocationsFromAPI(userLocation: location)
                }
            }
        }
        // No automatic GPS box creation - user must add items manually via map
        // .onChange(of: userLocationManager.currentLocation) { _, newLocation in
        //     // When we get a GPS fix, check if we need to create/regenerate locations
        //     if let location = newLocation {
        //         // Check if we have a valid GPS fix
        //         guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else {
        //             return
        //         }
        //
        //         // If no locations, or if we need to check/regenerate, reload with user location
        //         if locationManager.locations.isEmpty {
        //             locationManager.loadLocations(userLocation: location)
        //         } else {
        //             // Check if existing locations are too far away
        //             locationManager.loadLocations(userLocation: location)
        //         }
        //     }
        // }
    }
}

