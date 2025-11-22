import SwiftUI
import CoreLocation

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var locationManager = LootBoxLocationManager()
    @StateObject private var userLocationManager = UserLocationManager()
    @State private var showLocationConfig = false
    @State private var showSettings = false
    @State private var nearbyLocations: [LootBoxLocation] = []
    
    var body: some View {
        ZStack {
            ARLootBoxView(
                locationManager: locationManager,
                userLocationManager: userLocationManager,
                nearbyLocations: $nearbyLocations
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
                    }
                    
                    if !locationManager.locations.isEmpty {
                        Text("Loot Boxes Found: \(locationManager.locations.filter { $0.collected }.count)/\(locationManager.locations.count)")
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
        .sheet(isPresented: $showSettings) {
            SettingsView(locationManager: locationManager)
        }
        .onAppear {
            userLocationManager.requestLocationPermission()
        }
    }
}

