import Foundation
import CoreLocation
import Combine

/// Service for managing Dead Men's Secrets treasure hunt game mode
/// Handles map pieces, navigation, and story progression
class TreasureHuntService: ObservableObject {

    // MARK: - Published State

    @Published var hasMap: Bool = false
    @Published var mapPiece: APIService.MapPiece?
    @Published var treasureLocation: CLLocation?
    @Published var showMapModal: Bool = false

    // MARK: - Private State

    private var conversationManager: ARConversationManager?

    // MARK: - Initialization

    init() {
        // Load saved state if any
        loadState()
    }

    // MARK: - Configuration

    func setConversationManager(_ manager: ARConversationManager) {
        self.conversationManager = manager
    }

    // MARK: - Map Trigger Detection

    /// Check if user message is requesting directions/map
    /// Detects phrases like: "give me the map", "where is the treasure?", "show me the way"
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
            "give me"
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
                self.treasureLocation = CLLocation(latitude: lat, longitude: lon)
                print("🗺️ Treasure location set: \(lat), \(lon)")
            }

            // Save state
            self.saveState()

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
    func reset() {
        hasMap = false
        mapPiece = nil
        treasureLocation = nil
        showMapModal = false

        UserDefaults.standard.removeObject(forKey: hasMapKey)
        UserDefaults.standard.removeObject(forKey: mapPieceKey)
        UserDefaults.standard.removeObject(forKey: treasureLocationKey)

        print("🗑️ Treasure hunt state reset")
    }
}
