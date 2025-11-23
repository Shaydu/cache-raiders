import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import AVFoundation
import AudioToolbox
import Vision
import Combine

// Findable protocol and base class are now in FindableObject.swift

// MARK: - Object Types for Random Placement
enum PlacedObjectType {
    case chalice
    case treasureBox
    case sphere
    case cube
}

// MARK: - AR Coordinator
class ARCoordinator: NSObject, ARSessionDelegate {

    // Managers
    private var environmentManager: AREnvironmentManager?
    private var occlusionManager: AROcclusionManager?
    private var objectRecognizer: ARObjectRecognizer?
    private var distanceTracker: ARDistanceTracker?
    private var tapHandler: ARTapHandler?
    private var databaseIndicatorService: ARDatabaseIndicatorService?
    private var groundingService: ARGroundingService?
    
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var placedBoxes: [String: AnchorEntity] = [:]
    private var findableObjects: [String: FindableObject] = [:] // Track all findable objects
    private var arOriginLocation: CLLocation? // GPS location when AR session started
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var collectionNotificationBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    private var lastSpherePlacementTime: Date? // Prevent rapid duplicate sphere placements
    private var sphereModeActive: Bool = false // Track when we're in sphere randomization mode
    private var hasAutoRandomized: Bool = false // Track if we've already auto-randomized spheres
    private var shouldForceReplacement: Bool = false // Force re-placement after reset when AR is ready

    // Arrow direction tracking
    @Published var nearestObjectDirection: Double? = nil // Direction in degrees (0 = north, 90 = east, etc.)
    
    // Viewport visibility tracking for chime sounds
    private var objectsInViewport: Set<String> = [] // Track which objects are currently visible
    
    override init() {
        super.init()
    }
    
    /// Play a chime sound when an object enters the viewport
    /// Uses a different, gentler sound than the treasure found sound
    private func playViewportChime() {
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session for chime: \(error)")
        }
        
