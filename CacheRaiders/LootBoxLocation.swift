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
    @Published var enableObjectRecognition: Bool = false // Default: object recognition disabled (saves battery/processing)
    @Published var enableAudioMode: Bool = false // Default: audio mode disabled
    @Published var lootBoxMinSize: Double = 0.25 // Default 0.25m (minimum size)
    @Published var lootBoxMaxSize: Double = 1.0 // Default 1.0m (maximum size) - reduced from 3.0m
    @Published var shouldRandomize: Bool = false // Trigger for randomizing loot boxes in AR
    @Published var shouldPlaceSphere: Bool = false // Trigger for placing a single sphere in AR
    @Published var pendingSphereLocationId: String? // ID of the map marker location to use for the sphere
    @Published var pendingARItem: LootBoxLocation? // Item to place in AR room
    @Published var shouldResetARObjects: Bool = false // Trigger for removing all AR objects when locations are reset
    var onSizeChanged: (() -> Void)? // Callback when size settings change
    private let locationsFileName = "lootBoxLocations.json"
    private let maxDistanceKey = "maxSearchDistance"
    private let debugVisualsKey = "showARDebugVisuals"
    private let showFoundOnMapKey = "showFoundOnMap"
    private let disableOcclusionKey = "disableOcclusion"
    private let disableAmbientLightKey = "disableAmbientLight"
    private let enableObjectRecognitionKey = "enableObjectRecognition"
    private let enableAudioModeKey = "enableAudioMode"
    private let lootBoxMinSizeKey = "lootBoxMinSize"
    private let lootBoxMaxSizeKey = "lootBoxMaxSize"
    
    // API refresh timer - refreshes from API every 30 seconds when enabled
    private var apiRefreshTimer: Timer?
    private let apiRefreshInterval: TimeInterval = 30.0 // 30 seconds
    private var lastKnownUserLocation: CLLocation?
    
    init() {
        // Don't load existing locations on init - start with clean slate
        // loadLocations()
        loadMaxDistance()
        loadDebugVisuals()
        loadShowFoundOnMap()
        loadDisableOcclusion()
        loadDisableAmbientLight()
        loadEnableObjectRecognition()
        loadEnableAudioMode()
        loadLootBoxSizes()
        
        // API sync is always enabled - start refresh timer
        startAPIRefreshTimer()
        
        // Auto-connect to WebSocket
        WebSocketService.shared.connect()
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
    
    /// Returns only findable locations (excludes map markers, but includes AR items for counter)
    var findableLocations: [LootBoxLocation] {
        return locations.filter { location in
            // Exclude map-only markers - these are just visual markers, not findable items
            if location.id.hasPrefix("AR_SPHERE_MAP_") {
                return false
            }
            // Include AR_ITEM_ items - these are randomized AR items that should be counted
            // Include AR_SPHERE_ items (but not AR_SPHERE_MAP_ which are map markers)
            // Include all other locations (GPS-based locations with real coordinates)
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
            // AR_SPHERE_MAP_ locations should be saved because they're map markers
            // AR_ITEM_ and AR_SPHERE_ (without MAP) are temporary and don't need to be saved
            let isTemporaryARItem = (locationId.hasPrefix("AR_SPHERE_") && !locationId.hasPrefix("AR_SPHERE_MAP_")) || locationId.hasPrefix("AR_ITEM_")
            if !isTemporaryARItem {
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
            
            print("🔄 Auto-refreshing from API (every \(Int(self.apiRefreshInterval))s)...")
            Task {
                await self.loadLocationsFromAPI(userLocation: self.lastKnownUserLocation)
            }
        }
        
        // Add timer to common run loop modes so it works even when scrolling
        if let timer = apiRefreshTimer {
            RunLoop.current.add(timer, forMode: .common)
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
            let apiObjects: [APIObject]
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
            
            // Convert API objects to LootBoxLocations
            let loadedLocations = apiObjects.compactMap { apiObject in
                APIService.shared.convertToLootBoxLocation(apiObject)
            }
            
            await MainActor.run {
                self.locations = loadedLocations
                let collectedCount = loadedLocations.filter { $0.collected }.count
                print("✅ Loaded \(loadedLocations.count) loot box locations from API (\(collectedCount) collected)")
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
        
        // Check if this is a temporary AR item that shouldn't be synced
        let isTemporaryARItem = location.id.hasPrefix("AR_ITEM_") || 
                               (location.id.hasPrefix("AR_SPHERE_") && !location.id.hasPrefix("AR_SPHERE_MAP_"))
        
        if isTemporaryARItem {
            print("⏭️ Skipping API sync for temporary AR item: '\(location.name)' (ID: \(location.id))")
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
        let isTemporaryARItem = locationId.hasPrefix("AR_ITEM_") || 
                               (locationId.hasPrefix("AR_SPHERE_") && !locationId.hasPrefix("AR_SPHERE_MAP_"))
        
        if isTemporaryARItem {
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
            let isTemporaryARItem = location.id.hasPrefix("AR_ITEM_") || 
                                   (location.id.hasPrefix("AR_SPHERE_") && !location.id.hasPrefix("AR_SPHERE_MAP_"))
            
            if isTemporaryARItem {
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
            } catch {
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

