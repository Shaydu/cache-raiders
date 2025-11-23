import Foundation
import CoreLocation
import Combine

// MARK: - Loot Box Location Model
struct LootBoxLocation: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let type: LootBoxType
    let latitude: Double
    let longitude: Double
    let radius: Double // meters - how close user needs to be
    var collected: Bool = false
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

// MARK: - CLLocation Extension for Bearing
extension CLLocation {
    func bearing(to destination: CLLocation) -> Double {
        let lat1 = self.coordinate.latitude * .pi / 180.0
        let lat2 = destination.coordinate.latitude * .pi / 180.0
        let deltaLon = (destination.coordinate.longitude - self.coordinate.longitude) * .pi / 180.0
        
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        
        let bearing = atan2(y, x) * 180.0 / .pi
        return (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}

// MARK: - Loot Box Location Manager
class LootBoxLocationManager: ObservableObject {
    @Published var locations: [LootBoxLocation] = []
    @Published var maxSearchDistance: Double = 100.0 // Default 100 meters
    @Published var showARDebugVisuals: Bool = false // Default: debug visuals disabled
    @Published var showFoundOnMap: Bool = false // Default: don't show found items on map
    @Published var disableOcclusion: Bool = false // Default: occlusion enabled (false = occlusion ON)
    @Published var disableAmbientLight: Bool = false // Default: ambient light enabled (false = ambient light ON)
    @Published var lootBoxMinSize: Double = 0.25 // Default 0.25m (minimum size)
    @Published var lootBoxMaxSize: Double = 1.0 // Default 1.0m (maximum size) - reduced from 3.0m
    @Published var shouldRandomize: Bool = false // Trigger for randomizing loot boxes in AR
    @Published var shouldPlaceSphere: Bool = false // Trigger for placing a single sphere in AR
    @Published var pendingSphereLocationId: String? // ID of the map marker location to use for the sphere
    @Published var pendingARItem: LootBoxLocation? // Item to place in AR room
    var onSizeChanged: (() -> Void)? // Callback when size settings change
    private let locationsFileName = "lootBoxLocations.json"
    private let maxDistanceKey = "maxSearchDistance"
    private let debugVisualsKey = "showARDebugVisuals"
    private let showFoundOnMapKey = "showFoundOnMap"
    private let disableOcclusionKey = "disableOcclusion"
    private let disableAmbientLightKey = "disableAmbientLight"
    private let lootBoxMinSizeKey = "lootBoxMinSize"
    private let lootBoxMaxSizeKey = "lootBoxMaxSize"
    
    init() {
        // Don't load existing locations on init - start with clean slate
        // loadLocations()
        loadMaxDistance()
        loadDebugVisuals()
        loadShowFoundOnMap()
        loadDisableOcclusion()
        loadDisableAmbientLight()
        loadLootBoxSizes()
    }
    
    // Load locations from JSON file
    func loadLocations(userLocation: CLLocation? = nil) {
        guard let url = getLocationsFileURL() else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let loadedLocations = try JSONDecoder().decode([LootBoxLocation].self, from: data)
            
            // Check if we have a user location and if loaded locations are too far away
            if let userLocation = userLocation {
                // Check if any location is within a reasonable distance (10km)
                let hasNearbyLocation = loadedLocations.contains { location in
                    userLocation.distance(from: location.location) <= 10000
                }
                
                if !hasNearbyLocation && !loadedLocations.isEmpty {
                    // All locations are too far away - regenerate random ones nearby
                    print("⚠️ Loaded locations are too far away (>10km), regenerating random locations nearby")
                    createDefaultLocations(near: userLocation)
                    return
                }
            }
            
        locations = loadedLocations
        let collectedCount = locations.filter { $0.collected }.count
        print("✅ Loaded \(locations.count) loot box locations (\(collectedCount) collected)")
        } catch {
            // This is expected on first run - no saved locations file exists yet
            if (error as NSError).code == 260 { // File not found
                print("ℹ️ No saved locations found (first run) - will create default locations when GPS is available")
            } else {
                print("⚠️ Could not load locations: \(error.localizedDescription)")
            }
            // Only create defaults if we have a user location
            if let userLocation = userLocation {
                createDefaultLocations(near: userLocation)
            } else {
                // If no user location yet, create empty array (will be populated when location is available)
                locations = []
            }
        }
    }
    
    // Clear all locations and regenerate random ones near user
    func regenerateLocations(near userLocation: CLLocation) {
        locations = []
        createDefaultLocations(near: userLocation)
        print("🔄 Regenerated 3 random loot boxes near your location")
    }

    // Reset all locations to not collected (for testing/debugging)
    func resetAllLocations() {
        for i in 0..<locations.count {
            locations[i].collected = false
        }
        saveLocations()
        print("🔄 Reset all \(locations.count) loot boxes to not collected")
    }
    
    // Save locations to JSON file
    func saveLocations() {
        guard let url = getLocationsFileURL() else { return }
        
        do {
            let data = try JSONEncoder().encode(locations)
            try data.write(to: url)
            print("✅ Saved \(locations.count) loot box locations")
        } catch {
            print("❌ Error saving locations: \(error)")
        }
    }
    
    // Get file URL for locations JSON
    private func getLocationsFileURL() -> URL? {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsDirectory.appendingPathComponent(locationsFileName)
    }
    
    // Create default locations randomly within maxSearchDistance of user location
    func createDefaultLocations(near userLocation: CLLocation) {
        let lootBoxTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest]
        let lootBoxNames = ["Chalice", "Temple Relic", "Treasure Chest"]
        
        locations = []
        
        // Generate 3 random loot boxes within maxSearchDistance
        for _ in 0..<3 {
            // Generate random distance (between 10% and 90% of maxSearchDistance)
            // Ensure minimum distance is at least 5 meters
            let minDistance = max(maxSearchDistance * 0.1, 5.0)
            let maxDistance = maxSearchDistance * 0.9
            let randomDistance = Double.random(in: minDistance...maxDistance)
            
            // Generate random bearing (0-360 degrees)
            let randomBearing = Double.random(in: 0...360) * .pi / 180.0
            
            // Calculate new coordinates using haversine formula
            let earthRadius: Double = 6371000 // meters
            let lat1 = userLocation.coordinate.latitude * .pi / 180.0
            let lon1 = userLocation.coordinate.longitude * .pi / 180.0
            
            let lat2 = asin(sin(lat1) * cos(randomDistance / earthRadius) +
                           cos(lat1) * sin(randomDistance / earthRadius) * cos(randomBearing))
            let lon2 = lon1 + atan2(sin(randomBearing) * sin(randomDistance / earthRadius) * cos(lat1),
                                    cos(randomDistance / earthRadius) - sin(lat1) * sin(lat2))
            
            let newLat = lat2 * 180.0 / .pi
            let newLon = lon2 * 180.0 / .pi
            
            // Pick random type and name
            let randomIndex = Int.random(in: 0..<lootBoxTypes.count)
            
            locations.append(LootBoxLocation(
                id: UUID().uuidString,
                name: lootBoxNames[randomIndex],
                type: lootBoxTypes[randomIndex],
                latitude: newLat,
                longitude: newLon,
                radius: 5.0 // 5 meter radius
            ))
        }
        
        saveLocations()
        print("✅ Created 3 random loot boxes within \(maxSearchDistance)m of your location")
    }
    
