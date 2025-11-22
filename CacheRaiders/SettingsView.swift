import SwiftUI

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Environment(\.dismiss) var dismiss
    @State private var previousDistance: Double = 10.0
    
    var body: some View {
        NavigationView {
            List {
                Section("Search Distance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Search Distance: \(Int(locationManager.maxSearchDistance))m")
                            .font(.headline)
                        
                        Slider(
                            value: Binding(
                                get: { locationManager.maxSearchDistance },
                                set: { newValue in
                                    locationManager.maxSearchDistance = newValue
                                    locationManager.saveMaxDistance()
                                    
                                    // Regenerate locations when distance changes
                                    if previousDistance != newValue, let userLocation = userLocationManager.currentLocation {
                                        print("🔄 Search distance changed from \(previousDistance)m to \(newValue)m, regenerating loot boxes")
                                        locationManager.regenerateLocations(near: userLocation)
                                    }
                                    previousDistance = newValue
                                }
                            ),
                            in: 10...10000,
                            step: 10
                        )
                        
                        HStack {
                            Text("10m")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("10,000m")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Loot boxes within this distance will appear in AR")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Loot Box Size") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Min Size Slider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Minimum Size: \(String(format: "%.2f", locationManager.lootBoxMinSize))m")
                                .font(.headline)
                            
                            Slider(
                                value: Binding(
                                    get: { locationManager.lootBoxMinSize },
                                    set: { newValue in
                                        // Ensure min doesn't exceed max
                                        let clampedValue = min(newValue, locationManager.lootBoxMaxSize)
                                        locationManager.lootBoxMinSize = clampedValue
                                        locationManager.saveLootBoxSizes()
                                        // This will trigger onSizeChanged callback in ARCoordinator
                                    }
                                ),
                                in: 0.25...1.5,
                                step: 0.05
                            )
                            
                            HStack {
                                Text("0.25m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("1.5m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Max Size Slider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Maximum Size: \(String(format: "%.2f", locationManager.lootBoxMaxSize))m")
                                .font(.headline)
                            
                            Slider(
                                value: Binding(
                                    get: { locationManager.lootBoxMaxSize },
                                    set: { newValue in
                                        // Ensure max doesn't go below min
                                        let clampedValue = max(newValue, locationManager.lootBoxMinSize)
                                        locationManager.lootBoxMaxSize = clampedValue
                                        locationManager.saveLootBoxSizes()
                                        // This will trigger onSizeChanged callback in ARCoordinator
                                    }
                                ),
                                in: 0.25...1.5,
                                step: 0.05
                            )
                            
                            HStack {
                                Text("0.25m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("1.5m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Text("Loot boxes will randomly vary in size between min and max")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("AR Debug") {
                    Toggle("Show AR Debug Visuals", isOn: Binding(
                        get: { locationManager.showARDebugVisuals },
                        set: { newValue in
                            locationManager.showARDebugVisuals = newValue
                            locationManager.saveDebugVisuals()
                        }
                    ))
                    .padding(.vertical, 4)
                    
                    Text("Enable to see ARKit feature points (green triangles) and anchor origins for debugging")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Section("About") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cache Raiders")
                            .font(.headline)
                        Text("An AR treasure hunting game")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                previousDistance = locationManager.maxSearchDistance
            }
        }
    }
}

