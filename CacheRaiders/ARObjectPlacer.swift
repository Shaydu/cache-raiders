import RealityKit
import ARKit
import CoreLocation
import AudioToolbox
import UIKit

// MARK: - AR Coordinator Protocol
protocol ARCoordinatorProtocol: AnyObject {
    var arView: ARView? { get }
    var userLocationManager: UserLocationManager? { get }
    var arOriginLocation: CLLocation? { get }
    var geospatialService: ARGeospatialService? { get }
    var groundingService: ARGroundingService? { get }
    var findableObjects: [String: FindableObject] { get set }
    var placedBoxes: [String: AnchorEntity] { get set }
    var objectPlacementTimes: [String: Date] { get set }
    var lastSpherePlacementTime: Date? { get set }
    var sphereModeActive: Bool { get set }
    var locationManager: LootBoxLocationManager? { get }
    var tapHandler: ARTapHandler? { get }
    func removeAllPlacedObjects()
}

// MARK: - AR Object Placer
class ARObjectPlacer: ARObjectPlacementServiceProtocol {

    private weak var arCoordinator: ARCoordinatorProtocol?
    private var lootBoxLocationManager: LootBoxLocationManager?
    private var arLocationManager: ARLocationManager?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorProtocol, locationManager: LootBoxLocationManager) {
        self.arCoordinator = arCoordinator
        self.lootBoxLocationManager = locationManager
        // ARLocationManager requires ARCoordinatorCore, so we'll initialize it only if needed
        if let core = arCoordinator as? ARCoordinatorCore {
            self.arLocationManager = ARLocationManager(arCoordinator: core)
        }
    }

    // MARK: - Loot Box Placement

    /// Place a loot box at a specific location in AR space with tiered accuracy
    func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        Swift.print("🎯 placeLootBoxAtLocation called for: \(location.name) (type: \(location.type.displayName))")

        // Check if already placed
        if arCoordinator?.findableObjects[location.id] != nil {
            Swift.print("   ⏭️ Already placed, skipping")
            return
        }

        // Check AR frame availability
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': AR frame not available")
            return
        }

        // Check user location availability
        guard let userLocation = arCoordinator?.userLocationManager?.currentLocation else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': User location not available")
            return
        }

        // Calculate distance to object
        let objectLocation = location.location
        let distanceToObject = userLocation.distance(from: objectLocation)

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        Swift.print("   📏 Distance to object: \(String(format: "%.2f", distanceToObject))m")

        // TIERED ACCURACY: Use AR anchor when nearby for centimeter-level precision
        // Note: AR anchor support requires server-side metadata (not yet implemented)
        // For now, this is a placeholder for future implementation

        // Determine placement strategy based on available AR coordinates
        if let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude,
           let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z {

            Swift.print("   ℹ️ Using AR room coordinates")
            placeUsingARCoordinates(location, arOriginLat: arOriginLat, arOriginLon: arOriginLon,
                                  arOffsetX: arOffsetX, arOffsetY: arOffsetY, arOffsetZ: arOffsetZ,
                                  userLocation: userLocation, in: arView)
        } else {
            Swift.print("   📍 Using GPS coordinates")
            placeUsingGPSCoordinates(location, userLocation: userLocation, cameraPos: cameraPos, in: arView)
        }
    }

    private func placeUsingARCoordinates(_ location: LootBoxLocation, arOriginLat: Double, arOriginLon: Double,
                                       arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double,
                                       userLocation: CLLocation, in arView: ARView) {

        let arOriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)
        let arPosition = SIMD3<Float>(Float(arOffsetX), Float(arOffsetY), Float(arOffsetZ))
        let distanceFromOrigin = arLocationManager?.distanceFromAROrigin(arPosition) ?? 0

        // Check user's distance to the object (this is the key factor for precision)
        let objectLocation = location.location
        let userDistanceToObject = userLocation.distance(from: objectLocation)

        // Check if AR session origins match (within 1m tolerance)
        var arOriginsMatch = false
        if let currentAROrigin = arCoordinator?.arOriginLocation {
            let originDistance = currentAROrigin.distance(from: arOriginGPS)
            arOriginsMatch = originDistance < 1.0
        }

        // NEW LOGIC: Use AR coordinates when user is within 8m of object AND AR session is valid
        let useARCoordinates = userDistanceToObject < 8.0 && arOriginsMatch && distanceFromOrigin < 12.0

        Swift.print("🎯 AR COORDINATE DECISION for '\(location.name)':")
        Swift.print("   📍 User distance to object: \(String(format: "%.2f", userDistanceToObject))m (threshold: 8.0m)")
        Swift.print("   🔗 AR origins match: \(arOriginsMatch)")
        Swift.print("   📏 Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m (max: 12.0m)")
        Swift.print("   🎯 FINAL DECISION: \(useARCoordinates ? "✅ USING AR COORDINATES (PRECISION MODE)" : "📍 USING GPS COORDINATES (STANDARD MODE)")")

        if useARCoordinates {
            Swift.print("   💎 PRECISION PLACEMENT: Object will appear at exact AR position (cm accuracy)")
        } else {
            Swift.print("   🌍 STANDARD PLACEMENT: Object positioned using GPS (meter accuracy)")
        }

        if useARCoordinates {
            Swift.print("✅ PRECISE placement: Using AR coordinates (within 8m threshold)")
            placeBoxAtPosition(arPosition, location: location, in: arView)
        } else {
            var reasons: [String] = []
            if userDistanceToObject >= 8.0 { reasons.append("user >8m from object") }
            if !arOriginsMatch { reasons.append("AR origins don't match") }
            if distanceFromOrigin >= 12.0 { reasons.append("too far from AR origin") }

            Swift.print("📍 GPS placement: Using GPS coordinates - \(reasons.joined(separator: ", "))")
            placeUsingGPSCoordinates(location, userLocation: userLocation, cameraPos: SIMD3<Float>(0, 0, 0), in: arView)
        }
    }

    private func placeUsingGPSCoordinates(_ location: LootBoxLocation, userLocation: CLLocation,
                                        cameraPos: SIMD3<Float>, in arView: ARView) {

        guard let geospatialService = arCoordinator?.geospatialService,
              geospatialService.hasENUOrigin else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': No ENU origin set")
            return
        }

        // Convert GPS to AR position
        guard let arPosition = geospatialService.convertGPStoAR(location.location) else {
            Swift.print("⚠️ [Placement] Cannot convert GPS to AR for '\(location.name)'")
            return
        }

        // Ground the position
        let groundedPosition = arCoordinator?.groundingService?.groundPosition(arPosition, cameraPos: cameraPos) ?? arPosition

        Swift.print("✅ [Placement] Using GPS coordinates for \(location.name)")
        Swift.print("   GPS: (\(String(format: "%.6f", location.latitude)), \(String(format: "%.6f", location.longitude)))")
        Swift.print("   AR position: (\(String(format: "%.4f", groundedPosition.x)), \(String(format: "%.4f", groundedPosition.y)), \(String(format: "%.4f", groundedPosition.z)))m")

        placeBoxAtPosition(groundedPosition, location: location, in: arView)
    }

    private func placeBoxAtPosition(_ position: SIMD3<Float>, location: LootBoxLocation, in arView: ARView) {
        // Create anchor at position
        let anchor = AnchorEntity(world: position)
        anchor.name = location.id

        // Create the visual entity using the factory
        let factory = location.type.factory
        let (entity, findableObject) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: 1.0)

        // CRITICAL: Set entity name to location ID for tap detection
        entity.name = location.id

        // CRITICAL: Enable tap interaction by adding InputTargetComponent
        // This allows RealityKit to detect taps on the entity
        entity.components.set(InputTargetComponent())

        // CRITICAL FIX: Add the visual entity to the anchor
        anchor.addChild(entity)

        // Start loop animation if the factory supports it
        factory.animateLoop(entity: entity)

        // CRITICAL: Save AR coordinates for centimeter-level accuracy
        // This enables precise placement when returning to view the object
        if let arOrigin = arCoordinator?.arOriginLocation,
           let userLocation = arCoordinator?.userLocationManager?.currentLocation {

            // Only save AR coordinates if within 8m (precision threshold)
            let distanceToObject = userLocation.distance(from: location.location)
            if distanceToObject < 8.0 {
                // Update location with AR coordinates by creating a new instance
                let updatedLocation = LootBoxLocation(
                    id: location.id,
                    name: location.name,
                    type: location.type,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    radius: location.radius,
                    collected: location.collected,
                    grounding_height: location.grounding_height,
                    source: location.source,
                    created_by: location.created_by,
                    ar_origin_latitude: arOrigin.coordinate.latitude,
                    ar_origin_longitude: arOrigin.coordinate.longitude,
                    ar_offset_x: Double(position.x),
                    ar_offset_y: Double(position.y),
                    ar_offset_z: Double(position.z),
                    ar_placement_timestamp: Date(),
                    ar_anchor_transform: location.ar_anchor_transform
                )

                Swift.print("💎 [AR Coordinates] Saved for '\(location.name)':")
                Swift.print("   AR Origin GPS: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
                Swift.print("   AR Offset: (\(String(format: "%.4f", position.x)), \(String(format: "%.4f", position.y)), \(String(format: "%.4f", position.z)))m")
                Swift.print("   Distance to object: \(String(format: "%.2f", distanceToObject))m (< 8m = precision mode)")

                // Save to location manager (will sync to Core Data and API)
                Task {
                    await lootBoxLocationManager?.updateLocation(updatedLocation)
                }
            } else {
                Swift.print("📍 [AR Coordinates] Not saved - distance \(String(format: "%.2f", distanceToObject))m exceeds 8m precision threshold")
            }
        }

        // Create findable object (now using the one from factory)
        let finalFindableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: findableObject.sphereEntity,
            container: findableObject.container,
            location: location
        )

        // Add object to scene
        arView.scene.addAnchor(anchor)

        // Track the object
        arCoordinator?.findableObjects[location.id] = finalFindableObject
        arCoordinator?.placedBoxes[location.id] = anchor
        arCoordinator?.objectPlacementTimes[location.id] = Date()

        // CRITICAL: Also update tapHandler's findableObjects immediately
        // This ensures objects are tappable right away without waiting for periodic sync
        arCoordinator?.tapHandler?.findableObjects[location.id] = finalFindableObject

        Swift.print("✅ [Placement] Placed '\(location.name)' at AR position: (\(String(format: "%.4f", position.x)), \(String(format: "%.4f", position.y)), \(String(format: "%.4f", position.z)))m")
        Swift.print("   Object ID: \(location.id)")
        Swift.print("   Type: \(location.type.displayName)")
        Swift.print("   Entity added to anchor: \(anchor.children.contains(where: { $0 === entity }))")
        Swift.print("   Anchor added to scene: \(arView.scene.anchors.contains(where: { $0 === anchor }))")
        Swift.print("   Anchor children count: \(anchor.children.count)")
        Swift.print("   Anchor enabled: \(anchor.isEnabled)")
        Swift.print("   Entity enabled: \(entity.isEnabled)")
        Swift.print("   Entity name: '\(entity.name)'")
        Swift.print("   Entity has InputTargetComponent: \(entity.components.has(InputTargetComponent.self))")
        Swift.print("   Entity has CollisionComponent: \(entity.components.has(CollisionComponent.self))")
        Swift.print("   TapHandler exists: \(arCoordinator?.tapHandler != nil)")
        Swift.print("   TapHandler findableObjects count: \(arCoordinator?.tapHandler?.findableObjects.count ?? 0)")
        Swift.print("   TapHandler findableObjects keys: \(arCoordinator?.tapHandler?.findableObjects.keys.sorted() ?? [])")

        // Play haptic and sound feedback when object appears in AR
        playObjectPlacedFeedback(for: location)
    }

    /// Play haptic and audio feedback when an object is placed in AR
    private func playObjectPlacedFeedback(for location: LootBoxLocation) {
        // Play viewport entry chirp sound (system sound 1103 - soft notification chime)
        AudioServicesPlaySystemSound(1103)
        Swift.print("🔔 SOUND: Object placed chirp (system sound 1103)")

        // Haptic feedback - medium impact when object appears
        DispatchQueue.main.async {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
            Swift.print("📳 HAPTIC: Object placed feedback")
        }

        Swift.print("   Trigger: Object placed in AR")
        Swift.print("   Object: \(location.name) (\(location.type.displayName))")
        Swift.print("   Location ID: \(location.id)")
    }

    // MARK: - Sphere Placement

    /// Place a single random sphere for testing
    func placeSingleSphere(locationId: String? = nil) {
        guard let arView = arCoordinator?.arView,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place sphere: AR frame not available")
            return
        }

        // Use provided location ID or generate a proper UUID
        let sphereId = locationId ?? UUID().uuidString
        let location = createRandomSphereLocation(id: sphereId)

        // Place the sphere
        placeLootBoxAtLocation(location, in: arView)

        // Track placement time to prevent rapid re-placement
        arCoordinator?.lastSpherePlacementTime = Date()
    }

    private func createRandomSphereLocation(id: String) -> LootBoxLocation {
        // Create a random location near the user for testing
        guard let userLocation = arCoordinator?.userLocationManager?.currentLocation else {
            // Fallback location if GPS unavailable
            return LootBoxLocation(
                id: id,
                name: "Test Sphere",
                type: .sphere,
                latitude: 0,
                longitude: 0,
                radius: 10.0,
                collected: false,
                grounding_height: nil,
                source: .arRandomized
            )
        }

        // Generate random offset (up to 50 meters in any direction)
        let randomAngle = Double.random(in: 0..<2 * .pi)
        let randomDistance = Double.random(in: 10..<50) // 10-50 meters away
        let randomCoordinate = userLocation.coordinate.coordinate(atDistance: randomDistance, atBearing: randomAngle * 180 / .pi)

        return LootBoxLocation(
            id: id,
            name: "Random Sphere",
            type: .sphere,
            latitude: randomCoordinate.latitude,
            longitude: randomCoordinate.longitude,
            radius: 10.0,
            collected: false,
            grounding_height: nil,
            source: .arRandomized
        )
    }

    /// Randomize loot boxes by placing multiple spheres
    func randomizeLootBoxes() {
        guard let arView = arCoordinator?.arView else { return }

        Swift.print("🎲 Randomizing loot boxes...")

        // Clear existing objects first
        arCoordinator?.removeAllPlacedObjects()

        // Place multiple random spheres
        let sphereCount = 5
        for i in 0..<sphereCount {
            // Generate a proper UUID for each sphere
            let sphereId = UUID().uuidString
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self] in
                self?.placeSingleSphere(locationId: sphereId)
            }
        }

        arCoordinator?.sphereModeActive = true
        Swift.print("✅ Placed \(sphereCount) random spheres for testing")
    }

    // MARK: - Item Placement

    /// Place an AR item from game data
    func placeARItem(_ item: LootBoxLocation) {
        guard let arView = arCoordinator?.arView,
              let userLocation = arCoordinator?.userLocationManager?.currentLocation else {
            Swift.print("⚠️ Cannot place AR item: AR view or user location not available")
            return
        }

        Swift.print("📦 Placing AR item: \(item.name)")

        // Create anchor at current camera position with forward offset
        guard let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)

        // Place 3 meters in front of camera
        let placementPosition = cameraPos + forward * 3.0

        // Ground the position
        let groundedPosition = arCoordinator?.groundingService?.groundPosition(placementPosition, cameraPos: cameraPos) ?? placementPosition

        placeBoxAtPosition(groundedPosition, location: item, in: arView)
    }

    // MARK: - Utility Methods

    /// Check and place boxes based on nearby locations
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        guard let arCoordinator = arCoordinator else { return }
        guard let arCoordinatorCore = arCoordinator as? ARCoordinatorCore,
              let stateManager = arCoordinatorCore.services.state as? ARStateManager,
              stateManager.shouldPerformNearbyCheck() else { return }

        let nearbyLocationIds = Set(nearbyLocations.map { $0.id })
        let locationMap = Dictionary(uniqueKeysWithValues:
            (arCoordinator.locationManager?.locations ?? []).map { ($0.id, $0) })

        // Remove objects that are no longer nearby
        let findablesToRemove = arCoordinator.findableObjects.keys.filter { locationId in
            if nearbyLocationIds.contains(locationId) { return false }

            // Check if it's a special object that should persist
            if locationId.hasPrefix("npc_") || locationId.hasPrefix("sphere-") { return false }

            return true
        }

        // Remove objects that are too far or collected
        for locationId in findablesToRemove {
            let locationName = locationMap[locationId]?.name ?? locationId
            Swift.print("🗑️ Removing '\(locationName)' - no longer nearby or collected")

            if let findable = arCoordinator.findableObjects[locationId] {
                arCoordinator.arView?.scene.removeAnchor(findable.anchor)
            }
            arCoordinator.findableObjects.removeValue(forKey: locationId)
            arCoordinator.objectPlacementTimes.removeValue(forKey: locationId)
        }

        // Place new nearby objects
        for location in nearbyLocations {
            if arCoordinator.findableObjects[location.id] == nil && !location.collected {
                // Check distance from user
                let distance = userLocation.distance(from: location.location)
                if distance <= 100 { // Only place objects within 100m
                    arCoordinator.arView.map { placeLootBoxAtLocation(location, in: $0) }
                }
            }
        }
    }

    // MARK: - ARObjectPlacementServiceProtocol Methods
    
    func removeAllPlacedObjects() {
        guard let arCoordinator = arCoordinator else { return }
        
        Swift.print("🧹 Removing all placed objects")
        
        // Remove all anchors from scene
        for (_, anchor) in arCoordinator.placedBoxes {
            arCoordinator.arView?.scene.removeAnchor(anchor)
        }
        
        // Clear all tracking dictionaries
        arCoordinator.findableObjects.removeAll()
        arCoordinator.placedBoxes.removeAll()
        arCoordinator.objectPlacementTimes.removeAll()
        
        // Clear tap handler's findable objects
        arCoordinator.tapHandler?.findableObjects.removeAll()
        
        Swift.print("✅ All placed objects removed - scene cleared")
    }
    
    func configure(with coordinator: ARCoordinatorCoreProtocol) {
        // Implementation not needed for this service
    }
    
    func cleanup() {
        // Implementation not needed for this service
    }
    
    func findLootBox(_ location: LootBoxLocation, source: FoundSource) {
        // Implementation to be added from ARCoordinator
    }
    
    func handleObjectTap(_ entity: Entity) {
        // Implementation to be added from ARCoordinator
    }
}

