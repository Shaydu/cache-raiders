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
    @State private var cachedLootBoxCounter: (found: Int, total: Int) = (found: 0, total: 0) // Cache the counter to avoid recomputing on every render
    
    // Helper function to update the cached loot box counter
    private func updateLootBoxCounter() {
        // Use database stats if available (from API sync)
        if let stats = locationManager.databaseStats {
            cachedLootBoxCounter = (found: stats.foundByYou, total: stats.totalVisible)
        } else {
            // Fallback to local data if API stats not available
            let findableLocations = locationManager.findableLocations
            let foundCount = findableLocations.filter { $0.collected }.count
            let totalCount = findableLocations.count
            cachedLootBoxCounter = (found: foundCount, total: totalCount)
        }
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
    
    // Computed property to determine GPS connection status
    private var isGPSConnected: Bool {
        guard let location = userLocationManager.currentLocation else {
            return false
        }
        // GPS is connected if we have a valid location with good accuracy
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100
    }
    
    // MARK: - View Components
    
    private var topOverlayView: some View {
        VStack {
            topToolbarView
            
            locationDisplayView
            
            Spacer()
            
            notificationsView
        }
    }
    
    private var topToolbarView: some View {
        HStack {
            leftButtonsView
            
            Spacer()
            
            directionIndicatorView
            
            Spacer()
            
            rightButtonsView
        }
    }
    
    private var leftButtonsView: some View {
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
    }
    
    private var directionIndicatorView: some View {
        Group {
            if let distance = distanceToNearest {
                Button(action: {
                    // Manually send location to server (also sent automatically every 5 seconds)
                    userLocationManager.sendCurrentLocationToServer()
                }) {
                    VStack(alignment: .center, spacing: 4) {
                        directionArrowView
                        
                        if let temperature = temperatureStatus {
                            Text(temperature)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        
                        Text(formatDistanceInFeetInches(distance))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .overlay(directionIndicatorBorder)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top)
            }
        }
    }
    
    private var directionArrowView: some View {
        Group {
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
        }
    }
    
    private var directionIndicatorBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(directionIndicatorBorderColor, lineWidth: 2)
    }
    
    private var directionIndicatorBorderColor: Color {
        if userLocationManager.isSendingLocation || isRecentlySent {
            return .blue
        }
        return isGPSConnected ? .green : .red
    }
    
    private var isRecentlySent: Bool {
        guard let lastSent = userLocationManager.lastLocationSentSuccessfully else {
            return false
        }
        return Date().timeIntervalSince(lastSent) < 2.0
    }
    
    private var rightButtonsView: some View {
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
    
    private var locationDisplayView: some View {
        Group {
            if let currentLocation = userLocationManager.currentLocation {
                Text("📍 Location: \(currentLocation.coordinate.latitude, specifier: "%.8f"), \(currentLocation.coordinate.longitude, specifier: "%.8f")")
                    .font(.caption)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(.top)
            }
        }
    }
    
    private var notificationsView: some View {
        VStack(spacing: 8) {
            if !nearbyLocations.isEmpty {
                Text("🎯 \(nearbyLocations.count) loot box\(nearbyLocations.count == 1 ? "" : "es") nearby!")
                    .font(.headline)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .offset(y: -54)
            }
            
            if let notification = collectionNotification {
                Text(notification)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .offset(y: -80)
                    .transition(.opacity)
                    .animation(.easeInOut, value: collectionNotification)
            }
        }
        .padding()
        .padding(.bottom, -20)
    }
    
    private var bottomCounterView: some View {
        VStack {
            Spacer()
            HStack {
                if !locationManager.locations.isEmpty {
                    Text("Loot Boxes Found: \(cachedLootBoxCounter.found)/\(cachedLootBoxCounter.total)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
                
                Spacer()
            }
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
            
            topOverlayView
            
            bottomCounterView
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

            // Update cached counter
            updateLootBoxCounter()
        }
        .onChange(of: userLocationManager.currentLocation) { _, newLocation in
            // When we get a GPS fix, automatically load shared objects from API
            if let location = newLocation {
                // Check if we have a valid GPS fix
                guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else {
                    return
                }

                // Auto-load shared objects from API on background thread
                Task.detached(priority: .utility) {
                    await locationManager.loadLocationsFromAPI(userLocation: location)
                }
            }
        }
        .onChange(of: locationManager.locations) { _, _ in
            // Update cached counter when locations change
            updateLootBoxCounter()
        }
        .onChange(of: locationManager.databaseStats) { _, _ in
            // Update cached counter when stats change
            updateLootBoxCounter()
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

