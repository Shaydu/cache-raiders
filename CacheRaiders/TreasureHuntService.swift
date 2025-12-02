import Foundation
import CoreLocation
import Combine

/// Service for managing Dead Men's Secrets treasure hunt game mode
/// Handles map pieces, navigation, and story progression
/// 
/// Treasure hunt data is persisted on the SERVER (in treasure_hunts table)
/// so the X location and clues are generated ONCE and persist across sessions.
class TreasureHuntService: ObservableObject {

    // MARK: - Testing Mode
    
    /// TESTING: Set to true to place treasure within 50 feet of player for quick testing
    /// Set to false for production/normal gameplay
    private let testingMode = false

    /// Force reset on init for testing
    private let forceResetOnInit = true
    private let testingDistanceFeet: Double = 50.0 // ~15 meters - reasonable distance for testing
    
    // MARK: - Published State

    @Published var hasMap: Bool = false
    @Published var mapPiece: MapPiece?
    @Published var treasureLocation: CLLocation?
    @Published var showMapModal: Bool = false
    @Published var isLoadingFromServer: Bool = false
    @Published var treasureHuntId: Int?
    @Published var shouldSpawnCorgi: Bool = false // TESTING: Trigger corgi spawn after map
    @Published var pendingTreasurePlacement: Bool = false // User needs to place treasure X manually

    // MARK: - Private State

    private var conversationManager: ARConversationManager?
    private var hasLoadedFromServer: Bool = false

    // MARK: - Initialization

    init() {
        // Force reset for testing
        if forceResetOnInit {
            print("🔄 FORCE RESET: Clearing all treasure hunt state for fresh start")
            // Clear local state immediately
            hasMap = false
            mapPiece = nil
            treasureLocation = nil
            showMapModal = false
            treasureHuntId = nil
            shouldSpawnCorgi = false

            // Clear UserDefaults
            UserDefaults.standard.removeObject(forKey: hasMapKey)
            UserDefaults.standard.removeObject(forKey: mapPieceKey)
            UserDefaults.standard.removeObject(forKey: treasureLocationKey)

            print("🔄 FORCE RESET: Local state cleared")
            return // Skip loading saved state
        }

        // TESTING MODE: Auto-reset treasure hunt state so we always start fresh
        if testingMode {
            print("🧪 TESTING MODE: Auto-resetting treasure hunt state for fresh start")
            // Clear local state immediately
            hasMap = false
            mapPiece = nil
            treasureLocation = nil
            showMapModal = false
            treasureHuntId = nil
            shouldSpawnCorgi = false

            // Clear UserDefaults
            UserDefaults.standard.removeObject(forKey: hasMapKey)
            UserDefaults.standard.removeObject(forKey: mapPieceKey)
            UserDefaults.standard.removeObject(forKey: treasureLocationKey)

            print("🧪 TESTING MODE: Local state cleared - map will only appear after asking Captain Bones")

            // Also reset on server (async)
            Task {
                do {
                    try await APIService.shared.resetTreasureHunt()
                    print("🧪 TESTING MODE: Server treasure hunt reset")
                } catch {
                    print("⚠️ TESTING MODE: Failed to reset server state: \(error.localizedDescription)")
                }
            }
            return // Skip loading saved state in testing mode
        }

        // NORMAL MODE: Load cached state from UserDefaults (fast, offline-capable)
        loadState()

        // Also try to load from server (authoritative source)
        // This ensures we have the latest data and handles cross-device sync
        Task {
            await loadFromServer()
        }
    }

    // MARK: - Configuration

    func setConversationManager(_ manager: ARConversationManager) {
        self.conversationManager = manager
    }
    
    // MARK: - Server Sync
    
