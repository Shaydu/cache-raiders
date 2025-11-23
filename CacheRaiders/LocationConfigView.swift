import SwiftUI
import CoreLocation

// MARK: - Location Configuration View
struct LocationConfigView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @StateObject private var userLocationManager = UserLocationManager()
    @Environment(\.dismiss) var dismiss
    
    @State private var newLocationName = ""
    @State private var newLocationType: LootBoxType = .goldenIdol
    @State private var newLatitude = ""
    @State private var newLongitude = ""
    @State private var newRadius = "5.0"
    @State private var showDistanceError = false
    @State private var distanceError = ""
    
    var body: some View {
        NavigationView {
            List {
                Section("Add New Location") {
                    TextField("Name", text: $newLocationName)
                    
                    Picker("Type", selection: $newLocationType) {
                        ForEach(LootBoxType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    
                    TextField("Latitude", text: $newLatitude)
                        .keyboardType(.decimalPad)
                    
                    TextField("Longitude", text: $newLongitude)
                        .keyboardType(.decimalPad)
                    
                    TextField("Radius (meters)", text: $newRadius)
                        .keyboardType(.decimalPad)
                    
                    Button("Add Location") {
                        addLocation()
                    }
                    .disabled(newLocationName.isEmpty || newLatitude.isEmpty || newLongitude.isEmpty)
                    
                    if showDistanceError {
                        Text(distanceError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if let userLocation = userLocationManager.currentLocation {
                        Button("Use My Current Location") {
                            newLatitude = String(userLocation.coordinate.latitude)
                            newLongitude = String(userLocation.coordinate.longitude)
                        }
                        .font(.caption)
                    }
                }
                
                Section("Map View") {
                    if !locationManager.locations.isEmpty || userLocationManager.currentLocation != nil {
                        LootBoxMapView(locationManager: locationManager, userLocationManager: userLocationManager)
                            .frame(height: 300)
                            .cornerRadius(10)
                    } else {
                        Text("Add locations to see them on the map")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(height: 300)
                    }
                    
                    if let userLocation = userLocationManager.currentLocation {
                        Button("🔄 Regenerate Random Loot Boxes") {
                            locationManager.regenerateLocations(near: userLocation)
                        }
                        .foregroundColor(.blue)
                    }
                }
                
                Section("Current Locations") {
                    ForEach(locationManager.locations) { location in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(location.name)
                                .font(.headline)
                            Text(location.type.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("📍 \(location.latitude, specifier: "%.6f"), \(location.longitude, specifier: "%.6f")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Radius: \(location.radius, specifier: "%.1f")m")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if location.collected {
                                Text("✅ Collected")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        locationManager.locations.remove(atOffsets: indexSet)
                        locationManager.saveLocations()
                    }
                }
                
                Section("Instructions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Get your coordinates:")
                            .font(.caption)
                        Text("   • Use Maps app to find your location")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("   • Long press to drop a pin")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("   • Tap the pin to see coordinates")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("2. Enter coordinates above")
                            .font(.caption)
                            .padding(.top, 4)
                        
                        Text("3. Set radius (how close you need to be)")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
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
    
    private func addLocation() {
        guard let lat = Double(newLatitude),
              let lon = Double(newLongitude),
              let radius = Double(newRadius) else {
            return
        }
        
        // Check distance from user's current location
        if let userLocation = userLocationManager.currentLocation {
            let newLocation = CLLocation(latitude: lat, longitude: lon)
            let distance = userLocation.distance(from: newLocation)
            
            if distance > locationManager.maxSearchDistance {
                showDistanceError = true
                distanceError = "⚠️ Location is \(String(format: "%.1f", distance))m away. Must be within \(Int(locationManager.maxSearchDistance))m of your current location."
                return
            }
        }
        
        let location = LootBoxLocation(
            id: UUID().uuidString,
            name: newLocationName,
            type: newLocationType,
            latitude: lat,
            longitude: lon,
            radius: radius
        )
        
        locationManager.addLocation(location)
        showDistanceError = false
        
        // Reset fields
        newLocationName = ""
        newLatitude = ""
        newLongitude = ""
        newRadius = "5.0"
    }
}

