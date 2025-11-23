import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import AVFoundation
import AudioToolbox

// Findable protocol and base class are now in FindableObject.swift

// MARK: - Object Types for Random Placement
enum PlacedObjectType {
    case chalice
    case treasureBox
    case sphere
}

// MARK: - AR Coordinator
class ARCoordinator: NSObject, ARSessionDelegate {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var placedBoxes: [String: AnchorEntity] = [:]
    private var findableObjects: [String: FindableObject] = [:] // Track all findable objects
    private var arOriginLocation: CLLocation? // GPS location when AR session started
    private var distanceLogger: Timer?
    private var previousDistance: Double?
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var collectionNotificationBinding: Binding<String?>?
    private var proximitySoundPlayed: Set<String> = [] // Track which boxes have played proximity sound
    private var foundLootBoxes: Set<String> = [] // Track which boxes have been found (to avoid duplicate finds)
    private var occlusionPlanes: [UUID: AnchorEntity] = [:] // Track occlusion planes for walls
    private var occlusionCheckTimer: Timer? // Timer for checking occlusion
    private var distanceTextEntities: [String: ModelEntity] = [:] // Track distance text entities for each loot box
    
    override init() {
        super.init()
    }
    
    func setupARView(_ arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearbyLocations: Binding<[LootBoxLocation]>, distanceToNearest: Binding<Double?>, temperatureStatus: Binding<String?>, collectionNotification: Binding<String?>) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.nearbyLocationsBinding = nearbyLocations
        self.distanceToNearestBinding = distanceToNearest
        self.temperatureStatusBinding = temperatureStatus
        self.collectionNotificationBinding = collectionNotification
        
        // Set up callback for size changes
        locationManager.onSizeChanged = { [weak self] () -> Void in
            self?.updateLootBoxSizes()
        }
        
        // Store the GPS location when AR starts (this becomes our AR world origin)
        arOriginLocation = userLocationManager.currentLocation
        
        // Monitor AR session
        arView.session.delegate = self
        
        // Start distance logging timer
        startDistanceLogging()
        
        // Clean up any existing occlusion planes once at startup (they were causing dark boxes)
        // No need for periodic cleanup since we're not creating new occlusion planes anymore
        removeAllOcclusionPlanes()
        
