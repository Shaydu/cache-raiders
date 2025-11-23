import SwiftUI

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Environment(\.dismiss) var dismiss
    @State private var previousDistance: Double = 10.0
    
    // Helper function to get icon name for each findable type
    private func iconName(for type: LootBoxType) -> String {
        switch type {
        case .chalice:
            return "cup.and.saucer.fill"
        case .templeRelic:
            return "building.columns.fill"
        case .treasureChest:
            return "shippingbox.fill"
        case .sphere:
            return "circle.fill"
        case .cube:
            return "cube.fill"
        }
    }
    
    // Helper function to get model names for each findable type
    private func modelNames(for type: LootBoxType) -> [String] {
        switch type {
        case .chalice:
            return ["Chalice", "Chalice-basic"]
        case .templeRelic:
            return ["Stylised_Treasure_Chest", "Treasure_Chest"]
        case .treasureChest:
            return ["Treasure_Chest"]
        case .sphere, .cube:
            return [] // Spheres and cubes are procedural, no models
        }
    }
    
    // Group types by their model names to deduplicate
    private var groupedFindableTypes: [(models: [String], types: [LootBoxType])] {
        var groups: [[String]: [LootBoxType]] = [:]
        
        for type in LootBoxType.allCases {
            let models = modelNames(for: type)
            let key = models.sorted()
            if groups[key] == nil {
                groups[key] = []
            }
            groups[key]?.append(type)
        }
        
        return groups.map { (models: $0.key, types: $0.value) }
            .sorted { $0.types.first?.displayName ?? "" < $1.types.first?.displayName ?? "" }
    }
    
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
                            in: 10...100,
                            step: 10
                        )
                        
                        HStack {
                            Text("10m")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("100m")
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
                
                Section("Findable Types") {
                    ForEach(Array(groupedFindableTypes.enumerated()), id: \.offset) { index, group in
                        HStack(spacing: 12) {
                            // Use icon from first type in group
                            let firstType = group.types.first!
                            Image(systemName: iconName(for: firstType))
                                .foregroundColor(Color(firstType.color))
                                .font(.title3)
                                .frame(width: 30)
                            
                            // Show all type names that share these models
                            let typeNames = group.types.map { $0.displayName }.joined(separator: ", ")
                            
                            if group.models.isEmpty {
                                Text(typeNames)
                                    .font(.body)
                            } else {
                                Text("\(typeNames) (\(group.models.joined(separator: ", ")))")
                                    .font(.body)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                Section("Map Display") {
                    Toggle("Show Found on Map", isOn: Binding(
                        get: { locationManager.showFoundOnMap },
                        set: { newValue in
                            locationManager.showFoundOnMap = newValue
                            locationManager.saveShowFoundOnMap()
                        }
                    ))
                    .padding(.vertical, 4)
                    
                    Text("When enabled, found items appear in deep red and unfound items appear in green on the map")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                    
                    Toggle("Disable Occlusion", isOn: Binding(
                        get: { locationManager.disableOcclusion },
                        set: { newValue in
                            locationManager.disableOcclusion = newValue
                            locationManager.saveDisableOcclusion()
                        }
                    ))
                    .padding(.vertical, 4)
                    
                    Text("When enabled, objects will be visible even when behind walls. Useful for finding hidden objects.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Toggle("Disable Ambient Light", isOn: Binding(
                        get: { locationManager.disableAmbientLight },
                        set: { newValue in
                            locationManager.disableAmbientLight = newValue
                            locationManager.saveDisableAmbientLight()
                        }
                    ))
                    .padding(.vertical, 4)
                    
                    Text("When enabled, objects will have uniform brightness regardless of real-world lighting conditions.")
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