    /// Load existing treasure hunt from server
    /// This is the authoritative source - server data takes precedence over local cache
    @MainActor
    func loadFromServer() async {
        guard !hasLoadedFromServer else { return }
        
        isLoadingFromServer = true
        defer { isLoadingFromServer = false }
        
        do {
            let response = try await APIService.shared.getTreasureHunt()
            
            if response.has_active_hunt, let hunt = response.treasure_hunt {
                print("🗺️ Loaded existing treasure hunt from server: id=\(hunt.id)")
                
                // Update state from server data
                self.treasureHuntId = hunt.id
                self.treasureLocation = CLLocation(
                    latitude: hunt.treasure_latitude,
                    longitude: hunt.treasure_longitude
                )
                
                // Use map_piece_1 (skeleton's piece) if available
                if let piece = hunt.map_piece_1 {
                    self.mapPiece = piece
                    self.hasMap = true
                    print("🗺️ Restored map piece from server: treasure at (\(hunt.treasure_latitude), \(hunt.treasure_longitude))")
                }
                
                // Save to local cache
                saveState()
            } else {
                print("🗺️ No active treasure hunt found on server")
            }
            
            hasLoadedFromServer = true
        } catch {
            print("⚠️ Failed to load treasure hunt from server: \(error.localizedDescription)")
            // Fall back to local cache (already loaded in init)
            hasLoadedFromServer = true
        }
    }

    // MARK: - Map Trigger Detection


    // MARK: - Map Request Handling