        // Use a gentle system notification sound for viewport entry
        // System sound 1103 is a soft, pleasant notification chime
        // This is different from the treasure found sound (level-up-01.mp3)
        AudioServicesPlaySystemSound(1103) // Soft notification sound for viewport entry
        Swift.print("🔔 Viewport chime: Object entered viewport")
    }
    
    /// Check if an object is currently visible in the viewport
    private func isObjectInViewport(locationId: String, anchor: AnchorEntity) -> Bool {
        guard let arView = arView else { return false }
        
        // Get the object's world position
        let anchorTransform = anchor.transformMatrix(relativeTo: nil)
        let objectPosition = SIMD3<Float>(
            anchorTransform.columns.3.x,
            anchorTransform.columns.3.y,
            anchorTransform.columns.3.z
        )
        
        // Try to find a more specific position from child entities (like the actual box/chalice)
        var bestPosition = objectPosition
        for child in anchor.children {
            if let modelEntity = child as? ModelEntity {
                let childTransform = modelEntity.transformMatrix(relativeTo: nil)
                let childPosition = SIMD3<Float>(
                    childTransform.columns.3.x,
                    childTransform.columns.3.y,
                    childTransform.columns.3.z
                )
                // Use the first child entity's position as it's likely the visible part
                bestPosition = childPosition
                break
            }
        }
        
        // Project the position to screen coordinates
        guard let screenPoint = arView.project(bestPosition) else {
            return false // Object is behind camera or outside view
        }
        
        // Check if the projected point is within the viewport bounds
        let viewWidth = CGFloat(arView.bounds.width)
        let viewHeight = CGFloat(arView.bounds.height)
        
        // Add a small margin to account for object size (objects slightly off-screen still count)
        let margin: CGFloat = 50.0 // 50 point margin
        
        // Break down the complex expression into sub-expressions to help compiler type-checking
        let xInBounds = screenPoint.x >= -margin && screenPoint.x <= viewWidth + margin
        let yInBounds = screenPoint.y >= -margin && screenPoint.y <= viewHeight + margin
        let isInViewport = xInBounds && yInBounds
        
        return isInViewport
    }
    
    /// Check viewport visibility for all placed objects and play chime when objects enter
    private func checkViewportVisibility() {
        guard let arView = arView else { return }
        
        var currentlyVisible: Set<String> = []
        
        // Check visibility for each placed object
        for (locationId, anchor) in placedBoxes {
            // Skip if already found/collected
            if distanceTracker?.foundLootBoxes.contains(locationId) ?? false {
                continue
            }
            
            // Check if object is in viewport
            if isObjectInViewport(locationId: locationId, anchor: anchor) {
                currentlyVisible.insert(locationId)
                
                // If object just entered viewport (wasn't visible before), play chime and log details
                if !objectsInViewport.contains(locationId) {
                    playViewportChime()
                    
                    // Get object details for logging
                    let location = locationManager?.locations.first(where: { $0.id == locationId })
                    let objectName = location?.name ?? "Unknown"
                    let objectType = location?.type.displayName ?? "Unknown Type"
                    
                    // Calculate distance if user location is available
                    var distanceInfo = ""
                    if let userLocation = userLocationManager?.currentLocation,
                       let location = location {
                        let distance = userLocation.distance(from: location.location)
                        distanceInfo = String(format: " (%.1fm away)", distance)
                    }
                    
                    // Get screen position for additional context
                    let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                    let objectPosition = SIMD3<Float>(
                        anchorTransform.columns.3.x,
                        anchorTransform.columns.3.y,
                        anchorTransform.columns.3.z
                    )
                    if let screenPoint = arView.project(objectPosition) {
                        Swift.print("👁️ Object entered viewport: '\(objectName)' (\(objectType))\(distanceInfo) [ID: \(locationId)]")
                        Swift.print("   Screen position: (x: \(String(format: "%.1f", screenPoint.x)), y: \(String(format: "%.1f", screenPoint.y)))")
                    } else {
                        Swift.print("👁️ Object entered viewport: '\(objectName)' (\(objectType))\(distanceInfo) [ID: \(locationId)]")
                    }
                }
            }
        }
        
        // Update tracked visible objects
        objectsInViewport = currentlyVisible
    }
    
    func setupARView(_ arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearbyLocations: Binding<[LootBoxLocation]>, distanceToNearest: Binding<Double?>, temperatureStatus: Binding<String?>, collectionNotification: Binding<String?>, nearestObjectDirection: Binding<Double?>) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.nearbyLocationsBinding = nearbyLocations
        self.distanceToNearestBinding = distanceToNearest
        self.temperatureStatusBinding = temperatureStatus
        self.collectionNotificationBinding = collectionNotification
        self.nearestObjectDirectionBinding = nearestObjectDirection
        
        // Size changes not supported - objects are randomized on placement
        // locationManager.onSizeChanged callback removed
        
        // Store the GPS location when AR starts (this becomes our AR world origin)
        arOriginLocation = userLocationManager.currentLocation
        
        // Initialize managers
        environmentManager = AREnvironmentManager(arView: arView, locationManager: locationManager)
        // Only initialize object recognizer if enabled (saves battery/processing)
        if locationManager.enableObjectRecognition {
            objectRecognizer = ARObjectRecognizer()
            Swift.print("🔍 Object recognition enabled")
        } else {
            Swift.print("🔍 Object recognition disabled (saves battery/processing)")
        }
        distanceTracker = ARDistanceTracker(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager)
        occlusionManager = AROcclusionManager(arView: arView, locationManager: locationManager, distanceTracker: distanceTracker)
        tapHandler = ARTapHandler(arView: arView, locationManager: locationManager)
        databaseIndicatorService = ARDatabaseIndicatorService()
        groundingService = ARGroundingService(arView: arView)
        
        // Configure managers with shared state
        occlusionManager?.placedBoxes = placedBoxes
        distanceTracker?.placedBoxes = placedBoxes
        distanceTracker?.distanceToNearestBinding = distanceToNearest
        distanceTracker?.temperatureStatusBinding = temperatureStatus
        distanceTracker?.nearestObjectDirectionBinding = nearestObjectDirection
        tapHandler?.placedBoxes = placedBoxes
        tapHandler?.findableObjects = findableObjects
        tapHandler?.collectionNotificationBinding = collectionNotification
        
        // Set up tap handler callbacks
        tapHandler?.onFindLootBox = { [weak self] locationId, anchor, cameraPos, sphereEntity in
            self?.findLootBox(locationId: locationId, anchor: anchor, cameraPosition: cameraPos, sphereEntity: sphereEntity)
        }
        tapHandler?.onPlaceLootBoxAtTap = { [weak self] location, result in
            self?.placeLootBoxAtTapLocation(location, tapResult: result, in: arView)
        }
        
        // Monitor AR session
        arView.session.delegate = self
        
        // Start distance logging
        distanceTracker?.startDistanceLogging()
        
        // Clean up any existing occlusion planes once at startup
        occlusionManager?.removeAllOcclusionPlanes()
        
        // Start occlusion checking
        occlusionManager?.startOcclusionChecking()
        
        // Apply ambient light setting
        environmentManager?.updateAmbientLight()
    }
    
    // Clear found loot boxes set - makes objects tappable again after reset
    func clearFoundLootBoxes() {
        distanceTracker?.clearFoundLootBoxes()
        tapHandler?.foundLootBoxes.removeAll()
    }
    
    // Remove all placed objects from AR scene and clear tracking dictionaries
    // This allows objects to be re-placed at their proper GPS locations after reset
    func removeAllPlacedObjects() {
        guard let arView = arView else { return }
        
        Swift.print("🔄 Removing all \(placedBoxes.count) placed objects from AR scene...")
        
        // Remove all anchors from the scene
        for (_, anchor) in placedBoxes {
            anchor.removeFromParent()
        }
        
        // Clear tracking dictionaries
        placedBoxes.removeAll()
        findableObjects.removeAll()
        
        // Clear viewport visibility tracking
        objectsInViewport.removeAll()
        
        // Also clear found loot boxes tracking
        clearFoundLootBoxes()
        
        // Set flag to force re-placement when AR tracking is ready
        shouldForceReplacement = true
        
        Swift.print("✅ All placed objects removed - ready for re-placement at proper locations")
    }
    
    // Update scene ambient lighting based on settings
    func updateAmbientLight() {
        environmentManager?.updateAmbientLight()
    }
    
    // MARK: - Distance Tracking (delegated to ARDistanceTracker)
    // MARK: - Object Recognition (delegated to ARObjectRecognizer)
    
    deinit {
        distanceTracker?.stopDistanceLogging()
        occlusionManager?.stopOcclusionChecking()
    }
    
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        guard let arView = arView else { return }

        // Allow GPS-based loot boxes even when spheres are active
        // Limit to maximum 6 objects total (3 spheres + 3 GPS boxes)
        guard placedBoxes.count < 6 else {
            Swift.print("🎯 Maximum 6 objects reached - not placing more GPS boxes (current: \(placedBoxes.count))")
            return
        }

        for location in nearbyLocations {
            // Stop if we've reached the limit
            guard placedBoxes.count < 6 else { break }

            // Skip locations that are already placed (double-check to prevent duplicates)
            if placedBoxes[location.id] != nil {
                continue
            }

            // Skip tap-created locations (lat: 0, lon: 0) - they're placed manually via tap
            // These should not be placed again by checkAndPlaceBoxes
            if location.latitude == 0 && location.longitude == 0 {
                Swift.print("⏭️ Skipping \(location.name) - tap-created location (AR-only)")
                continue
            }

            // Skip if already collected (critical check to prevent re-placement after finding)
            if location.collected {
                Swift.print("⏭️ Skipping \(location.name) - already collected")
                continue
            }
            
            // CRITICAL: Check for GPS collision - if another object with same/similar GPS coordinates is already placed OR in the current batch
            // This prevents stacking when multiple objects share GPS coordinates
            if location.latitude != 0 && location.longitude != 0 {
                var hasGPSCollision = false
                let newLoc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                
                // First check against already-placed objects
                for (existingId, _) in placedBoxes {
                    // Find the location for this existing object
                    if let existingLocation = nearbyLocations.first(where: { $0.id == existingId }) {
                        // Check if GPS coordinates are very close (within 1 meter)
                        let existingLoc = CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude)
                        let gpsDistance = existingLoc.distance(from: newLoc)
                        
                        if gpsDistance < 1.0 {
                            Swift.print("⏭️ Skipping \(location.name) - GPS collision with already-placed '\(existingLocation.name)'")
                            Swift.print("   GPS distance: \(String(format: "%.2f", gpsDistance))m (too close)")
                            hasGPSCollision = true
                            break
                        }
                    }
                }
                
                // Also check against other locations in the current batch (to prevent placing duplicates in same loop)
                if !hasGPSCollision {
                    for otherLocation in nearbyLocations {
                        // Skip self and already-placed objects (we checked those above)
                        if otherLocation.id == location.id || placedBoxes[otherLocation.id] != nil {
                            continue
                        }
                        
                        // Check if GPS coordinates are very close (within 1 meter)
                        let otherLoc = CLLocation(latitude: otherLocation.latitude, longitude: otherLocation.longitude)
                        let gpsDistance = newLoc.distance(from: otherLoc)
                        
                        if gpsDistance < 1.0 {
                            Swift.print("⏭️ Skipping \(location.name) - GPS collision with '\(otherLocation.name)' in current batch")
                            Swift.print("   GPS distance: \(String(format: "%.2f", gpsDistance))m (too close)")
                            Swift.print("   💡 Multiple objects at same GPS location - only placing first one")
                            hasGPSCollision = true
                            break
                        }
                    }
                }
                
                if hasGPSCollision {
                    continue
                }
            }

            // Place box if it's nearby (within maxSearchDistance), hasn't been placed, and isn't collected
            // The box will appear in AR when you're within the search distance
            // (location.collected check already done above, so we know it's not collected)
            if location.id.hasPrefix("AR_SPHERE_MAP_") {
                // This is a map-only marker for spheres - skip AR placement
                continue
            } else if location.id.hasPrefix("AR_ITEM_") {
                // This is a randomized AR item - place it based on its type (not just as sphere)
                // Use placeBoxAtPosition which respects location.type and creates appropriate object
                // But first check if we need GPS-based placement or if it's already AR-only
                if location.latitude == 0 && location.longitude == 0 {
                    // AR-only item - need to find position via raycast
                    // For now, skip - these are placed directly in randomizeLootBoxes
                    Swift.print("⏭️ Skipping \(location.name) - AR-only item (should be placed via randomizeLootBoxes)")
                    continue
                } else {
                    // Has GPS coordinates - place using GPS-based placement
                    placeLootBoxAtLocation(location, in: arView)
                }
            } else if location.id.hasPrefix("AR_SPHERE_") {
                // This is an AR sphere location - place a sphere instead of treasure box
                placeARSphereAtLocation(location, in: arView)
            } else {
                // Regular GPS treasure box
                placeLootBoxAtLocation(location, in: arView)
            }
        }
    }
    

    // Regenerate loot boxes at random locations in the AR room
    func randomizeLootBoxes() {
        print("🎲 RANDOMIZE TRIGGERED - Starting sphere placement...")

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            Swift.print("⚠️ Cannot randomize: AR not ready")
            return
        }

        // Enter sphere mode - prevent GPS boxes
        sphereModeActive = true
        hasAutoRandomized = true // Mark as having randomized (whether auto or manual)

        print("🗑️ Removing \(placedBoxes.count) existing spheres...")
        // Remove all existing placed boxes
        for (_, anchor) in placedBoxes {
            anchor.removeFromParent()
        }
        placedBoxes.removeAll()
        findableObjects.removeAll() // Also clear findable objects

        // Also remove old randomly-generated AR item locations from locationManager to reset the counter
        // Keep GPS-based locations and manually-added spheres (AR_SPHERE_MAP_ prefix)
        let oldCount = locationManager.locations.count
        locationManager.locations.removeAll { location in
            // Remove both AR_SPHERE_ (old sphere locations) and AR_ITEM_ (new randomized locations)
            // But keep manually-added map markers (AR_SPHERE_MAP_)
            (location.id.hasPrefix("AR_SPHERE_") && !location.id.hasPrefix("AR_SPHERE_MAP_")) ||
            location.id.hasPrefix("AR_ITEM_")
        }
        let removedCount = oldCount - locationManager.locations.count
        print("🗑️ Removed \(removedCount) old random AR item locations from locationManager")

        // Generate exactly 3 new loot boxes at random positions (since we only allow 3 total)
        let numberOfBoxes = 3
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Add time-based offset to ensure different results each randomization
        let timeOffset = Float(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100.0))
        Swift.print("🎲 Time-based randomization offset: \(String(format: "%.2f", timeOffset))")

        // Create a virtual "random center" that's offset from the actual camera position
        // This ensures different placement patterns even when starting from the same location
        let centerOffsetDistance = Float.random(in: 0...2.0) // Up to 2m offset
        let centerOffsetAngle = Float.random(in: 0...(2 * Float.pi))
        let randomCenterX = cameraPos.x + centerOffsetDistance * cos(centerOffsetAngle)
        let randomCenterZ = cameraPos.z + centerOffsetDistance * sin(centerOffsetAngle)
        let randomCenter = SIMD3<Float>(randomCenterX, cameraPos.y, randomCenterZ)

        Swift.print("🎲 Using random center at (\(String(format: "%.2f", randomCenterX)), \(String(format: "%.2f", randomCenterZ))) instead of camera position")

        // TEMPORARILY DISABLE indoor detection to ensure spheres spawn
        // TODO: Re-enable with better logic once spheres are working reliably
        let isIndoors = false // Always use outdoor placement for now
        Swift.print("🏠 Environment detection: DISABLED (using outdoor placement)")
        Swift.print("   Starting placement...")

        // Adjust placement strategy based on environment
        let (minDistance, maxDistance, placementStrategy) = getPlacementStrategy(isIndoors: isIndoors, searchDistance: Float(locationManager.maxSearchDistance))

        Swift.print("🎲 Randomizing \(numberOfBoxes) loot boxes (\(placementStrategy))...")

        var placedCount = 0
        var attempts = 0
        let maxAttempts = numberOfBoxes * 15 // Allow more attempts for complex indoor placement
        
        while placedCount < numberOfBoxes && attempts < maxAttempts {
            attempts += 1

            var randomX: Float
            var randomZ: Float

            // Simplified placement for reliable sphere spawning
            let randomDistance = Float.random(in: minDistance...maxDistance)
            let randomAngle = Float.random(in: 0...(2 * Float.pi))

            // Add time-based variation to ensure different results each session
            let angleOffset = timeOffset * 0.1 // Small angle variation based on time
            let adjustedAngle = randomAngle + angleOffset

            // Use random center instead of camera position for more varied placement
            randomX = randomCenter.x + randomDistance * cos(adjustedAngle)
            randomZ = randomCenter.z + randomDistance * sin(adjustedAngle)

            // Find the highest blocking surface (floor or table above floor)
            guard let surfaceY = groundingService?.findHighestBlockingSurface(x: randomX, z: randomZ, cameraPos: cameraPos) else {
                if attempts <= 3 { // Only log first few failures to avoid spam
                    Swift.print("⚠️ No surface detected at attempt \(attempts)")
                    Swift.print("   💡 Try moving camera to scan more surfaces, or place objects manually by tapping")
                }
                continue
            }

            Swift.print("✅ Found surface at attempt \(attempts) - Y: \(String(format: "%.2f", surfaceY))")

            let cameraY = cameraPos.y

            // Reject surfaces too far away (more than 2m above or below camera)
            let heightDiff = abs(surfaceY - cameraY)
            if heightDiff > 2.0 {
                Swift.print("⚠️ Surface too far rejected at attempt \(attempts) - surfaceY: \(String(format: "%.2f", surfaceY)), cameraY: \(String(format: "%.2f", cameraY)), diff: \(String(format: "%.2f", heightDiff))")
                continue
            }
            
            let boxPosition = SIMD3<Float>(randomX, surfaceY, randomZ)
            let distanceFromCamera = length(boxPosition - cameraPos)

            // CRITICAL: Enforce MINIMUM 1m distance from camera to prevent objects spawning on camera
            if distanceFromCamera < 1.0 {
                Swift.print("⚠️ Too close to camera rejected at attempt \(attempts) - distance: \(String(format: "%.2f", distanceFromCamera))m")
                continue
            }

            if distanceFromCamera < minDistance || distanceFromCamera > maxDistance {
                Swift.print("⚠️ Distance out of range rejected at attempt \(attempts) - distance: \(String(format: "%.2f", distanceFromCamera))m, min: \(String(format: "%.2f", minDistance))m, max: \(String(format: "%.2f", maxDistance))m")
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
                let distanceToExisting = length(boxPosition - existingPos)
                if distanceToExisting < 3.0 {
                    Swift.print("⚠️ Too close to existing box rejected at attempt \(attempts) - distance: \(String(format: "%.2f", distanceToExisting))m")
                    tooClose = true
                    break
                }
            }

            if tooClose {
                continue
            }
            
            // Create a new temporary location for this object
            // Use completely unique IDs to avoid any confusion with map locations
            // Randomly select object type for variety
            let objectTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest, .sphere, .cube]
            let selectedType = objectTypes.randomElement() ?? .chalice
            
            // Use the factory's itemDescription() to get the proper name for this type
            // This ensures each type gets its unique description (e.g., "Golden Chalice" not just "Chalice")
            let factory = selectedType.factory
            let itemName = factory.itemDescription()
            
            let newLocation = LootBoxLocation(
                id: "AR_ITEM_" + UUID().uuidString, // Generic prefix for all AR-only items (not just spheres)
                name: itemName, // Use the factory's description to ensure proper naming
                type: selectedType,
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0 // Large radius since we're not using GPS
            )
            
            // Add the location to locationManager so it shows up in the counter
            locationManager.addLocation(newLocation)

            // Place the object (will create appropriate type based on location.type)
            Swift.print("✅ Found valid position at attempt \(attempts) - placing \(itemName) (\(selectedType.displayName)) at distance: \(String(format: "%.2f", distanceFromCamera))m")
            placeBoxAtPosition(boxPosition, location: newLocation, in: arView)
            placedCount += 1
        }
        
        Swift.print("✅ Randomized and placed \(placedCount) objects!")
        if placedCount == 0 {
            Swift.print("⚠️ WARNING: No objects were placed!")
            Swift.print("   💡 Try: 1) Move camera around to scan surfaces, 2) Tap on surfaces to place manually")
        } else {
            Swift.print("   🎯 Objects placed on floors/tables - look around to find them!")
        }
    }


    // Generate position for indoor placement (simplified approach)
    private func generateIndoorPosition(cameraPos: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> (x: Float, z: Float) {
        // Simplified indoor placement: just place closer to camera in a smaller area
        // Avoid complex wall boundary calculations that might be failing
        Swift.print("🏠 Using simplified indoor placement")

        let randomDistance = Float.random(in: minDistance...min(maxDistance, 4.0)) // Limit to 4m indoors
        let randomAngle = Float.random(in: 0...(2 * Float.pi)) // Any direction

        let x = cameraPos.x + randomDistance * cos(randomAngle)
        let z = cameraPos.z + randomDistance * sin(randomAngle)

        Swift.print("🏠 Indoor position: distance \(String(format: "%.1f", randomDistance))m, angle \(String(format: "%.1f", randomAngle * 180 / .pi))°")
        return (x, z)
    }

    // Check if a position is within room boundaries defined by walls
    private func isPositionWithinRoomBounds(x: Float, z: Float, cameraPos: SIMD3<Float>, walls: [ARPlaneAnchor]) -> Bool {
        let testPos = SIMD3<Float>(x, cameraPos.y, z)

        // For each wall, check if the position is on the correct side
        for wall in walls {
            let wallTransform = wall.transform
            let wallPosition = SIMD3<Float>(
                wallTransform.columns.3.x,
                wallTransform.columns.3.y,
                wallTransform.columns.3.z
            )

            // Get wall normal (direction the wall is facing)
            let wallNormal = SIMD3<Float>(
                wallTransform.columns.2.x,
                wallTransform.columns.2.y,
                wallTransform.columns.2.z
            )

            // Vector from wall to test position
            let toTestPos = testPos - wallPosition

            // If the dot product is positive, the position is on the "outside" of the wall
            // We want positions on the "inside" (negative dot product)
            let dotProduct = dot(wallNormal, toTestPos)

            // Allow some tolerance - if clearly outside, reject
            if dotProduct > 1.0 { // More than 1m outside the wall
                return false
            }
        }

        return true // Position is within bounds or no clear boundary violation
    }

    // Get placement strategy - simplified for reliable sphere spawning
    private func getPlacementStrategy(isIndoors: Bool, searchDistance: Float) -> (minDistance: Float, maxDistance: Float, strategy: String) {
        // Use indoor-like distances for reliable sphere spawning
        return (
            minDistance: 1.0, // Minimum 1 meter
            maxDistance: 8.0,  // Maximum 8 meters (reasonable for indoor spaces)
            strategy: "INDOOR-FRIENDLY MODE - close placement for spheres"
        )
    }

    // MARK: - Object Recognition (delegated to ARObjectRecognizer)

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Set AR origin on first frame if not set
        if arOriginLocation == nil,
           let userLocation = userLocationManager?.currentLocation {
            arOriginLocation = userLocation
            Swift.print("📍 AR Origin set at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
        }
        
        // Perform object recognition on camera frame
        objectRecognizer?.performObjectRecognition(on: frame.capturedImage)

        // Check for nearby locations when AR is tracking
        if frame.camera.trackingState == .normal,
           let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            
            // Force re-placement after reset if flag is set
            if shouldForceReplacement {
                Swift.print("🔄 Force re-placement triggered - re-placing all nearby objects")
                Swift.print("   📍 Found \(nearby.count) nearby locations within \(locationManager.maxSearchDistance)m")
                shouldForceReplacement = false
                // Clear placedBoxes to ensure all objects can be re-placed
                // (removeAllPlacedObjects already cleared it, but double-check)
                checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
            } else {
                checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
            }

            // No automatic sphere spawning - user must add items manually via map
            // if !hasAutoRandomized && placedBoxes.isEmpty {
            //     Swift.print("🎯 AR tracking stable - auto-spawning 3 spheres")
            //     randomizeLootBoxes()
            // }
            
            // Check viewport visibility and play chime when objects enter
            checkViewportVisibility()
        }
    }
    
    // Handle AR anchor updates - remove any unwanted plane anchors (especially ceilings)
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        for anchor in anchors {
            // Handle horizontal plane anchors (floors/tables) - we need these for raycasting!
            if let planeAnchor = anchor as? ARPlaneAnchor {
                if planeAnchor.alignment == .horizontal {
                    // Check if this plane is above the camera (likely a ceiling) or suspiciously large
                    let planeY = planeAnchor.transform.columns.3.y
                    let planeHeight = planeAnchor.planeExtent.height
                    let planeWidth = planeAnchor.planeExtent.width

                    // Allow reasonable-sized horizontal planes (floors/tables) but remove problematic ones
                    let isCeiling = planeY > cameraPos.y + 0.5 // Clearly above camera
                    let isTooLarge = planeHeight > 8.0 || planeWidth > 8.0 // Suspiciously large
                    let isTooSmall = planeHeight < 0.3 || planeWidth < 0.3 // Too small to be useful

                    if isCeiling || isTooLarge || isTooSmall {
                        Swift.print("🗑️ Removing horizontal plane anchor: ceiling=\(isCeiling), too_large=\(isTooLarge), too_small=\(isTooSmall), Y=\(String(format: "%.2f", planeY)), size=\(String(format: "%.2f", planeWidth))x\(String(format: "%.2f", planeHeight))")
                        // Remove the anchor by not adding it to the scene
                        // ARKit will handle cleanup
                    } else {
                        Swift.print("✅ Keeping horizontal plane anchor (floor/table): Y=\(String(format: "%.2f", planeY)), size=\(String(format: "%.2f", planeWidth))x\(String(format: "%.2f", planeHeight))")

                        // Auto-randomize spheres when we have a good surface available
                        if !hasAutoRandomized && placedBoxes.isEmpty {
                            Swift.print("🎯 Auto-randomizing spheres on detected surface!")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                                // Small delay to let AR settle
                                self?.hasAutoRandomized = true
                                self?.randomizeLootBoxes()
                            }
                        }
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
        // Occlusion plane cleanup is now handled by AROcclusionManager
        // No action needed here
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
        guard let frame = arView.session.currentFrame,
              let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ No AR frame or user location available for \(location.name)")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Use GPS-based placement if location has GPS coordinates
        if location.latitude != 0 || location.longitude != 0 {
            // Calculate GPS-based position
            let targetLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            var distance = userLocation.distance(from: targetLocation) // Distance in meters
            let bearing = userLocation.bearing(to: targetLocation) // Bearing in degrees (0-360, 0 = North)
            
            // Ensure minimum distance of 1m for AR placement
            let minDistance: Double = 1.0
            if distance < minDistance {
                Swift.print("⚠️ GPS distance \(String(format: "%.2f", distance))m is too close, using minimum \(minDistance)m")
                distance = minDistance
            }
            
            Swift.print("📍 Placing \(location.name) at GPS distance \(String(format: "%.2f", distance))m, bearing \(String(format: "%.1f", bearing))°")
            
            // Get camera's forward and right directions
            let cameraForward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                0,
                -cameraTransform.columns.2.z
            )
            let cameraRight = SIMD3<Float>(
                cameraTransform.columns.0.x,
                0,
                cameraTransform.columns.0.z
            )
            
            // Normalize directions
            let forwardDir = normalize(cameraForward)
            let rightDir = normalize(cameraRight)
            
            // Convert bearing to radians (0 = North, 90 = East, 180 = South, 270 = West)
            let bearingRad = Float(bearing * .pi / 180.0)
            
            // Calculate offset in AR space relative to camera orientation
            // X = distance * sin(bearing) (east/west)
            // Z = distance * cos(bearing) (north/south)
            let offsetX = Float(distance) * sin(bearingRad)
            let offsetZ = Float(distance) * cos(bearingRad)
            
            // Apply offset relative to camera's orientation
            let targetPos = cameraPos + rightDir * offsetX + forwardDir * offsetZ
            
            // Clamp distance to reasonable AR space (max 20m for GPS items)
            let clampedDistance = min(distance, 20.0)
            if distance > 20.0 {
                Swift.print("⚠️ GPS distance \(String(format: "%.2f", distance))m exceeds 20m, clamping to 20m for AR placement")
                let scale = Float(20.0 / distance)
                let adjustedTargetPos = cameraPos + (targetPos - cameraPos) * scale
                
                // Find the highest blocking surface at adjusted position
                if let surfaceY = groundingService?.findHighestBlockingSurface(x: adjustedTargetPos.x, z: adjustedTargetPos.z, cameraPos: cameraPos) {
                    let itemPosition = SIMD3<Float>(adjustedTargetPos.x, surfaceY, adjustedTargetPos.z)
                    Swift.print("✅ Placed \(location.type.displayName) on surface at GPS-based AR position (Y: \(String(format: "%.2f", surfaceY)))")
                    placeBoxAtPosition(itemPosition, location: location, in: arView)
                    return
                } else {
                    // Fallback: use adjusted position (placeBoxAtPosition will try to ground it)
                    placeBoxAtPosition(adjustedTargetPos, location: location, in: arView)
                    return
                }
            }
            
            // Try to find the highest horizontal surface that blocks the floor
            if let surfaceY = groundingService?.findHighestBlockingSurface(x: targetPos.x, z: targetPos.z, cameraPos: cameraPos) {
                let itemPosition = SIMD3<Float>(targetPos.x, surfaceY, targetPos.z)
                Swift.print("✅ Placed \(location.type.displayName) on surface at GPS-based AR position (Y: \(String(format: "%.2f", surfaceY)))")
                placeBoxAtPosition(itemPosition, location: location, in: arView)
                return
            } else {
                // Fallback: Try wider search before giving up
                Swift.print("⚠️ No surface detected for GPS location, trying wider search...")
                let searchOffsets: [SIMD3<Float>] = [
                    SIMD3<Float>(0, 0, 0),
                    SIMD3<Float>(0.5, 0, 0),
                    SIMD3<Float>(-0.5, 0, 0),
                    SIMD3<Float>(0, 0, 0.5),
                    SIMD3<Float>(0, 0, -0.5)
                ]
                
                var foundSurface = false
                if let surfaceY = groundingService?.findSurfaceWithFallback(centerX: targetPos.x, centerZ: targetPos.z, cameraPos: cameraPos) {
                    let groundedPos = SIMD3<Float>(targetPos.x, surfaceY, targetPos.z)
                    Swift.print("✅ Found surface at offset position - grounding object")
                    placeBoxAtPosition(groundedPos, location: location, in: arView)
                    foundSurface = true
                }
                
                if !foundSurface {
                    Swift.print("⚠️ No surface found after extended search - object may float")
                    Swift.print("   💡 Try moving camera to scan surfaces before placing")
                    // Still place it, but placeBoxAtPosition will try to ground it
                    placeBoxAtPosition(targetPos, location: location, in: arView)
                }
                return
            }
        }
        
        // Fallback: If no GPS coordinates, use random placement (for AR-only items)
        Swift.print("⚠️ No GPS coordinates for \(location.name), using random placement")
        placeLootBoxInFrontOfCamera(location: location, in: arView)
    }
    
    // Place a loot box at tap location (allows closer placement for manual taps)
    private func placeLootBoxAtTapLocation(_ location: LootBoxLocation, tapResult: ARRaycastResult, in arView: ARView) {
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ No AR frame available for tap placement")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let hitY = tapResult.worldTransform.columns.3.y
        let hitX = tapResult.worldTransform.columns.3.x
        let hitZ = tapResult.worldTransform.columns.3.z
        
        var boxPosition = SIMD3<Float>(hitX, hitY, hitZ)
        
        // For manual tap placement, allow closer placement (minimum 1m instead of 3-5m)
        let distanceFromCamera = length(boxPosition - cameraPos)
        let minDistance: Float = 1.0 // Allow closer placement for manual taps
        
        if distanceFromCamera < minDistance {
            // Adjust position to be at minimum distance
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * minDistance
            // Recalculate Y from highest blocking surface at new position
            if let surfaceY = groundingService?.findHighestBlockingSurface(x: boxPosition.x, z: boxPosition.z, cameraPos: cameraPos) {
                boxPosition.y = surfaceY
            }
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
            if distanceToExisting < 1.5 { // Reduced from 3.0 for manual placement
                tooCloseToOtherBox = true
                break
            }
        }
        
        if tooCloseToOtherBox {
            Swift.print("⚠️ Tap location too close to existing object")
            return
        }
        
        Swift.print("🎯 Placing object at tap location (distance: \(String(format: "%.2f", length(boxPosition - cameraPos)))m)")
        placeBoxAtPosition(boxPosition, location: location, in: arView)
    }
    
    // Place an AR sphere at a GPS location (for map-added spheres)
    private func placeARSphereAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ No AR frame available for sphere \(location.name)")
            return
        }

        // Convert GPS location to AR position
        guard let arOrigin = arOriginLocation else {
            Swift.print("⚠️ No AR origin set for sphere placement")
            return
        }

        let locationCLLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let distance = arOrigin.distance(from: locationCLLocation)
        let bearing = arOrigin.bearing(to: locationCLLocation)

        // Convert to AR coordinates (simple approximation)
        let x = Float(distance * sin(bearing * .pi / 180.0))
        let z = Float(distance * cos(bearing * .pi / 180.0))

        Swift.print("🎯 Placing AR sphere '\(location.name)' at GPS distance \(String(format: "%.1f", distance))m, bearing \(String(format: "%.1f", bearing))°")
        Swift.print("   AR position: (\(String(format: "%.2f", x)), \(String(format: "%.2f", z)))")

        // Create sphere at calculated position
        let sphereRadius: Float = 0.15 // Smaller sphere for GPS-located items
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: .orange)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = location.id

        // Get camera position for grounding
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Find the highest blocking surface to ground the sphere
        let groundY: Float
        if let surfaceY = groundingService?.findHighestBlockingSurface(x: x, z: z, cameraPos: cameraPos) {
            groundY = surfaceY
        } else {
            // Fallback to camera height - 1.5m if no surface found
            groundY = cameraPos.y - 1.5
            Swift.print("⚠️ No surface found for sphere - using fallback height")
        }
        
        // Position sphere so bottom sits flat on surface
        sphere.position = SIMD3<Float>(x, sphereRadius, z) // Bottom of sphere touches surface

        // Add point light to make it visible
        let light = PointLightComponent(color: .orange, intensity: 200)
        sphere.components.set(light)

        // Create anchor at grounded position
        let anchor = AnchorEntity(world: SIMD3<Float>(x, groundY, z))
        anchor.addChild(sphere)

        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to increment found count
        findableObjects[location.id] = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: nil,
            location: location
        )

        // Set callback to mark as collected when found
        findableObjects[location.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        Swift.print("✅ Placed AR sphere '\(location.name)' at AR position (\(String(format: "%.2f", x)), \(String(format: "%.2f", z)))")
    }
    
    // Helper method to place a randomly selected object at a specific position
    private func placeBoxAtPosition(_ boxPosition: SIMD3<Float>, location: LootBoxLocation, in arView: ARView) {
        // Prevent duplicate placements
        if placedBoxes[location.id] != nil {
            Swift.print("⚠️ Object with ID \(location.id) already placed - skipping duplicate placement")
            return
        }
        
        // CRITICAL: Check for collision with already placed objects (minimum 2m horizontal separation, 0.5m vertical)
        let minHorizontalSeparation: Float = 2.0 // Minimum 2 meters horizontal distance between objects
        let minVerticalSeparation: Float = 0.5 // Minimum 0.5 meters vertical distance (prevents stacking)
        for (existingId, existingAnchor) in placedBoxes {
            let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
            let existingPos = SIMD3<Float>(
                existingTransform.columns.3.x,
                existingTransform.columns.3.y,
                existingTransform.columns.3.z
            )
            
            // Calculate horizontal distance (X-Z plane)
            let horizontalDistance = sqrt(
                pow(boxPosition.x - existingPos.x, 2) +
                pow(boxPosition.z - existingPos.z, 2)
            )
            
            // Calculate vertical distance (Y-axis)
            let verticalDistance = abs(boxPosition.y - existingPos.y)
            
            // Check both horizontal and vertical separation
            if horizontalDistance < minHorizontalSeparation {
                Swift.print("⚠️ Rejected placement of \(location.name) - too close horizontally to existing object '\(existingId)'")
                Swift.print("   Horizontal distance: \(String(format: "%.2f", horizontalDistance))m (minimum: \(minHorizontalSeparation)m)")
                Swift.print("   Vertical distance: \(String(format: "%.2f", verticalDistance))m")
                return
            }
            
            // Also check if objects are stacking vertically (same X-Z position but different Y)
            if horizontalDistance < 0.5 && verticalDistance < minVerticalSeparation {
                Swift.print("⚠️ Rejected placement of \(location.name) - stacking detected with existing object '\(existingId)'")
                Swift.print("   Horizontal distance: \(String(format: "%.2f", horizontalDistance))m")
                Swift.print("   Vertical distance: \(String(format: "%.2f", verticalDistance))m (minimum: \(minVerticalSeparation)m)")
                return
            }
        }
        
        // CRITICAL: Final safety check - ensure minimum 3m distance from camera
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place box: no AR frame available")
            return
        }
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let distanceFromCamera = length(boxPosition - cameraPos)

        if distanceFromCamera < 3.0 {
            Swift.print("⚠️ Rejected placement of \(location.name) - too close to camera (\(String(format: "%.2f", distanceFromCamera))m)")
            return
        }

        // CRITICAL: Ensure object is grounded on the highest horizontal surface that blocks the floor
        // This places objects on tables/raised surfaces if they block the floor, otherwise on the floor
        var groundedPosition = boxPosition
        if let surfaceY = groundingService?.findHighestBlockingSurface(x: boxPosition.x, z: boxPosition.z, cameraPos: cameraPos) {
            groundedPosition = SIMD3<Float>(boxPosition.x, surfaceY, boxPosition.z)
            Swift.print("✅ Grounded object on surface at Y: \(String(format: "%.2f", surfaceY))")
        } else {
            Swift.print("⚠️ No horizontal surface detected at position - object may float")
            Swift.print("   💡 Try moving camera to scan more surfaces before placing objects")
        }
        
        // DEBUG: Log position details
        Swift.print("📍 Placing at position: (\(String(format: "%.2f", groundedPosition.x)), \(String(format: "%.2f", groundedPosition.y)), \(String(format: "%.2f", groundedPosition.z)))")
        Swift.print("📍 Camera position: (\(String(format: "%.2f", cameraPos.x)), \(String(format: "%.2f", cameraPos.y)), \(String(format: "%.2f", cameraPos.z)))")
        Swift.print("📍 Distance from camera: \(String(format: "%.2f", distanceFromCamera))m")
        Swift.print("📍 Height difference (camera - box): \(String(format: "%.2f", cameraPos.y - groundedPosition.y))m")
        
        // Use same simple world anchor approach as spheres for consistency
        // This ensures boxes stay fixed in world space and don't follow the camera
        let anchor = AnchorEntity(world: groundedPosition)
        
        // Determine object type based on location type from dropdown selection
        let selectedObjectType: PlacedObjectType
        switch location.type {
        case .chalice:
            selectedObjectType = .chalice
        case .sphere:
            selectedObjectType = .sphere
        case .cube:
            selectedObjectType = .cube
        case .templeRelic, .treasureChest:
            selectedObjectType = .treasureBox
        }

        Swift.print("🎲 Placing \(selectedObjectType) (\(location.type.displayName)) for \(location.name)")
        Swift.print("   Location ID: \(location.id)")
        Swift.print("   Location type: \(location.type)")
        Swift.print("   Selected object type: \(selectedObjectType)")

        // Use factory to create entity - each factory encapsulates its own creation logic
        Swift.print("🎯 Creating \(location.type.displayName) using factory for \(location.name)")
        Swift.print("   Location type: \(location.type), Factory type: \(type(of: location.type.factory))")
        let sizeMultiplier = Float.random(in: 0.5...1.0) // Vary size for variety
        let factory = location.type.factory
        
        // CRITICAL: Verify each type uses its correct factory to ensure proper separation
        // Check factory type name to ensure correct factory is being used
        let factoryTypeName = String(describing: type(of: factory))
        let expectedFactoryNames: [LootBoxType: String] = [
            .chalice: "ChaliceFactory",
            .treasureChest: "TreasureChestFactory",
            .templeRelic: "TempleRelicFactory",
            .sphere: "SphereFactory",
            .cube: "CubeFactory"
        ]
        
        if let expectedName = expectedFactoryNames[location.type] {
            if !factoryTypeName.contains(expectedName) {
                Swift.print("❌ CRITICAL ERROR: \(location.type.displayName) location \(location.id) is using factory \(factoryTypeName) instead of \(expectedName)!")
                Swift.print("   This will cause incorrect object rendering and naming!")
            } else {
                Swift.print("✅ Verified \(location.type.displayName) is using correct factory: \(factoryTypeName)")
            }
        }
        
        let (entity, findable) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: sizeMultiplier)
        
        let placedEntity = entity
        let findableObject = findable

        // Add the placed entity to the anchor
        anchor.addChild(placedEntity)

        // Store the anchor and findable object
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // DEBUG: Log final world positions
        let finalAnchorTransform = anchor.transformMatrix(relativeTo: nil)
        let finalAnchorPos = SIMD3<Float>(
            finalAnchorTransform.columns.3.x,
            finalAnchorTransform.columns.3.y,
            finalAnchorTransform.columns.3.z
        )

        Swift.print("✅ Placed \(selectedObjectType) at AR position: \(finalAnchorPos)")
        
        // DEBUG: Log container info
        Swift.print("   FindableObject created:")
        Swift.print("     - Has container: \(findableObject.container != nil)")
        Swift.print("     - Has location: \(findableObject.location != nil)")
        Swift.print("     - Location name: \(findableObject.location?.name ?? "nil")")
        if let container = findableObject.container {
            Swift.print("     - Container has box: \(container.box.name)")
            Swift.print("     - Container has lid: \(container.lid.name)")
            Swift.print("     - Container has prize: \(container.prize.name)")
            Swift.print("     - Built-in animation: \(container.builtInAnimation != nil ? "YES" : "NO")")
        }

        // Set callback to increment found count
        findableObject.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        findableObjects[location.id] = findableObject
        Swift.print("   ✅ Stored FindableObject in findableObjects dictionary")
        
        // Add orange database indicator if this object is from the shared database
        databaseIndicatorService?.addDatabaseIndicator(to: anchor, location: location, in: arView)
    }
    
    // MARK: - Distance Text Overlay (delegated to ARDistanceTracker)
    
    // Fallback: place in front of camera
    private func placeLootBoxInFrontOfCamera(location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        
        // Try to raycast to find ground plane at least 6m away (further than normal placement)
        // CRITICAL: Use at least 3m minimum distance (preferably more for fallback)
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
                // CRITICAL: Enforce minimum 3m distance (preferably 5m for fallback)
                if distanceFromCamera < 3.0 {
                    let direction = normalize(hitPoint - cameraPos)
                    boxPosition = cameraPos + direction * max(fallbackMinDistance, 3.0)
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
            // CRITICAL: Must be at least 3m away (preferably more)
            boxPosition = cameraPos + forward * max(fallbackMinDistance, 3.0)
            boxPosition.y = cameraPos.y - 1.5

            // DEBUG: Log placement details
            Swift.print("📍 Fallback placement: camera at (\(String(format: "%.1f", cameraPos.x)), \(String(format: "%.1f", cameraPos.y)), \(String(format: "%.1f", cameraPos.z)))")
            Swift.print("📍 Forward direction: (\(String(format: "%.2f", forward.x)), \(String(format: "%.2f", forward.y)), \(String(format: "%.2f", forward.z)))")
            Swift.print("📍 Placing at: (\(String(format: "%.1f", boxPosition.x)), \(String(format: "%.1f", boxPosition.y)), \(String(format: "%.1f", boxPosition.z)))")
        }

        // CRITICAL: Final safety check - enforce ABSOLUTE minimum 3m distance from camera
        let finalDistance = length(boxPosition - cameraPos)
        if finalDistance < 3.0 {
            // If somehow too close, move it to exactly 3m away (absolute minimum)
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * 3.0
            Swift.print("⚠️ CRITICAL: Adjusted \(location.name) placement to 3m MINIMUM distance from camera")
        } else if finalDistance < 5.0 {
            // Prefer 5m for fallback placement
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * 5.0
            Swift.print("⚠️ Adjusted \(location.name) placement to 5m minimum distance from camera")
        }

        // ADDITIONAL SAFETY: Ensure box is below camera level and not too high
        if boxPosition.y > cameraPos.y - 0.5 {
            boxPosition.y = cameraPos.y - 1.5 // Ensure it's at least 1.5m below camera
            Swift.print("⚠️ Adjusted \(location.name) to be below camera level")
        }
        
        // Use the standard placement function instead of duplicating logic
        placeBoxAtPosition(boxPosition, location: location, in: arView)
        Swift.print("✅ Placed \(location.name) in front of camera (fallback) at: \(boxPosition)")
        Swift.print("   Distance from camera: \(String(format: "%.2f", finalDistance))m")
    }
    
    
    
    // MARK: - Find Loot Box Helper
    /// Finds any findable object using the FindableObject base class behavior
    private func findLootBox(locationId: String, anchor: AnchorEntity, cameraPosition: SIMD3<Float>, sphereEntity: ModelEntity?) {
        guard !(distanceTracker?.foundLootBoxes.contains(locationId) ?? false) else {
            return // Already found
        }
        
        // Mark as found to prevent duplicate finds
        distanceTracker?.foundLootBoxes.insert(locationId)
        tapHandler?.foundLootBoxes.insert(locationId)
        
        // Remove distance text when found
        if let textEntity = distanceTracker?.distanceTextEntities[locationId] {
            textEntity.removeFromParent()
            distanceTracker?.distanceTextEntities.removeValue(forKey: locationId)
        }
        
        // Get or create FindableObject for this location
        var findableObject: FindableObject
        if let existing = findableObjects[locationId] {
            // Use existing FindableObject (already has container/sphere info)
            findableObject = existing
            Swift.print("✅ Using existing FindableObject for \(locationId)")
            Swift.print("   Has container: \(findableObject.container != nil)")
            Swift.print("   Has location: \(findableObject.location != nil)")
            // Update sphereEntity if provided (in case it wasn't set initially)
            if let sphereEntity = sphereEntity {
                findableObject.sphereEntity = sphereEntity
            }
        } else {
            Swift.print("⚠️ Creating new FindableObject for \(locationId) (should not happen if placed correctly)")
            // Create new FindableObject (fallback case - should rarely happen)
            let location = locationManager?.locations.first(where: { $0.id == locationId })
            var container: LootBoxContainer? = nil
            
            // Try to get container from component
            if let info = anchor.components[LootBoxInfoComponent.self] {
                container = info.container
            }
            
            // If no container from component, try to find it in anchor's children
            // (containers are typically the main child entity)
            if container == nil {
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity,
                       child.name == locationId || child.name.contains("container") {
                        // This might be a container - check if it has prize/lid children
                        // For now, we'll create a minimal container structure if needed
                        // But ideally containers should be stored in FindableObject when placed
                    }
                }
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
        
        // CRITICAL: Mark as collected IMMEDIATELY to prevent re-placement by checkAndPlaceBoxes
        // This must happen before the animation starts to prevent race conditions
        if let foundLocation = findableObject.location {
            DispatchQueue.main.async { [weak self] in
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(foundLocation.id)
                    Swift.print("✅ Marked \(foundLocation.name) as collected immediately to prevent re-placement")
                }
            }
        }
        
        // Use FindableObject's find() method - this encapsulates all the basic findable behavior
        // The notification will appear AFTER animation completes
        let objectName = findableObject.itemDescription()
        findableObject.find { [weak self] in
            // Show discovery notification AFTER animation completes
            DispatchQueue.main.async { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = "🎉 Discovered: \(objectName)!"
            }
            
            // Hide notification after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = nil
            }
            
            // Cleanup after find completes
            self?.placedBoxes.removeValue(forKey: locationId)
            self?.findableObjects.removeValue(forKey: locationId)
            self?.objectsInViewport.remove(locationId) // Also remove from viewport tracking
            
            // Remove randomized AR items from locationManager when found (they're AR-only, not GPS-based)
            // This keeps the counter accurate - only shows items that are actually placed on screen
            if locationId.hasPrefix("AR_ITEM_") || locationId.hasPrefix("AR_SPHERE_") {
                DispatchQueue.main.async { [weak self] in
                    if let locationManager = self?.locationManager {
                        // Remove the location from locationManager since it's no longer on screen
                        locationManager.locations.removeAll { $0.id == locationId }
                        Swift.print("🗑️ Removed AR item \(locationId) from locationManager (no longer on screen)")
                    }
                }
            }
            
            Swift.print("🎉 Collected: \(objectName)")

            // Check if all randomized AR items are found and disable sphere mode
            if let self = self, self.sphereModeActive {
                // Check for both old AR_SPHERE_ prefix and new AR_ITEM_ prefix
                let remainingItems = self.placedBoxes.keys.filter { 
                    $0.hasPrefix("AR_SPHERE_") || $0.hasPrefix("AR_ITEM_")
                }
                if remainingItems.isEmpty {
                    Swift.print("🎯 All randomized AR items collected - exiting sphere mode")
                    self.sphereModeActive = false
                }
            }
        }
    }
    
    // MARK: - Tap Handling (delegated to ARTapHandler)
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        tapHandler?.handleTap(sender)
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
        Swift.print("   Placed boxes count: \(placedBoxes.count), keys: \(placedBoxes.keys.sorted())")
        
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

        Swift.print("🎯 Tap entity hit test result: \(tappedEntity != nil ? "hit entity" : "no entity hit")")

        // Walk up the entity hierarchy to find the location ID
        var entityToCheck = tappedEntity
        while let currentEntity = entityToCheck {
            let entityName = currentEntity.name
            Swift.print("🎯 Checking entity: '\(entityName)'")
            // Entity.name is a String, not String?, so check if it's not empty
            if !entityName.isEmpty {
                let idString = entityName
                // Check if this ID matches a placed box
                if placedBoxes[idString] != nil {
                    locationId = idString
                    Swift.print("🎯 Found matching placed box ID: \(idString)")
                    break
                }
            }
            entityToCheck = currentEntity.parent
        }
        
        // If entity hit didn't work, try proximity-based detection using screen-space projection
        // Check all placed boxes to see if tap is near any of them on screen
        if locationId == nil && !placedBoxes.isEmpty {
            var closestBoxId: String? = nil
            var closestScreenDistance: CGFloat = CGFloat.infinity
            let maxScreenDistance: CGFloat = 150.0 // Maximum screen distance in points to consider a tap "on" the box
            
            // Use ARView's project method to convert world positions to screen coordinates
            for (boxId, anchor) in placedBoxes {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Project the box's world position to screen coordinates
                guard let optionalScreenPoint = arView.project(anchorWorldPos) else {
                    // Box is not visible (behind camera or outside view)
                    continue
                }
                let screenPoint = optionalScreenPoint
                
                // Check if the projection is valid (box is visible on screen)
                let viewWidth = CGFloat(arView.bounds.width)
                let viewHeight = CGFloat(arView.bounds.height)
                let pointX = screenPoint.x
                let pointY = screenPoint.y
                let isOnScreen = pointX >= 0 && pointX <= viewWidth &&
                                 pointY >= 0 && pointY <= viewHeight
                
                if isOnScreen {
                    // Calculate screen-space distance from tap to box
                    let tapX = CGFloat(tapLocation.x)
                    let tapY = CGFloat(tapLocation.y)
                    let dx = tapX - screenPoint.x
                    let dy = tapY - screenPoint.y
                    let screenDistance = sqrt(dx * dx + dy * dy)
                    
                    // Also check world-space distance if we have tap world position (for validation)
                    var worldDistance: Float = Float.infinity
                    if let tapPos = tapWorldPosition {
                        worldDistance = length(anchorWorldPos - tapPos)
                    }
                    
                    // If screen distance is within threshold, consider it a hit
                    if screenDistance < maxScreenDistance {
                        // If we have world position, prefer boxes that are also close in world space
                        let isCloseInWorld = worldDistance < 10.0
                        let shouldSelect = worldDistance == Float.infinity || isCloseInWorld
                        
                        if shouldSelect && screenDistance < closestScreenDistance {
                            closestScreenDistance = screenDistance
                            closestBoxId = boxId
                            if worldDistance != Float.infinity {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px, world dist=\(String(format: "%.2f", worldDistance))m")
                            } else {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px")
                            }
                        }
                    }
                } else {
                    // Box is not visible on screen (behind camera or outside view)
                    Swift.print("   Box \(boxId) is off-screen (projected to: (\(String(format: "%.1f", screenPoint.x)), \(String(format: "%.1f", screenPoint.y))))")
                }
            }
            
            if let closestId = closestBoxId {
                locationId = closestId
                Swift.print("🎯 Detected tap on box via screen projection: \(closestId), screen distance: \(String(format: "%.1f", closestScreenDistance))px")
            } else {
                Swift.print("⚠️ Tap did not hit any box. Tap world pos: \(tapWorldPosition != nil ? "yes" : "no"), boxes checked: \(placedBoxes.count)")
                // Debug: show where boxes are projected
                for (boxId, anchor) in placedBoxes {
                    let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                    let anchorWorldPos = SIMD3<Float>(
                        anchorTransform.columns.3.x,
                        anchorTransform.columns.3.y,
                        anchorTransform.columns.3.z
                    )
                    if let screenPoint = arView.project(anchorWorldPos) {
                        let distanceFromCamera = length(anchorWorldPos - cameraPos)
                        Swift.print("   Box \(boxId): screen=(\(String(format: "%.1f", screenPoint.x)), \(String(format: "%.1f", screenPoint.y))), camera dist=\(String(format: "%.2f", distanceFromCamera))m")
                    } else {
                        Swift.print("   Box \(boxId): not projectable (behind camera)")
                    }
                }
            }
        }
        
        // UNIFIED FINDABLE BEHAVIOR: All objects in placedBoxes are findable and clickable
        // If we found a location ID (tapped on any findable object), trigger find behavior
        Swift.print("🎯 Tap result: locationId = \(locationId ?? "nil")")
        if let idString = locationId {
            Swift.print("🎯 Processing tap on: \(idString)")
            
            // Check if already found - but also check if location was reset
            // If location is not collected, allow tapping again (reset functionality)
            let isLocationCollected = locationManager.locations.first(where: { $0.id == idString })?.collected ?? false
            
            let isFound = (distanceTracker?.foundLootBoxes.contains(idString) ?? false) || (tapHandler?.foundLootBoxes.contains(idString) ?? false)
            if isFound && isLocationCollected {
                Swift.print("⚠️ Object \(idString) has already been found and is still marked as collected")
                return
            } else if isFound && !isLocationCollected {
                // Location was reset - clear from found set to allow tapping again
                distanceTracker?.foundLootBoxes.remove(idString)
                tapHandler?.foundLootBoxes.remove(idString)
                Swift.print("🔄 Object \(idString) was reset - clearing from found set, allowing tap again")
            }
            
            // Check if in location manager and already collected
            if let location = locationManager.locations.first(where: { $0.id == idString }),
               location.collected {
                Swift.print("⚠️ \(location.name) has already been collected")
                return
            }
            
            // Get the anchor for this object
            guard let anchor = placedBoxes[idString] else {
                Swift.print("⚠️ Anchor not found for \(idString)")
                return
            }
            
            // Get camera position
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            
            // Find the sphere entity if it exists (for objects with spheres)
            var sphereEntity: ModelEntity? = nil
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.components[PointLightComponent.self] != nil {
                    sphereEntity = modelEntity
                    break
                }
            }
            
            // Use unified findLootBox for ALL objects (spheres, chalices, treasure boxes, etc.)
            // This handles: sound, confetti, animation, increment count, and removal
            Swift.print("🎯 Finding object: \(idString) (type: sphere=\(sphereEntity != nil), has findableObject=\(findableObjects[idString] != nil))")
            findLootBox(locationId: idString, anchor: anchor, cameraPosition: cameraPos, sphereEntity: sphereEntity)
            return
        }
        
        // If no location-based system or not at a location, allow manual placement
        // Place a test loot box where user taps (for testing without locations)
        if placedBoxes.count >= 3 {
            Swift.print("🎯 Maximum 3 objects reached - cannot place more via tap")
            return
        }

        // Prevent rapid duplicate tap placements (debounce)
        let now = Date()
        if let lastTap = tapHandler?.lastTapPlacementTime,
           now.timeIntervalSince(lastTap) < 1.0 {
            Swift.print("⚠️ Tap placement blocked - too soon since last placement (\(String(format: "%.1f", now.timeIntervalSince(lastTap)))s ago)")
            return
        }
        tapHandler?.lastTapPlacementTime = now

        if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first,
           let frame = arView.session.currentFrame {
            let cameraY = frame.camera.transform.columns.3.y
            let hitY = result.worldTransform.columns.3.y
            if hitY <= cameraY - 0.2 {
                let testLocation = LootBoxLocation(
                    id: UUID().uuidString,
                    name: "Test Artifact",
                    type: .templeRelic,
                    latitude: 0,
                    longitude: 0,
                    radius: 100
                )
                // For manual tap placement, allow closer placement (1-2m instead of 3-5m)
                // Add to locationManager FIRST so it's tracked, then place it
                // This ensures the location exists before placement and prevents duplicates
                locationManager.addLocation(testLocation)
                placeLootBoxAtTapLocation(testLocation, tapResult: result, in: arView)
            } else {
                Swift.print("⚠️ Tap raycast hit likely ceiling. Ignoring manual placement.")
            }
        }
    }

    // Place a single sphere in the current AR room
    func placeSingleSphere(locationId: String? = nil) {
        Swift.print("🎯 placeSingleSphere() called - checking if already placed recently...")

        // Prevent multiple placements from rapid view updates
        let now = Date()
        if let lastPlacement = lastSpherePlacementTime,
           now.timeIntervalSince(lastPlacement) < 2.0 {
            Swift.print("⚠️ Sphere placement blocked - too soon since last placement (\(String(format: "%.1f", now.timeIntervalSince(lastPlacement)))s ago)")
            return
        }
        lastSpherePlacementTime = now

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            Swift.print("⚠️ Cannot place single sphere: AR not ready")
            return
        }

        // Limit to maximum objects
        guard placedBoxes.count < 6 else {
            Swift.print("🎯 Maximum 6 objects reached - not placing sphere")
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Try to find ground plane for proper placement
        let raycastQuery = ARRaycastQuery(
            origin: cameraPos,
            direction: SIMD3<Float>(0, -1, 0), // Downward ray
            allowing: .estimatedPlane,
            alignment: .horizontal
        )

        var spherePosition: SIMD3<Float>

        if let raycastResult = arView.session.raycast(raycastQuery).first {
            // Place on detected ground plane, 2m in front of camera
            let groundY = raycastResult.worldTransform.columns.3.y
            let forwardDirection = SIMD3<Float>(
                -cameraTransform.columns.2.x, // Forward vector (negative Z in camera space)
                0,
                -cameraTransform.columns.2.z
            )
            let forwardPos = cameraPos + normalize(forwardDirection) * 2.0
            spherePosition = SIMD3<Float>(forwardPos.x, groundY, forwardPos.z)
            Swift.print("✅ Placed sphere on detected ground plane at Y: \(groundY)")
        } else {
            // Fallback: place 2m in front at current camera height
            spherePosition = cameraPos + SIMD3<Float>(0, 0, -2)
            Swift.print("⚠️ No ground plane detected, placing at camera height")
        }

        // Use provided location ID (from map marker) or create a new one
        let newLocation: LootBoxLocation
        if let existingLocationId = locationId,
           let existingLocation = locationManager.locations.first(where: { $0.id == existingLocationId }) {
            // Use the existing map marker location
            newLocation = existingLocation
            Swift.print("✅ Using existing map marker location: \(existingLocationId)")
        } else {
            // Create a new location (fallback for manual sphere placement)
            newLocation = LootBoxLocation(
                id: "AR_SPHERE_" + UUID().uuidString,
                name: "Mysterious Sphere",
                type: .sphere,
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0 // Large radius since we're not using GPS
            )
            // Add to locationManager so it counts toward the total
            // Note: AR_SPHERE_ items are temporary and won't sync to API (by design)
            locationManager.addLocation(newLocation)
            Swift.print("✅ Created new location for sphere: \(newLocation.id)")
            Swift.print("   📍 Note: Temporary AR sphere (AR_SPHERE_ prefix) will NOT sync to API")
        }

        // Create sphere directly
        let sphereRadius: Float = 0.15
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: .red)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = newLocation.id // This is crucial for tap detection

        // Position sphere so bottom sits flat on ground
        sphere.position = SIMD3<Float>(0, sphereRadius, 0) // Bottom of sphere touches ground

        // Add point light to make it visible
        let light = PointLightComponent(color: .red, intensity: 200)
        sphere.components.set(light)

        // Create anchor and add sphere
        let anchor = AnchorEntity(world: spherePosition)
        anchor.addChild(sphere)

        arView.scene.addAnchor(anchor)
        placedBoxes[newLocation.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to mark as collected when found
        findableObjects[newLocation.id] = FindableObject(
            locationId: newLocation.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: nil,
            location: newLocation
        )

        findableObjects[newLocation.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        Swift.print("✅ Placed single sphere at position (\(spherePosition.x), \(spherePosition.y), \(spherePosition.z))")
    }

    // Place any AR item in the current AR room (same size as spheres)
    func placeARItem(_ item: LootBoxLocation) {
        Swift.print("🎯 placeARItem() called for: \(item.name) (ID: \(item.id)) at GPS (\(item.latitude), \(item.longitude))")
        
        // Check if this item should sync to API
        let isTemporaryARItem = item.id.hasPrefix("AR_ITEM_") || 
                               (item.id.hasPrefix("AR_SPHERE_") && !item.id.hasPrefix("AR_SPHERE_MAP_"))
        if isTemporaryARItem {
            Swift.print("   ⏭️ This is a temporary AR item - will NOT sync to API")
        } else {
            Swift.print("   🔄 This is a permanent item - should sync to API if API sync is enabled")
            // Check if item is already in locationManager (which means it should be synced)
            if let existingLocation = locationManager?.locations.first(where: { $0.id == item.id }) {
                Swift.print("   ✅ Item already exists in locationManager - API sync status depends on useAPISync setting")
            } else {
                Swift.print("   ⚠️ Item not found in locationManager - may need to be added/synced")
            }
        }

        // CRITICAL: Check if this item is already placed to prevent duplicates
        if placedBoxes[item.id] != nil {
            Swift.print("⚠️ Item \(item.name) (ID: \(item.id)) already placed - skipping duplicate placement")
            return
        }

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager,
              let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ Cannot place AR item: AR not ready or no user location")
            return
        }

        // Limit to maximum objects
        guard placedBoxes.count < 6 else {
            Swift.print("🎯 Maximum 6 objects reached - not placing item")
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Calculate GPS-based position
        let targetLocation = CLLocation(latitude: item.latitude, longitude: item.longitude)
        var distance = userLocation.distance(from: targetLocation) // Distance in meters
        let bearing = userLocation.bearing(to: targetLocation) // Bearing in degrees (0-360, 0 = North)
        
        // Ensure minimum distance of 1m for AR placement (items too close are hard to interact with)
        let minDistance: Double = 1.0
        if distance < minDistance {
            Swift.print("⚠️ GPS distance \(String(format: "%.2f", distance))m is too close, using minimum \(minDistance)m")
            distance = minDistance
        }
        
        Swift.print("📍 GPS offset: \(String(format: "%.2f", distance))m at bearing \(String(format: "%.1f", bearing))°")

        // Convert bearing to radians and calculate offset in AR space
        // ARKit uses a right-handed coordinate system where:
        // - X is right (east)
        // - Z is forward (north when camera faces north)
        // - Y is up
        // We need to account for the camera's current orientation
        
        // Get camera's forward direction in AR space
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            0,
            -cameraTransform.columns.2.z
        )
        let cameraRight = SIMD3<Float>(
            cameraTransform.columns.0.x,
            0,
            cameraTransform.columns.0.z
        )
        
        // Normalize directions
        let forwardDir = normalize(cameraForward)
        let rightDir = normalize(cameraRight)
        
        // Calculate bearing relative to camera's forward direction
        // We need to know which way the camera is facing in GPS terms
        // For now, assume camera forward is roughly north and calculate relative bearing
        // Convert bearing to radians (0 = North, 90 = East, 180 = South, 270 = West)
        let bearingRad = Float(bearing * .pi / 180.0)
        
        // Calculate offset in AR space: use distance and bearing
        // X = distance * sin(bearing) (east/west)
        // Z = distance * cos(bearing) (north/south)
        // But we need to align with camera's orientation
        // For simplicity, place relative to camera's current position
        let offsetX = Float(distance) * sin(bearingRad)
        let offsetZ = Float(distance) * cos(bearingRad)
        
        // Apply offset relative to camera's orientation
        // Rotate the offset to match camera's current orientation
        // This is a simplified approach - for more accuracy, we'd need compass heading
        let targetPos = cameraPos + rightDir * offsetX + forwardDir * offsetZ
        
        // Clamp distance to reasonable AR space (max 10m)
        let clampedDistance = min(distance, 10.0)
        if distance > 10.0 {
            Swift.print("⚠️ GPS distance \(String(format: "%.2f", distance))m exceeds 10m, clamping to 10m for AR placement")
            let scale = Float(10.0 / distance)
            let adjustedTargetPos = cameraPos + (targetPos - cameraPos) * scale
            // Find the highest blocking surface at adjusted position
            var itemPosition: SIMD3<Float>
            if let surfaceY = groundingService?.findHighestBlockingSurface(x: adjustedTargetPos.x, z: adjustedTargetPos.z, cameraPos: cameraPos) {
                itemPosition = SIMD3<Float>(adjustedTargetPos.x, surfaceY, adjustedTargetPos.z)
                Swift.print("✅ Placed \(item.type.displayName) on surface at AR position (\(String(format: "%.2f", adjustedTargetPos.x)), \(String(format: "%.2f", surfaceY)), \(String(format: "%.2f", adjustedTargetPos.z)))")
            } else {
                itemPosition = adjustedTargetPos
                Swift.print("⚠️ No surface detected, placing at camera height")
            }
            
            // Location is already added to locationManager in addFindableItem, no need to add again
            // Use unified placeBoxAtPosition which handles all object types correctly
            placeBoxAtPosition(itemPosition, location: item, in: arView)
            return
        }

        // Find the highest blocking surface at target position
        var itemPosition: SIMD3<Float>
        if let surfaceY = groundingService?.findHighestBlockingSurface(x: targetPos.x, z: targetPos.z, cameraPos: cameraPos) {
            itemPosition = SIMD3<Float>(targetPos.x, surfaceY, targetPos.z)
            Swift.print("✅ Placed \(item.type.displayName) on surface at AR position (\(String(format: "%.2f", targetPos.x)), \(String(format: "%.2f", surfaceY)), \(String(format: "%.2f", targetPos.z))) based on GPS offset")
        } else {
            // Fallback: place at target position at current camera height
            itemPosition = targetPos
            Swift.print("⚠️ No surface detected, placing \(item.type.displayName) at camera height")
        }

        // Location is already added to locationManager in addFindableItem, no need to add again
        // Use unified placeBoxAtPosition which handles all object types correctly
        placeBoxAtPosition(itemPosition, location: item, in: arView)
    }

    private func createSphereEntity(at position: SIMD3<Float>, item: LootBoxLocation, in arView: ARView) {
        // Create sphere directly (same as placeSingleSphere)
        let sphereRadius: Float = 0.15
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: item.type.color)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = item.id

        // Position sphere so bottom sits flat on ground
        sphere.position = SIMD3<Float>(0, sphereRadius, 0)

        // Add point light to make it visible
        let light = PointLightComponent(color: item.type.glowColor, intensity: 200)
        sphere.components.set(light)

        // Create anchor and add sphere
        let anchor = AnchorEntity(world: position)
        anchor.addChild(sphere)

        arView.scene.addAnchor(anchor)
        placedBoxes[item.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to mark as collected when found
        findableObjects[item.id] = FindableObject(
            locationId: item.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: nil,
            location: item
        )

        findableObjects[item.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        Swift.print("✅ Placed sphere \(item.name) at position (\(position.x), \(position.y), \(position.z))")
    }

    private func placeItemAsBox(at position: SIMD3<Float>, item: LootBoxLocation, in arView: ARView) {
        // Create a box entity scaled to sphere size (0.15 radius = 0.3 diameter)
        let boxSize: Float = 0.3 // Same size as sphere diameter

        // Create a simple box for the item
        let boxMesh = MeshResource.generateBox(width: boxSize, height: boxSize, depth: boxSize, cornerRadius: 0.05)
        var boxMaterial = SimpleMaterial()
        boxMaterial.color = .init(tint: item.type.color)
        boxMaterial.roughness = 0.3
        boxMaterial.metallic = 0.5

        let boxEntity = ModelEntity(mesh: boxMesh, materials: [boxMaterial])
        boxEntity.name = item.id

        // Position box so bottom sits on ground
        boxEntity.position = SIMD3<Float>(0, boxSize/2, 0)

        // Add point light for visibility
        let light = PointLightComponent(color: item.type.glowColor, intensity: 150)
        boxEntity.components.set(light)

        // Create anchor and add box
        let anchor = AnchorEntity(world: position)
        anchor.addChild(boxEntity)

        arView.scene.addAnchor(anchor)
        placedBoxes[item.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to mark as collected when found
        findableObjects[item.id] = FindableObject(
            locationId: item.id,
            anchor: anchor,
            sphereEntity: nil, // Not a sphere
            container: nil, // Simple box, no container
            location: item
        )

        findableObjects[item.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        Swift.print("✅ Placed \(item.type.displayName) \(item.name) as box at position (\(position.x), \(position.y), \(position.z))")
    }

}
