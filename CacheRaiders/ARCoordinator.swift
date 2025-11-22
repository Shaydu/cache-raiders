import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import AVFoundation
import AudioToolbox

// MARK: - AR Coordinator
class ARCoordinator: NSObject, ARSessionDelegate {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var placedBoxes: [String: AnchorEntity] = [:]
    private var arOriginLocation: CLLocation? // GPS location when AR session started
    private var distanceLogger: Timer?
    private var previousDistance: Double?
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    private var occlusionCheckTimer: Timer?
    private var proximitySoundPlayed: Set<String> = [] // Track which boxes have played proximity sound
    private var occlusionPlanes: [UUID: AnchorEntity] = [:] // Track occlusion planes for walls
    
    func setupARView(_ arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearbyLocations: Binding<[LootBoxLocation]>, distanceToNearest: Binding<Double?>, temperatureStatus: Binding<String?>) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.nearbyLocationsBinding = nearbyLocations
        self.distanceToNearestBinding = distanceToNearest
        self.temperatureStatusBinding = temperatureStatus
        
        // Set up callback for size changes
        locationManager.onSizeChanged = { [weak self] in
            self?.updateLootBoxSizes()
        }
        
        // Store the GPS location when AR starts (this becomes our AR world origin)
        arOriginLocation = userLocationManager.currentLocation
        
        // Monitor AR session
        arView.session.delegate = self
        
        // Start distance logging timer
        startDistanceLogging()
        
        // Clean up any existing occlusion planes (they were causing issues)
        removeAllOcclusionPlanes()
        
