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
    
    /// TESTING: Set to true to place treasure within 20 feet of player for quick testing
    /// Set to false for production/normal gameplay
    private let testingMode = true
    private let testingDistanceFeet: Double = 18.0 // ~5.5 meters - within 20 feet
    
    // MARK: - Published State

    @Published var hasMap: Bool = false
    @Published var mapPiece: APIService.MapPiece?
    @Published var treasureLocation: CLLocation?
    @Published var showMapModal: Bool = false
    @Published var isLoadingFromServer: Bool = false
    @Published var treasureHuntId: Int?
    @Published var shouldSpawnCorgi: Bool = false // TESTING: Trigger corgi spawn after map

    // MARK: - Private State

    private var conversationManager: ARConversationManager?
    private var hasLoadedFromServer: Bool = false

    // MARK: - Initialization

    init() {
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

    /// Check if user message is requesting directions/map
    /// Detects phrases like: "give me the map", "where is the treasure?", "show me the way", "instructions", "guidance", "info"
    func isMapRequest(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let mapTriggers = [
            "map",
            "treasure",
            "where",
            "direction",
            "way",
            "go",
            "find",
            "location",
            "show me",
            "guide",
            "help me find",
            "give me",
            "instruction",  // "instruction" or "instructions"
            "guidance",      // "guidance" or "guide me"
            "info",          // "info" or "information"
            "tell me",       // "tell me where"
            "how do",        // "how do I find"
            "what do",       // "what do I do"
            "help"           // "help" or "help me"
        ]
        return mapTriggers.contains { lowercased.contains($0) }
    }

    // MARK: - Map Request Handling

    /// Handle map request - fetch treasure map from Captain Bones
    /// - Parameters:
    ///   - npcId: The NPC ID (skeleton-1)
    ///   - npcName: Display name (Captain Bones)
    ///   - userLocation: Current player location (used to generate treasure location nearby)
    func handleMapRequest(npcId: String, npcName: String, userLocation: CLLocation) async throws {
        print("🗺️ TreasureHuntService: Fetching treasure map from \(npcName)")

        // Fetch map piece from API
        let mapResponse = try await APIService.shared.getMapPiece(
            npcId: npcId,
            targetLocation: userLocation
        )

        await MainActor.run {
            // Store the map piece
            self.mapPiece = mapResponse.map_piece
            self.hasMap = true

            // Extract treasure location from map piece
            if let lat = mapResponse.map_piece.approximate_latitude,
               let lon = mapResponse.map_piece.approximate_longitude {
                
                // TESTING: Override treasure location to be within 20 feet of player
                if self.testingMode {
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
                    print("🧪 TESTING MODE: Treasure placed \(self.testingDistanceFeet) feet (~\(String(format: "%.1f", distanceMeters))m) from player")
                    print("   Original location: (\(lat), \(lon))")
                    print("   Test location: (\(testLat), \(testLon))")
                } else {
                    self.treasureLocation = CLLocation(latitude: lat, longitude: lon)
                    print("🗺️ Treasure location set: \(lat), \(lon)")
                }
            }

            // Save state
            self.saveState()
            
            // TESTING: Add corgi NPC location close to the TREASURE X (not the player)
            // Normal game flow: Corgi appears near the treasure X location
            if self.testingMode, let treasureLoc = self.treasureLocation {
                print("🧪 TESTING MODE: Adding corgi NPC location 15 feet from treasure X")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.shouldSpawnCorgi = true
                    // Place corgi 15 feet from the TREASURE X location (not player)
                    let corgiDistanceFeet: Double = 15.0 // Corgi is 15 feet from treasure X
                    let corgiDistanceMeters = corgiDistanceFeet * 0.3048
                    let randomBearing = Double.random(in: 0...360) * .pi / 180.0
                    let earthRadius: Double = 6371000
                    // Use TREASURE location as origin (not player location)
                    let lat1 = treasureLoc.coordinate.latitude * .pi / 180.0
                    let lon1 = treasureLoc.coordinate.longitude * .pi / 180.0
                    
                    let lat2 = asin(sin(lat1) * cos(corgiDistanceMeters / earthRadius) +
                                   cos(lat1) * sin(corgiDistanceMeters / earthRadius) * cos(randomBearing))
                    let lon2 = lon1 + atan2(sin(randomBearing) * sin(corgiDistanceMeters / earthRadius) * cos(lat1),
                                            cos(corgiDistanceMeters / earthRadius) - sin(lat1) * sin(lat2))
                    
                    let corgiLat = lat2 * 180.0 / .pi
                    let corgiLon = lon2 * 180.0 / .pi
                    
                    print("🐕 TESTING: Corgi location set at (\(corgiLat), \(corgiLon)) - \(corgiDistanceFeet) feet from TREASURE X")
                    print("   Treasure X is at: (\(treasureLoc.coordinate.latitude), \(treasureLoc.coordinate.longitude))")
                    
                    // Post notification with corgi location for ARCoordinator/locationManager
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SpawnCorgiNPC"),
                        object: nil,
                        userInfo: ["latitude": corgiLat, "longitude": corgiLon]
                    )
                }
            }

            // Show Captain Bones response
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.conversationManager?.showMessage(
                    npcName: npcName,
                    message: "Arr! Here be the treasure map, matey! Follow it to find the booty!",
                    isUserMessage: false,
                    duration: 3.0
                )

                // Show the map modal after brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    self?.showMapModal = true
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
           let decoded = try? JSONDecoder().decode(APIService.MapPiece.self, from: data) {
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
    
    /// Manually refresh treasure hunt data from server
    func refreshFromServer() {
        hasLoadedFromServer = false
        Task {
            await loadFromServer()
        }
    }
}