    /// Handle map request - fetch treasure map from Captain Bones
    /// - Parameters:
    ///   - npcId: The NPC ID (skeleton-1)
    ///   - npcName: Display name (Captain Bones)
    ///   - userLocation: Current player location (used to generate treasure location nearby)
    func handleMapRequest(npcId: String, npcName: String, userLocation: CLLocation) async throws {
        print("🗺️ [TreasureHuntService] handleMapRequest called")
        print("🗺️ [TreasureHuntService] NPC: \(npcName) (ID: \(npcId))")
        print("🗺️ [TreasureHuntService] User location: (\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude))")
        print("🗺️ [TreasureHuntService] Testing mode: \(testingMode)")
        print("🗺️ [TreasureHuntService] Fetching treasure map from server...")

        // Fetch map piece from API
        let mapResponse = try await APIService.shared.getMapPiece(
            npcId: npcId,
            targetLocation: userLocation
        )
        print("✅ [TreasureHuntService] API call returned successfully")
        print("🗺️ [TreasureHuntService] Map piece received: \(mapResponse.map_piece != nil ? "YES" : "NO")")

        await MainActor.run {
            print("💾 [TreasureHuntService] Storing map piece in service...")
            // Store the map piece
            self.mapPiece = mapResponse.map_piece
            self.hasMap = true
            print("✅ [TreasureHuntService] Map piece stored, hasMap = true")

            // Extract treasure location from map piece
            if let mapPiece = mapResponse.map_piece {
                let lat = mapPiece.approximate_latitude
                let lon = mapPiece.approximate_longitude
                print("📍 [TreasureHuntService] Treasure location from server: (\(lat), \(lon))")

                // TESTING: Auto-place treasure X for easier testing
                if self.testingMode {
                    print("🧪 [TreasureHuntService] TESTING MODE ENABLED - auto-placing treasure nearby")
                    let distanceMeters = self.testingDistanceFeet * 0.3048 // Convert feet to meters
                    // Place treasure in a random direction from player
                    let randomBearing = Double.random(in: 0...360) * .pi / 180.0
                    let earthRadius: Double = 6371000 // meters
                    let lat1 = userLocation.coordinate.latitude * .pi / 180.0
                    let lon1 = userLocation.coordinate.longitude * .pi / 180.0

                    let lat2 = asin(sin(lat1) * cos(distanceMeters / earthRadius) +
                                   cos(lat1) * sin(distanceMeters / earthRadius) * cos(randomBearing))
                    let lon2 = lon1 + atan2(sin(randomBearing) * sin(distanceMeters / earthRadius) * cos(lat1),
                                            cos(distanceMeters / earthRadius) - sin(lat1) * sin(lat2))

                    let testLat = lat2 * 180.0 / .pi
                    let testLon = lon2 * 180.0 / .pi
                    self.treasureLocation = CLLocation(latitude: testLat, longitude: testLon)
                    print("🧪 TESTING MODE: Treasure X auto-placed \(self.testingDistanceFeet) feet (~\(String(format: "%.1f", distanceMeters))m) from player")
                    print("   Server location was: (\(lat), \(lon))")
                    print("   Test location: (\(testLat), \(testLon))")
                } else {
                    self.treasureLocation = CLLocation(latitude: lat, longitude: lon)
                    print("🗺️ Treasure location set: \(lat), \(lon)")
                }
            }

            // Save state
            self.saveState()

            // Notify that we have a map now (for AR treasure X placement)
            if let mapPiece = self.mapPiece {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TreasureMapAcquired"),
                    object: nil,
                    userInfo: ["mapPiece": mapPiece]
                )
                print("🗺️ [TreasureHuntService] Posted TreasureMapAcquired notification")
            }

            // TESTING: Add corgi NPC location close to the PLAYER (for immediate testing)
            // Normal game flow: Corgi appears near the treasure X location after arriving there
            if self.testingMode {
                print("🧪 TESTING MODE: Adding corgi NPC location 1 foot from PLAYER (immediate testing)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.shouldSpawnCorgi = true
                    // Place corgi 1 foot from the PLAYER location (for immediate interaction)
                    let corgiDistanceFeet: Double = 1.0 // Corgi is 1 foot from player for testing
                    let corgiDistanceMeters = corgiDistanceFeet * 0.3048
                    let randomBearing = Double.random(in: 0...360) * .pi / 180.0
                    let earthRadius: Double = 6371000
                    // Use PLAYER location as origin (for immediate testing)
                    let lat1 = userLocation.coordinate.latitude * .pi / 180.0
                    let lon1 = userLocation.coordinate.longitude * .pi / 180.0

                    let lat2 = asin(sin(lat1) * cos(corgiDistanceMeters / earthRadius) +
                                   cos(lat1) * sin(corgiDistanceMeters / earthRadius) * cos(randomBearing))
                    let lon2 = lon1 + atan2(sin(randomBearing) * sin(corgiDistanceMeters / earthRadius) * cos(lat1),
                                            cos(corgiDistanceMeters / earthRadius) - sin(lat1) * sin(lat2))

                    let corgiLat = lat2 * 180.0 / .pi
                    let corgiLon = lon2 * 180.0 / .pi

                    print("🐕 TESTING: Corgi location set at (\(corgiLat), \(corgiLon)) - \(corgiDistanceFeet) foot from PLAYER")
                    print("   Player is at: (\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude))")

                    // Post notification with corgi location for ARCoordinator/locationManager
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SpawnCorgiNPC"),
                        object: nil,
                        userInfo: ["latitude": corgiLat, "longitude": corgiLon]
                    )
                }
            }
        }
    }

    // MARK: - Navigation Helpers

    /// Should show navigation arrow (only after map is obtained)
    var shouldShowNavigation: Bool {
        return hasMap && treasureLocation != nil
    }

    /// Should show temperature indicator (only after map is obtained)
    var shouldShowTemperature: Bool {
        return hasMap && treasureLocation != nil
    }

    /// Get direction to treasure from current location
    func getDirectionToTreasure(from currentLocation: CLLocation) -> Double? {
        guard let treasureLocation = treasureLocation else { return nil }

        // Calculate bearing from current location to treasure
        let lat1 = currentLocation.coordinate.latitude * .pi / 180
        let lat2 = treasureLocation.coordinate.latitude * .pi / 180
        let lon1 = currentLocation.coordinate.longitude * .pi / 180
        let lon2 = treasureLocation.coordinate.longitude * .pi / 180

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi

        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Get distance to treasure from current location
    func getDistanceToTreasure(from currentLocation: CLLocation) -> Double? {
        guard let treasureLocation = treasureLocation else { return nil }
        return currentLocation.distance(from: treasureLocation)
    }

    // MARK: - State Persistence

    private let hasMapKey = "treasureHunt_hasMap"
    private let mapPieceKey = "treasureHunt_mapPiece"
    private let treasureLocationKey = "treasureHunt_treasureLocation"

    private func saveState() {
        UserDefaults.standard.set(hasMap, forKey: hasMapKey)

        if let mapPiece = mapPiece {
            if let encoded = try? JSONEncoder().encode(mapPiece) {
                UserDefaults.standard.set(encoded, forKey: mapPieceKey)
            }
        }

        if let treasureLocation = treasureLocation {
            let coords = ["lat": treasureLocation.coordinate.latitude,
                         "lon": treasureLocation.coordinate.longitude]
            UserDefaults.standard.set(coords, forKey: treasureLocationKey)
        }
    }

    private func loadState() {
        hasMap = UserDefaults.standard.bool(forKey: hasMapKey)

        if let data = UserDefaults.standard.data(forKey: mapPieceKey),
           let decoded = try? JSONDecoder().decode(MapPiece.self, from: data) {
            mapPiece = decoded
        }

        if let coords = UserDefaults.standard.dictionary(forKey: treasureLocationKey),
           let lat = coords["lat"] as? Double,
           let lon = coords["lon"] as? Double {
            treasureLocation = CLLocation(latitude: lat, longitude: lon)
        }
    }

    /// Reset treasure hunt state (for new game)
    /// This resets both local cache AND server state
    func reset() {
        // Reset local state
        hasMap = false
        mapPiece = nil
        treasureLocation = nil
        showMapModal = false
        treasureHuntId = nil
        hasLoadedFromServer = false
        pendingTreasurePlacement = false
        shouldSpawnCorgi = false

        UserDefaults.standard.removeObject(forKey: hasMapKey)
        UserDefaults.standard.removeObject(forKey: mapPieceKey)
        UserDefaults.standard.removeObject(forKey: treasureLocationKey)

        print("🗑️ Treasure hunt state reset (local)")
        
        // Also reset on server so next request generates new treasure location
        Task {
            do {
                try await APIService.shared.resetTreasureHunt()
                print("🗑️ Treasure hunt reset on server")
            } catch {
                print("⚠️ Failed to reset treasure hunt on server: \(error.localizedDescription)")
            }
        }
    }
    
    /// Mark the treasure hunt as completed (user found the treasure)
    func markCompleted() {
        Task {
            do {
                try await APIService.shared.completeTreasureHunt()
                print("🎉 Treasure hunt marked as completed on server")
                
                await MainActor.run {
                    // Reset local state for next hunt
                    self.reset()
                }
            } catch {
                print("⚠️ Failed to mark treasure hunt as completed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Place treasure X at user-specified location (for testing mode)
    /// - Parameter location: The GPS location where user tapped to place treasure X
    func placeTreasureAtLocation(_ location: CLLocation) {
        guard pendingTreasurePlacement else {
            print("⚠️ Not in pending treasure placement mode")
            return
        }

        self.treasureLocation = location
        self.pendingTreasurePlacement = false
        print("🎯 User placed treasure X at: (\(location.coordinate.latitude), \(location.coordinate.longitude))")

        // Save state
        saveState()

        // TESTING: Spawn corgi immediately after placing treasure X
        if testingMode {
            print("🧪 TESTING MODE: Auto-spawning corgi after treasure placement")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.shouldSpawnCorgi = true
                // Place corgi 1 foot from the TREASURE X location (not player)
                let corgiDistanceFeet: Double = 1.0
                let corgiDistanceMeters = corgiDistanceFeet * 0.3048
                let randomBearing = Double.random(in: 0...360) * .pi / 180.0
                let earthRadius: Double = 6371000
                let lat1 = location.coordinate.latitude * .pi / 180.0
                let lon1 = location.coordinate.longitude * .pi / 180.0

                let lat2 = asin(sin(lat1) * cos(corgiDistanceMeters / earthRadius) +
                               cos(lat1) * sin(corgiDistanceMeters / earthRadius) * cos(randomBearing))
                let lon2 = lon1 + atan2(sin(randomBearing) * sin(corgiDistanceMeters / earthRadius) * cos(lat1),
                                        cos(corgiDistanceMeters / earthRadius) - sin(lat1) * sin(lat2))

                let corgiLat = lat2 * 180.0 / .pi
                let corgiLon = lon2 * 180.0 / .pi

                print("🐕 TESTING: Corgi spawned \(corgiDistanceFeet) foot from treasure X")
                print("   Treasure X: (\(location.coordinate.latitude), \(location.coordinate.longitude))")
                print("   Corgi location: (\(corgiLat), \(corgiLon))")

                // Post notification with corgi location
                NotificationCenter.default.post(
                    name: NSNotification.Name("SpawnCorgiNPC"),
                    object: nil,
                    userInfo: ["latitude": corgiLat, "longitude": corgiLon]
                )
            }
        }
    }

    /// Manually refresh treasure hunt data from server
    func refreshFromServer() {
        hasLoadedFromServer = false
        Task {
            await loadFromServer()
        }
    }

    // MARK: - Map Request Detection

    /// Detect if user message is requesting a treasure map
    /// Used by SkeletonConversationView to trigger special map-giving behavior
    func isMapRequest(_ message: String) -> Bool {
        print("🔍 [TreasureHuntService] Checking if message is map request: '\(message)'")
        let lowerMessage = message.lowercased()

        // Keywords that indicate user wants the treasure map
        let mapKeywords = [
            "treasure", "map", "where", "find", "location", "directions",
            "guide", "show me", "tell me", "give me", "booty", "gold",
            "buried", "x marks", "marks the spot", "dig", "hunt"
        ]

        // Check if message contains any map-related keywords
        for keyword in mapKeywords {
            if lowerMessage.contains(keyword) {
                print("✅ [TreasureHuntService] MAP REQUEST DETECTED - keyword '\(keyword)' found in '\(message)'")
                return true
            }
        }
        print("⏭️ [TreasureHuntService] No keywords matched, checking phrases...")

        // Special phrases that definitely indicate map requests
        let mapPhrases = [
            "where is the treasure",
            "where's the treasure",
            "show me the map",
            "give me the map",
            "i need the map",
            "can i have the map",
            "tell me where",
            "guide me",
            "take me to",
            "lead me to"
        ]

        for phrase in mapPhrases {
            if lowerMessage.contains(phrase) {
                print("✅ [TreasureHuntService] MAP REQUEST DETECTED - phrase '\(phrase)' found in '\(message)'")
                return true
            }
        }

        print("❌ [TreasureHuntService] Not a map request - no phrases matched either")
        return false
    }

    // MARK: - Map Piece Acquisition

    /// Request a treasure map piece from Captain Bones
    /// This should be called when the user asks for the map during conversation
    func requestMapPieceFromCaptainBones(userLocation: CLLocation?) async throws {
        print("🗺️ Requesting treasure map piece from Captain Bones...")

        // Use the provided user location
        guard let userLocation = userLocation else {
            throw NSError(domain: "TreasureHuntService", code: 1, userInfo: [NSLocalizedDescriptionKey: "User location not available"])
        }

        do {
            // Call the NPC interaction API with include_map_piece=true
            let response = try await APIService.shared.interactWithNPC(
                npcId: "captain_bones",
                message: "Give me the treasure map!",
                npcName: "Captain Bones",
                npcType: "skeleton",
                isSkeleton: true,
                includeMapPiece: true
            )

            // Check if the response includes a map piece
            if let mapPiece = response.map_piece {
                print("✅ Received map piece from Captain Bones!")
                print("   Piece \(mapPiece.piece_number)/\(mapPiece.total_pieces)")
                print("   Hint: \(mapPiece.hint)")

                // Store the map piece
                self.mapPiece = mapPiece
                self.hasMap = true

                // Save to UserDefaults
                saveState()

                // Notify that we have a map now
                NotificationCenter.default.post(
                    name: NSNotification.Name("TreasureMapAcquired"),
                    object: nil,
                    userInfo: ["mapPiece": mapPiece]
                )

                print("🗺️ Treasure map piece stored and notifications sent")
            } else {
                print("⚠️ Captain Bones response didn't include a map piece")
                throw NSError(domain: "TreasureHuntService", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "No map piece received from Captain Bones"])
            }

        } catch {
            print("❌ Failed to get map piece from Captain Bones: \(error.localizedDescription)")
            throw error
        }
    }
}