    // Add a new location
    func addLocation(_ location: LootBoxLocation) {
        locations.append(location)
        saveLocations()
    }
    
    // Update location
    func updateLocation(_ location: LootBoxLocation) {
        if let index = locations.firstIndex(where: { $0.id == location.id }) {
            locations[index] = location
            saveLocations()
        }
    }
    
    // Mark location as collected
    func markCollected(_ locationId: String) {
        if let index = locations.firstIndex(where: { $0.id == locationId }) {
            print("✅ Marking location \(locations[index].name) (ID: \(locationId)) as collected")
            // Create a new location with collected = true to trigger @Published update
            var updatedLocation = locations[index]
            updatedLocation.collected = true
            locations[index] = updatedLocation

            // Save all locations except temporary AR-only spheres (AR_SPHERE_ without MAP)
            // AR_SPHERE_MAP_ locations should be saved because they're map markers
            let isTemporaryARSphere = locationId.hasPrefix("AR_SPHERE_") && !locationId.hasPrefix("AR_SPHERE_MAP_")
            if !isTemporaryARSphere {
                saveLocations()
                print("💾 Saved locations (including collected status for \(locationId))")
            } else {
                print("⏭️ Skipping save for temporary AR sphere: \(locationId)")
            }

            // Explicitly notify observers (in case @Published doesn't catch the change)
            objectWillChange.send()
        } else {
            print("⚠️ Could not find location with ID \(locationId) to mark as collected")
        }
    }
    
