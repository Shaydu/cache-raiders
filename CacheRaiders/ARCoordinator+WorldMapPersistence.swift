import Foundation
import RealityKit
import ARKit
import CoreLocation

// MARK: - ARCoordinator World Map Persistence Extension
/// Extension to ARCoordinator that integrates with ARWorldMapPersistenceService
/// This provides stable, drift-resistant AR object positioning using world map anchoring
extension ARCoordinator {

    // MARK: - World Map Persistence Integration

    /// Initializes world map persistence service integration
    func setupWorldMapPersistence() {
        guard let worldMapPersistenceService = worldMapPersistenceService,
              let arView = arView else {
            print("⚠️ World map persistence service or ARView not available")
            return
        }

        // Service is already configured in main coordinator initialization
        // Just enable persistence
        worldMapPersistenceService.isPersistenceEnabled = true

        // Try to load any previously persisted world map
        if worldMapPersistenceService.loadPersistedWorldMap() {
            print("📁 Loaded previously persisted world map")
            // Note: Applying to session happens in session setup
        }

        print("✅ ARCoordinator world map persistence integration initialized")
    }

    /// Captures and persists the current AR world map for stability
    func captureAndPersistWorldMap() async {
        guard let worldMapPersistenceService = worldMapPersistenceService else {
            print("⚠️ World map persistence service not available")
            return
        }

        let success = await worldMapPersistenceService.captureAndPersistWorldMap()
        if success {
            print("✅ World map captured and persisted for stability")
        } else {
            print("⚠️ World map capture failed - will use GPS anchoring")
        }
    }

    /// Applies a persisted world map to the current AR session
    func applyPersistedWorldMap() -> Bool {
        guard let worldMapPersistenceService = worldMapPersistenceService else {
            print("⚠️ World map persistence service not available")
            return false
        }

        return worldMapPersistenceService.applyWorldMapToSession()
    }

    /// Shares current world map and anchored objects with other users
    func shareWorldMapAndObjects() async {
        guard let worldMapPersistenceService = worldMapPersistenceService else {
            print("⚠️ World map persistence service not available")
            return
        }

        await worldMapPersistenceService.shareWorldMapAndObjects()
    }

    /// Loads a shared world map from another user
    func loadSharedWorldMap(_ sharedData: [String: Any]) -> Bool {
        guard let worldMapPersistenceService = worldMapPersistenceService else {
            print("⚠️ World map persistence service not available")
            return false
        }

        return worldMapPersistenceService.loadSharedWorldMap(sharedData)
    }

    /// Checks if world map persistence is available and active
    var isWorldMapPersistenceActive: Bool {
        guard let worldMapPersistenceService = worldMapPersistenceService else {
            return false
        }
        return worldMapPersistenceService.isPersistenceEnabled &&
               (worldMapPersistenceService.hasPersistedWorldMap || worldMapPersistenceService.isWorldMapLoaded)
    }

    /// Gets world map quality assessment (0.0 to 1.0)
    var worldMapQuality: Double {
        return worldMapPersistenceService?.worldMapQuality ?? 0.0
    }

    /// Gets the number of world-map-anchored objects
    var worldAnchoredObjectCount: Int {
        return worldMapPersistenceService?.worldAnchoredObjectsCount ?? 0
    }

    /// Checks if a specific object is world-map-anchored
    func isObjectWorldAnchored(_ objectId: String) -> Bool {
        return worldMapPersistenceService?.isWorldAnchored(objectId: objectId) ?? false
    }

    /// Gets diagnostic information about world map persistence
    func getWorldMapPersistenceDiagnostics() -> [String: Any]? {
        return worldMapPersistenceService?.getDiagnostics()
    }

    // MARK: - World Map Session Management

    /// Called when AR session starts - attempt to apply persisted world map
    func onARSessionStarted() {
        // Try to apply persisted world map for consistency
        if applyPersistedWorldMap() {
            print("🗺️ Applied persisted world map to new AR session")
        }

        // Restore any previously anchored objects
        worldMapPersistenceService?.restoreAnchoredObjects()
    }

    /// Called when AR session ends - persist current state
    func onARSessionEnded() {
        // Persist anchored objects for next session
        worldMapPersistenceService?.persistAnchoredObjects()

        // Optionally capture world map if quality is good
        Task {
            await captureAndPersistWorldMap()
        }
    }

    // MARK: - Multi-User Synchronization

    /// Synchronizes world map state with nearby users
    func synchronizeWorldMapWithNearbyUsers() async {
        // Check if we should share our world map
        if isWorldMapPersistenceActive && worldMapQuality > 0.5 {
            await shareWorldMapAndObjects()
        }
    }

    /// Handles incoming world map data from another user
    func handleIncomingWorldMapData(_ worldMapData: Data, from userId: String) {
        // Convert data to shared format
        let sharedData: [String: Any] = [
            "worldMapData": worldMapData.base64EncodedString(),
            "sourceUserId": userId,
            "timestamp": Date().timeIntervalSince1970
        ]

        // Load the shared world map
        let success = loadSharedWorldMap(sharedData)
        if success {
            print("🔄 Successfully loaded world map from user: \(userId)")
        } else {
            print("⚠️ Failed to load world map from user: \(userId)")
        }
    }
}
