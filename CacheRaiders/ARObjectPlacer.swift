import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Object Placer
class ARObjectPlacer {

    private weak var arCoordinator: ARCoordinatorCore?
    private var locationManager: ARLocationManager?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore, locationManager: ARLocationManager) {
        self.arCoordinator = arCoordinator
        self.locationManager = locationManager
    }

    // MARK: - Loot Box Placement

    /// Place a loot box at a specific location in AR space
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

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Determine placement strategy based on available AR coordinates
        if let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude,
           let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z {

            placeUsingARCoordinates(location, arOriginLat: arOriginLat, arOriginLon: arOriginLon,
                                  arOffsetX: arOffsetX, arOffsetY: arOffsetY, arOffsetZ: arOffsetZ,
                                  userLocation: userLocation, in: arView)
        } else {
            placeUsingGPSCoordinates(location, userLocation: userLocation, cameraPos: cameraPos, in: arView)
        }
    }

    private func placeUsingARCoordinates(_ location: LootBoxLocation, arOriginLat: Double, arOriginLon: Double,
                                       arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double,
                                       userLocation: CLLocation, in arView: ARView) {

        let arOriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)
        let arPosition = SIMD3<Float>(Float(arOffsetX), Float(arOffsetY), Float(arOffsetZ))
        let distanceFromOrigin = locationManager?.distanceFromAROrigin(arPosition) ?? 0

        // Determine if we can use AR coordinates directly
        var useARCoordinates = false
        if let currentAROrigin = arCoordinator?.arOriginLocation {
            let originDistance = currentAROrigin.distance(from: arOriginGPS)
            useARCoordinates = originDistance < 1.0 && distanceFromOrigin < 12.0
        }

        if useARCoordinates {
            Swift.print("✅ INDOOR placement: Using AR coordinates for mm/cm-precision")
            placeBoxAtPosition(arPosition, location: location, in: arView)
        } else {
            if let currentAROrigin = arCoordinator?.arOriginLocation,
               currentAROrigin.distance(from: arOriginGPS) >= 1.0 {
                Swift.print("⚠️ AR origins don't match - falling back to GPS coordinates")
            } else {
                Swift.print("🌍 OUTDOOR placement: Using GPS coordinates")
            }
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
        anchor.name = "anchor-\(location.id)"

        // Create the visual entity using the factory
        let factory = location.type.factory
        let (entity, findableObject) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: 1.0)

        // CRITICAL FIX: Add the visual entity to the anchor
        anchor.addChild(entity)

        // Start loop animation if the factory supports it
        factory.animateLoop(entity: entity)

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
        arCoordinator?.objectPlacementTimes[location.id] = Date()

        Swift.print("✅ [Placement] Placed '\(location.name)' at AR position: (\(String(format: "%.4f", position.x)), \(String(format: "%.4f", position.y)), \(String(format: "%.4f", position.z)))m")
        Swift.print("   Object ID: \(location.id)")
        Swift.print("   Type: \(location.type.displayName)")
        Swift.print("   Entity added to anchor: \(anchor.children.contains(where: { $0 === entity }))")
        Swift.print("   Anchor added to scene: \(arView.scene.anchors.contains(where: { $0 === anchor }))")
        Swift.print("   Anchor children count: \(anchor.children.count)")
        Swift.print("   Anchor enabled: \(anchor.isEnabled)")
        Swift.print("   Entity enabled: \(entity.isEnabled)")
    }

    // MARK: - Sphere Placement

    /// Place a single random sphere for testing
    func placeSingleSphere(locationId: String? = nil) {
        guard let arView = arCoordinator?.arView,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place sphere: AR frame not available")
            return
        }

        // Use provided location ID or generate a random one
        let sphereId = locationId ?? "sphere-\(UUID().uuidString.prefix(8))"
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
            let sphereId = "random-sphere-\(i)"
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
        guard (arCoordinator as? ARCoordinator)?.shouldPerformNearbyCheck() ?? true else { return }

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
}

