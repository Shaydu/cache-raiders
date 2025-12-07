import Foundation
import CoreLocation
import Combine
import RealityKit

// MARK: - Game Mode Enum
/// Represents the game mode
enum GameMode: String, Codable, CaseIterable {
    case open = "open"                    // Open mode - all treasures appear normally
    case deadMensSecrets = "dead_mens_secrets"  // Story Mode - skeleton guides you to treasure
    
    var displayName: String {
        switch self {
        case .open:
            return "Open"
        case .deadMensSecrets:
            return "Story Mode"
        }
    }
    
    var description: String {
        switch self {
        case .open:
            return "Open mode: All treasures appear normally. Find any treasure you want!"
        case .deadMensSecrets:
            return "Story Mode: Skeleton appears in AR to guide you. Follow the skeleton's clues to find the 200-year-old treasure."
        }
    }
}

// MARK: - Game Mode Response
struct GameModeResponse: Codable {
    let gameMode: String
}

// MARK: - Item Source Enum
/// Represents where a loot box location came from
enum ItemSource: String, Codable {
    case api = "api"              // From the shared API database
    case map = "map"              // Added from map (has GPS, should be saved)
    
    /// Whether this source should be persisted to disk
    var shouldPersist: Bool {
        switch self {
        case .api, .map:
            return true
        }
    }
    
    /// Whether this source should sync to API
    var shouldSyncToAPI: Bool {
        switch self {
        case .api, .map:
            return true
        }
    }
    
