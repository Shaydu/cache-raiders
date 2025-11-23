import SwiftUI
import CoreLocation

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var locationManager = LootBoxLocationManager()
    @StateObject private var userLocationManager = UserLocationManager()
    @State private var showLocationConfig = false
    @State private var showSettings = false
    @State private var nearbyLocations: [LootBoxLocation] = []
    @State private var distanceToNearest: Double?
    @State private var temperatureStatus: String?
    @State private var collectionNotification: String?
    
    var body: some View {
        ZStack {
            ARLootBoxView(
                locationManager: locationManager,
                userLocationManager: userLocationManager,
                nearbyLocations: $nearbyLocations,
                distanceToNearest: $distanceToNearest,
                temperatureStatus: $temperatureStatus,
                collectionNotification: $collectionNotification
            )
            .ignoresSafeArea()
            
            VStack {
                HStack {
                    Button(action: { showLocationConfig = true }) {
                        Image(systemName: "map")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    .padding(.top)
                    
                    Spacer()
                    
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    .padding(.top)
                }
                
                if let currentLocation = userLocationManager.currentLocation {
                    Text("📍 Location: \(currentLocation.coordinate.latitude, specifier: "%.6f"), \(currentLocation.coordinate.longitude, specifier: "%.6f")")
                        .font(.caption)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .padding(.top)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    if locationManager.locations.isEmpty {
                        Text("Tap the map icon to add loot box locations")
                            .font(.headline)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    } else if nearbyLocations.isEmpty {
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
                        
                        Text("💡 Tap on a loot box to discover and collect it")
                            .font(.caption)
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
                        Text("Loot Boxes Found: \(locationManager.locations.filter { $0.collected }.count)/\(locationManager.locations.count)")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    
                    // Randomize button
                    Button(action: {
                        locationManager.shouldRandomize = true
                    }) {
                        HStack {
                            Image(systemName: "shuffle")
                            Text("Randomize Loot Boxes")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.orange)
                        .cornerRadius(10)
                    }

                    // Reset collected status button
                    Button(action: {
                        locationManager.resetAllLocations()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reset All to Not Found")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(10)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showLocationConfig) {
            LocationConfigView(locationManager: locationManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(locationManager: locationManager, userLocationManager: userLocationManager)
        }
        .onAppear {
            userLocationManager.requestLocationPermission()
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

