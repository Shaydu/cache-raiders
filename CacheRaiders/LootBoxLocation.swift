import Foundation
import CoreLocation
import Combine

// MARK: - Item Source Enum
/// Represents where a loot box location came from
enum ItemSource: String, Codable {
    case api = "api"              // From the shared API database
    case map = "map"              // Added from map (has GPS, should be saved)
    case arRandomized = "ar_randomized"  // Randomized in AR (temporary, no GPS)
    case arManual = "ar_manual"   // Manually placed in AR (temporary, no GPS)
    
    /// Whether this source should be persisted to disk
    var shouldPersist: Bool {
        switch self {
        case .api, .map:
            return true
        case .arRandomized, .arManual:
            return false
        }
    }
    
    /// Whether this source should sync to API
    var shouldSyncToAPI: Bool {
        switch self {
        case .api, .map:
            return true
        case .arRandomized, .arManual:
            return false
        }
    }
    
    /// Whether this source should appear on the map
    var shouldShowOnMap: Bool {
        switch self {
        case .api, .map:
            return true
        case .arRandomized, .arManual:
            return false
        }
    }
}

// MARK: - Database Stats
struct DatabaseStats: Equatable {
    let foundByYou: Int
    let totalVisible: Int
}

// MARK: - Loot Box Location Model
struct LootBoxLocation: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let type: LootBoxType
    let latitude: Double
    let longitude: Double
    let radius: Double // meters - how close user needs to be
    var collected: Bool = false
    var grounding_height: Double? // Optional: stored grounding height in meters (AR world space Y coordinate)
    var source: ItemSource = .api // Default to API source for backward compatibility

    // AR-offset based positioning for centimeter-level accuracy
    var ar_origin_latitude: Double? // GPS location where AR session originated
    var ar_origin_longitude: Double? // GPS location where AR session originated
    var ar_offset_x: Double? // X offset from AR origin in meters
    var ar_offset_y: Double? // Y offset from AR origin in meters (height)
    var ar_offset_z: Double? // Z offset from AR origin in meters
    var ar_placement_timestamp: Date? // When the object was placed in AR
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
    
    // MARK: - Computed Properties (replaces prefix checks)
    
    /// Whether this is a temporary AR-only item (not persisted)
    var isTemporary: Bool {
        return !source.shouldPersist
    }
    
    /// Whether this item should be saved to disk
    var shouldPersist: Bool {
        return source.shouldPersist
    }
    
    /// Whether this item should sync to API
    var shouldSyncToAPI: Bool {
        return source.shouldSyncToAPI
    }
    
    /// Whether this item should appear on the map
    var shouldShowOnMap: Bool {
        return source.shouldShowOnMap
    }
    
    /// Whether this is an AR-only item (no GPS coordinates)
    var isAROnly: Bool {
        return latitude == 0 && longitude == 0
    }
    
    /// Whether this has valid GPS coordinates
    var hasGPSCoordinates: Bool {
        return !isAROnly
    }
    
    // MARK: - Initializers
    
    /// Normal initializer for creating new locations
    init(id: String, name: String, type: LootBoxType, latitude: Double, longitude: Double, radius: Double, collected: Bool = false, grounding_height: Double? = nil, source: ItemSource = .api) {
        self.id = id
        self.name = name
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.collected = collected
        self.grounding_height = grounding_height
        self.source = source
    }
    
    // MARK: - Custom Decoding (backward compatibility with prefix-based IDs)
    
    /// Initialize from decoder with backward compatibility for prefix-based IDs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(LootBoxType.self, forKey: .type)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        radius = try container.decode(Double.self, forKey: .radius)
        collected = try container.decodeIfPresent(Bool.self, forKey: .collected) ?? false
        grounding_height = try container.decodeIfPresent(Double.self, forKey: .grounding_height)
        
        // Try to decode source, but if not present, infer from ID prefix (backward compatibility)
        if let decodedSource = try? container.decode(ItemSource.self, forKey: .source) {
            source = decodedSource
        } else {
            // Infer source from ID prefix for backward compatibility
            if id.hasPrefix("AR_SPHERE_MAP_") {
                source = .map
            } else if id.hasPrefix("MAP_ITEM_") {
                source = .map
            } else if id.hasPrefix("AR_ITEM_") {
                source = .arRandomized
            } else if id.hasPrefix("AR_SPHERE_") {
                source = .arRandomized
            } else {
                source = .api // Default to API for regular IDs
            }
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, type, latitude, longitude, radius, collected, grounding_height, source
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
    @Published var maxObjectLimit: Int = 6 // Default 6 objects (range: 1-25)
    @Published var showARDebugVisuals: Bool = false // Default: debug visuals disabled
    @Published var showFoundOnMap: Bool = false // Default: don't show found items on map
    @Published var disableOcclusion: Bool = false // Default: occlusion enabled (false = occlusion ON)
    @Published var disableAmbientLight: Bool = false // Default: ambient light enabled (false = ambient light ON)
    @Published var enableObjectRecognition: Bool = false // Default: object recognition disabled (saves battery/processing)
    @Published var enableAudioMode: Bool = false // Default: audio mode disabled
    @Published var lootBoxMinSize: Double = 0.25 // Default 0.25m (minimum size)
    @Published var lootBoxMaxSize: Double = 0.61 // Default 0.61m (2 feet maximum size)
    @Published var arZoomLevel: Double = 1.0 // Default 1.0x zoom (normal view)
    @Published var selectedARLens: String? = nil // Selected AR camera lens identifier (nil = default/wide)
    @Published var shouldRandomize: Bool = false // Trigger for randomizing loot boxes in AR
    @Published var shouldPlaceSphere: Bool = false // Trigger for placing a single sphere in AR
    @Published var pendingSphereLocationId: String? // ID of the map marker location to use for the sphere
    @Published var pendingARItem: LootBoxLocation? // Item to place in AR room
    @Published var shouldResetARObjects: Bool = false // Trigger for removing all AR objects when locations are reset
    @Published var selectedDatabaseObjectId: String? = nil // Selected database object to find (only one at a time)
    @Published var databaseStats: DatabaseStats? = nil // Database stats for loot box counter
    @Published var showOnlyNextItem: Bool = false // Show only the next unfound item in the list
    var onSizeChanged: (() -> Void)? // Callback when size settings change
    var onObjectCollectedByOtherUser: ((String) -> Void)? // Callback when object is collected by another user (to remove from AR)
    private let locationsFileName = "lootBoxLocations.json"
    private let maxDistanceKey = "maxSearchDistance"
    private let maxObjectLimitKey = "maxObjectLimit"
    private let debugVisualsKey = "showARDebugVisuals"
    private let showFoundOnMapKey = "showFoundOnMap"
    private let disableOcclusionKey = "disableOcclusion"
    private let disableAmbientLightKey = "disableAmbientLight"
    private let enableObjectRecognitionKey = "enableObjectRecognition"
    private let enableAudioModeKey = "enableAudioMode"
    private let lootBoxMinSizeKey = "lootBoxMinSize"
    private let lootBoxMaxSizeKey = "lootBoxMaxSize"
    private let selectedDatabaseObjectIdKey = "selectedDatabaseObjectId"
    private let arZoomLevelKey = "arZoomLevel"
    private let selectedARLensKey = "selectedARLens"
    private let showOnlyNextItemKey = "showOnlyNextItem"
    
    // API refresh timer - refreshes from API periodically when enabled
    private var apiRefreshTimer: Timer?
    private let apiRefreshInterval: TimeInterval = 120.0 // 120 seconds (2 minutes) - reduced frequency for better performance
    private var lastKnownUserLocation: CLLocation?
    private var isRefreshingFromAPI: Bool = false // Prevent concurrent API refreshes
    
    init() {
        // Don't load existing locations on init - start with clean slate
        // loadLocations()
        loadMaxDistance()
        loadMaxObjectLimit()
        loadDebugVisuals()
        loadShowFoundOnMap()
        loadDisableOcclusion()
        loadDisableAmbientLight()
        loadEnableObjectRecognition()
        loadEnableAudioMode()
        loadLootBoxSizes()
        loadSelectedDatabaseObjectId()
        loadARZoomLevel()
        loadSelectedARLens()
        loadShowOnlyNextItem()
        
        // API sync is always enabled - start refresh timer
        startAPIRefreshTimer()
        
        // Auto-connect to WebSocket
        WebSocketService.shared.connect()
        
        // Set up WebSocket event handlers for real-time updates
        setupWebSocketCallbacks()
    }
    
    /// Set up WebSocket callbacks to handle real-time collection events from other users
    private func setupWebSocketCallbacks() {
        WebSocketService.shared.onObjectCollected = { [weak self] objectId, foundBy, foundAt in
            guard let self = self else { return }
            
            // Get current user ID to check if we collected it ourselves
            let currentUserId = APIService.shared.currentUserID
            
            // Only handle if collected by another user (not us)
            if foundBy != currentUserId {
                print("🔔 Another user (\(foundBy)) collected object: \(objectId)")
                
                // Defer state modifications to avoid "Modifying state during view update" warnings
                Task { @MainActor in
                    // Update the location's collected status
                    if let index = self.locations.firstIndex(where: { $0.id == objectId }) {
                        var updatedLocation = self.locations[index]
                        updatedLocation.collected = true
                        self.locations[index] = updatedLocation
                        
                        // Notify observers
                        self.objectWillChange.send()
                        
                        // Notify AR coordinator to remove the object from AR scene
                        self.onObjectCollectedByOtherUser?(objectId)
                        
                        print("✅ Updated location '\(updatedLocation.name)' to collected status (found by another user)")
                    } else {
                        // Location not in our list yet - might need to reload from API
                        print("⚠️ Object \(objectId) collected by another user but not in local locations list")
                        // Optionally trigger a refresh from API
                        if let userLocation = self.lastKnownUserLocation {
                            Task {
                                await self.loadLocationsFromAPI(userLocation: userLocation, includeFound: true)
                            }
                        }
                    }
                }
            } else {
                print("ℹ️ We collected object \(objectId) ourselves - no action needed")
            }
        }
        
        WebSocketService.shared.onObjectUncollected = { [weak self] objectId in
            guard let self = self else { return }
            
            print("🔄 Object uncollected (reset): \(objectId)")
            
            // Update the location's collected status to false
            if let index = self.locations.firstIndex(where: { $0.id == objectId }) {
                var updatedLocation = self.locations[index]
                updatedLocation.collected = false
                self.locations[index] = updatedLocation
                
                // Notify observers
                self.objectWillChange.send()
                
                print("✅ Updated location '\(updatedLocation.name)' to uncollected status")
            }
        }
        
        WebSocketService.shared.onAllFindsReset = { [weak self] in
            guard let self = self else { return }
            
            print("🔄 All finds reset - reloading from API")
            
            // Reload all locations from API to get updated collected status
            if let userLocation = self.lastKnownUserLocation {
                Task {
                    await self.loadLocationsFromAPI(userLocation: userLocation, includeFound: true)
                }
            }
        }
    }
    
    deinit {
        stopAPIRefreshTimer()
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
        
        // Trigger AR object removal so they can be re-placed at proper GPS locations
        shouldResetARObjects = true
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
    // NOTE: These auto-generated objects are LOCAL ONLY and do NOT sync to API
    // Only manually added objects (via addLocation) sync to the shared API database
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
    
    // Add a new location (manually added by user)
    // NOTE: Manually added objects ARE synced to the shared API database when useAPISync is enabled
    func addLocation(_ location: LootBoxLocation) {
        // Check if location with same ID already exists (prevent duplicates)
        if locations.contains(where: { $0.id == location.id }) {
            print("⚠️ Location with ID \(location.id) already exists - skipping duplicate")
            return
        }
        locations.append(location)
        saveLocations()
        
        // Sync to shared API database if enabled (manual additions are shared)
        if useAPISync {
            Task {
                await saveLocationToAPI(location)
                print("✅ Synced manually added object '\(location.name)' to shared API database")
            }
        }
    }
    
    /// Returns only findable locations (excludes temporary AR-only items, but includes map-added spheres)
    var findableLocations: [LootBoxLocation] {
        return locations.filter { location in
            // All locations are findable (filtering happens elsewhere)
            return true
        }
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

            // Save all locations except temporary AR-only items
            if updatedLocation.shouldPersist {
                saveLocations()
                print("💾 Saved locations (including collected status for \(locationId))")
                
                // Also sync to API if enabled
                if useAPISync {
                    Task {
                        await markCollectedInAPI(locationId)
                    }
                }
            } else {
                print("⏭️ Skipping save for temporary AR item: \(locationId)")
            }

            // Explicitly notify observers (in case @Published doesn't catch the change)
            objectWillChange.send()
        } else {
            print("⚠️ Could not find location with ID \(locationId) to mark as collected")
        }
    }
    
    // Unmark location as collected
    func unmarkCollected(_ locationId: String) {
        if let index = locations.firstIndex(where: { $0.id == locationId }) {
            print("🔄 Unmarking location \(locations[index].name) (ID: \(locationId)) as not collected")
            // Create a new location with collected = false to trigger @Published update
            var updatedLocation = locations[index]
            updatedLocation.collected = false
            locations[index] = updatedLocation

            // Save all locations except temporary AR-only items
            if updatedLocation.shouldPersist {
                saveLocations()
                print("💾 Saved locations (including uncollected status for \(locationId))")
                
                // Also sync to API if enabled
                if useAPISync {
                    Task {
                        await unmarkCollectedInAPI(locationId)
                    }
                }
            } else {
                print("⏭️ Skipping save for temporary AR item: \(locationId)")
            }

            // Explicitly notify observers (in case @Published doesn't catch the change)
            objectWillChange.send()
        } else {
            print("⚠️ Could not find location with ID \(locationId) to unmark as collected")
        }
    }
    
    // Toggle collected status
    func toggleCollected(_ locationId: String) {
        if let index = locations.firstIndex(where: { $0.id == locationId }) {
            let location = locations[index]
            if location.collected {
                unmarkCollected(locationId)
            } else {
                markCollected(locationId)
            }
        }
    }
    
    // Unmark collected in API
    private func unmarkCollectedInAPI(_ locationId: String) async {
        do {
            try await APIService.shared.unmarkFound(objectId: locationId)
            print("✅ Successfully unmarked \(locationId) as not collected in API")
        } catch {
            print("❌ Failed to unmark \(locationId) as not collected in API: \(error.localizedDescription)")
        }
    }
    
    // Get nearby locations within radius
    func getNearbyLocations(userLocation: CLLocation) -> [LootBoxLocation] {
        return locations.filter { location in
            // Only include uncollected locations
            guard !location.collected else { return false }

            // Exclude AR-only locations - these are AR-only and shouldn't be counted as "nearby" for GPS
            // They're placed in AR space, not GPS space, so they don't have meaningful GPS coordinates
            if location.isAROnly {
                return false
            }

            // CRITICAL: If a specific object is selected, ALWAYS include it regardless of distance
            // This ensures the selected object appears in AR even if it's far away
            if let selectedId = selectedDatabaseObjectId, location.id == selectedId {
                // PERFORMANCE: Logging disabled - this runs in filter loop, causes massive spam
                return true
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
    
    // Save max object limit preference
    func saveMaxObjectLimit() {
        UserDefaults.standard.set(maxObjectLimit, forKey: maxObjectLimitKey)
    }
    
    // Load max object limit preference
    private func loadMaxObjectLimit() {
        if let saved = UserDefaults.standard.object(forKey: maxObjectLimitKey) as? Int {
            // Clamp to valid range (1-25)
            maxObjectLimit = max(1, min(25, saved))
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
    
    // Save enable object recognition preference
    func saveEnableObjectRecognition() {
        UserDefaults.standard.set(enableObjectRecognition, forKey: enableObjectRecognitionKey)
    }
    
    // Load enable object recognition preference
    private func loadEnableObjectRecognition() {
        enableObjectRecognition = UserDefaults.standard.bool(forKey: enableObjectRecognitionKey)
    }
    
    // Save enable audio mode preference
    func saveEnableAudioMode() {
        UserDefaults.standard.set(enableAudioMode, forKey: enableAudioModeKey)
    }
    
    // Load enable audio mode preference
    // Always defaults to false (OFF) when app loads
    private func loadEnableAudioMode() {
        // Don't load from UserDefaults - always default to false (OFF)
        enableAudioMode = false
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
    
    // Save AR zoom level preference
    func saveARZoomLevel() {
        UserDefaults.standard.set(arZoomLevel, forKey: arZoomLevelKey)
    }
    
    // Load AR zoom level preference
    private func loadARZoomLevel() {
        if let saved = UserDefaults.standard.object(forKey: arZoomLevelKey) as? Double {
            arZoomLevel = saved
        } else {
            arZoomLevel = 1.0 // Default to 1.0x (normal view)
        }
        // Clamp zoom level to valid range (0.5x to 3.0x)
        arZoomLevel = max(0.5, min(3.0, arZoomLevel))
    }
    
    // Save selected database object ID
    func saveSelectedDatabaseObjectId() {
        if let objectId = selectedDatabaseObjectId {
            UserDefaults.standard.set(objectId, forKey: selectedDatabaseObjectIdKey)
            print("✅ Saved selected database object ID: \(objectId)")
        } else {
            UserDefaults.standard.removeObject(forKey: selectedDatabaseObjectIdKey)
            print("✅ Cleared selected database object ID")
        }
    }
    
    // Load selected database object ID
    private func loadSelectedDatabaseObjectId() {
        selectedDatabaseObjectId = UserDefaults.standard.string(forKey: selectedDatabaseObjectIdKey)
        if let objectId = selectedDatabaseObjectId {
            print("✅ Loaded selected database object ID: \(objectId)")
        }
    }
    
    // Set selected database object ID (and save)
    func setSelectedDatabaseObjectId(_ objectId: String?) {
        selectedDatabaseObjectId = objectId
        saveSelectedDatabaseObjectId()
    }
    
    // Save show only next item preference
    func saveShowOnlyNextItem() {
        UserDefaults.standard.set(showOnlyNextItem, forKey: showOnlyNextItemKey)
    }
    
    // Load show only next item preference
    private func loadShowOnlyNextItem() {
        showOnlyNextItem = UserDefaults.standard.bool(forKey: showOnlyNextItemKey)

        // Clear all AR objects since we're changing the filter
        // This ensures old objects don't remain visible when filtering to a specific object
        shouldResetARObjects = true

        // Reload locations from API to filter to only the selected object
        if let userLocation = lastKnownUserLocation {
            Task {
                await loadLocationsFromAPI(userLocation: userLocation)
            }
        }
    }
    
    // Save selected AR lens preference
    func saveSelectedARLens() {
        if let lensId = selectedARLens {
            UserDefaults.standard.set(lensId, forKey: selectedARLensKey)
            print("✅ Saved selected AR lens: \(lensId)")
        } else {
            UserDefaults.standard.removeObject(forKey: selectedARLensKey)
            print("✅ Cleared selected AR lens (using default)")
        }
    }
    
    // Load selected AR lens preference
    private func loadSelectedARLens() {
        selectedARLens = UserDefaults.standard.string(forKey: selectedARLensKey)
        if let lensId = selectedARLens {
            print("✅ Loaded selected AR lens: \(lensId)")
        }
    }
    
    // Set selected AR lens (and save)
    func setSelectedARLens(_ lensId: String?) {
        selectedARLens = lensId
        saveSelectedARLens()
    }
    
    // Check if user is at a specific location
    func isAtLocation(_ location: LootBoxLocation, userLocation: CLLocation) -> Bool {
        let distance = userLocation.distance(from: location.location)
        return distance <= location.radius
    }
    
    // MARK: - API Sync Methods
    
    /// API sync is always enabled - automatically syncs to shared database
    var useAPISync: Bool {
        get {
            // Always return true - API sync is always enabled
            return true
        }
        set {
            // Ignore attempts to disable - API sync is always enabled
            // Always start the refresh timer
            startAPIRefreshTimer()
        }
    }
    
    /// Start the API refresh timer to periodically sync from API
    private func startAPIRefreshTimer() {
        stopAPIRefreshTimer() // Stop any existing timer first

        apiRefreshTimer = Timer.scheduledTimer(withTimeInterval: apiRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.useAPISync else {
                self.stopAPIRefreshTimer()
                return
            }

            // Prevent concurrent refreshes to avoid UI blocking
            guard !self.isRefreshingFromAPI else {
                print("⏭️ Skipping API refresh - already in progress")
                return
            }

            print("🔄 Auto-refreshing from API (every \(Int(self.apiRefreshInterval))s)...")

            // Run on background thread with lower priority to avoid blocking UI
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }

                await MainActor.run {
                    self.isRefreshingFromAPI = true
                }

                await self.loadLocationsFromAPI(userLocation: self.lastKnownUserLocation)

                await MainActor.run {
                    self.isRefreshingFromAPI = false
                }
            }
        }

        // Add timer to main run loop (not common) to avoid blocking during scrolling
        if let timer = apiRefreshTimer {
            RunLoop.main.add(timer, forMode: .default)
        }

        print("✅ Started API refresh timer (every \(Int(apiRefreshInterval))s)")
    }
    
    /// Stop the API refresh timer
    private func stopAPIRefreshTimer() {
        apiRefreshTimer?.invalidate()
        apiRefreshTimer = nil
        print("⏹️ Stopped API refresh timer")
    }
    
    /// Update the last known user location (called when location changes)
    func updateUserLocation(_ location: CLLocation) {
        lastKnownUserLocation = location
    }
    
    /// Load locations from API instead of local file
    func loadLocationsFromAPI(userLocation: CLLocation? = nil, includeFound: Bool = false) async {
        guard useAPISync else {
            print("ℹ️ API sync is disabled, using local storage")
            return
        }
        
        do {
            // Check API health first
            let isHealthy = try await APIService.shared.checkHealth()
            guard isHealthy else {
                print("⚠️ API server at \(APIService.shared.baseURL) is not available")
                print("   Make sure the server is running: cd server && python app.py")
                print("   Falling back to local storage")
                loadLocations(userLocation: userLocation)
                return
            }
            
            // Get objects from API
            var apiObjects: [APIObject]
            var allApiObjectsForStats: [APIObject] = [] // All objects for accurate stats

            // CRITICAL: If a specific object is selected, skip distance filtering
            // This ensures the selected object is always loaded, regardless of how far away it is
            if let selectedId = selectedDatabaseObjectId {
                // Get ALL objects (no distance filter) and then filter to just the selected one
                print("🎯 Selected object mode: fetching all objects to find '\(selectedId)'")
                apiObjects = try await APIService.shared.getObjects(includeFound: includeFound)
                apiObjects = apiObjects.filter { $0.id == selectedId }
                allApiObjectsForStats = apiObjects // For selected mode, stats = selected object only

                if apiObjects.isEmpty {
                    print("⚠️ Selected database object ID '\(selectedId)' not found in API results")
                    print("   Clearing selection to show all objects")
                    // Clear selection so user can see other objects
                    await MainActor.run {
                        self.selectedDatabaseObjectId = nil
                        self.saveSelectedDatabaseObjectId()
                    }
                    // Re-fetch without selection filter
                    if let userLocation = userLocation {
                        apiObjects = try await APIService.shared.getObjects(
                            latitude: userLocation.coordinate.latitude,
                            longitude: userLocation.coordinate.longitude,
                            radius: maxSearchDistance,
                            includeFound: includeFound
                        )
                    } else {
                        apiObjects = try await APIService.shared.getObjects(includeFound: includeFound)
                    }
                } else {
                    let selectedName = apiObjects.first?.name ?? "Unknown"
                    print("🎯 Found selected database object: \(selectedName) (ID: \(selectedId))")
                }
            } else {
                // Normal mode: get nearby objects for AR placement, but ALL objects for accurate stats
                if let userLocation = userLocation {
                    // Get nearby objects for AR placement (within maxSearchDistance)
                    apiObjects = try await APIService.shared.getObjects(
                        latitude: userLocation.coordinate.latitude,
                        longitude: userLocation.coordinate.longitude,
                        radius: maxSearchDistance,
                        includeFound: includeFound
                    )
                    
                    // Get ALL objects (large radius) for accurate stats matching Settings view
                    // Use 10km radius to match what Settings view shows (or all if no location)
                    allApiObjectsForStats = try await APIService.shared.getObjects(
                        latitude: userLocation.coordinate.latitude,
                        longitude: userLocation.coordinate.longitude,
                        radius: 10000.0, // 10km to match Settings view
                        includeFound: true // Always include found for accurate stats
                    )
                } else {
                    // No location: get all objects for both AR and stats
                    apiObjects = try await APIService.shared.getObjects(includeFound: includeFound)
                    allApiObjectsForStats = apiObjects
                }
            }
            
            // Convert API objects to LootBoxLocations for AR placement
            let loadedLocations = apiObjects.compactMap { apiObject in
                APIService.shared.convertToLootBoxLocation(apiObject)
            }
            
            // Convert ALL objects for stats calculation (matching Settings view)
            let allLocationsForStats = allApiObjectsForStats.compactMap { apiObject in
                APIService.shared.convertToLootBoxLocation(apiObject)
            }
            
            await MainActor.run {
                // Merge API-loaded locations with local items that haven't been synced yet
                // This preserves locally created items (spheres, cubes) that aren't in the API yet
                let apiLocationIds = Set(loadedLocations.map { $0.id })
                let localOnlyItems = self.locations.filter { location in
                    // Keep local items that:
                    // 1. Are temporary AR-only items (not persisted, not synced)
                    // 2. Are map-created items that aren't in API yet
                    let isTemporaryAR = location.isTemporary && location.isAROnly
                    let isMapCreatedNotSynced = location.source == .map && !apiLocationIds.contains(location.id)
                    return isTemporaryAR || isMapCreatedNotSynced
                }
                
                // Combine API locations with local-only items
                self.locations = loadedLocations + localOnlyItems
                
                let collectedCount = loadedLocations.filter { $0.collected }.count
                let unfoundCount = loadedLocations.count - collectedCount
                print("✅ Loaded \(loadedLocations.count) loot box locations from API for AR (\(collectedCount) collected, \(unfoundCount) unfound)")
                if !localOnlyItems.isEmpty {
                    print("✅ Preserved \(localOnlyItems.count) local item(s) not yet synced to API: \(localOnlyItems.map { $0.name }.joined(separator: ", "))")
                }

                // Calculate stats from ALL objects (matching Settings database list view)
                let allCollectedCount = allLocationsForStats.filter { $0.collected }.count
                let allTotalCount = allLocationsForStats.count
                print("📊 Database total: \(allTotalCount) objects (\(allCollectedCount) found by you, \(allTotalCount - allCollectedCount) unfound)")

                // Update database stats for the counter display
                // foundByYou = number of items YOU have found (collected = true) from ALL objects
                // totalVisible = total number of items in database (matching Settings view)
                self.databaseStats = DatabaseStats(foundByYou: allCollectedCount, totalVisible: allTotalCount)
                print("📊 Updated database stats: \(allCollectedCount) found / \(allTotalCount) total (matches Settings view)")
                print("📊 Unfound items: \(allTotalCount - allCollectedCount)")
                
                // Debug: Print all loaded locations with their coordinates
                for location in loadedLocations {
                    if !location.collected {
                        print("   🎯 Unfound: \(location.name) at (\(location.latitude), \(location.longitude))")
                    }
                }

                if let selectedId = self.selectedDatabaseObjectId {
                    print("   Selected object filter active: \(selectedId)")
                    if let selectedObj = loadedLocations.first {
                        print("   Selected object: \(selectedObj.name) (collected: \(selectedObj.collected))")
                    }
                }

                // Force SwiftUI update
                self.objectWillChange.send()
            }
            
        } catch {
            // Suppress detailed connection errors - they're noisy
            // Just show a simple message and fall back to local storage
            print("⚠️ Cannot connect to API server at \(APIService.shared.baseURL)")
            print("   Falling back to local storage")
            // Fallback to local storage
            loadLocations(userLocation: userLocation)
        }
    }
    
    /// Save location to API
    func saveLocationToAPI(_ location: LootBoxLocation) async {
        guard useAPISync else {
            print("⚠️ API sync is disabled - location '\(location.name)' (ID: \(location.id)) not synced to shared database")
            return
        }

        // Check if this is a temporary AR-only item that shouldn't be synced
        if !location.shouldSyncToAPI {
            print("⏭️ Skipping API sync for AR-only item (no GPS): '\(location.name)' (ID: \(location.id))")
            return
        }
        
        print("🔄 Attempting to sync location '\(location.name)' (ID: \(location.id), Type: \(location.type.displayName)) to API...")
        print("   GPS: (\(String(format: "%.8f", location.latitude)), \(String(format: "%.8f", location.longitude)))")
        
        do {
            let createdObject = try await APIService.shared.createObject(location)
            print("✅ Successfully synced location '\(location.name)' (ID: \(location.id)) to shared API database")
            print("   API returned object ID: \(createdObject.id)")
        } catch {
            print("❌ Error saving location '\(location.name)' (ID: \(location.id)) to API: \(error.localizedDescription)")
            print("   Location saved locally but NOT in shared database")
            if let apiError = error as? APIError {
                print("   API Error details: \(apiError)")
            }
        }
    }
    
    /// Mark location as found in API
    func markCollectedInAPI(_ locationId: String) async {
        guard useAPISync else {
            print("⚠️ API sync is disabled - not marking location \(locationId) as found in API")
            return
        }
        
        // Find location name for logging
        let locationName = locations.first(where: { $0.id == locationId })?.name ?? "Unknown"
        
        // Check if this is a temporary AR item that shouldn't be synced
        if let location = locations.first(where: { $0.id == locationId }), !location.shouldSyncToAPI {
            print("⏭️ Skipping API sync for temporary AR item collection: '\(locationName)' (ID: \(locationId))")
            return
        }
        
        print("🔄 Attempting to mark location '\(locationName)' (ID: \(locationId)) as found in API...")
        
        do {
            try await APIService.shared.markFound(objectId: locationId)
            print("✅ Successfully marked location '\(locationName)' (ID: \(locationId)) as found in API")
        } catch {
            print("❌ Error marking location '\(locationName)' (ID: \(locationId)) as found in API: \(error.localizedDescription)")
            if let apiError = error as? APIError {
                print("   API Error details: \(apiError)")
            }
        }
    }
    
    /// Sync all local locations to API (useful for migration or if items were created before API sync was enabled)
    func syncAllLocationsToAPI() async {
        guard useAPISync else {
            print("⚠️ API sync is disabled - enable it in Settings first")
            return
        }
        
        print("🔄 Syncing \(locations.count) local locations to shared API database...")
        
        var syncedCount = 0
        var errorCount = 0
        
        for location in locations {
            // Skip temporary AR-only items
            if location.isTemporary {
                print("⏭️ Skipping temporary AR item: \(location.name)")
                continue
            }
            
            do {
                // Check if object already exists in API
                let existingObject = try? await APIService.shared.getObject(id: location.id)
                
                if existingObject == nil {
                    // Object doesn't exist, create it
                    await saveLocationToAPI(location)
                    syncedCount += 1
                } else {
                    print("ℹ️ Object '\(location.name)' already exists in API, skipping")
                }
                
                // Sync collected status if needed
                if location.collected {
                    await markCollectedInAPI(location.id)
                }
            } catch let error {
                errorCount += 1
                print("❌ Failed to sync '\(location.name)': \(error.localizedDescription)")
            }
        }
        
        print("✅ Finished syncing: \(syncedCount) new items, \(errorCount) errors")
    }
    
    /// View all objects in the shared database
    func viewDatabaseContents(userLocation: CLLocation? = nil) async {
        guard useAPISync else {
            print("⚠️ API sync is disabled - cannot view database contents")
            return
        }
        
        print("📊 Querying shared database contents...")
        
        do {
            // Check API health first
            let isHealthy = try await APIService.shared.checkHealth()
            guard isHealthy else {
                print("❌ API server at \(APIService.shared.baseURL) is not available")
                print("   Make sure the server is running: cd server && python app.py")
                return
            }
            
            // Get all objects from API
            let apiObjects: [APIObject]
            if let userLocation = userLocation {
                apiObjects = try await APIService.shared.getObjects(
                    latitude: userLocation.coordinate.latitude,
                    longitude: userLocation.coordinate.longitude,
                    radius: 10000.0, // 10km radius to see all nearby objects
                    includeFound: true // Include found objects too
                )
            } else {
                apiObjects = try await APIService.shared.getObjects(includeFound: true)
            }
            
            print("📊 Database Contents:")
            print("   Total objects: \(apiObjects.count)")
            
            let foundCount = apiObjects.filter { $0.collected }.count
            let unfoundCount = apiObjects.count - foundCount
            
            print("   Found: \(foundCount)")
            print("   Unfound: \(unfoundCount)")
            print("")
            
            if apiObjects.isEmpty {
                print("   (Database is empty)")
            } else {
                print("   Objects:")
                for (index, obj) in apiObjects.enumerated() {
                    let status = obj.collected ? "✅ FOUND" : "🔍 UNFOUND"
                    let finder = obj.found_by != nil ? " by \(obj.found_by!)" : ""
                    let foundAt = obj.found_at != nil ? " at \(obj.found_at!)" : ""
                    
                    print("   \(index + 1). \(obj.name) (\(obj.type))")
                    print("      ID: \(obj.id)")
                    print("      Status: \(status)\(finder)\(foundAt)")
                    print("      Location: (\(String(format: "%.8f", obj.latitude)), \(String(format: "%.8f", obj.longitude)))")
                    print("      Radius: \(obj.radius)m")
                    if let createdAt = obj.created_at {
                        print("      Created: \(createdAt)")
                    }
                    if let createdBy = obj.created_by {
                        print("      Created by: \(createdBy)")
                    }
                    print("")
                }
            }
            
            // Also get stats
            do {
                let stats = try await APIService.shared.getStats()
                print("📈 Database Statistics:")
                print("   Total objects: \(stats.total_objects)")
                print("   Found objects: \(stats.found_objects)")
                print("   Unfound objects: \(stats.unfound_objects)")
                print("   Total finds: \(stats.total_finds)")
                if !stats.top_finders.isEmpty {
                    print("   Top finders:")
                    for finder in stats.top_finders {
                        print("      - \(finder.user): \(finder.count) finds")
                    }
                }
            } catch {
                print("⚠️ Could not fetch statistics: \(error.localizedDescription)")
            }
            
        } catch {
            print("❌ Error querying database: \(error.localizedDescription)")
            if let apiError = error as? APIError {
                print("   API Error details: \(apiError)")
            }
        }
    }
}