    // Get nearby locations within radius
    func getNearbyLocations(userLocation: CLLocation) -> [LootBoxLocation] {
        return locations.filter { location in
            // Only include uncollected locations
            guard !location.collected else { return false }
            
            // Exclude AR-only locations (AR_SPHERE_ prefix) - these are AR-only and shouldn't be counted as "nearby" for GPS
            // They're placed in AR space, not GPS space, so they don't have meaningful GPS coordinates
            if location.id.hasPrefix("AR_SPHERE_") {
                return false
            }
            
            // Exclude locations with invalid GPS coordinates (lat: 0, lon: 0) - these are AR-only or tap-created
            // They don't have real GPS positions, so distance calculation is meaningless
            if location.latitude == 0 && location.longitude == 0 {
                return false
            }
            
            // Check if within search distance
            return userLocation.distance(from: location.location) <= maxSearchDistance
        }
    }
    
    // Save max distance preference
    func saveMaxDistance() {
        UserDefaults.standard.set(maxSearchDistance, forKey: maxDistanceKey)
    }
    
    // Load max distance preference
    private func loadMaxDistance() {
        if let saved = UserDefaults.standard.object(forKey: maxDistanceKey) as? Double {
            maxSearchDistance = saved
        }
    }
    
    // Save debug visuals preference
    func saveDebugVisuals() {
        UserDefaults.standard.set(showARDebugVisuals, forKey: debugVisualsKey)
    }
    
    // Load debug visuals preference
    private func loadDebugVisuals() {
        showARDebugVisuals = UserDefaults.standard.bool(forKey: debugVisualsKey)
    }
    
    // Save show found on map preference
    func saveShowFoundOnMap() {
        UserDefaults.standard.set(showFoundOnMap, forKey: showFoundOnMapKey)
    }
    
    // Load show found on map preference
    private func loadShowFoundOnMap() {
        showFoundOnMap = UserDefaults.standard.bool(forKey: showFoundOnMapKey)
    }
    
    // Save disable occlusion preference
    func saveDisableOcclusion() {
        UserDefaults.standard.set(disableOcclusion, forKey: disableOcclusionKey)
    }
    
    // Load disable occlusion preference
    private func loadDisableOcclusion() {
        disableOcclusion = UserDefaults.standard.bool(forKey: disableOcclusionKey)
    }
    
    // Save disable ambient light preference
    func saveDisableAmbientLight() {
        UserDefaults.standard.set(disableAmbientLight, forKey: disableAmbientLightKey)
    }
    
    // Load disable ambient light preference
    private func loadDisableAmbientLight() {
        disableAmbientLight = UserDefaults.standard.bool(forKey: disableAmbientLightKey)
    }
    
    // Save loot box size preferences
    func saveLootBoxSizes() {
        UserDefaults.standard.set(lootBoxMinSize, forKey: lootBoxMinSizeKey)
        UserDefaults.standard.set(lootBoxMaxSize, forKey: lootBoxMaxSizeKey)
        
        // Ensure min <= max
        if lootBoxMinSize > lootBoxMaxSize {
            lootBoxMinSize = lootBoxMaxSize
        }
        
        // Notify that sizes have changed
        onSizeChanged?()
    }
    
    // Load loot box size preferences
    private func loadLootBoxSizes() {
        if let saved = UserDefaults.standard.object(forKey: lootBoxMinSizeKey) as? Double {
            lootBoxMinSize = saved
        }
        if let saved = UserDefaults.standard.object(forKey: lootBoxMaxSizeKey) as? Double {
            lootBoxMaxSize = saved
        }
        // Ensure min <= max
        if lootBoxMinSize > lootBoxMaxSize {
            lootBoxMinSize = lootBoxMaxSize
        }
    }
    
    // Get a random size between min and max
    func getRandomLootBoxSize() -> Double {
        return Double.random(in: lootBoxMinSize...lootBoxMaxSize)
    }
    
    // Check if user is at a specific location
    func isAtLocation(_ location: LootBoxLocation, userLocation: CLLocation) -> Bool {
        let distance = userLocation.distance(from: location.location)
        return distance <= location.radius
    }
}

