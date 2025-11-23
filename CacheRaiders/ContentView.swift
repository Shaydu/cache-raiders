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
    
    // Helper function to convert meters to feet and inches
    private func formatDistanceInFeetInches(_ meters: Double) -> String {
        let totalInches = meters * 39.3701 // Convert meters to inches
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        
        if feet > 0 {
            return "\(feet)'\(inches)\""
        } else {
            return "\(inches)\""
        }
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
                    
                    // Direction indicator, temperature, and distance to nearest box
                    if let distance = distanceToNearest {
                        VStack(alignment: .center, spacing: 4) {
                            // Rotated pointer icon pointing to selected/nearest object (on top)
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
                            
                            // Temperature status (warmer/colder) - below arrow
                            if let temperature = temperatureStatus {
                                Text(temperature)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            
                            // Distance in feet/inches - on separate line
                            Text(formatDistanceInFeetInches(distance))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
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
                    if !nearbyLocations.isEmpty {
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
                }
                .padding()
                .padding(.bottom, -20)
            }
            
            // Bottom overlay: Loot boxes found (left) and lens selector (right)
            VStack {
                Spacer()
                HStack {
                    // Loot boxes found counter - bottom left, 50% smaller
                    if !locationManager.locations.isEmpty {
                        let counter = lootBoxCounter
                        Text("Loot Boxes Found: \(counter.found)/\(counter.total)")
                            .font(.caption) // 50% smaller (was .body/default, now .caption)
                            .padding(.horizontal, 8) // 50% smaller padding
                            .padding(.vertical, 4) // 50% smaller padding
                            .background(.ultraThinMaterial)
                            .cornerRadius(8) // Slightly smaller corner radius
                            .padding(.leading, 16)
                            .padding(.bottom, 16)
                    }
                    
                    Spacer()
                    
                    // Lens selector - bottom right
                    ARLensSelector(locationManager: locationManager)
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
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

