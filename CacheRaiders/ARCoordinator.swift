import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import AVFoundation
import AudioToolbox
import Vision
import Combine
import UIKit

// MARK: - AR Coordinator
class ARCoordinator: ARCoordinatorCore {

    // MARK: - Manager Instances
    private var sessionManager: ARSessionManager!
    var stateManager: ARStateManager!
    private var audioManager: ARAudioManager!
    private var uiManager: ARUIManager!
    private var locationManagerHelper: ARLocationManager!
    private var objectPlacer: ARObjectPlacer!
    private var npcManager: ARNPCManager!
    private var nfcARService: NFCARIntegrationService!

    // MARK: - Initialization
    override init() {
        super.init()

        // Initialize managers
        initializeManagers()
    }

    private func initializeManagers() {
        stateManager = ARStateManager()
        audioManager = ARAudioManager(arCoordinator: self)
        uiManager = ARUIManager(arCoordinator: self)
        locationManagerHelper = ARLocationManager(arCoordinator: self)
        objectPlacer = ARObjectPlacer(arCoordinator: self, locationManager: locationManagerHelper)
        npcManager = ARNPCManager(arCoordinator: self, uiManager: uiManager)
        nfcARService = NFCARIntegrationService.shared

        // Session manager is initialized after AR view setup
    }

    // MARK: - Setup Override
    override func setupARView(_ arView: ARView,
                             locationManager: LootBoxLocationManager,
                             userLocationManager: UserLocationManager,
                             nearbyLocations: Binding<[LootBoxLocation]>,
                             distanceToNearest: Binding<Double?>,
                             temperatureStatus: Binding<String?>,
                             collectionNotification: Binding<String?>,
                             nearestObjectDirection: Binding<Double?>,
                             conversationNPC: Binding<ConversationNPC?>,
                             conversationManager: ARConversationManager,
                             treasureHuntService: TreasureHuntService? = nil) {

        // Call parent setup
        super.setupARView(arView, locationManager: locationManager, userLocationManager: userLocationManager,
                         nearbyLocations: nearbyLocations, distanceToNearest: distanceToNearest,
                         temperatureStatus: temperatureStatus, collectionNotification: collectionNotification,
                         nearestObjectDirection: nearestObjectDirection, conversationNPC: conversationNPC,
                         conversationManager: conversationManager, treasureHuntService: treasureHuntService)

        // Initialize session manager now that AR view is set
        sessionManager = ARSessionManager(arCoordinator: self, stateManager: stateManager, audioManager: audioManager)

        // Set AR session delegate to our session manager
        arView.session.delegate = sessionManager

        // Setup precise positioning service
        nfcARService.setup(with: arView)

        // Setup tap handler callbacks
        setupTapHandlerCallbacks()

        // Setup notification observers for NPC spawning
        setupNotificationObservers()

        // Check if we need to spawn NPCs based on current game mode
        checkAndSpawnInitialNPCs()
    }