        // Occlusion checking disabled - was causing issues with ceiling detection
        // startOcclusionChecking()
    }
    
    // Remove all existing occlusion planes
    private func removeAllOcclusionPlanes() {
        guard let arView = arView else { return }
        
        // Remove all tracked occlusion planes
        for (_, anchor) in occlusionPlanes {
            anchor.removeFromParent()
        }
        occlusionPlanes.removeAll()
        
        // Also remove any orphaned occlusion planes from the scene
        // Iterate over all anchors in the scene and check for occlusion entities
        let anchors = Array(arView.scene.anchors)
        for anchor in anchors {
            // Remove occlusion entities recursively
            removeOcclusionEntities(from: anchor)
            
            // Also check if anchor itself is an occlusion plane anchor (from ARPlaneAnchor)
            if let anchorEntity = anchor as? AnchorEntity {
                // Remove the entire anchor if it only contains occlusion planes
                let hasNonOcclusionChildren = anchorEntity.children.contains { child in
                    if let modelEntity = child as? ModelEntity,
                       let model = modelEntity.model {
                        return !model.materials.contains(where: { $0 is OcclusionMaterial })
                    }
                    return true
                }
                
                if !hasNonOcclusionChildren && !anchorEntity.children.isEmpty {
                    // This anchor only has occlusion planes - remove it entirely
                    print("🗑️ Removing occlusion-only anchor")
                    anchorEntity.removeFromParent()
                }
            }
        }
        
        print("🧹 Removed all occlusion planes")
    }
    
    // Recursively find and remove any entities with OcclusionMaterial or suspiciously large planes
    private func removeOcclusionEntities(from entity: Entity) {
        // Make a copy of children array before iterating (to avoid mutation issues)
        let children = Array(entity.children)
        
        // First, recursively process children
        for child in children {
            removeOcclusionEntities(from: child)
        }
        
        // Then check this entity itself
        if let modelEntity = entity as? ModelEntity,
           let model = modelEntity.model {
            // Check if any material is OcclusionMaterial
            if model.materials.contains(where: { $0 is OcclusionMaterial }) {
                print("🗑️ Found and removing occlusion entity: \(entity.name ?? "unnamed")")
                entity.removeFromParent()
                return
            }
        }
    }
    
    private func startOcclusionChecking() {
        // Check occlusion more frequently (every 0.1 seconds = 10 times per second)
        occlusionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkOcclusionForPlacedBoxes()
        }
    }
    
    private func checkOcclusionForPlacedBoxes() {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Check each placed loot box for occlusion
        for (locationId, anchor) in placedBoxes {
            guard let boxEntity = anchor.children.first else { continue }
            
            // Get box position in world space
            let boxTransform = anchor.transformMatrix(relativeTo: nil)
            let boxPosition = SIMD3<Float>(
                boxTransform.columns.3.x,
                boxTransform.columns.3.y,
                boxTransform.columns.3.z
            )
            
            // Calculate direction from camera to box
            let direction = boxPosition - cameraPosition
            let distance = length(direction)
            
            // Skip if box is too close or too far
            guard distance > 0.1 && distance < 50.0 else {
                boxEntity.isEnabled = true
                continue
            }
            
            let normalizedDirection = direction / distance
            
            // Convert to ARKit coordinate space (camera space)
            let cameraSpaceDirection = simd_mul(
                simd_inverse(cameraTransform),
                SIMD4<Float>(normalizedDirection.x, normalizedDirection.y, normalizedDirection.z, 0)
            )
            
            // Perform raycast from camera to loot box to check for walls
            // Use trackableType to check for vertical planes (walls)
            let raycastQuery = ARRaycastQuery(
                origin: cameraPosition,
                direction: SIMD3<Float>(cameraSpaceDirection.x, cameraSpaceDirection.y, cameraSpaceDirection.z),
                allowing: .estimatedPlane,
                alignment: .vertical // Check for vertical planes (walls)
            )
            
            let raycastResults = arView.session.raycast(raycastQuery)
            
            // If we hit a vertical plane (wall) before reaching the box, hide it
            var isOccluded = false
            for result in raycastResults {
                // Check if the hit point is closer than the box (wall is between camera and box)
                let hitPoint = SIMD3<Float>(
                    result.worldTransform.columns.3.x,
                    result.worldTransform.columns.3.y,
                    result.worldTransform.columns.3.z
                )
                let hitDistance = length(hitPoint - cameraPosition)
                
                // If wall is closer than box (with some tolerance), box is occluded
                if hitDistance < distance - 0.5 { // 0.5m tolerance
                    isOccluded = true
                    break
                }
            }
            
            // Show/hide box based on occlusion
            boxEntity.isEnabled = !isOccluded
        }
    }
    
    private func startDistanceLogging() {
        distanceLogger = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.logDistanceToNearestLootBox()
        }
    }
    
    private func logDistanceToNearestLootBox() {
        // Only show status if we have GPS fix and can calculate distance
        guard let userLocation = userLocationManager?.currentLocation,
              let locationManager = locationManager else {
            // No GPS fix or location manager - don't show anything
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        // Check if we have a valid GPS fix (horizontal accuracy should be reasonable)
        guard userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 100 else {
            // GPS fix not accurate enough - don't show anything
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        // Find nearest uncollected loot box
        let uncollectedLocations = locationManager.locations.filter { !$0.collected }
        guard !uncollectedLocations.isEmpty else {
            // No uncollected loot boxes - don't show anything
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        let distances = uncollectedLocations.map { location in
            (location: location, distance: userLocation.distance(from: location.location))
        }
        
        guard let nearest = distances.min(by: { $0.distance < $1.distance }) else {
            // Couldn't find nearest - don't show anything
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        let currentDistance = nearest.distance
        
        // Log distance
        print("📏 Distance to nearest loot box (\(nearest.location.name)): \(String(format: "%.2f", currentDistance))m")
        
        // Update temperature status with distance included (only show distance when we have a comparison)
        var status: String?
        if let previous = previousDistance {
            // We have a previous distance to compare - show warmer/colder with distance
            if currentDistance < previous {
                status = "🔥 Warmer (\(String(format: "%.1f", currentDistance))m)"
                print("   🔥 Getting warmer! (was \(String(format: "%.2f", previous))m)")
            } else if currentDistance > previous {
                status = "❄️ Colder (\(String(format: "%.1f", currentDistance))m)"
                print("   ❄️ Getting colder... (was \(String(format: "%.2f", previous))m)")
            } else {
                status = "➡️ Same distance (\(String(format: "%.1f", currentDistance))m)"
            }
            previousDistance = currentDistance
        } else {
            // First reading - don't show distance yet, just store it for next comparison
            previousDistance = currentDistance
            status = nil // Don't show anything until we have a comparison
        }
        
        // Check for proximity (within 1m) - play sound and open box
        if currentDistance <= 1.0 && !proximitySoundPlayed.contains(nearest.location.id) {
            playProximitySound()
            proximitySoundPlayed.insert(nearest.location.id)
            
            // Automatically open the loot box
            if let arView = arView,
               let anchor = placedBoxes[nearest.location.id],
               var info = anchor.components[LootBoxInfoComponent.self],
               let container = info.container,
               !info.isOpening {
                info.isOpening = true
                anchor.components[LootBoxInfoComponent.self] = info
                
                LootBoxAnimation.openLootBox(container: container, location: nearest.location) { [weak self] in
                    // Animation complete - mark as collected and remove
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(nearest.location.id)
                    }
                    
                    anchor.removeFromParent()
                    self?.placedBoxes.removeValue(forKey: nearest.location.id)
                    
                    print("🎉 Collected: \(nearest.location.name)")
                }
            }
        }
        
        // Update bindings
        DispatchQueue.main.async { [weak self] in
            self?.distanceToNearestBinding?.wrappedValue = currentDistance
            self?.temperatureStatusBinding?.wrappedValue = status
        }
    }
    
    /// Plays a sound when user is within 1m of a loot box
    private func playProximitySound() {
        // Play a subtle proximity sound (different from opening sound)
        AudioServicesPlaySystemSound(1054) // System sound for proximity/notification
    }
    
    deinit {
        distanceLogger?.invalidate()
        occlusionCheckTimer?.invalidate()
    }
    
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        guard let arView = arView, let locationManager = locationManager else { return }
        
        for location in nearbyLocations {
            // Place box if it's nearby (within maxSearchDistance), hasn't been placed, and isn't collected
            // The box will appear in AR when you're within the search distance
            if placedBoxes[location.id] == nil && !location.collected {
                placeLootBoxAtLocation(location, in: arView)
            }
        }
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Set AR origin on first frame if not set
        if arOriginLocation == nil,
           let userLocation = userLocationManager?.currentLocation {
            arOriginLocation = userLocation
            print("📍 AR Origin set at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
        }
        
        // Check for nearby locations when AR is tracking
        if frame.camera.trackingState == .normal,
           let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
        }
    }
    
    // Handle AR anchor updates to create occlusion planes for walls
    // DISABLED: Occlusion planes were creating enormous objects (likely from ceiling detection)
    // If re-enabling, add filtering to exclude ceiling-sized planes
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Occlusion planes disabled - was causing issues with ceiling detection
        // guard let arView = arView else { return }
        //
        // for anchor in anchors {
        //     // Only process vertical plane anchors (walls)
        //     if let planeAnchor = anchor as? ARPlaneAnchor,
        //        planeAnchor.alignment == .vertical {
        //         createOcclusionPlane(for: planeAnchor, in: arView)
        //     }
        // }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Occlusion planes disabled
        // guard let arView = arView else { return }
        //
        // for anchor in anchors {
        //     if let planeAnchor = anchor as? ARPlaneAnchor,
        //        planeAnchor.alignment == .vertical,
        //        let occlusionAnchor = occlusionPlanes[planeAnchor.identifier] {
        //         // Update the occlusion plane geometry when ARKit refines the plane
        //         updateOcclusionPlane(occlusionAnchor, with: planeAnchor)
        //     }
        // }
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Clean up any remaining occlusion planes
        for anchor in anchors {
            if let occlusionAnchor = occlusionPlanes[anchor.identifier] {
                occlusionAnchor.removeFromParent()
                occlusionPlanes.removeValue(forKey: anchor.identifier)
            }
        }
    }
    
    // Create an occlusion plane entity for a detected wall
    private func createOcclusionPlane(for planeAnchor: ARPlaneAnchor, in arView: ARView) {
        // Create anchor entity at the plane's position
        let anchorEntity = AnchorEntity(anchor: planeAnchor)
        
        // Create a mesh for the plane
        let planeMesh = MeshResource.generatePlane(
            width: planeAnchor.planeExtent.width,
            depth: planeAnchor.planeExtent.height
        )
        
        // Use OcclusionMaterial to make this plane occlude virtual objects behind it
        let occlusionMaterial = OcclusionMaterial()
        let occlusionEntity = ModelEntity(mesh: planeMesh, materials: [occlusionMaterial])
        
        // Rotate the plane to match the wall orientation
        // Vertical planes need to be rotated 90 degrees around X axis
        occlusionEntity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        
        anchorEntity.addChild(occlusionEntity)
        arView.scene.addAnchor(anchorEntity)
        
        occlusionPlanes[planeAnchor.identifier] = anchorEntity
        
        print("🧱 Created occlusion plane for wall at: \(planeAnchor.center)")
    }
    
    // Update occlusion plane when ARKit refines the plane geometry
    private func updateOcclusionPlane(_ anchorEntity: AnchorEntity, with planeAnchor: ARPlaneAnchor) {
        guard let occlusionEntity = anchorEntity.children.first as? ModelEntity else { return }
        
        // Update the mesh to match the refined plane dimensions
        let updatedMesh = MeshResource.generatePlane(
            width: planeAnchor.planeExtent.width,
            depth: planeAnchor.planeExtent.height
        )
        occlusionEntity.model?.mesh = updatedMesh
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("❌ AR Session failed: \(error.localizedDescription)")
        // Try to restart the session
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking])
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        print("⚠️ AR Session was interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        print("✅ AR Session interruption ended, restarting...")
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking])
        }
    }
    
    // MARK: - Loot Box Placement
    private func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame,
              let userLocation = userLocationManager?.currentLocation,
              let originLocation = arOriginLocation ?? userLocationManager?.currentLocation else {
            // Fallback: place in front of camera if we don't have GPS
            placeLootBoxInFrontOfCamera(location: location, in: arView)
            return
        }
        
        // Calculate offset from AR origin GPS to loot box GPS location
        let lootBoxGPSLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let offset = calculateGPSOffset(from: originLocation, to: lootBoxGPSLocation)
        
        // ARKit's coordinate system:
        // - Origin (0,0,0) is where tracking started
        // - X axis: typically right/east
        // - Y axis: up
        // - Z axis: forward (but direction depends on initial orientation)
        
        // Place box at GPS offset relative to AR origin (0,0,0)
        // Convert GPS offset (north/east in meters) to AR world coordinates
        // Note: We'll use X for east, Z for north (negative Z typically = forward/north in ARKit)
        let targetXZ = SIMD3<Float>(
            Float(offset.east),   // East = X axis
            0.0,                  // Will be set by raycast
            -Float(offset.north)  // North = -Z axis (negative because +Z is typically forward/south)
        )
        
        // Check distance from AR origin (0,0,0) - must be at least 5m
        let distanceFromOrigin = length(SIMD3<Float>(targetXZ.x, 0, targetXZ.z))
        if distanceFromOrigin < 5.0 {
            print("⚠️ Skipping \(location.name) - too close to AR origin (\(String(format: "%.2f", distanceFromOrigin))m < 5m)")
            return
        }
        
        // Also check distance from current camera position
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let distanceFromCamera = length(SIMD3<Float>(targetXZ.x, 0, targetXZ.z) - SIMD3<Float>(cameraPos.x, 0, cameraPos.z))
        if distanceFromCamera < 5.0 {
            print("⚠️ Skipping \(location.name) - too close to camera (\(String(format: "%.2f", distanceFromCamera))m < 5m)")
            return
        }
        
        // Use raycasting to find the ground plane at this X/Z position
        // Start raycast from above the target position (at camera height or higher)
        let raycastOrigin = SIMD3<Float>(targetXZ.x, cameraPos.y + 1.0, targetXZ.z)
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0), // Point downward
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        let raycastResults = arView.session.raycast(raycastQuery)
        var groundY: Float = 0.0
        
        if let result = raycastResults.first {
            // Use the hit point on the ground plane
            groundY = result.worldTransform.columns.3.y
        } else {
            // No plane detected, estimate ground level (assume AR origin is at ground)
            groundY = 0.0
            print("⚠️ No ground plane detected at \(location.name), using estimated ground level")
        }
        
        // Final position on ground plane
        let boxPosition = SIMD3<Float>(targetXZ.x, groundY, targetXZ.z)
        
        var boxTransform = matrix_identity_float4x4
        boxTransform.columns.3 = SIMD4<Float>(boxPosition.x, boxPosition.y, boxPosition.z, 1.0)
        
        let anchor = AnchorEntity(world: boxTransform)
        // Get random size between min and max from location manager (in meters)
        // Size multiplier scales the base size to the desired final size
        let randomSize = locationManager?.getRandomLootBoxSize() ?? 0.3
        let baseSize = Float(location.type.size) // Base size (0.3-0.5m)
        
        // Clamp random size to reasonable range and calculate multiplier
        let clampedSize = max(0.1, min(Float(randomSize), 1.5)) // Clamp between 0.1m and 1.5m
        let sizeMultiplier = clampedSize / baseSize
        
        let lootBoxContainer = LootBoxEntity.createLootBox(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
        
        // Position object so bottom sits on ground plane
        // The object's origin is typically at its center, so we need to move it up by half its height
        // Different object types have different heights
        let objectHeight: Float
        switch location.type {
        case .crystalSkull:
            objectHeight = baseSize * sizeMultiplier * 0.7 // Skull is roughly 0.7x its base size in height
        case .goldenIdol:
            objectHeight = baseSize * sizeMultiplier * 0.6 // Chalice is roughly 0.6x its base size in height
        default:
            objectHeight = baseSize * sizeMultiplier * 0.6 // Boxes are roughly 0.6x their base size in height
        }
        lootBoxContainer.container.position.y = objectHeight / 2.0
        
        // Ensure object is right-side up (not upside down)
        lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        
        anchor.addChild(lootBoxContainer.container)
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        
        // Store container info for opening animation
        var info = LootBoxInfoComponent()
        info.container = lootBoxContainer
        anchor.components[LootBoxInfoComponent.self] = info
        
        let distance = originLocation.distance(from: lootBoxGPSLocation)
        print("✅ Placed \(location.name) at GPS: \(location.latitude), \(location.longitude)")
        print("   Distance from AR origin: \(String(format: "%.2f", distance))m")
        print("   Offset: \(String(format: "%.2f", offset.north))m N, \(String(format: "%.2f", offset.east))m E")
        print("   AR world position: \(boxPosition)")
    }
    
    // Fallback: place in front of camera
    private func placeLootBoxInFrontOfCamera(location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        
        // Try to raycast to find ground plane at least 5m away
        let targetPosition = cameraPos + forward * 5.0
        let raycastOrigin = SIMD3<Float>(targetPosition.x, cameraPos.y, targetPosition.z)
        
        // Create raycast query to find horizontal plane
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0), // Point downward
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        let raycastResults = arView.session.raycast(raycastQuery)
        
        var boxPosition: SIMD3<Float>
        if let result = raycastResults.first {
            // Use the hit point on the ground plane
            let hitPoint = SIMD3<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z
            )
            
            // Check distance from camera
            let distanceFromCamera = length(hitPoint - cameraPos)
            if distanceFromCamera < 5.0 {
                // Too close, place at exactly 5m away
                let direction = normalize(hitPoint - cameraPos)
                boxPosition = cameraPos + direction * 5.0
                boxPosition.y = hitPoint.y // Use the ground plane Y
            } else {
                boxPosition = hitPoint
            }
        } else {
            // No plane detected, place 5m in front at estimated ground level
            boxPosition = cameraPos + forward * 5.0
            boxPosition.y = cameraPos.y - 1.5 // Assume camera is ~1.5m above ground
        }
        
        // Double-check minimum distance
        let finalDistance = length(boxPosition - cameraPos)
        if finalDistance < 5.0 {
            print("⚠️ Skipping \(location.name) - fallback placement too close to camera (\(String(format: "%.2f", finalDistance))m < 5m)")
            return
        }
        
        var boxTransform = matrix_identity_float4x4
        boxTransform.columns.3 = SIMD4<Float>(boxPosition.x, boxPosition.y, boxPosition.z, 1.0)
        
        let anchor = AnchorEntity(world: boxTransform)
        // Get random size between min and max from location manager (in meters)
        // Size multiplier scales the base size to the desired final size
        let randomSize = locationManager?.getRandomLootBoxSize() ?? 0.3
        let baseSize = Float(location.type.size) // Base size (0.3-0.5m)
        
        // Clamp random size to reasonable range and calculate multiplier
        let clampedSize = max(0.1, min(Float(randomSize), 1.5)) // Clamp between 0.1m and 1.5m
        let sizeMultiplier = clampedSize / baseSize
        
        let lootBoxContainer = LootBoxEntity.createLootBox(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
        
        // Position object so bottom sits on ground plane
        // Different object types have different heights
        let objectHeight: Float
        switch location.type {
        case .crystalSkull:
            objectHeight = baseSize * sizeMultiplier * 0.7 // Skull is roughly 0.7x its base size in height
        case .goldenIdol:
            objectHeight = baseSize * sizeMultiplier * 0.6 // Chalice is roughly 0.6x its base size in height
        default:
            objectHeight = baseSize * sizeMultiplier * 0.6 // Boxes are roughly 0.6x their base size in height
        }
        lootBoxContainer.container.position.y = objectHeight / 2.0
        
        // Ensure object is right-side up (not upside down)
        lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        
        anchor.addChild(lootBoxContainer.container)
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        
        // Store container info for opening animation
        var info = LootBoxInfoComponent()
        info.container = lootBoxContainer
        anchor.components[LootBoxInfoComponent.self] = info
        
        print("✅ Placed \(location.name) in front of camera at: \(boxPosition)")
        print("   Distance from camera: \(String(format: "%.2f", finalDistance))m")
    }
    
    // Update all existing loot boxes with new size settings
    func updateLootBoxSizes() {
        guard let arView = arView,
              let locationManager = locationManager,
              let originLocation = arOriginLocation else { return }
        
        print("🔄 Updating all loot box sizes...")
        
        for (locationId, anchor) in placedBoxes {
            // Find the location
            guard let location = locationManager.locations.first(where: { $0.id == locationId }) else { continue }
            
            // Remove old box
            anchor.removeFromParent()
            
            // Calculate new position (preserve existing X/Z position, but find ground plane)
            let currentTransform = anchor.transformMatrix(relativeTo: nil)
            let currentXZ = SIMD3<Float>(
                currentTransform.columns.3.x,
                0.0,
                currentTransform.columns.3.z
            )
            
            // Use raycasting to find the ground plane at this X/Z position
            guard let frame = arView.session.currentFrame else { continue }
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            
            let raycastOrigin = SIMD3<Float>(currentXZ.x, cameraPos.y + 1.0, currentXZ.z)
            let raycastQuery = ARRaycastQuery(
                origin: raycastOrigin,
                direction: SIMD3<Float>(0, -1, 0), // Point downward
                allowing: .estimatedPlane,
                alignment: .horizontal
            )
            
            let raycastResults = arView.session.raycast(raycastQuery)
            var groundY: Float = currentTransform.columns.3.y // Fallback to current Y
            
            if let result = raycastResults.first {
                groundY = result.worldTransform.columns.3.y
            }
            
            let currentPosition = SIMD3<Float>(currentXZ.x, groundY, currentXZ.z)
            
            // Create new box with updated size
            let randomSize = locationManager.getRandomLootBoxSize()
            let baseSize = Float(location.type.size)
            
            // Clamp random size to reasonable range and calculate multiplier
            let clampedSize = max(0.1, min(Float(randomSize), 1.5))
            let sizeMultiplier = clampedSize / baseSize
            
            let lootBoxContainer = LootBoxEntity.createLootBox(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
            
            // Position object so bottom sits on ground plane
            let objectHeight: Float
            switch location.type {
            case .crystalSkull:
                objectHeight = baseSize * sizeMultiplier * 0.7
            case .goldenIdol:
                objectHeight = baseSize * sizeMultiplier * 0.6
            default:
                objectHeight = baseSize * sizeMultiplier * 0.6
            }
            lootBoxContainer.container.position.y = objectHeight / 2.0
            
            // Ensure object is right-side up
            lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            
            // Create new anchor at same position
            var boxTransform = matrix_identity_float4x4
            boxTransform.columns.3 = SIMD4<Float>(currentPosition.x, currentPosition.y, currentPosition.z, 1.0)
            let newAnchor = AnchorEntity(world: boxTransform)
            
            newAnchor.addChild(lootBoxContainer.container)
            arView.scene.addAnchor(newAnchor)
            placedBoxes[locationId] = newAnchor
            
            // Store container info
            var info = LootBoxInfoComponent()
            info.container = lootBoxContainer
            newAnchor.components[LootBoxInfoComponent.self] = info
        }
        
        print("✅ Updated \(placedBoxes.count) loot box sizes")
    }
    
    // Calculate GPS offset in meters (north/south, east/west)
    private func calculateGPSOffset(from origin: CLLocation, to target: CLLocation) -> (north: Double, east: Double) {
        // Calculate distance and bearing
        let distance = origin.distance(from: target)
        let bearing = origin.bearing(to: target)
        
        // Convert bearing to north/east offset
        let northOffset = distance * cos(bearing * .pi / 180.0)
        let eastOffset = distance * sin(bearing * .pi / 180.0)
        
        return (north: northOffset, east: eastOffset)
    }
    
    // MARK: - Tap Handling
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        guard let arView = arView,
              let userLocation = userLocationManager?.currentLocation,
              let locationManager = locationManager else { return }
        
        let tapLocation = sender.location(in: arView)
        
        // Check if tapped on existing loot box
        if let entity = arView.entity(at: tapLocation) {
            let idString = entity.name
            
            // Try to find in location manager
            if let location = locationManager.locations.first(where: { $0.id == idString }) {
                // Check if user is within collection radius
                let distance = userLocation.distance(from: location.location)
                
                if distance <= location.radius {
                    // User is close enough - open the loot box with animation
                    if let anchor = placedBoxes[idString],
                       var info = anchor.components[LootBoxInfoComponent.self],
                       let container = info.container,
                       !info.isOpening {
                        info.isOpening = true
                        anchor.components[LootBoxInfoComponent.self] = info
                        
                        LootBoxAnimation.openLootBox(container: container, location: location) { [weak self] in
                            // Animation complete - mark as collected and remove
                            if let locationManager = self?.locationManager {
                                locationManager.markCollected(location.id)
                            }
                            
                            anchor.removeFromParent()
                            self?.placedBoxes.removeValue(forKey: location.id)
                            
                            print("🎉 Collected: \(location.name)")
                        }
                    }
                } else {
                    // User is too far away
                    print("⚠️ Too far away to collect \(location.name). Need to be within \(location.radius)m (currently \(String(format: "%.1f", distance))m away)")
                }
                return
            }
        }
        
        // If no location-based system or not at a location, allow manual placement
        // Place a test loot box where user taps (for testing without locations)
        if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first {
            let testLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: "Test Artifact",
                type: .crystalSkull,
                latitude: 0,
                longitude: 0,
                radius: 100
            )
            placeLootBoxAtLocation(testLocation, in: arView)
        }
    }
}