        // Start occlusion checking to hide loot boxes behind walls
        startOcclusionChecking()
    }
    
    // Remove all existing occlusion planes
    private func removeAllOcclusionPlanes(quiet: Bool = false) {
        guard let arView = arView else { return }
        
        var removedCount = 0
        
        // Remove all tracked occlusion planes
        removedCount += occlusionPlanes.count
        for (_, anchor) in occlusionPlanes {
            anchor.removeFromParent()
        }
        occlusionPlanes.removeAll()
        
        // Also remove any orphaned occlusion planes from the scene
        // Iterate over all anchors in the scene and check for occlusion entities
        let anchors = Array(arView.scene.anchors)
        for anchor in anchors {
            // Remove occlusion entities recursively
            removeOcclusionEntities(from: anchor, removedCount: &removedCount)
            
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
                    if !quiet {
                        Swift.print("🗑️ Removing occlusion-only anchor")
                    }
                    anchorEntity.removeFromParent()
                    removedCount += 1
                }
            }
        }
        
        // Only print if something was removed or if not in quiet mode
        if removedCount > 0 {
            if !quiet {
                Swift.print("🧹 Removed \(removedCount) occlusion plane(s)")
            }
        } else if !quiet {
            Swift.print("🧹 Removed all occlusion planes")
        }
    }
    
    // Recursively find and remove any entities with OcclusionMaterial or suspiciously large planes
    private func removeOcclusionEntities(from entity: Entity, removedCount: inout Int) {
        // Make a copy of children array before iterating (to avoid mutation issues)
        let children = Array(entity.children)
        
        // First, recursively process children
        for child in children {
            removeOcclusionEntities(from: child, removedCount: &removedCount)
        }
        
        // Then check this entity itself
        if let modelEntity = entity as? ModelEntity,
           let model = modelEntity.model {
            // Check if any material is OcclusionMaterial
            if model.materials.contains(where: { $0 is OcclusionMaterial }) {
                let entityName = entity.name.isEmpty ? "unnamed" : entity.name
                print("🗑️ Found and removing occlusion entity: \(entityName)")
                entity.removeFromParent()
                removedCount += 1
                return
            }
            
            // Also check for suspiciously large plane meshes (likely ceiling planes)
            let mesh = model.mesh
                let bounds = mesh.bounds
                let size = bounds.extents
                let maxDimension = max(size.x, max(size.y, size.z))
                if maxDimension > 3.0 {
                    let entityName = entity.name.isEmpty ? "unnamed" : entity.name
                    print("🗑️ Found and removing large plane entity (likely ceiling): \(entityName), size=\(String(format: "%.2f", maxDimension))m")
                    entity.removeFromParent()
                    removedCount += 1
                    return
            }
        }
    }
    
    // MARK: - Occlusion Detection
    // Use raycasting to detect walls and hide loot boxes behind them
    private func startOcclusionChecking() {
        // Check occlusion periodically (every 0.2 seconds = 5 times per second)
        occlusionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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
        
        // Update distance texts for all loot boxes
        updateDistanceTexts()
        
        // Check each placed loot box for occlusion and camera collision
        for (locationId, anchor) in placedBoxes {
            // Get anchor position in world space
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let anchorPosition = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )

            // Find the actual loot box position (not just anchor position)
            // Loot boxes are positioned with Y offset relative to anchor
            var lootBoxPosition = anchorPosition
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.name == locationId {
                    // This is the loot box container - get its world position
                    let lootBoxTransform = modelEntity.transformMatrix(relativeTo: nil)
                    lootBoxPosition = SIMD3<Float>(
                        lootBoxTransform.columns.3.x,
                        lootBoxTransform.columns.3.y,
                        lootBoxTransform.columns.3.z
                    )
                    break
                }
            }

            // Use the actual loot box position for distance calculations
            let direction = lootBoxPosition - cameraPosition
            let distance = length(direction)
            
            // PROXIMITY DETECTION: Auto-find when within 1m of loot box
            let findDistance: Float = 1.0 // 1 meter threshold for finding
            
            // Check if camera is within 1m of the loot box
            if distance <= findDistance && !foundLootBoxes.contains(locationId) {
                // Find the sphere entity for animation
                var sphereEntity: ModelEntity? = nil
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity,
                       modelEntity.components[PointLightComponent.self] != nil {
                        sphereEntity = modelEntity
                        break
                    }
                }
                
                // Trigger finding (sound, confetti, animation, increment count)
                findLootBox(locationId: locationId, anchor: anchor, cameraPosition: cameraPosition, sphereEntity: sphereEntity)
                continue // Skip occlusion check
            }
            
            // COLLISION DETECTION: Hide objects when camera is too close (within their boundary)
            // Loot box size: 0.3m total (0.15m radius), sphere: 0.15m radius
            // Add 0.1m buffer to prevent camera from entering boundary
            let lootBoxRadius: Float = 0.15 // Half of 0.3m total size
            let sphereRadius: Float = 0.15 // Sphere indicator radius
            let buffer: Float = 0.1 // Safety buffer
            let minDistanceForLootBox = lootBoxRadius + buffer
            let minDistanceForSphere = sphereRadius + buffer

            // Check if camera is too close to the actual loot box position
            var isCameraTooClose = false
            if distance < minDistanceForLootBox {
                isCameraTooClose = true
            }
            
            // Also check distance to sphere indicator (positioned above the box)
            var spherePosition = anchorPosition
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.components[PointLightComponent.self] != nil {
                    // This is the sphere - get its world position
                    let sphereTransform = modelEntity.transformMatrix(relativeTo: nil)
                    spherePosition = SIMD3<Float>(
                        sphereTransform.columns.3.x,
                        sphereTransform.columns.3.y,
                        sphereTransform.columns.3.z
                    )
                    let sphereDistance = length(spherePosition - cameraPosition)
                    if sphereDistance < minDistanceForSphere {
                        isCameraTooClose = true
                    }
                    break
                }
            }
            
            // If camera is too close, hide all children to prevent camera from appearing inside
            if isCameraTooClose {
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        modelEntity.isEnabled = false
                    } else {
                        child.isEnabled = false
                    }
                }
                continue // Skip occlusion check if camera is too close
            }
            
            // Skip occlusion check if box is too far
            guard distance > 0.1 && distance < 50.0 else {
                // Show all children if too far (no occlusion check needed)
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        modelEntity.isEnabled = true
                    } else {
                        child.isEnabled = true
                    }
                }
                continue
            }
            
            let normalizedDirection = direction / distance

            // Perform raycast from camera to actual loot box position to check for walls
            // Use vertical plane detection to find walls
            let raycastQuery = ARRaycastQuery(
                origin: cameraPosition,
                direction: normalizedDirection,
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
                if hitDistance < distance - 0.3 { // 0.3m tolerance
                    isOccluded = true
                    break
                }
            }
            
            // Show/hide all children (loot box container and orb indicator) based on occlusion
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity {
                    modelEntity.isEnabled = !isOccluded
                } else {
                    child.isEnabled = !isOccluded
                }
            }
        }
    }
    
    private func startDistanceLogging() {
        // Check every 0.5 seconds for more responsive warmer/colder feedback
        distanceLogger = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.logDistanceToNearestLootBox()
        }
    }
    
    private func logDistanceToNearestLootBox() {
        // Try to use AR world coordinates first (more accurate for AR), fallback to GPS
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            // Fallback to GPS if AR not available
            guard let userLocation = userLocationManager?.currentLocation else {
                DispatchQueue.main.async { [weak self] in
                    self?.distanceToNearestBinding?.wrappedValue = nil
                    self?.temperatureStatusBinding?.wrappedValue = nil
                }
                return
            }
            calculateDistanceUsingGPS(userLocation: userLocation)
            return
        }
        
        // Use AR world coordinates for more accurate distance calculation
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Find nearest uncollected loot box in AR world space
        var nearestBox: (location: LootBoxLocation, distance: Double, anchor: AnchorEntity)? = nil
        var minDistance: Double = Double.infinity
        
        // Check all placed boxes in AR space
        for (locationId, anchor) in placedBoxes {
            // Find the location for this box
            guard let location = locationManager.locations.first(where: { $0.id == locationId && !$0.collected }) else {
                continue
            }
            
            // Get anchor position in AR world space
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let anchorPosition = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )
            
            // Find the sphere indicator position (more visible and accurate - this is what user sees)
            // The sphere is positioned above the loot box
            var spherePosition = anchorPosition
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.name == locationId,
                   modelEntity.components[PointLightComponent.self] != nil {
                    // This is the orange sphere - get its world position
                    let sphereTransform = modelEntity.transformMatrix(relativeTo: nil)
                    spherePosition = SIMD3<Float>(
                        sphereTransform.columns.3.x,
                        sphereTransform.columns.3.y,
                        sphereTransform.columns.3.z
                    )
                    break
                }
            }
            
            // Calculate distance in AR world space (meters) - use sphere position for accuracy
            let distance = Double(length(spherePosition - cameraPosition))
            
            if distance < minDistance {
                minDistance = distance
                nearestBox = (location: location, distance: distance, anchor: anchor)
            }
        }
        
        // If we found a box in AR space, use that
        if let nearest = nearestBox {
            updateTemperatureStatus(currentDistance: nearest.distance, location: nearest.location)
            return
        }
        
        // Fallback to GPS if no boxes are placed in AR yet
        if let userLocation = userLocationManager?.currentLocation {
            calculateDistanceUsingGPS(userLocation: userLocation)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
        }
    }
    
    // Helper to calculate distance using GPS coordinates
    private func calculateDistanceUsingGPS(userLocation: CLLocation) {
        guard let locationManager = locationManager else {
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        // Check if we have a valid GPS fix (horizontal accuracy should be reasonable)
        guard userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 100 else {
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        // Find nearest uncollected loot box using GPS
        let uncollectedLocations = locationManager.locations.filter { !$0.collected }
        guard !uncollectedLocations.isEmpty else {
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
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
            }
            return
        }
        
        updateTemperatureStatus(currentDistance: nearest.distance, location: nearest.location)
    }
    
    // Helper function to convert meters to feet and inches
    private func metersToFeetAndInches(_ meters: Double) -> (feet: Int, inches: Int) {
        let totalInches = meters * 39.3701 // 1 meter = 39.3701 inches
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        return (feet: feet, inches: inches)
    }
    
    // Helper function to format distance as feet and inches string
    private func formatDistance(_ meters: Double) -> String {
        let (feet, inches) = metersToFeetAndInches(meters)
        if feet == 0 {
            return "\(inches)\""
        } else if inches == 0 {
            return "\(feet)'"
        } else {
            return "\(feet)'\(inches)\""
        }
    }
    
    // Update temperature status based on distance change
    private func updateTemperatureStatus(currentDistance: Double, location: LootBoxLocation) {
        // Log distance in both meters and feet/inches for debugging
        let (feet, inches) = metersToFeetAndInches(currentDistance)
        Swift.print("📏 Distance to nearest loot box (\(location.name)): \(String(format: "%.2f", currentDistance))m (\(feet)'\(inches)\")")
        
        // Update temperature status with distance included (only show distance when we have a comparison)
        var status: String?
        if let previous = previousDistance {
            // We have a previous distance to compare - show warmer/colder with distance
            // Use a threshold to avoid flickering (only show change if difference is significant)
            // 1.5 feet threshold (approximately 0.46m)
            let threshold: Double = 0.46 // ~1.5 feet
            if currentDistance < previous - threshold {
                let distanceStr = formatDistance(currentDistance)
                status = "🔥 Warmer (\(distanceStr))"
                let (prevFeet, prevInches) = metersToFeetAndInches(previous)
                Swift.print("   🔥 Getting warmer! (was \(prevFeet)'\(prevInches)\")")
            } else if currentDistance > previous + threshold {
                let distanceStr = formatDistance(currentDistance)
                status = "❄️ Colder (\(distanceStr))"
                let (prevFeet, prevInches) = metersToFeetAndInches(previous)
                Swift.print("   ❄️ Getting colder... (was \(prevFeet)'\(prevInches)\")")
            } else {
                // Within threshold - keep previous status or show same distance
                let distanceStr = formatDistance(currentDistance)
                status = "➡️ \(distanceStr)"
            }
            previousDistance = currentDistance
        } else {
            // First reading - don't show distance yet, just store it for next comparison
            previousDistance = currentDistance
            status = nil // Don't show anything until we have a comparison
        }
        
        // Check for proximity (within 3 feet = ~0.91m) - play sound only (no auto-collection)
        // User must tap to collect boxes
        if currentDistance <= 0.91 && !proximitySoundPlayed.contains(location.id) {
            playProximitySound()
            proximitySoundPlayed.insert(location.id)
            // NOTE: Auto-collection disabled - user must tap to collect
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
        guard let arView = arView else { return }
        
        for location in nearbyLocations {
            // Place box if it's nearby (within maxSearchDistance), hasn't been placed, and isn't collected
            // The box will appear in AR when you're within the search distance
            if placedBoxes[location.id] == nil && !location.collected {
                placeLootBoxAtLocation(location, in: arView)
            }
        }
    }
    
    // Regenerate loot boxes at random locations in the AR room
    func randomizeLootBoxes() {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            Swift.print("⚠️ Cannot randomize: AR not ready")
            return
        }
        
        // Remove all existing placed boxes
        for (_, anchor) in placedBoxes {
            anchor.removeFromParent()
        }
        placedBoxes.removeAll()
        
        // Get available loot box types
        let lootBoxTypes: [LootBoxType] = [.goldenIdol, .ancientArtifact, .templeRelic, .puzzleBox, .stoneTablet]
        let lootBoxNames = ["Golden Idol", "Ancient Artifact", "Temple Relic", "Puzzle Box", "Stone Tablet"]
        
        // Generate 3-5 new loot boxes at random positions
        let numberOfBoxes = Int.random(in: 3...5)
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Get search distance for placement range
        let searchDistance = Float(locationManager.maxSearchDistance)
        let minDistance: Float = 5.0 // Minimum 5 meters from camera
        let maxDistance: Float = min(searchDistance * 0.8, 50.0)
        
        Swift.print("🎲 Randomizing \(numberOfBoxes) loot boxes in AR room...")
        
        var placedCount = 0
        var attempts = 0
        let maxAttempts = numberOfBoxes * 10 // Allow more attempts for placement
        
        while placedCount < numberOfBoxes && attempts < maxAttempts {
            attempts += 1
            
            // Generate random position around camera
            let randomDistance = Float.random(in: minDistance...maxDistance)
            let randomAngle = Float.random(in: 0...(2 * Float.pi))
            
            let randomX = cameraPos.x + randomDistance * cos(randomAngle)
            let randomZ = cameraPos.z + randomDistance * sin(randomAngle)
            
            // Raycast to find floor
            let raycastOrigin = SIMD3<Float>(randomX, cameraPos.y + 1.0, randomZ)
            let raycastQuery = ARRaycastQuery(
                origin: raycastOrigin,
                direction: SIMD3<Float>(0, -1, 0),
                allowing: .estimatedPlane,
                alignment: .horizontal
            )
            
            let raycastResults = arView.session.raycast(raycastQuery)
            
            guard let result = raycastResults.first else {
                continue
            }
            
            let hitY = result.worldTransform.columns.3.y
            let cameraY = cameraPos.y
            
            // Reject ceiling hits or floors too far away
            if hitY > cameraY - 0.2 || abs(hitY - cameraY) > 2.0 {
                continue
            }
            
            let boxPosition = SIMD3<Float>(randomX, hitY, randomZ)
            let distanceFromCamera = length(boxPosition - cameraPos)

            // CRITICAL: Enforce MINIMUM 1m distance from camera to prevent large objects spawning on/near camera
            if distanceFromCamera < 1.0 {
                // Too close to camera - skip this position
                continue
            }

            if distanceFromCamera < minDistance || distanceFromCamera > maxDistance {
                continue
            }
            
            // Check if too close to other boxes
            var tooClose = false
            for (_, existingAnchor) in placedBoxes {
                let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
                let existingPos = SIMD3<Float>(
                    existingTransform.columns.3.x,
                    existingTransform.columns.3.y,
                    existingTransform.columns.3.z
                )
                if length(boxPosition - existingPos) < 1.5 {
                    tooClose = true
                    break
                }
            }
            
            if tooClose {
                continue
            }
            
            // Create a new temporary location for this box
            let randomIndex = Int.random(in: 0..<lootBoxTypes.count)
            let newLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: lootBoxNames[randomIndex],
                type: lootBoxTypes[randomIndex],
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0 // Large radius since we're not using GPS
            )
            
            // Place the box
            placeBoxAtPosition(boxPosition, location: newLocation, in: arView)
            placedCount += 1
        }
        
        Swift.print("✅ Randomized and placed \(placedCount) loot boxes")
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Set AR origin on first frame if not set
        if arOriginLocation == nil,
           let userLocation = userLocationManager?.currentLocation {
            arOriginLocation = userLocation
            Swift.print("📍 AR Origin set at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
        }
        
        // Check for nearby locations when AR is tracking
        if frame.camera.trackingState == .normal,
           let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
        }
    }
    
    // Handle AR anchor updates - remove any unwanted plane anchors (especially ceilings)
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        for anchor in anchors {
            // Remove all horizontal plane anchors (floors/ceilings) - we don't need them
            // ARKit's plane detection is causing issues with ceiling detection
            if let planeAnchor = anchor as? ARPlaneAnchor {
                if planeAnchor.alignment == .horizontal {
                    // Check if this plane is above the camera (likely a ceiling)
                    let planeY = planeAnchor.transform.columns.3.y
                    let planeHeight = planeAnchor.planeExtent.height
                    let planeWidth = planeAnchor.planeExtent.width
                    
                    // Remove if it's above camera or if it's suspiciously large (likely a ceiling)
                    if planeY > cameraPos.y || (planeHeight > 5.0 || planeWidth > 5.0) {
                        Swift.print("🗑️ Removing horizontal plane anchor (likely ceiling): Y=\(String(format: "%.2f", planeY)), size=\(String(format: "%.2f", planeWidth))x\(String(format: "%.2f", planeHeight))")
                        // Remove the anchor by not adding it to the scene
                        // ARKit will handle cleanup
                    }
                }
                // Disabled: Don't create occlusion planes for vertical planes (was causing dark boxes everywhere)
                // if planeAnchor.alignment == .vertical {
                //     createOcclusionPlane(for: planeAnchor, in: arView)
                // }
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Disabled: No longer updating occlusion planes (was causing dark boxes)
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
        
        Swift.print("🧱 Created occlusion plane for wall at: \(planeAnchor.center)")
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
        Swift.print("❌ AR Session failed: \(error.localizedDescription)")
        // Try to restart the session
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for wall detection (occlusion)
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking])
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        Swift.print("⚠️ AR Session was interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        Swift.print("✅ AR Session interruption ended, restarting...")
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for wall detection (occlusion)
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking])
        }
    }
    
    // MARK: - Loot Box Placement
    private func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ No AR frame available for \(location.name)")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Place boxes within the same room by finding floor planes near the camera
        // Try multiple random positions around the camera within the search distance
        var attempts = 0
        let maxAttempts = 10

        while attempts < maxAttempts {
            attempts += 1

            // Generate random position around camera using settings from maxSearchDistance
            // Use min 5m to avoid being too close to camera, max 80% of search distance to stay within room
            let minDistance: Float = 5.0 // Minimum 5 meters from camera
            let searchDistance = Float(locationManager?.maxSearchDistance ?? 100.0)
            let maxDistance: Float = min(searchDistance * 0.8, 50.0) // Cap at 50m for practical AR limits
            let randomDistance = Float.random(in: minDistance...maxDistance)
            let randomAngle = Float.random(in: 0...(2 * Float.pi))
            
            // Calculate random position in XZ plane around camera
            let randomX = cameraPos.x + randomDistance * cos(randomAngle)
            let randomZ = cameraPos.z + randomDistance * sin(randomAngle)
            
            // Raycast downward from above this position to find the floor
            let raycastOrigin = SIMD3<Float>(randomX, cameraPos.y + 1.0, randomZ)
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0), // Point downward
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        let raycastResults = arView.session.raycast(raycastQuery)
            
            guard let result = raycastResults.first else {
                // No floor plane detected at this position, try another
                continue
            }
            
            let hitY = result.worldTransform.columns.3.y
            let cameraY = cameraPos.y
            
            // Reject if hit is above camera (likely ceiling) or too far below (likely wrong floor)
            if hitY > cameraY - 0.2 {
                // Likely a ceiling hit
                continue
            }
            
            // Check if floor is at a reasonable level (within 2 meters of camera height)
            if abs(hitY - cameraY) > 2.0 {
                // Floor too far from camera level, likely different floor
                continue
            }
            
            var boxPosition = SIMD3<Float>(randomX, hitY, randomZ)

            // CRITICAL: Enforce MINIMUM 1m distance from camera to prevent large objects spawning on/near camera
            let distanceFromCamera = length(boxPosition - cameraPos)
            if distanceFromCamera < 1.0 {
                // Too close to camera - skip this position
                continue
            }

            // BASIC FINDABLE BEHAVIOR: Ensure minimum distance from camera (5m)
            // Use FindableObject's static method to enforce minimum distance
            if let adjustedPosition = FindableObject.ensureMinimumDistance(from: boxPosition, to: cameraPos, minDistance: minDistance) {
                boxPosition = adjustedPosition
            } else {
                // Position is too close, skip this attempt
                continue
            }

            // Check distance from camera (use the same limits as placement)
            let finalDistanceFromCamera = length(boxPosition - cameraPos)
            if finalDistanceFromCamera > maxDistance {
                continue
            }
            
            // Check if position is too close to other boxes
            var tooCloseToOtherBox = false
            for (_, existingAnchor) in placedBoxes {
                let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
                let existingPos = SIMD3<Float>(
                    existingTransform.columns.3.x,
                    existingTransform.columns.3.y,
                    existingTransform.columns.3.z
                )
                let distanceToExisting = length(boxPosition - existingPos)
                if distanceToExisting < 1.5 {
                    tooCloseToOtherBox = true
                    break
                }
            }
            
            if tooCloseToOtherBox {
                continue
            }
            
            // Found a good position! Place the box here
            placeBoxAtPosition(boxPosition, location: location, in: arView)
            return
        }
        
        // If we couldn't find a good position after max attempts, try fallback
        Swift.print("⚠️ Could not find suitable floor plane for \(location.name) after \(maxAttempts) attempts, using fallback")
        placeLootBoxInFrontOfCamera(location: location, in: arView)
    }
    
    // Helper method to place a randomly selected object at a specific position
    private func placeBoxAtPosition(_ boxPosition: SIMD3<Float>, location: LootBoxLocation, in arView: ARView) {
        // CRITICAL: Final safety check - ensure minimum 1m distance from camera
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place box: no AR frame available")
            return
        }
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let distanceFromCamera = length(boxPosition - cameraPos)

        if distanceFromCamera < 1.0 {
            Swift.print("⚠️ Rejected placement of \(location.name) - too close to camera (\(String(format: "%.2f", distanceFromCamera))m)")
            return
        }

        var boxTransform = matrix_identity_float4x4
        boxTransform.columns.3 = SIMD4<Float>(boxPosition.x, boxPosition.y, boxPosition.z, 1.0)
        
        let anchor = AnchorEntity(world: boxTransform)
        
        // Randomly choose what type of object to place (chalice, treasure box, or sphere)
        let objectTypes: [PlacedObjectType] = [.chalice, .treasureBox, .sphere]
        let selectedObjectType = objectTypes.randomElement()!

        Swift.print("🎲 Placing \(selectedObjectType) for \(location.name)")

        var placedEntity: ModelEntity? = nil
        var findableObject: FindableObject? = nil

        switch selectedObjectType {
        case .chalice:
            // Place a chalice
            let targetSize = Float.random(in: 0.3...1.0) // Random size
            let sizeMultiplier = targetSize / 0.3 // Base size for golden idol
            let lootBoxContainer = ChaliceLootContainer.create(type: .goldenIdol, id: location.id, sizeMultiplier: sizeMultiplier)

            // Position chalice so bottom sits on ground
            let objectHeight = targetSize * 0.6
            lootBoxContainer.container.position.y = objectHeight / 2.0
            lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))

            placedEntity = lootBoxContainer.container

            findableObject = FindableObject(
                locationId: location.id,
                anchor: anchor,
                sphereEntity: nil, // No sphere for chalice-only placement
                container: lootBoxContainer,
                location: location
            )

        case .treasureBox:
            // Place a treasure box
            let targetSize = Float.random(in: 0.3...1.0) // Random size
            let randomBoxType: LootBoxType = [.ancientArtifact, .templeRelic, .puzzleBox, .stoneTablet].randomElement()!
            let sizeMultiplier = targetSize / Float(randomBoxType.size)
            let lootBoxContainer = LootBoxEntity.createLootBox(type: randomBoxType, id: location.id, sizeMultiplier: sizeMultiplier)

            // Position treasure box so bottom sits on ground
            let objectHeight = targetSize * 0.6
            lootBoxContainer.container.position.y = objectHeight / 2.0
            lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))

            placedEntity = lootBoxContainer.container

            findableObject = FindableObject(
                locationId: location.id,
                anchor: anchor,
                sphereEntity: nil, // No sphere for treasure box-only placement
                container: lootBoxContainer,
                location: location
            )

        case .sphere:
            // Place just a sphere indicator (no loot box)
            let indicatorSize: Float = 0.15 // 15cm sphere
            let indicatorMesh = MeshResource.generateSphere(radius: indicatorSize)
            var indicatorMaterial = SimpleMaterial()
            indicatorMaterial.color = .init(tint: .orange)
            indicatorMaterial.roughness = 0.2
            indicatorMaterial.metallic = 0.3

            let orangeIndicator = ModelEntity(mesh: indicatorMesh, materials: [indicatorMaterial])
            orangeIndicator.name = location.id

            // Position sphere at ground level (no loot box underneath)
            orangeIndicator.position = SIMD3<Float>(0, indicatorSize, 0) // Bottom of sphere touches ground

            // Add point light to make it visible
            let light = PointLightComponent(color: .orange, intensity: 200)
            orangeIndicator.components.set(light)

            placedEntity = orangeIndicator

            findableObject = FindableObject(
                locationId: location.id,
                anchor: anchor,
                sphereEntity: orangeIndicator, // The sphere itself is the findable object
                container: nil, // No loot box container
                location: location
            )
        }

        // Add the placed entity to the anchor
        if let entity = placedEntity {
            anchor.addChild(entity)
        }

        // Store the anchor and findable object
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor

        // DEBUG: Log final world positions
        let finalAnchorTransform = anchor.transformMatrix(relativeTo: nil)
        let finalAnchorPos = SIMD3<Float>(
            finalAnchorTransform.columns.3.x,
            finalAnchorTransform.columns.3.y,
            finalAnchorTransform.columns.3.z
        )

        Swift.print("✅ Placed \(selectedObjectType) at AR position: \(finalAnchorPos)")

        // Set callback to increment found count
        findableObject?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        if let findableObj = findableObject {
            findableObjects[location.id] = findableObj
        }
    }
    
    // MARK: - Distance Text Overlay
    /// Creates a 3D text entity for displaying distance
    private func createDistanceTextEntity() -> ModelEntity {
        // Create a small plane for the text
        let textPlaneSize: Float = 0.2 // 20cm plane
        let textMesh = MeshResource.generatePlane(width: textPlaneSize, depth: textPlaneSize * 0.3)
        
        // Create initial text texture (will be updated)
        let textMaterial = createTextMaterial(text: "0'0\"")
        
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        textEntity.name = "distanceText"
        
        // Make text always face camera (billboard effect)
        // We'll update orientation in the update function
        
        return textEntity
    }
    
    /// Creates a material with text rendered on it
    private func createTextMaterial(text: String) -> SimpleMaterial {
        // Create text image
        let fontSize: CGFloat = 48
        let font = UIFont.boldSystemFont(ofSize: fontSize)
        let textColor = UIColor.white
        let backgroundColor = UIColor.black.withAlphaComponent(0.7)
        
        // Calculate text size
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedString.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        
        // Create image with padding
        let padding: CGFloat = 20
        let imageSize = CGSize(
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let image = renderer.image { context in
            // Draw background
            backgroundColor.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: imageSize))
            
            // Draw text
            let textRect = CGRect(
                x: padding,
                y: padding,
                width: textSize.width,
                height: textSize.height
            )
            attributedString.draw(in: textRect)
        }
        
        // Create material from image
        var material = SimpleMaterial()
        if let cgImage = image.cgImage {
            do {
                let texture = try TextureResource(image: cgImage, options: .init(semantic: .color))
                material.color = .init(texture: .init(texture))
            } catch {
                print("⚠️ Failed to create texture from text: \(error)")
                material.color = .init(tint: .white)
            }
        }
        material.roughness = 0.1
        material.metallic = 0.0
        
        return material
    }
    
    /// Updates the distance text for all loot boxes
    private func updateDistanceTexts() {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Update distance text for each loot box
        for (locationId, anchor) in placedBoxes {
            // Skip if already found
            if foundLootBoxes.contains(locationId) {
                continue
            }
            
            guard let textEntity = distanceTextEntities[locationId] else { continue }
            
            // Get box position (use sphere position if available, otherwise anchor position)
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            var boxPosition = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )
            
            // Try to find sphere position (more accurate)
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.components[PointLightComponent.self] != nil {
                    let sphereTransform = modelEntity.transformMatrix(relativeTo: nil)
                    boxPosition = SIMD3<Float>(
                        sphereTransform.columns.3.x,
                        sphereTransform.columns.3.y,
                        sphereTransform.columns.3.z
                    )
                    break
                }
            }
            
            // Calculate distance
            let distance = Double(length(boxPosition - cameraPosition))
            
            // Format as feet and inches
            let distanceText = formatDistance(distance)
            
            // Update text material
            let newMaterial = createTextMaterial(text: distanceText)
            if var model = textEntity.model {
                model.materials = [newMaterial]
                textEntity.model = model
            }
            
            // Make text face camera (billboard effect)
            let directionToCamera = normalize(cameraPosition - boxPosition)
            // Calculate rotation to face camera (simplified - just rotate around Y axis)
            let angle = atan2(directionToCamera.x, directionToCamera.z)
            textEntity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }
    
    // Fallback: place in front of camera
    private func placeLootBoxInFrontOfCamera(location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        
        // Try to raycast to find ground plane at least 6m away (further than normal placement)
        // CRITICAL: Use at least 1m minimum distance (preferably more for fallback)
        let fallbackMinDistance: Float = 6.0 // Prefer 6m for fallback placement
        let targetPosition = cameraPos + forward * fallbackMinDistance
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
            let hitPoint = SIMD3<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z
            )
            // Reject ceiling-like hits
            if hitPoint.y > cameraPos.y - 0.2 {
                boxPosition = cameraPos + forward * max(fallbackMinDistance, 1.0)
                boxPosition.y = cameraPos.y - 1.5
                Swift.print("⚠️ Raycast landed on ceiling-like plane. Falling back to estimated ground placement.")
            } else {
                let distanceFromCamera = length(hitPoint - cameraPos)
                // CRITICAL: Enforce minimum 1m distance (preferably 5m for fallback)
                if distanceFromCamera < 1.0 {
                    let direction = normalize(hitPoint - cameraPos)
                    boxPosition = cameraPos + direction * max(fallbackMinDistance, 1.0)
                    boxPosition.y = hitPoint.y
                } else if distanceFromCamera < 5.0 {
                    let direction = normalize(hitPoint - cameraPos)
                    boxPosition = cameraPos + direction * 5.0
                    boxPosition.y = hitPoint.y
                } else {
                    boxPosition = hitPoint
                }
            }
        } else {
            // No plane detected, place at fallback distance in front at estimated ground level
            // CRITICAL: Must be at least 1m away (preferably more)
            boxPosition = cameraPos + forward * max(fallbackMinDistance, 1.0)
            boxPosition.y = cameraPos.y - 1.5
        }

        // CRITICAL: Final safety check - enforce ABSOLUTE minimum 1m distance from camera
        let finalDistance = length(boxPosition - cameraPos)
        if finalDistance < 1.0 {
            // If somehow too close, move it to exactly 1m away (absolute minimum)
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * 1.0
            Swift.print("⚠️ CRITICAL: Adjusted \(location.name) placement to 1m MINIMUM distance from camera")
        } else if finalDistance < 5.0 {
            // Prefer 5m for fallback placement
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * 5.0
            Swift.print("⚠️ Adjusted \(location.name) placement to 5m minimum distance from camera")
        }
        
        var boxTransform = matrix_identity_float4x4
        boxTransform.columns.3 = SIMD4<Float>(boxPosition.x, boxPosition.y, boxPosition.z, 1.0)
        
        let anchor = AnchorEntity(world: boxTransform)
        
        // Use random size between 0.3m to 1.0m (capped at 1 meter maximum)
        // Ensure no object renders larger than 1 meter
        let minSize: Float = 0.3  // Minimum size (30cm)
        let maxSize: Float = 1.0  // Maximum size (1 meter) - cap at 1m
        let targetSize = Float.random(in: minSize...maxSize) // Random size between 0.3-1.0m
        let baseSize = Float(location.type.size) // Base size (0.3-0.5m)
        let sizeMultiplier = min(targetSize / baseSize, 1.0 / baseSize) // Calculate multiplier, cap to ensure max 1m
        
        let lootBoxContainer = LootBoxEntity.createLootBox(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
        
        // Position object so bottom sits on ground plane (grounded like the sphere was)
        // Different object types have different heights
        let objectHeight: Float
        switch location.type {
        case .goldenIdol:
            objectHeight = targetSize * 0.6 // Chalice is roughly 0.6x its total size in height
        default:
            objectHeight = targetSize * 0.6 // Boxes are roughly 0.6x their total size in height
        }
        // Position so bottom of object sits on ground (sphere was at y = radius, so just touching ground)
        lootBoxContainer.container.position.y = objectHeight / 2.0
        
        // Ensure object is right-side up (not upside down)
        lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        
        // Create orange sphere indicator (same size as before - 0.15m radius)
        let indicatorSize: Float = 0.15 // 15cm sphere - same size as loot boxes
        let indicatorMesh = MeshResource.generateSphere(radius: indicatorSize)
        var indicatorMaterial = SimpleMaterial()
        indicatorMaterial.color = .init(tint: .orange)
        indicatorMaterial.roughness = 0.2
        indicatorMaterial.metallic = 0.3
        
        let orangeIndicator = ModelEntity(mesh: indicatorMesh, materials: [indicatorMaterial])
        orangeIndicator.name = location.id // Set name for tap detection
        // Position sphere above the loot box (at the top of the box height)
        orangeIndicator.position = SIMD3<Float>(0, objectHeight + indicatorSize, 0)
        
        // Add a point light to make it more visible
        let light = PointLightComponent(color: .orange, intensity: 200)
        orangeIndicator.components.set(light)
        
        // Add both the loot box container and the orange sphere indicator
        anchor.addChild(lootBoxContainer.container)
        anchor.addChild(orangeIndicator)
        
        // Create distance text overlay above the sphere
        let distanceTextEntity = createDistanceTextEntity()
        // Position text above the sphere (sphere is at objectHeight + indicatorSize, so text goes above that)
        distanceTextEntity.position = SIMD3<Float>(0, objectHeight + indicatorSize + 0.3, 0)
        anchor.addChild(distanceTextEntity)
        distanceTextEntities[location.id] = distanceTextEntity
        
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        
        // Store container info for opening animation
        var info = LootBoxInfoComponent()
        info.container = lootBoxContainer
        anchor.components[LootBoxInfoComponent.self] = info
        
        Swift.print("✅ Placed \(location.name) in front of camera at: \(boxPosition)")
        Swift.print("   Distance from camera: \(String(format: "%.2f", finalDistance))m")
    }
    
    // Update all existing loot boxes with new size settings
    func updateLootBoxSizes() {
        guard let arView = arView,
              let locationManager = locationManager,
              let _ = arOriginLocation else { return }
        
        Swift.print("🔄 Updating all loot box sizes...")
        
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
            
            // Create new box with random size between 0.3m to 1.0m (capped at 1 meter maximum)
            // Ensure no object renders larger than 1 meter
            let minSize: Float = 0.3  // Minimum size (30cm)
            let maxSize: Float = 1.0  // Maximum size (1 meter) - cap at 1m
            let targetSize = Float.random(in: minSize...maxSize) // Random size between 0.3-1.0m
            let baseSize = Float(location.type.size)
            let sizeMultiplier = min(targetSize / baseSize, 1.0 / baseSize) // Calculate multiplier, cap to ensure max 1m
            
            let lootBoxContainer = LootBoxEntity.createLootBox(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
            
            // Position object so bottom sits on ground plane
            let objectHeight: Float
            switch location.type {
            case .goldenIdol:
                objectHeight = targetSize * 0.6
            default:
                objectHeight = targetSize * 0.6
            }
            lootBoxContainer.container.position.y = objectHeight / 2.0
            
            // Ensure object is right-side up
            lootBoxContainer.container.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            
            // Create new anchor at same position
            var boxTransform = matrix_identity_float4x4
            boxTransform.columns.3 = SIMD4<Float>(currentPosition.x, currentPosition.y, currentPosition.z, 1.0)
            let newAnchor = AnchorEntity(world: boxTransform)
            
            // Create orange sphere indicator (same size as before - 0.15m radius)
            let indicatorSize: Float = 0.15 // 15cm sphere - same size as loot boxes
            let indicatorMesh = MeshResource.generateSphere(radius: indicatorSize)
            var indicatorMaterial = SimpleMaterial()
            indicatorMaterial.color = .init(tint: .orange)
            indicatorMaterial.roughness = 0.2
            indicatorMaterial.metallic = 0.3
            
            let orangeIndicator = ModelEntity(mesh: indicatorMesh, materials: [indicatorMaterial])
            orangeIndicator.name = location.id
            // Position sphere above the loot box (at the top of the box height)
            orangeIndicator.position = SIMD3<Float>(0, objectHeight + indicatorSize, 0)
            
            let light = PointLightComponent(color: .orange, intensity: 200)
            orangeIndicator.components.set(light)
            
            // Add both the loot box container and the orange sphere indicator
            newAnchor.addChild(lootBoxContainer.container)
            newAnchor.addChild(orangeIndicator)
            
            // Create or update distance text overlay above the sphere
            let distanceTextEntity = createDistanceTextEntity()
            // Position text above the sphere (sphere is at objectHeight + indicatorSize, so text goes above that)
            distanceTextEntity.position = SIMD3<Float>(0, objectHeight + indicatorSize + 0.3, 0)
            newAnchor.addChild(distanceTextEntity)
            distanceTextEntities[locationId] = distanceTextEntity
            
            arView.scene.addAnchor(newAnchor)
            placedBoxes[locationId] = newAnchor
            
            // Store container info
            var info = LootBoxInfoComponent()
            info.container = lootBoxContainer
            newAnchor.components[LootBoxInfoComponent.self] = info
            
            // Create or update FindableObject
            let findableObject = FindableObject(
                locationId: locationId,
                anchor: newAnchor,
                sphereEntity: orangeIndicator,
                container: lootBoxContainer,
                location: location
            )
            
            // Set callback to increment found count
            findableObject.onFoundCallback = { [weak self] id in
                DispatchQueue.main.async {
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(id)
                    }
                }
            }
            
            findableObjects[locationId] = findableObject
        }
        
        Swift.print("✅ Updated \(placedBoxes.count) loot box sizes")
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
    
    // MARK: - Find Loot Box Helper
    /// Finds any findable object using the FindableObject base class behavior
    private func findLootBox(locationId: String, anchor: AnchorEntity, cameraPosition: SIMD3<Float>, sphereEntity: ModelEntity?) {
        guard !foundLootBoxes.contains(locationId) else {
            return // Already found
        }
        
        // Mark as found to prevent duplicate finds
        foundLootBoxes.insert(locationId)
        
        // Remove distance text when found
        if let textEntity = distanceTextEntities[locationId] {
            textEntity.removeFromParent()
            distanceTextEntities.removeValue(forKey: locationId)
        }
        
        // Get or create FindableObject for this location
        var findableObject: FindableObject
        if let existing = findableObjects[locationId] {
            findableObject = existing
        } else {
            // Create new FindableObject
            let location = locationManager?.locations.first(where: { $0.id == locationId })
            var container: LootBoxContainer? = nil
            if let info = anchor.components[LootBoxInfoComponent.self] {
                container = info.container
            }
            
            findableObject = FindableObject(
                locationId: locationId,
                anchor: anchor,
                sphereEntity: sphereEntity,
                container: container,
                location: location
            )
            
            // Set callback to increment found count
            findableObject.onFoundCallback = { [weak self] id in
                DispatchQueue.main.async {
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(id)
                    }
                }
            }
            
            findableObjects[locationId] = findableObject
        }
        
        // Show discovery notification
        let objectName = findableObject.location?.name ?? "Treasure"
        DispatchQueue.main.async { [weak self] in
            self?.collectionNotificationBinding?.wrappedValue = "🎉 Discovered: \(objectName)!"
        }
        
        // Hide notification after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.collectionNotificationBinding?.wrappedValue = nil
        }
        
        // Use FindableObject's find() method - this encapsulates all the basic findable behavior
        findableObject.find { [weak self] in
            // Cleanup after find completes
            self?.placedBoxes.removeValue(forKey: locationId)
            self?.findableObjects.removeValue(forKey: locationId)
            Swift.print("🎉 Collected: \(objectName)")
        }
    }
    
    // MARK: - Tap Handling
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        guard let arView = arView,
              let locationManager = locationManager,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Tap handler: Missing AR view, location manager, or frame")
            return
        }
        
        let tapLocation = sender.location(in: arView)
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        Swift.print("👆 Tap detected at screen: (\(tapLocation.x), \(tapLocation.y))")
        Swift.print("   Placed boxes count: \(placedBoxes.count)")
        
        // Get tap world position using raycast
        var tapWorldPosition: SIMD3<Float>? = nil
        if let raycastResult = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first {
            tapWorldPosition = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
        }
        
        // Check if tapped on existing loot box
        // First try direct entity hit
        let tappedEntity: Entity? = arView.entity(at: tapLocation)
        var locationId: String? = nil
        
        // Walk up the entity hierarchy to find the location ID
        var entityToCheck = tappedEntity
        while let currentEntity = entityToCheck {
            let entityName = currentEntity.name
            // Entity.name is a String, not String?, so check if it's not empty
            if !entityName.isEmpty {
                let idString = entityName
                // Check if this ID matches a placed box
                if placedBoxes[idString] != nil {
                    locationId = idString
                    break
                }
            }
            entityToCheck = currentEntity.parent
        }
        
        // If entity hit didn't work, try proximity-based detection
        // Check all placed boxes to see if tap is near any of them
        if locationId == nil && !placedBoxes.isEmpty {
            var closestBoxId: String? = nil
            var closestDistance: Float = Float.infinity
            let maxWorldDistance: Float = 1.5 // Maximum world distance in meters to consider a tap "on" the box
            let maxScreenDistance: Float = 200.0 // Maximum screen distance in points (fallback)
            
            // Use ARView's built-in method to project world positions to screen
            // We'll check both world-space distance (if we have tap world position) 
            // and use a simple screen-space check as fallback
            for (boxId, anchor) in placedBoxes {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Check world-space distance if we have a tap world position
                var worldDistance: Float = Float.infinity
                if let tapPos = tapWorldPosition {
                    worldDistance = length(anchorWorldPos - tapPos)
                }
                
                // Also check distance from camera to box (if tap is in that direction)
                let distanceFromCamera = length(anchorWorldPos - cameraPos)
                
                // Simple screen-space approximation: if box is close to camera and tap is near center, consider it
                // This is a fallback when we don't have a tap world position
                var screenDistance: Float = Float.infinity
                if tapWorldPosition == nil && distanceFromCamera < 5.0 {
                    // Rough approximation: assume tap near center of screen might hit nearby boxes
                    let centerX = Float(arView.bounds.width / 2)
                    let centerY = Float(arView.bounds.height / 2)
                    let tapX = Float(tapLocation.x)
                    let tapY = Float(tapLocation.y)
                    let distanceFromCenter = sqrt(pow(tapX - centerX, 2) + pow(tapY - centerY, 2))
                    
                    // If tap is near center and box is close, use this as a heuristic
                    if distanceFromCenter < 100.0 {
                        screenDistance = distanceFromCenter
                    }
                }
                
                // Consider it a hit if:
                // 1. World distance is small (tap hit near the box in 3D space), OR
                // 2. Screen distance is small and box is close to camera (fallback heuristic)
                if worldDistance < maxWorldDistance || (screenDistance < maxScreenDistance && distanceFromCamera < 3.0) {
                    let effectiveDistance = min(worldDistance, screenDistance)
                    if effectiveDistance < closestDistance {
                        closestDistance = effectiveDistance
                        closestBoxId = boxId
                    }
                }
            }
            
            if let closestId = closestBoxId {
                locationId = closestId
                Swift.print("🎯 Detected tap on box via proximity: \(closestId), distance: \(String(format: "%.2f", closestDistance))m")
            } else {
                Swift.print("⚠️ Tap did not hit any box. Tap world pos: \(tapWorldPosition != nil ? "yes" : "no"), boxes checked: \(placedBoxes.count)")
            }
        }
        
        // UNIFIED FINDABLE BEHAVIOR: All objects in placedBoxes are findable and clickable
        // If we found a location ID (tapped on any findable object), trigger find behavior
        if let idString = locationId {
            // Try to find in location manager first
            if let location = locationManager.locations.first(where: { $0.id == idString }) {
                // Check if already collected
                if location.collected {
                    Swift.print("⚠️ \(location.name) has already been collected")
                    return
                }
                
                // User tapped on the box - find it regardless of distance
                if let anchor = placedBoxes[idString] {
                    // Get camera position
                    let cameraTransform = frame.camera.transform
                    let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
                    
                    // Find the orange orb/sphere
                    var orangeOrb: ModelEntity? = nil
                    for child in anchor.children {
                        if let modelEntity = child as? ModelEntity,
                           modelEntity.components[PointLightComponent.self] != nil {
                            // This is the sphere/orb
                                    orangeOrb = modelEntity
                                    break
                        }
                    }
                    
                    Swift.print("🎯 Treasure box tapped - triggering find!")
                    
                    // Find the loot box (plays sound, confetti, animation, increments count)
                    findLootBox(locationId: idString, anchor: anchor, cameraPosition: cameraPos, sphereEntity: orangeOrb)
                }
                return
            } else {
                // Box not in location manager (might be from randomization) - still trigger find behavior
                if let anchor = placedBoxes[idString] {
                    // Find the orange orb/sphere
                    var orangeOrb: ModelEntity? = nil
                    for child in anchor.children {
                        if let modelEntity = child as? ModelEntity,
                           modelEntity.components[PointLightComponent.self] != nil {
                            // This is the sphere/orb
                            orangeOrb = modelEntity
                            break
                        }
                    }
                    
                    Swift.print("🎯 Randomized treasure box tapped - triggering find!")
                    
                    // For randomized boxes, we need to handle them differently since they're not in locationManager
                    // But we can still trigger the find animation and effects
                    guard var info = anchor.components[LootBoxInfoComponent.self],
                          let container = info.container,
                          !info.isOpening else {
                        return
                    }
                    
                    info.isOpening = true
                    anchor.components[LootBoxInfoComponent.self] = info
                    
                    // Mark as found to prevent duplicate finds
                    foundLootBoxes.insert(idString)
                    
                    // Remove distance text when found
                    if let textEntity = distanceTextEntities[idString] {
                        textEntity.removeFromParent()
                        distanceTextEntities.removeValue(forKey: idString)
                    }
                    
                    // Get anchor world position for confetti
                    let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                    let anchorWorldPos = SIMD3<Float>(
                        anchorTransform.columns.3.x,
                        anchorTransform.columns.3.y,
                        anchorTransform.columns.3.z
                    )
                    
                    // Create a temporary location for this box
                    let tempLocation = LootBoxLocation(
                        id: idString,
                        name: "Treasure",
                        type: .ancientArtifact, // Default type
                        latitude: 0,
                        longitude: 0,
                        radius: 100.0
                    )
                    
                    Swift.print("🎉 Finding randomized treasure box")
                    
                    // Play sound immediately
                    LootBoxAnimation.playOpeningSound()
                    
                    // Create confetti effect immediately
                    let parentEntity = anchor
                    let confettiRelativePos = SIMD3<Float>(0, 0.15, 0) // At sphere position
                    LootBoxAnimation.createConfettiEffect(at: confettiRelativePos, parent: parentEntity)
                    
                    // Show discovery notification
                    DispatchQueue.main.async { [weak self] in
                        self?.collectionNotificationBinding?.wrappedValue = "🎉 Discovered: \(tempLocation.name)!"
                    }
                    
                    // Hide notification after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        self?.collectionNotificationBinding?.wrappedValue = nil
                    }
                    
                    // Animate sphere "find" animation (+25% for 0.5s, ease out, then pop by shrinking 100%)
                    if let orb = orangeOrb {
                        LootBoxAnimation.animateSphereFind(orb: orb) {
                            // Open the loot box with confetti
                            LootBoxAnimation.openLootBox(container: container, location: tempLocation, tapWorldPosition: anchorWorldPos) { [weak self] in
                                anchor.removeFromParent()
                                self?.placedBoxes.removeValue(forKey: idString)
                                Swift.print("🎉 Collected: \(tempLocation.name)")
                            }
                        }
                    } else {
                        LootBoxAnimation.openLootBox(container: container, location: tempLocation, tapWorldPosition: anchorWorldPos) { [weak self] in
                            anchor.removeFromParent()
                            self?.placedBoxes.removeValue(forKey: idString)
                            Swift.print("🎉 Collected: \(tempLocation.name)")
                        }
                    }
                }
                return
            }
        }
        
        // If no location-based system or not at a location, allow manual placement
        // Place a test loot box where user taps (for testing without locations)
        if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first,
           let frame = arView.session.currentFrame {
            let cameraY = frame.camera.transform.columns.3.y
            let hitY = result.worldTransform.columns.3.y
            if hitY <= cameraY - 0.2 {
                let testLocation = LootBoxLocation(
                    id: UUID().uuidString,
                    name: "Test Artifact",
                    type: .ancientArtifact,
                    latitude: 0,
                    longitude: 0,
                    radius: 100
                )
                placeLootBoxAtLocation(testLocation, in: arView)
            } else {
                Swift.print("⚠️ Tap raycast hit likely ceiling. Ignoring manual placement.")
            }
        }
    }
    
    // Remove any boxes that are too close to the camera (can look huge and occlude view)
    private func cleanupBoxesNearCamera() {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        var toRemove: [String] = []
        for (id, anchor) in placedBoxes {
            let t = anchor.transformMatrix(relativeTo: nil)
            let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let d = length(pos - cameraPos)
            if d < 1.5 { // within 1.5m of camera
                Swift.print("🗑️ Removing box too close to camera: \(id), distance: \(String(format: "%.2f", d))m")
                anchor.removeFromParent()
                toRemove.append(id)
            }
        }
        for id in toRemove { placedBoxes.removeValue(forKey: id) }
    }
    
    // NOTE: Removed cleanupBoxesAtOrigin() - it was causing boxes to be removed incorrectly
    // The AR origin is arbitrary and boxes within 5m of it are not necessarily problematic
}