    private func checkAndSpawnInitialNPCs() {
        Swift.print("🔍 [ARCoordinator] checkAndSpawnInitialNPCs called")
        Swift.print("   Current game mode: \(locationManager?.gameMode.rawValue ?? "nil")")
        Swift.print("   skeleton-1 already placed: \(placedNPCs["skeleton-1"] != nil)")

        // If we're in story mode and no skeleton is placed, spawn Captain Bones
        if locationManager?.gameMode == .deadMensSecrets && placedNPCs["skeleton-1"] == nil {
            Swift.print("🎭 ARCoordinator initialized in story mode - spawning Captain Bones")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.placeNPC(type: NPCType.skeleton)
            }
        } else {
            Swift.print("❌ [ARCoordinator] NOT spawning Captain Bones:")
            if locationManager?.gameMode != .deadMensSecrets {
                Swift.print("   Reason: Game mode is \(locationManager?.gameMode.rawValue ?? "nil"), not deadMensSecrets")
            }
            if placedNPCs["skeleton-1"] != nil {
                Swift.print("   Reason: skeleton-1 already placed")
            }
        }
    }

    private func setupTapHandlerCallbacks() {
        // Initialize tap handler with current state
        tapHandler?.placedBoxes = placedBoxes
        tapHandler?.findableObjects = findableObjects
        tapHandler?.placedNPCs = placedNPCs
        tapHandler?.collectionNotificationBinding = collectionNotificationBinding

        tapHandler?.onFindLootBox = { [weak self] locationId, anchor, cameraPos, sphereEntity in
            self?.findLootBox(locationId: locationId, anchor: anchor, cameraPosition: cameraPos, sphereEntity: sphereEntity)
        }
        tapHandler?.onPlaceLootBoxAtTap = { [weak self] location, result in
            self?.placeLootBoxAtTapLocation(location, tapResult: result, in: self?.arView)
        }
        tapHandler?.onNPCTap = { [weak self] npcId in
            Swift.print("🎯 ARCoordinator.onNPCTap called with npcId: \(npcId)")

            // Check if this is an NFC-tagged object first
            if self?.isNFCTaggedObject(npcId) == true {
                self?.handleNFCTaggedObjectTap(npcId)
            } else {
                // Handle regular NPCs
                self?.handleRegularNPCTap(npcId)
            }
        }

        // Start distance logging
        distanceTracker?.startDistanceLogging()

        // Clean up occlusion planes and start checking
        occlusionManager?.removeAllOcclusionPlanes()
        occlusionManager?.startOcclusionChecking()

        // Apply ambient light
        environmentManager?.updateAmbientLight()
    }

    private func setupNotificationObservers() {
        // Listen for skeleton NPC spawn request (when entering story mode)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(spawnSkeletonNPC),
            name: NSNotification.Name("SpawnSkeletonNPC"),
            object: nil
        )

        // Listen for corgi NPC spawn request (after getting map from skeleton)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(spawnCorgiNPC),
            name: NSNotification.Name("SpawnCorgiNPC"),
            object: nil
        )

        // Listen for game mode changes to spawn NPCs when switching to story mode
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGameModeChange),
            name: NSNotification.Name("GameModeChanged"),
            object: nil
        )

        // Listen for dialog state changes to pause/resume AR session
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogOpened),
            name: NSNotification.Name("DialogOpened"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogClosed),
            name: NSNotification.Name("DialogClosed"),
            object: nil
        )

        // Listen for treasure map acquisition to place red X in AR
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTreasureMapAcquired),
            name: NSNotification.Name("TreasureMapAcquired"),
            object: nil
        )
    }

    @objc private func spawnSkeletonNPC() {
        Swift.print("📨 Received SpawnSkeletonNPC notification - spawning Captain Bones")
        placeNPC(type: NPCType.skeleton)
    }

    @objc private func spawnCorgiNPC() {
        Swift.print("🐕 Received request to spawn corgi NPC")
        placeNPC(type: NPCType.corgi)
    }

    @objc private func handleGameModeChange() {
        Swift.print("🎮 Game mode changed - checking if NPCs need to be spawned")
        checkAndSpawnInitialNPCs()
    }

    @objc private func handleDialogOpened() {
        Swift.print("📱 Dialog opened - pausing AR session to prevent freezing")
        pauseARSession()
    }

    @objc private func handleDialogClosed() {
        Swift.print("📱 Dialog closed - resuming AR session")
        resumeARSession()
    }

    @objc func handleTreasureMapAcquired(notification: Notification) {
        Swift.print("🗺️ Received TreasureMapAcquired notification - placing red X in AR")

        // Get treasure location from treasure hunt service
        guard let treasureHuntService = treasureHuntService,
              let treasureLocation = treasureHuntService.treasureLocation else {
            Swift.print("⚠️ No treasure hunt service or treasure location available")
            return
        }

        // Place red X marker at treasure location
        placeTreasureXAtLocation(treasureLocation)
    }

    // MARK: - Public Interface Methods

    /// Check and place boxes based on nearby locations (called by SwiftUI view)
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        objectPlacer?.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
    }

    /// Randomize loot boxes for testing
    func randomizeLootBoxes() {
        objectPlacer?.randomizeLootBoxes()
    }

    /// Place a single sphere for testing
    func placeSingleSphere(locationId: String? = nil) {
        objectPlacer?.placeSingleSphere(locationId: locationId)
    }

    /// Place an AR item from game data
    func placeARItem(_ item: LootBoxLocation) {
        objectPlacer?.placeARItem(item)
    }

    /// Place an NPC in AR
    func placeNPC(type: NPCType) {
        Swift.print("🎭 ARCoordinator.placeNPC called for \(type.rawValue)")
        guard let arView = arView else {
            Swift.print("⚠️ Cannot place NPC: arView is nil")
            return
        }
        guard let npcService = npcService else {
            Swift.print("⚠️ Cannot place NPC: npcService is nil")
            return
        }
        Swift.print("🎭 Delegating to npcService.placeNPC")
        npcService.placeNPC(type: type, in: arView)

        // Ensure tap handler has the latest NPC data
        DispatchQueue.main.async {
            self.tapHandler?.placedNPCs = self.placedNPCs
            Swift.print("🎭 Updated tap handler with placed NPCs: \(self.placedNPCs.keys.sorted())")
        }
    }


    /// Get AR-enhanced location
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        return locationManagerHelper?.getAREnhancedLocation()
    }

    /// Correct GPS coordinates for a placed object
    func correctGPSCoordinates(location: LootBoxLocation, intendedARPosition: SIMD3<Float>, arOrigin: CLLocation, cameraTransform: simd_float4x4) {
        locationManagerHelper?.correctGPSCoordinates(location: location, intendedARPosition: intendedARPosition, arOrigin: arOrigin, cameraTransform: cameraTransform)
    }

    /// Handle object collected by another user
    func handleObjectCollectedByOtherUser(objectId: String) {
        guard let arView = arView,
              let findable = findableObjects[objectId] else { return }

        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"

        Swift.print("🗑️ Removing object '\(objectName)' from AR - collected by another user")

        // Remove from scene
        arView.scene.removeAnchor(findable.anchor)

        // Clean up tracking
        findableObjects.removeValue(forKey: objectId)
        objectsInViewport.remove(objectId)
        distanceTracker?.foundLootBoxes.insert(objectId)

        // Remove distance text if exists
        if let textEntity = distanceTracker?.distanceTextEntities[objectId] {
            textEntity.removeFromParent()
            distanceTracker?.distanceTextEntities.removeValue(forKey: objectId)
        }
    }

    /// Handle object uncollected (marked as unfound)
    func handleObjectUncollected(objectId: String) {
        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"

        Swift.print("🔄 Object uncollected: '\(objectName)' - clearing found sets")

        // Clear from found sets
        distanceTracker?.foundLootBoxes.remove(objectId)
        tapHandler?.foundLootBoxes.remove(objectId)

        // Remove from scene if placed
        if let findable = findableObjects[objectId] {
            arView?.scene.removeAnchor(findable.anchor)
            findableObjects.removeValue(forKey: objectId)
            objectsInViewport.remove(objectId)
            objectPlacementTimes.removeValue(forKey: objectId)
        }

        // Trigger re-placement if nearby
        if let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            if nearby.contains(where: { $0.id == objectId }) {
                checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
            }
        }
    }


    /// Find a loot box (handle collection)
    private func findLootBox(locationId: String, anchor: AnchorEntity, cameraPosition: SIMD3<Float>, sphereEntity: ModelEntity?) {
        // Implementation delegated to tap handler and other managers
        // This method coordinates the collection process
        Swift.print("🎯 Loot box found: \(locationId)")

        // Mark as found
        distanceTracker?.foundLootBoxes.insert(locationId)

        // Remove from scene
        anchor.removeFromParent()

        // Clean up tracking
        findableObjects.removeValue(forKey: locationId)
        objectsInViewport.remove(locationId)
        objectPlacementTimes.removeValue(forKey: locationId)

        // Update UI
        if let location = locationManager?.locations.first(where: { $0.id == locationId }) {
            collectionNotificationBinding?.wrappedValue = "🎉 Found \(location.name)!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = nil
            }
        }
    }

    /// Place loot box at tap location
    private func placeLootBoxAtTapLocation(_ location: LootBoxLocation, tapResult: ARRaycastResult, in arView: ARView?) {
        guard let arView = arView else { return }

        // Convert tap result to world position
        let transform = tapResult.worldTransform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // Create anchor and place object
        let anchor = AnchorEntity(world: position)
        let findableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            location: location
        )

        arView.scene.addAnchor(anchor)
        findableObjects[location.id] = findableObject
        objectPlacementTimes[location.id] = Date()

        Swift.print("👆 Placed \(location.name) at tapped location")
    }

    /// Clear all AR objects
    func clearAllARObjects() {
        guard let arView = arView else { return }

        // Clear all objects via managers
        removeAllPlacedObjects()
        npcManager?.removeAllNPCs()

        // Also clear NPC service state
        npcService?.placedNPCs.removeAll()
        npcService?.skeletonPlaced = false
        npcService?.corgiPlaced = false

        // Reset state
        arOriginLocation = nil
        arOriginSetTime = nil
        isDegradedMode = false
        arOriginGroundLevel = nil

        Swift.print("🧹 Cleared all AR objects and reset state")
    }

    // MARK: - Session Management

    /// Pause AR session
    override func pauseARSession() {
        arView?.session.pause()
        Swift.print("⏸️ AR session paused")
    }

    /// Resume AR session
    override func resumeARSession() {
        if let config = savedARConfiguration {
            arView?.session.run(config)
            Swift.print("▶️ AR session resumed")
        }
    }

    // MARK: - Tap Handling

    @objc override func handleTap(_ sender: UITapGestureRecognizer) {
        // Delegate tap handling to the tap handler
        tapHandler?.handleTap(sender)
    }

    // MARK: - Dialog State Management

    /// Set dialog open state
    func setDialogOpen(_ isOpen: Bool) {
        uiManager?.dialogOpen = isOpen
    }

    // MARK: - State Throttling Helpers

    /// Check if view update should be performed
    func shouldPerformViewUpdate(currentLocationsCount: Int) -> Bool {
        return stateManager?.shouldPerformViewUpdate(currentLocationsCount: currentLocationsCount) ?? false
    }

    /// Check if nearby locations check should be performed
    func shouldPerformNearbyCheck() -> Bool {
        return stateManager?.shouldPerformNearbyCheck() ?? false
    }

    // MARK: - State Manager Access (for ARLootBoxView)

    /// Get last view update time
    var lastViewUpdateTime: Date {
        return stateManager?.lastViewUpdateTime ?? Date()
    }

    /// Get last locations count
    var lastLocationsCount: Int {
        return stateManager?.lastLocationsCount ?? 0
    }

    /// Get view update throttle interval
    var viewUpdateThrottleInterval: TimeInterval {
        return stateManager?.viewUpdateThrottleInterval ?? 0.1
    }

    // MARK: - NFC-AR Integration
    private func isNFCTaggedObject(_ objectId: String) -> Bool {
        // Check if object ID follows NFC tag pattern (e.g., "nfc_cache_001")
        return objectId.hasPrefix("nfc_") || objectId.hasPrefix("tag_")
    }

    private func handleNFCTaggedObjectTap(_ objectId: String) {
        print("🎯 Handling NFC-tagged object tap: \(objectId)")

        // Start the macro positioning process
        nfcARService.startMacroPositioning(for: objectId)

        // Simulate NFC discovery (in real app, this would come from NFC scan)
        // For demo purposes, we'll trigger it after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.nfcARService.discoverObject(tagID: "NFC_CACHE_001")
        }
    }

    private func handleRegularNPCTap(_ npcId: String) {
        Swift.print("🎯 Handling NPC tap for \(npcId)")
        Swift.print("🎯 npcManager exists: \(self.npcManager != nil)")
        Swift.print("🎯 npcService exists: \(self.npcService != nil)")
        Swift.print("🎯 arView exists: \(self.arView != nil)")

        // Use full conversation view for skeleton (Captain Bones)
        if npcId == NPCType.skeleton.npcId {
            Swift.print("💀 Skeleton tapped - using full conversation view")
            self.npcService?.handleNPCTap(type: NPCType.skeleton)
        } else {
            // Use inline alerts for other NPCs (corgi)
            Swift.print("🎯 Other NPC tapped - using inline alerts")
            if let arView = self.arView {
                self.npcManager?.handleNPCTap(npcId: npcId, in: arView)
            } else {
                Swift.print("⚠️ Cannot handle NPC tap: arView is nil")
            }
        }
    }

    /// Place a red X marker at the treasure location in AR
    func placeTreasureXAtLocation(_ location: CLLocation) {
        guard let arView = arView else {
            Swift.print("⚠️ Cannot place treasure X: AR view not available")
            return
        }

        // Check if treasure X is already placed
        if treasureXPlaced {
            Swift.print("✅ Treasure X already placed, skipping")
            return
        }

        Swift.print("🎯 Placing red X marker at treasure location: (\(location.coordinate.latitude), \(location.coordinate.longitude))")

        do {
            // Try to use geospatial service for precise GPS positioning
            if let geospatialService = geospatialService,
               let arPosition = geospatialService.convertGPSToAR(location) {

                Swift.print("📍 Using geospatial positioning: AR coords (\(String(format: "%.2f", arPosition.x)), \(String(format: "%.2f", arPosition.y)), \(String(format: "%.2f", arPosition.z)))")

                // Create anchor at precise GPS location
                let anchor = AnchorEntity(world: arPosition)

                // Create a red X marker model
                let xMarker = createTreasureXMarker()
                anchor.addChild(xMarker)

                // Add to AR scene
                arView.scene.addAnchor(anchor)

                // Mark as placed
                treasureXPlaced = true

                Swift.print("✅ Treasure X marker placed at precise GPS location")

            } else {
                // Fallback: place relative to user position (demo mode)
                Swift.print("⚠️ Geospatial service not available, using fallback positioning")

                // Create anchor 5 meters in front for demo
                let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -5))

                // Create a red X marker model
                let xMarker = createTreasureXMarker()
                anchor.addChild(xMarker)

                // Add to AR scene
                arView.scene.addAnchor(anchor)

                // Mark as placed
                treasureXPlaced = true

                Swift.print("✅ Treasure X marker placed in fallback mode (5m in front)")
            }

        } catch {
            Swift.print("❌ Failed to place treasure X marker: \(error.localizedDescription)")
        }
    }

    /// Create a visual red X marker for the treasure location
    private func createTreasureXMarker() -> ModelEntity {
        // Create a red X shape using simple geometry
        let mesh = MeshResource.generateText(
            "✕",
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.5),
            containerFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

        let material = SimpleMaterial(color: .red, roughness: 0.5, isMetallic: false)
        let modelEntity = ModelEntity(mesh: mesh, materials: [material])

        // Scale it appropriately for AR
        modelEntity.scale = SIMD3<Float>(2, 2, 2)

        return modelEntity
    }
}
