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

// MARK: - Loot Box Location Manager
class LootBoxLocationManager: ObservableObject {
    @Published var locations: [LootBoxLocation] = []
    @Published var maxSearchDistance: Double = 100.0 // Default 100 meters
    private let locationsFileName = "lootBoxLocations.json"
    private let maxDistanceKey = "maxSearchDistance"
    
    init() {
        loadLocations()
        loadMaxDistance()
    }
    
    // Load locations from JSON file
    func loadLocations() {
        guard let url = getLocationsFileURL() else { return }
        
        do {
            let data = try Data(contentsOf: url)
            locations = try JSONDecoder().decode([LootBoxLocation].self, from: data)
            print("✅ Loaded \(locations.count) loot box locations")
        } catch {
            print("⚠️ Could not load locations, using defaults: \(error)")
            createDefaultLocations()
        }
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
    
    // Create default locations (example coordinates - user should update these)
    func createDefaultLocations() {
        // Example: Replace these with your actual yard coordinates
        locations = [
            LootBoxLocation(
                id: UUID().uuidString,
                name: "Crystal Skull",
                type: .crystalSkull,
                latitude: 37.7749,  // Replace with your latitude
                longitude: -122.4194, // Replace with your longitude
                radius: 5.0 // 5 meter radius
            ),
            LootBoxLocation(
                id: UUID().uuidString,
                name: "Golden Idol",
                type: .goldenIdol,
                latitude: 37.7750,  // Replace with your latitude
                longitude: -122.4195, // Replace with your longitude
                radius: 5.0
            ),
            LootBoxLocation(
                id: UUID().uuidString,
                name: "Ancient Artifact",
                type: .ancientArtifact,
                latitude: 37.7751,  // Replace with your latitude
                longitude: -122.4196, // Replace with your longitude
                radius: 5.0
            )
        ]
        saveLocations()
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
            locations[index].collected = true
            saveLocations()
        }
    }
    
    // Get nearby locations within radius
    func getNearbyLocations(userLocation: CLLocation) -> [LootBoxLocation] {
        return locations.filter { location in
            !location.collected && userLocation.distance(from: location.location) <= maxSearchDistance
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
    
    // Check if user is at a specific location
    func isAtLocation(_ location: LootBoxLocation, userLocation: CLLocation) -> Bool {
        let distance = userLocation.distance(from: location.location)
        return distance <= location.radius
    }
}