    /// Whether this source should appear on the map
    var shouldShowOnMap: Bool {
        // All sources (API and map-placed) should appear on the map
        return true
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
    var created_by: String? // User ID who created this object
    var needs_sync: Bool = false // Whether this item needs to be synced to API
    var last_modified: Date? // Timestamp of last modification for conflict resolution
    var server_version: Int64? // Server version for conflict resolution

    // AR-offset based positioning for centimeter-level accuracy
    var ar_origin_latitude: Double? // GPS location where AR session originated
    var ar_origin_longitude: Double? // GPS location where AR session originated
    var ar_offset_x: Double? // X offset from AR origin in meters
    var ar_offset_y: Double? // Y offset from AR origin in meters (height)
    var ar_offset_z: Double? // Z offset from AR origin in meters
    var ar_placement_timestamp: Date? // When the object was placed in AR
    var ar_anchor_transform: String? // Base64-encoded AR anchor transform for mm precision
    var ar_world_transform: Data? // Full AR world transform matrix for exact tap positioning
    var nfc_tag_id: String? // NFC tag ID if this object was placed via NFC
    var multifindable: Bool? // Whether this item is multifindable (nil = use default based on placement type)
    var ar_placement_heading: Double? // Compass heading (degrees) when object was placed for rotation consistency
    
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
        // NPCs should not be synced as objects - they use the NPC API instead
        if id.starts(with: "npc_") {
            return false
        }
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

    /// Whether this location has AR positioning data
    var hasARData: Bool {
        return ar_origin_latitude != nil &&
               ar_origin_longitude != nil &&
               ar_offset_x != nil &&
               ar_offset_y != nil &&
               ar_offset_z != nil
    }
    
    // MARK: - Initializers
    
    /// Normal initializer for creating new locations
    init(id: String, name: String, type: LootBoxType, latitude: Double, longitude: Double, radius: Double, collected: Bool = false, grounding_height: Double? = nil, source: ItemSource = .api, created_by: String? = nil, needs_sync: Bool = false, last_modified: Date? = nil, server_version: Int64? = nil, ar_origin_latitude: Double? = nil, ar_origin_longitude: Double? = nil, ar_offset_x: Double? = nil, ar_offset_y: Double? = nil, ar_offset_z: Double? = nil, ar_placement_timestamp: Date? = nil, ar_anchor_transform: String? = nil, ar_world_transform: Data? = nil, nfc_tag_id: String? = nil, multifindable: Bool? = nil, ar_placement_heading: Double? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.collected = collected
        self.grounding_height = grounding_height
        self.source = source
        self.created_by = created_by
        self.needs_sync = needs_sync
        self.last_modified = last_modified
        self.server_version = server_version
        self.ar_origin_latitude = ar_origin_latitude
        self.ar_origin_longitude = ar_origin_longitude
        self.ar_offset_x = ar_offset_x
        self.ar_offset_y = ar_offset_y
        self.ar_offset_z = ar_offset_z
        self.ar_placement_timestamp = ar_placement_timestamp
        self.ar_anchor_transform = ar_anchor_transform
        self.ar_world_transform = ar_world_transform
        self.nfc_tag_id = nfc_tag_id
        self.multifindable = multifindable
        self.ar_placement_heading = ar_placement_heading
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
        created_by = try container.decodeIfPresent(String.self, forKey: .created_by)
        needs_sync = try container.decodeIfPresent(Bool.self, forKey: .needs_sync) ?? false
        last_modified = try container.decodeIfPresent(Date.self, forKey: .last_modified)
        server_version = try container.decodeIfPresent(Int64.self, forKey: .server_version)

        // Try to decode source, but if not present, infer from ID prefix (backward compatibility)
        if let decodedSource = try? container.decode(ItemSource.self, forKey: .source) {
            source = decodedSource
        } else {
            // Infer source from ID prefix for backward compatibility
            if id.hasPrefix("AR_SPHERE_MAP_") {
                source = .map
            } else if id.hasPrefix("MAP_ITEM_") {
                source = .map
            } else {
                source = .api // Default to API for regular IDs
            }
        }
        
        // Decode AR positioning data if present
        ar_origin_latitude = try container.decodeIfPresent(Double.self, forKey: .ar_origin_latitude)
        ar_origin_longitude = try container.decodeIfPresent(Double.self, forKey: .ar_origin_longitude)
        ar_offset_x = try container.decodeIfPresent(Double.self, forKey: .ar_offset_x)
        ar_offset_y = try container.decodeIfPresent(Double.self, forKey: .ar_offset_y)
        ar_offset_z = try container.decodeIfPresent(Double.self, forKey: .ar_offset_z)
        ar_placement_timestamp = try container.decodeIfPresent(Date.self, forKey: .ar_placement_timestamp)
        ar_anchor_transform = try container.decodeIfPresent(String.self, forKey: .ar_anchor_transform)
        ar_world_transform = try container.decodeIfPresent(Data.self, forKey: .ar_world_transform)
        nfc_tag_id = try container.decodeIfPresent(String.self, forKey: .nfc_tag_id)
        multifindable = try container.decodeIfPresent(Bool.self, forKey: .multifindable)
        ar_placement_heading = try container.decodeIfPresent(Double.self, forKey: .ar_placement_heading)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, latitude, longitude, radius, collected, grounding_height, source, created_by, needs_sync, last_modified, server_version, ar_origin_latitude, ar_origin_longitude, ar_offset_x, ar_offset_y, ar_offset_z, ar_placement_timestamp, ar_anchor_transform, ar_world_transform, nfc_tag_id, multifindable, ar_placement_heading
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
    @Published var showDebugOverlay: Bool = false // Default: debug overlay disabled (shows object IDs/names)
    @Published var showFoundOnMap: Bool = false // Default: don't show found items on map
    @Published var disableOcclusion: Bool = false // Default: occlusion enabled (false = occlusion ON)
    @Published var disableAmbientLight: Bool = false // Default: ambient light enabled (false = ambient light ON)
    @Published var enableObjectRecognition: Bool = false // Default: object recognition disabled (saves battery/processing)
    @Published var enableAudioMode: Bool = false // Default: audio mode disabled
    @Published var lootBoxMinSize: Double = 0.25 // Default 0.25m (minimum size)
    @Published var lootBoxMaxSize: Double = 0.61 // Default 0.61m (2 feet maximum size)
    @Published var arZoomLevel: Double = 1.0 // Default 1.0x zoom (normal view)
    @Published var selectedARLens: String? = nil // Selected AR camera lens identifier (nil = default/wide)
    @Published var pendingARItem: LootBoxLocation? // Item to place in AR room
    @Published var shouldResetARObjects: Bool = false // Trigger for removing all AR objects when locations are reset
    @Published var selectedDatabaseObjectId: String? = nil // Selected database object to find (only one at a time)
    @Published var databaseStats: DatabaseStats? = nil // Database stats for loot box counter
    @Published var showOnlyNextItem: Bool = false // Show only the next unfound item in the list
    @Published var useGenericDoubloonIcons: Bool = false // When enabled, show generic doubloon icons and reveal real objects with animation
    @Published var sharedAROrigin: CLLocation? = nil // Shared AR origin between main AR view and placement view for coordinate consistency
    weak var sharedARView: ARView? = nil // Shared ARView instance to prevent session resets and maintain coordinate system
    @Published var gameMode: GameMode = .open { // Game mode: Open or Story Mode
        didSet {
            print("🎮 [LootBoxLocationManager] gameMode didSet: \(oldValue.displayName) → \(gameMode.displayName)")
            
            // STORY MODE: Remove all API objects when entering story mode (only NPCs should remain)
            if gameMode == .deadMensSecrets && oldValue != gameMode {
                let objectsToRemove = locations.filter { location in
                    // Remove all API-sourced objects (keep AR-manual and AR-randomized for now)
                    return location.source == .api || location.source == .map
                }
                if !objectsToRemove.isEmpty {
                    locations.removeAll { location in
                        location.source == .api || location.source == .map
                    }
                    Swift.print("🗑️ Story mode activated: Removed \(objectsToRemove.count) API/map objects (only NPCs will be shown)")
                    saveLocations() // Persist the change
                }

                // Stop API refresh timer in story mode (no API objects needed)
                stopAPIRefreshTimer()
                Swift.print("⏹️ Stopped API refresh timer (story mode - no API objects needed)")

                // STORY MODE: Automatically spawn Captain Bones (skeleton NPC) when entering story mode
                // This allows players to start the treasure hunt by talking to him
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    // Post notification to spawn skeleton NPC after a short delay
                    Swift.print("📢 Posting SpawnSkeletonNPC notification...")
                    NotificationCenter.default.post(name: NSNotification.Name("SpawnSkeletonNPC"), object: nil)
                    Swift.print("💀 Story mode activated: Automatically spawning Captain Bones (skeleton NPC)")
                }
            }
            
            // OPEN MODE: Restart API refresh timer when switching back to open mode
            if gameMode == .open && oldValue == .deadMensSecrets {
                startAPIRefreshTimer()
                Swift.print("▶️ Restarted API refresh timer (open mode - API objects enabled)")
            }
            
            // Notify that game mode changed (for UI updates)
            objectWillChange.send()

            // Post notification for ARCoordinator to handle NPC spawning
            NotificationCenter.default.post(name: NSNotification.Name("GameModeChanged"), object: nil)
        }
    }
    var onSizeChanged: (() -> Void)? // Callback when size settings change
    var onObjectCollectedByOtherUser: ((String) -> Void)? // Callback when object is collected (by any user, to remove from AR)
    var onObjectUncollected: ((String) -> Void)? // Callback when object is uncollected (to re-place in AR)
    var onAllObjectsCleared: (() -> Void)? // Callback when all objects should be cleared (e.g., game mode change)
    private let locationsFileName = "lootBoxLocations.json"
    private let maxDistanceKey = "maxSearchDistance"
    private let dataService = GameItemDataService.shared
    private let hasMigratedToCoreDataKey = "hasMigratedToCoreData"
    private let maxObjectLimitKey = "maxObjectLimit"
    private let debugVisualsKey = "showARDebugVisuals"
    private let debugOverlayKey = "showDebugOverlay"
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
    private let useGenericDoubloonIconsKey = "useGenericDoubloonIcons"
    private let gameModeKey = "gameMode"
    
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
        loadUseGenericDoubloonIcons()
        loadGameMode()
        
        // Migrate from JSON to Core Data if needed (one-time migration)
        migrateFromJSONIfNeeded()
        
        // API sync is always enabled - start refresh timer
        startAPIRefreshTimer()
        
        // CRITICAL: Set up WebSocket event handlers BEFORE connecting
        // This ensures we catch game mode changes that may come during/after connection
        setupWebSocketCallbacks()
        
        // Auto-connect to WebSocket (only if not in offline mode)
        // WebSocket provides pub/sub for real-time game mode changes (no polling needed)
        if !OfflineModeManager.shared.isOfflineMode {
            // Connect to WebSocket (callbacks are already set up above)
            WebSocketService.shared.connect()
            
            // Fetch initial game mode from server after a brief delay to ensure API is ready
            // This ensures we get the current server state on startup
            // After this, all changes will come via WebSocket pub/sub (game_mode_changed event)
            Task {
                // Shorter initial delay - API should be ready quickly
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                print("🎮 [LootBoxLocationManager] Initial game mode fetch from server (startup)...")
                await fetchGameModeFromServer(retryCount: 5) // More retries for reliability
            }
        }
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
                
                // Notify ARCoordinator to clear found sets and re-place the object
                self.onObjectUncollected?(objectId)
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
        
        WebSocketService.shared.onGameModeChanged = { [weak self] gameModeString in
            print("🎮🎮🎮 [LootBoxLocationManager] onGameModeChanged callback INVOKED with: \(gameModeString)")
            print("   Thread: \(Thread.current)")
            print("   Callback timestamp: \(Date())")
            
            guard let self = self else {
                print("⚠️ [LootBoxLocationManager] onGameModeChanged callback: self is nil")
                return
            }
            
            print("🎮 [LootBoxLocationManager] Game mode changed callback received: \(gameModeString)")
            print("   Current game mode before update: \(self.gameMode.rawValue) (\(self.gameMode.displayName))")
            print("   Callback executed on thread: \(Thread.current)")
            
            // Update game mode from server
            if let newMode = GameMode(rawValue: gameModeString) {
                Task { @MainActor in
                    let oldMode = self.gameMode
                    
                    print("   New game mode from server: \(newMode.rawValue) (\(newMode.displayName))")
                    print("   Old game mode: \(oldMode.rawValue) (\(oldMode.displayName))")
                    
                    // If game mode actually changed, update it and reset
                    if oldMode != newMode {
                        print("   🎮 Game mode changed from \(oldMode.displayName) to \(newMode.displayName) - updating and resetting")
                        
                        // Update game mode first - this will trigger the notification
                        self.gameMode = newMode
                        // Don't save to UserDefaults - server is the source of truth
                        print("✅ [LootBoxLocationManager] Game mode updated to: \(newMode.displayName)")
                        
                        // Give a small delay to ensure notification appears before clearing objects
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        
                        // Now reset and reload
                        await self.resetAndReloadGameItems()
                    } else {
                        print("   ℹ️ Game mode unchanged (already \(newMode.displayName))")
                        // Still update to ensure sync
                        self.gameMode = newMode
                    }
                }
            } else {
                print("⚠️ [LootBoxLocationManager] Invalid game mode received from server: \(gameModeString)")
                print("   Valid game modes are: \(GameMode.allCases.map { $0.rawValue }.joined(separator: ", "))")
            }
        }
        
        print("✅ [LootBoxLocationManager] onGameModeChanged callback registered")
        print("   Callback address: \(String(describing: WebSocketService.shared.onGameModeChanged))")
        
        // Set up object updated callback
        WebSocketService.shared.onObjectUpdated = { [weak self] objectData in
            guard let self = self else { return }
            
            print("🔄 WebSocket: Object updated - data: \(objectData)")
            
            Task { @MainActor in
                // Convert the WebSocket data to a LootBoxLocation
                guard let lootBoxLocation = APIService.shared.convertWebSocketDataToLootBoxLocation(objectData) else {
                    print("⚠️ Failed to convert WebSocket object update data to LootBoxLocation")
                    return
                }
                
                print("🔄 Real-time object update: '\(lootBoxLocation.name)' (ID: \(lootBoxLocation.id))")
                
                // Update the location in our array
                if let index = self.locations.firstIndex(where: { $0.id == lootBoxLocation.id }) {
                    self.locations[index] = lootBoxLocation
                    print("✅ Updated object in locations array")
                } else {
                    // Add if not found (shouldn't happen, but handle gracefully)
                    self.locations.append(lootBoxLocation)
                    print("⚠️ Object not found in local array, added as new")
                }
                
                // Notify observers that locations have changed
                self.objectWillChange.send()
                
                // Save to Core Data for offline access
                Task.detached(priority: .utility) { [weak self] in
                    guard let self = self else { return }
                    do {
                        try await self.dataService.saveLocations([lootBoxLocation])
                        print("💾 Saved updated object to Core Data")
                    } catch {
                        print("⚠️ Failed to save updated object to Core Data: \(error)")
                    }
                }
                
                // Notify AR coordinator to update the object
                NotificationCenter.default.post(
                    name: NSNotification.Name("ObjectUpdatedRealtime"),
                    object: nil,
                    userInfo: ["location": lootBoxLocation]
                )
            }
        }
        
        // Fetch game mode when WebSocket connects (in case it changed while disconnected)
        WebSocketService.shared.onConnected = { [weak self] in
            guard let self = self else { return }

            print("🔌 WebSocket connected - fetching current game mode from server")
            print("   Current local game mode: \(self.gameMode.rawValue) (\(self.gameMode.displayName))")

            // Fetch current game mode to ensure we're in sync with server (with retries)
            Task {
                await self.fetchGameModeFromServer(retryCount: 2)
            }
        }

        // Set up NotificationCenter observer for real-time object creation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebSocketObjectCreated(_:)),
            name: NSNotification.Name("WebSocketObjectCreated"),
            object: nil
        )
    }

    /// Handle real-time object creation via WebSocket
    @objc private func handleWebSocketObjectCreated(_ notification: Notification) {
        guard let objectData = notification.userInfo as? [String: Any] else {
            print("⚠️ WebSocketObjectCreated notification missing userInfo or invalid format")
            return
        }

        print("📦 Handling real-time object creation: \(objectData)")

        Task { @MainActor in
            // Convert the WebSocket data to a LootBoxLocation
            guard let lootBoxLocation = APIService.shared.convertWebSocketDataToLootBoxLocation(objectData) else {
                print("⚠️ Failed to convert WebSocket object data to LootBoxLocation")
                return
            }

            print("📦 Real-time object created: '\(lootBoxLocation.name)' (ID: \(lootBoxLocation.id)) at (\(lootBoxLocation.latitude), \(lootBoxLocation.longitude))")

            // Check if this object already exists (avoid duplicates)
            if let existingIndex = self.locations.firstIndex(where: { $0.id == lootBoxLocation.id }) {
                print("⚠️ Object '\(lootBoxLocation.id)' already exists, updating instead")
                self.locations[existingIndex] = lootBoxLocation
            } else {
                // Add the new object to our locations array
                self.locations.append(lootBoxLocation)
                print("✅ Added new object to locations array (total: \(self.locations.count))")
            }

            // Notify observers that locations have changed
            self.objectWillChange.send()

            // Save to Core Data for offline access
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.dataService.saveLocations([lootBoxLocation])
                    print("💾 Saved real-time object to Core Data")
                } catch {
                    print("⚠️ Failed to save real-time object to Core Data: \(error)")
                }
            }

            // Notify any listeners that a new object was created
            // This allows the AR view to immediately place the new object
            NotificationCenter.default.post(
                name: NSNotification.Name("ObjectCreatedRealtime"),
                object: nil,
                userInfo: ["location": lootBoxLocation]
            )
        }
    }
    
    /// Fetch game mode from server (public method for manual refresh)
    /// Call this when the app becomes active or after QR code scan to ensure sync with server
    func refreshGameMode() async {
        await fetchGameModeFromServer(retryCount: 3)
    }
    
    /// Fetch game mode from server with retry logic
    private func fetchGameModeFromServer(retryCount: Int = 1) async {
        // Skip if offline mode is enabled
        if OfflineModeManager.shared.isOfflineMode {
            print("📴 [LootBoxLocationManager] Offline mode - skipping game mode fetch from server")
            return
        }
        
        print("🔄 [LootBoxLocationManager] Fetching game mode from server...")
        
        var lastError: Error?
        
        for attempt in 1...retryCount {
            do {
                let gameModeString = try await APIService.shared.getGameMode()
                
                print("   Server returned game mode: \(gameModeString)")
                
                await MainActor.run {
                    if let newMode = GameMode(rawValue: gameModeString) {
                        let oldMode = self.gameMode
                        
                        print("   Current local game mode: \(oldMode.rawValue) (\(oldMode.displayName))")
                        print("   Server game mode: \(newMode.rawValue) (\(newMode.displayName))")
                        
                        // If game mode actually changed, update it and reset
                        if oldMode != newMode {
                            print("✅ [LootBoxLocationManager] Game mode changed from server: \(oldMode.displayName) → \(newMode.displayName)")
                            
                            // Update game mode first - this will trigger the notification
                            self.gameMode = newMode
                            
                            // Give a small delay to ensure notification appears before clearing objects
                            Task {
                                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                await self.resetAndReloadGameItems()
                            }
                        } else {
                            print("✅ [LootBoxLocationManager] Game mode fetched from server: \(newMode.displayName) (unchanged)")
                            // Still update to ensure sync
                            self.gameMode = newMode
                        }
                    } else {
                        print("⚠️ [LootBoxLocationManager] Invalid game mode from server: \(gameModeString)")
                        print("   Valid game modes are: \(GameMode.allCases.map { $0.rawValue }.joined(separator: ", "))")
                    }
                }
                return // Success - exit the retry loop
            } catch {
                lastError = error
                print("⚠️ [LootBoxLocationManager] Attempt \(attempt)/\(retryCount) failed to fetch game mode: \(error.localizedDescription)")
                
                if attempt < retryCount {
                    // Wait before retry (exponential backoff)
                    let delaySeconds = Double(attempt)
                    print("   Retrying in \(delaySeconds)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
        
        // All retries failed
        if let error = lastError {
            print("❌ [LootBoxLocationManager] All \(retryCount) attempts failed to fetch game mode: \(error.localizedDescription)")
            print("   Using local value: \(gameMode.displayName)")
        }
    }
    
    /// Reset and reload all game items when game mode changes
    /// This clears all locations and AR objects, then reloads from server based on new game mode
    func resetAndReloadGameItems() async {
        print("🔄 Resetting and reloading game items due to game mode change...")
        
        await MainActor.run {
            // Clear all locations
            let clearedCount = self.locations.count
            self.locations.removeAll()
            print("🗑️ Cleared \(clearedCount) locations")
            
            // Notify AR coordinator to clear all AR objects
            self.onAllObjectsCleared?()
            
            // Save the cleared state
            self.saveLocations()
        }
        
        // Reload from server based on current game mode
        if let userLocation = self.lastKnownUserLocation {
            await self.loadLocationsFromAPI(userLocation: userLocation, includeFound: true)
            print("✅ Reloaded game items from server for game mode: \(self.gameMode.displayName)")
        } else {
            print("⚠️ No user location available - game items will load when location is available")
        }
    }
    
    deinit {
        stopAPIRefreshTimer()
    }
    
    // MARK: - Migration from JSON to Core Data
    
    /// Migrate locations from JSON file to Core Data (one-time migration)
    private func migrateFromJSONIfNeeded() {
        // Check if migration has already been done
        if UserDefaults.standard.bool(forKey: hasMigratedToCoreDataKey) {
            return
        }
        
        // Check if JSON file exists
        guard let url = getLocationsFileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            // No JSON file to migrate - mark as migrated
            UserDefaults.standard.set(true, forKey: hasMigratedToCoreDataKey)
            return
        }
        
        // Perform migration on background thread
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            do {
                let data = try Data(contentsOf: url)
                let jsonLocations = try JSONDecoder().decode([LootBoxLocation].self, from: data)
                
                // Save to Core Data
                try await self.dataService.saveLocations(jsonLocations)
                
                // Mark migration as complete
                UserDefaults.standard.set(true, forKey: self.hasMigratedToCoreDataKey)
                
                print("✅ Migrated \(jsonLocations.count) locations from JSON to Core Data")
                
                // Optionally: Delete JSON file after successful migration (keep as backup for now)
                // try? FileManager.default.removeItem(at: url)
                
            } catch {
                print("⚠️ Error migrating from JSON to Core Data: \(error.localizedDescription)")
                // Don't mark as migrated if there was an error - will retry next time
            }
        }
    }
    
    // Load locations from Core Data (SQLite)
    // PERFORMANCE: Run on background thread to prevent UI blocking
    func loadLocations(userLocation: CLLocation? = nil) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Load from Core Data
                let loadedLocations = try await self.dataService.loadAllLocationsAsync()
                
                // Check if we have a user location and if loaded locations are too far away
                if let userLocation = userLocation {
                    // Check if any location is within a reasonable distance (10km)
                    let hasNearbyLocation = loadedLocations.contains { location in
                        let locationCLLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                        return userLocation.distance(from: locationCLLocation) <= 10000
                    }
                    
                    if !hasNearbyLocation && !loadedLocations.isEmpty {
                        // All locations are too far away - clear them since we only want API/database objects
                        print("⚠️ Loaded locations are too far away (>10km), clearing local data to rely on API")
                        await MainActor.run {
                            self.locations = []
                            self.saveLocations()
                        }
                        return
                    }
                }
                
                // Update UI on main thread
                await MainActor.run {
                    self.locations = loadedLocations
                    let collectedCount = self.locations.filter { $0.collected }.count
                    print("✅ Loaded \(self.locations.count) loot box locations from Core Data (\(collectedCount) collected)")
                }
            } catch {
                print("⚠️ Could not load locations from Core Data: \(error.localizedDescription)")
                // If we can't load from Core Data, start with empty array (will be populated from API)
                await MainActor.run {
                    self.locations = []
                }
            }
        }
    }
    

    // Reset all locations to not collected (for testing/debugging)
    func resetAllLocations() {
        for i in 0..<locations.count {
            var location = locations[i]
            location.collected = false
            locations[i] = location
            
            // Update in Core Data if should persist
            if location.shouldPersist {
                do {
                    try dataService.markUncollected(location.id)
                } catch {
                    print("⚠️ Error resetting location in Core Data: \(error)")
                }
            }
        }
        print("🔄 Reset all \(locations.count) loot boxes to not collected")
        
        // Trigger AR object removal so they can be re-placed at proper GPS locations
        shouldResetARObjects = true
    }
    
    // Save locations to Core Data (SQLite)
    // PERFORMANCE: Run on background thread to prevent UI blocking
    func saveLocations() {
        // Capture current locations on main thread (since @Published property)
        // Only save items that should be persisted (exclude temporary AR-only items)
        let locationsToSave = locations.filter { $0.shouldPersist }
        
        // Perform save on background thread
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            do {
                try await self.dataService.saveLocations(locationsToSave)
                print("✅ Saved \(locationsToSave.count) loot box locations to Core Data")
            } catch {
                print("❌ Error saving locations to Core Data: \(error)")
            }
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
    
    
    // Add a new location (manually added by user)
    // NOTE: Manually added objects ARE synced to the shared API database when useAPISync is enabled
    func addLocation(_ location: LootBoxLocation) {
        // Check if location with same ID already exists (prevent duplicates)
        if locations.contains(where: { $0.id == location.id }) {
            print("⚠️ Location with ID \(location.id) already exists - skipping duplicate")
            return
        }
        locations.append(location)
        
        // Save to Core Data if should persist
        if location.shouldPersist {
            do {
                try dataService.saveLocation(location)
                print("💾 Saved location '\(location.name)' to Core Data")
            } catch {
                print("❌ Error saving location to Core Data: \(error)")
            }
        }
        
        // Sync to shared API database if enabled (manual additions are shared)
        // Will queue for sync if offline
        if useAPISync && location.shouldSyncToAPI {
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
            
            // Save to Core Data if should persist
            if location.shouldPersist {
                do {
                    try dataService.saveLocation(location)
                    print("💾 Updated location '\(location.name)' in Core Data")
                } catch {
                    print("❌ Error updating location in Core Data: \(error)")
                }
            }
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

            // Save to Core Data if should persist
            if updatedLocation.shouldPersist {
                do {
                    try dataService.markCollected(locationId)
                    print("💾 Saved collected status to Core Data for \(locationId)")
                } catch {
                    print("❌ Error saving collected status to Core Data: \(error)")
                }

                // Also sync to API if enabled (will queue if offline)
                if useAPISync {
                    Task {
                        await markCollectedInAPI(locationId)
                    }
                }
            } else {
                print("⏭️ Skipping save for temporary AR item: \(locationId)")
            }

            // Notify AR coordinator to remove the object from AR scene
            // This callback is used for both current user and other users collecting objects
            onObjectCollectedByOtherUser?(locationId)

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

            // Save to Core Data if should persist
            if updatedLocation.shouldPersist {
                do {
                    try dataService.markUncollected(locationId)
                    print("💾 Saved uncollected status to Core Data for \(locationId)")
                } catch {
                    print("❌ Error saving uncollected status to Core Data: \(error)")
                }
                
                // Also sync to API if enabled (will queue if offline)
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
        // Don't sync to API if offline mode is enabled
        if OfflineModeManager.shared.isOfflineMode {
            print("📴 Offline mode enabled - location unmarked in local database, will sync when online")
            return
        }
        
        do {
            try await APIService.shared.unmarkFound(objectId: locationId)
            print("✅ Successfully unmarked \(locationId) as not collected in API")
            
            // Mark as synced in Core Data
            try? dataService.markAsSynced(locationId)
        } catch {
            print("❌ Failed to unmark \(locationId) as not collected in API: \(error.localizedDescription)")
            print("   Will sync when connection is restored")
            // Item is already marked as needing sync in Core Data (from unmarkCollected)
        }
    }
    
    // Get nearby locations within radius
    // PERFORMANCE: Run filtering on background thread to prevent UI blocking
    // This maintains backward compatibility while improving performance
    func getNearbyLocations(userLocation: CLLocation) -> [LootBoxLocation] {
        // Capture current state on main thread
        let currentLocations = locations
        let currentGameMode = gameMode
        let currentSelectedId = selectedDatabaseObjectId
        let currentMaxDistance = maxSearchDistance
        
        // Use a background queue for filtering to prevent UI blocking
        // For small datasets, this will be very fast, but for large datasets it prevents freezes
        var result: [LootBoxLocation] = []
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // CRITICAL: Only return UNFOUND (uncollected) objects for "nearby" display
            // Collected objects should not appear in the nearby count
            result = currentLocations.filter { location in
                // FIRST CHECK: Exclude collected/found objects - only show unfound ones
                // This applies to ALL objects, including AR-placed ones
                guard !location.collected else {
                    // This object has been found - exclude it from nearby count
                    return false
                }

                // Story Mode: Only show story-relevant treasures (treasure map, clues, final treasure)
                // In story modes, filter out regular loot boxes - only NPCs and story items
                if currentGameMode == .deadMensSecrets {
                    // In story modes, we don't show regular loot boxes from the API
                    // Only NPCs (skeleton, corgi) are shown, and they're placed by ARCoordinator
                    // So we filter out ALL API objects in story modes
                    // Note: API calls are prevented in story mode, so this should rarely be hit
                    // Only logs if debug mode is enabled to reduce log spam
                    if UserDefaults.standard.bool(forKey: "showARDebugVisuals") {
                        Swift.print("   📖 Story mode: Skipping API object '\(location.name)' (only NPCs shown in story mode)")
                    }
                    return false
                }

                // CRITICAL: If a specific object is selected, ALWAYS include it regardless of distance
                // This ensures the selected object appears in AR even if it's far away
                if let selectedId = currentSelectedId, location.id == selectedId {
                    // PERFORMANCE: Logging disabled - this runs in filter loop, causes massive spam
                    return true
                }

                // Apply distance check to ALL objects with GPS coordinates (including AR-placed ones)
                // AR-placed objects are now treated the same as admin-placed objects
                return userLocation.distance(from: location.location) <= currentMaxDistance
            }
            
            semaphore.signal()
        }
        
        // Wait for result (should be very fast - just filtering)
        _ = semaphore.wait(timeout: .now() + 0.5)
        return result
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

    // Save debug overlay preference
    func saveDebugOverlay() {
        UserDefaults.standard.set(showDebugOverlay, forKey: debugOverlayKey)
    }

    // Load debug overlay preference
    private func loadDebugOverlay() {
        showDebugOverlay = UserDefaults.standard.bool(forKey: debugOverlayKey)
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
    // Default: occlusion is ON (disableOcclusion = false)
    // This ensures users don't see through walls to loot boxes by default
    private func loadDisableOcclusion() {
        // Only load from UserDefaults if the key exists, otherwise default to false (occlusion ON)
        if UserDefaults.standard.object(forKey: disableOcclusionKey) != nil {
            disableOcclusion = UserDefaults.standard.bool(forKey: disableOcclusionKey)
        } else {
            // Default: occlusion ON (disableOcclusion = false)
            disableOcclusion = false
        }
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

    // Save generic doubloon icon preference
    func saveUseGenericDoubloonIcons() {
        UserDefaults.standard.set(useGenericDoubloonIcons, forKey: useGenericDoubloonIconsKey)
    }

    // Load generic doubloon icon preference
    private func loadUseGenericDoubloonIcons() {
        useGenericDoubloonIcons = UserDefaults.standard.bool(forKey: useGenericDoubloonIconsKey)
    }
    
    // Save game mode preference - DISABLED: Game mode is server-authoritative
    // This function is kept for backwards compatibility but does nothing
    func saveGameMode() {
        // NO-OP: Game mode is controlled by server, not saved locally
        print("⚠️ [LootBoxLocationManager] saveGameMode() called but game mode is server-authoritative - not saving locally")
    }
    
    // Load game mode preference - ALWAYS default to open mode
    // Game mode is server-authoritative, so we don't load from UserDefaults
    // The server value will be fetched shortly after startup via WebSocket/API
    private func loadGameMode() {
        // DEBUG: Check what was previously stored (but don't use it)
        if let savedMode = UserDefaults.standard.string(forKey: gameModeKey) {
            print("⚠️ [LootBoxLocationManager] Found stale UserDefaults gameMode: '\(savedMode)' - IGNORING (server is authoritative)")
            // Clear the stale value
            UserDefaults.standard.removeObject(forKey: gameModeKey)
            print("🗑️ [LootBoxLocationManager] Cleared stale gameMode from UserDefaults")
        }
        
        // Always start with open mode - server will update us via fetchGameModeFromServer()
        // This prevents the app from using stale local values when admin has changed the mode
        gameMode = .open
        print("🎮 [LootBoxLocationManager] Defaulting to OPEN mode - will sync with server shortly")
        print("   Current gameMode value: \(gameMode.rawValue) (\(gameMode.displayName))")
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
        
        // Don't start timer in offline mode (use local database)
        if OfflineModeManager.shared.isOfflineMode {
            print("⏭️ Skipping API refresh timer start (offline mode - using local database)")
            return
        }
        
        // Don't start timer in story mode (no API objects needed)
        if gameMode == .deadMensSecrets {
            print("⏭️ Skipping API refresh timer start (story mode - no API objects needed)")
            return
        }

        apiRefreshTimer = Timer.scheduledTimer(withTimeInterval: apiRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.useAPISync else {
                self.stopAPIRefreshTimer()
                return
            }
            
            // Check offline mode in timer callback (in case mode changed while timer was running)
            if OfflineModeManager.shared.isOfflineMode {
                print("⏭️ Skipping API refresh (offline mode active)")
                return
            }
            
            // Check game mode in timer callback (in case mode changed while timer was running)
            if self.gameMode == .deadMensSecrets {
                print("⏭️ Skipping API refresh (story mode active)")
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
    /// Note: includeFound defaults to true to ensure all objects (including found ones) are loaded for accurate counting
    func loadLocationsFromAPI(userLocation: CLLocation? = nil, includeFound: Bool = true) async {
        // OFFLINE MODE: Use local Core Data if offline mode is enabled
        if OfflineModeManager.shared.isOfflineMode {
            print("📴 Offline mode enabled - loading from local SQLite database")
            loadLocations(userLocation: userLocation)
            return
        }
        
        guard useAPISync else {
            print("ℹ️ API sync is disabled, using local storage")
            return
        }
        
        // STORY MODE: Skip API calls entirely in story mode
        // Story mode only shows NPCs, not API objects, so fetching them wastes bandwidth and performance
        if gameMode == .deadMensSecrets {
            print("📖 Story mode active (\(gameMode.displayName)) - skipping API fetch (only NPCs shown, no API objects needed)")
            return
        }
        
        do {
            // Check API health first
            let isHealthy = try await APIService.shared.checkHealth()
            guard isHealthy else {
                print("⚠️ API server at \(APIService.shared.baseURL) is not available")
                print("   Make sure the server is running: cd server && python app.py")
                print("   Falling back to local storage")
                
                // Notify that connection failed - trigger QR scanner
                NotificationCenter.default.post(name: NSNotification.Name("APIConnectionFailed"), object: nil)
                
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
            // CRITICAL: Use allApiObjectsForStats to populate locations so counter shows all objects
            let allLocationsForStats = allApiObjectsForStats.compactMap { apiObject in
                APIService.shared.convertToLootBoxLocation(apiObject)
            }
            
            await MainActor.run {
                // Merge API-loaded locations with local items that haven't been synced yet
                // This preserves locally created items (spheres, cubes) that aren't in the API yet
                // CRITICAL: Use allLocationsForStats (all objects) instead of loadedLocations (nearby only)
                // This ensures the counter shows all objects from the database, not just nearby ones
                let apiLocationIds = Set(allLocationsForStats.map { $0.id })
                let localOnlyItems = self.locations.filter { location in
                    // Keep local items that:
                    // 1. Are temporary AR-only items (not persisted, not synced)
                    // 2. Are map-created items that aren't in API yet
                    let isTemporaryAR = location.isTemporary && location.isAROnly
                    let isMapCreatedNotSynced = location.source == .map && !apiLocationIds.contains(location.id)
                    return isTemporaryAR || isMapCreatedNotSynced
                }
                
                // CRITICAL FIX: Preserve AR data from local locations when API doesn't have it
                // This prevents AR coordinates from being lost when locations are reloaded from API
                // Also replace temporary "New AR Object" entries with proper API data
                var mergedLocations = allLocationsForStats
                for (index, apiLocation) in mergedLocations.enumerated() {
                    // Check if we have a local version with AR data that the API version lacks
                    if let localLocation = self.locations.first(where: { $0.id == apiLocation.id }) {
                        // Check if local location is a temporary "New AR Object" that should be replaced
                        let isTemporaryObject = localLocation.name == "New AR Object" || localLocation.name == "NFC Object"

                        if isTemporaryObject {
                            // Replace temporary object with API data (including AR data if available)
                            mergedLocations[index] = apiLocation
                            print("🔄 Replaced temporary object '\(localLocation.name)' (ID: \(apiLocation.id)) with API data: '\(apiLocation.name)'")
                        } else if localLocation.hasARData && !apiLocation.hasARData {
                            // Preserve AR data from local location for non-temporary objects
                            mergedLocations[index] = LootBoxLocation(
                                id: apiLocation.id,
                                name: apiLocation.name, // Use API name, not local name
                                type: apiLocation.type,
                                latitude: apiLocation.latitude,
                                longitude: apiLocation.longitude,
                                radius: apiLocation.radius,
                                collected: apiLocation.collected,
                                grounding_height: apiLocation.grounding_height,
                                source: apiLocation.source,
                                created_by: apiLocation.created_by,
                                last_modified: apiLocation.last_modified,
                                ar_origin_latitude: localLocation.ar_origin_latitude,
                                ar_origin_longitude: localLocation.ar_origin_longitude,
                                ar_offset_x: localLocation.ar_offset_x,
                                ar_offset_y: localLocation.ar_offset_y,
                                ar_offset_z: localLocation.ar_offset_z,
                                ar_placement_timestamp: localLocation.ar_placement_timestamp,
                                multifindable: apiLocation.multifindable
                            )
                            print("🛡️ Preserved AR data for object '\(apiLocation.name)' (ID: \(apiLocation.id)) from local storage")
                        }
                        // If neither condition applies, use API location as-is
                    }
                }

                // Combine merged API locations with local-only items
                // This ensures locationManager.locations contains all objects for accurate counting
                self.locations = mergedLocations + localOnlyItems
                
                // Save all API-loaded locations to Core Data for offline access
                // Only save items that should be persisted (exclude temporary AR-only items)
                let locationsToSave = allLocationsForStats.filter { $0.shouldPersist }
                Task.detached(priority: .utility) { [weak self] in
                    guard let self = self else { return }
                    do {
                        try await self.dataService.saveLocations(locationsToSave)
                        print("💾 Saved \(locationsToSave.count) API locations to Core Data for offline access")
                    } catch {
                        print("⚠️ Error saving API locations to Core Data: \(error)")
                    }
                }
                
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
            print("   Falling back to Core Data (offline mode)")
            // Fallback to Core Data - load from local SQLite database
            loadLocations(userLocation: userLocation)
        }
    }
    
    /// Sync pending changes to API when connection is restored
    /// This method should be called when the app detects it's back online
    func syncPendingChangesToAPI() async {
        guard useAPISync else { return }
        
        do {
            // Get items that need syncing
            let itemsNeedingSync = try dataService.getItemsNeedingSync()
            
            if itemsNeedingSync.isEmpty {
                print("ℹ️ No pending changes to sync")
                return
            }
            
            print("🔄 Syncing \(itemsNeedingSync.count) pending changes to API...")
            
            // Check API health first
            let isHealthy = try await APIService.shared.checkHealth()
            guard isHealthy else {
                print("⚠️ API server not available - will retry later")
                return
            }
            
            var syncedCount = 0
            var errorCount = 0
            
            for location in itemsNeedingSync {
                do {
                    // Check if item exists in API
                    let existingObject = try? await APIService.shared.getObject(id: location.id)
                    
                    if existingObject == nil {
                        // Item doesn't exist - create it
                        await saveLocationToAPI(location)
                    } else {
                        // Item exists - update collected status if changed
                        if location.collected {
                            await markCollectedInAPI(location.id)
                        } else {
                            await unmarkCollectedInAPI(location.id)
                        }
                    }
                    
                    // Mark as synced in Core Data
                    try dataService.markAsSynced(location.id)
                    syncedCount += 1
                    
                } catch {
                    print("⚠️ Error syncing item \(location.id): \(error.localizedDescription)")
                    errorCount += 1
                }
            }
            
            print("✅ Synced \(syncedCount) items, \(errorCount) errors")
            
        } catch {
            print("❌ Error getting items needing sync: \(error.localizedDescription)")
        }
    }
    
    /// Save location to API
    func saveLocationToAPI(_ location: LootBoxLocation) async {
        // Don't sync to API if offline mode is enabled
        if OfflineModeManager.shared.isOfflineMode {
            print("📴 Offline mode enabled - location '\(location.name)' saved to local database, will sync when online")
            return
        }
        
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
            
            // Mark as synced in Core Data
            try? dataService.markAsSynced(location.id)
        } catch {
            print("❌ Error saving location '\(location.name)' (ID: \(location.id)) to API: \(error.localizedDescription)")
            print("   Location saved to Core Data - will sync when online")
            
            // Mark as needing sync in Core Data (if not already marked)
            do {
                // Re-save to ensure needs_sync flag is set
                try dataService.saveLocation(location)
            } catch {
                print("⚠️ Error marking location for sync: \(error)")
            }
            
            if let apiError = error as? APIError {
                print("   API Error details: \(apiError)")
            }
        }
    }
    
    /// Mark location as found in API
    func markCollectedInAPI(_ locationId: String) async {
        // Don't sync to API if offline mode is enabled
        if OfflineModeManager.shared.isOfflineMode {
            print("📴 Offline mode enabled - location marked as collected in local database, will sync when online")
            return
        }
        
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
            
            // Mark as synced in Core Data
            try? dataService.markAsSynced(locationId)
        } catch {
            // Check if the error is "Object already found" - this is actually a success case
            let errorDescription = error.localizedDescription
            if errorDescription.contains("Object already found") || errorDescription.contains("already found") {
                print("ℹ️ Object '\(locationName)' (ID: \(locationId)) was already marked as found in API - treating as success")
                // Mark as synced since it's already in the correct state
                try? dataService.markAsSynced(locationId)
            } else {
                // This is a real error - mark as needing sync
                print("❌ Error marking location '\(locationName)' (ID: \(locationId)) as found in API: \(errorDescription)")
                print("   Will sync when connection is restored")
                // Item is already marked as needing sync in Core Data (from markCollected)
                if let apiError = error as? APIError {
                    print("   API Error details: \(apiError)")
                }
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
        let errorCount = 0
        
        for location in locations {
            // Skip temporary AR-only items
            if location.isTemporary {
                print("⏭️ Skipping temporary AR item: \(location.name)")
                continue
            }
            
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
                        print("      - \(finder.display_name ?? finder.user_id): \(finder.find_count) finds")
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

    /// View all objects in the local Core Data database
    func viewLocalDatabaseContents() async {
        print("📱 Querying local Core Data database contents...")

        do {
            // Get all items from local Core Data
            let localItems = try dataService.getAllItems()

            print("📱 Local Database Contents:")
            print("   Total objects: \(localItems.count)")

            let foundCount = localItems.filter { $0.collected }.count
            let unfoundCount = localItems.count - foundCount

            print("   Found: \(foundCount)")
            print("   Unfound: \(unfoundCount)")
            print("")

            if localItems.isEmpty {
                print("   (Local database is empty)")
            } else {
                print("   Objects:")
                for (index, location) in localItems.enumerated() {
                    let status = location.collected ? "✅ FOUND" : "🔍 UNFOUND"
                    let syncStatus = location.needs_sync ? " (needs sync)" : ""

                    print("   \(index + 1). \(location.name) (\(location.type.displayName))")
                    print("      ID: \(location.id)")
                    print("      Status: \(status)\(syncStatus)")
                    print("      Location: (\(String(format: "%.8f", location.latitude)), \(String(format: "%.8f", location.longitude)))")
                    print("      Radius: \(location.radius)m")
                    print("      Source: \(location.source.rawValue)")
                    print("")
                }
            }

            // Also get stats
            do {
                let dataService = GameItemDataService.shared
                let itemsNeedingSync = try dataService.getItemsNeedingSync()
                print("   Items needing sync to API: \(itemsNeedingSync.count)")
            } catch {
                print("⚠️ Error getting sync stats: \(error.localizedDescription)")
            }

        } catch {
            print("❌ Error querying local database: \(error.localizedDescription)")
        }
    }

    /// Clear collected status for all loot boxes (reset found state)
    func clearCollectedLootBoxes() {
        for index in locations.indices {
            locations[index].collected = false
        }
        print("🧹 Cleared collected status for all \(locations.count) loot boxes")
        saveLocations() // Persist the changes
    }
}

