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
    private var precisionPositioningService: ARPrecisionPositioningService? // Legacy - kept for compatibility
    private var geospatialService: ARGeospatialService? // New ENU-based geospatial service
    
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var placedBoxes: [String: AnchorEntity] = [:]
    private var findableObjects: [String: FindableObject] = [:] // Track all findable objects
    private var arOriginLocation: CLLocation? // GPS location when AR session started
    private var arOriginSetTime: Date? // When AR origin was set (for degraded mode timeout)
    private var isDegradedMode: Bool = false // True if operating without GPS (AR-only mode)
    private var arOriginGroundLevel: Float? // Fixed ground level at AR origin (never changes)
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var collectionNotificationBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    private var lastSpherePlacementTime: Date? // Prevent rapid duplicate sphere placements
    private var sphereModeActive: Bool = false // Track when we're in sphere randomization mode
    private var hasAutoRandomized: Bool = false // Track if we've already auto-randomized spheres
    private var shouldForceReplacement: Bool = false // Force re-placement after reset when AR is ready
    var lastAppliedLensId: String? = nil // Track last applied AR lens to prevent redundant session resets

    // Arrow direction tracking
    @Published var nearestObjectDirection: Double? = nil // Direction in degrees (0 = north, 90 = east, etc.)
    
    // Viewport visibility tracking for chime sounds
    private var objectsInViewport: Set<String> = [] // Track which objects are currently visible
    private var lastViewportCheck: Date = Date() // Throttle viewport checks to improve framerate
    
    // Throttling for object recognition and placement checks
    private var lastRecognitionTime: Date = Date() // Throttle object recognition to improve framerate
    private var lastDegradedModeLogTime: Date? // Throttle degraded mode logging
    private var lastPlacementCheck: Date = Date() // Throttle box placement checks to improve framerate
    
    override init() {
        super.init()
    }
    
    /// Play a chime sound when an object enters the viewport
    /// Uses a different, gentler sound than the treasure found sound
    private func playViewportChime(for locationId: String) {
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session for chime: \(error)")
        }
        
        // Get object details for logging
        let location = locationManager?.locations.first(where: { $0.id == locationId })
        let objectName = location?.name ?? "Unknown"
        let objectType = location?.type.displayName ?? "Unknown Type"
        
        // Use a gentle system notification sound for viewport entry
        // System sound 1103 is a soft, pleasant notification chime
        // This is different from the treasure found sound (level-up-01.mp3)
        AudioServicesPlaySystemSound(1103) // Soft notification sound for viewport entry
        Swift.print("🔔 SOUND: Viewport chime (system sound 1103)")
        Swift.print("   Trigger: Object entered viewport")
        Swift.print("   Object: \(objectName) (\(objectType))")
        Swift.print("   Location ID: \(locationId)")
    }
    
    /// Check if an object is currently visible in the viewport
    private func isObjectInViewport(locationId: String, anchor: AnchorEntity) -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return false }
        
        // Get camera position and forward direction
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Camera forward direction is the negative Z axis in camera space (columns.2)
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        
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
        
        // CRITICAL: Check if object is in front of camera (not behind)
        // Calculate vector from camera to object
        let cameraToObject = bestPosition - cameraPos
        let _ = length(cameraToObject) // Distance check (unused but calculated for future use)
        
        // Normalize camera forward direction for dot product
        let normalizedForward = normalize(cameraForward)
        let normalizedToObject = normalize(cameraToObject)
        
        // Dot product: positive = in front, negative = behind, zero = perpendicular
        let dotProduct = dot(normalizedForward, normalizedToObject)
        
        // Only consider objects that are in front of the camera (dot product > 0)
        // Use a small threshold (0.0) to avoid edge cases at exactly 90 degrees
        guard dotProduct > 0.0 else {
            return false // Object is behind camera
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
                    playViewportChime(for: locationId)
                    
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
        
        // Set up callback to remove objects from AR when collected by other users
        locationManager.onObjectCollectedByOtherUser = { [weak self] objectId in
            self?.handleObjectCollectedByOtherUser(objectId: objectId)
        }
        
        // Store the GPS location when AR starts (this becomes our AR world origin)
        arOriginLocation = userLocationManager.currentLocation
        
        // Set AR coordinator reference in user location manager for enhanced location tracking
        userLocationManager.arCoordinator = self
        
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
        precisionPositioningService = ARPrecisionPositioningService(arView: arView) // Legacy
        geospatialService = ARGeospatialService() // New ENU-based service

        // Start periodic grounding checks to ensure objects stay on surfaces
        // This continuously monitors for better surface data and re-grounds objects when found
        startPeriodicGrounding()

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
    
    /// Handle when an object is collected by another user - remove it from AR scene
    private func handleObjectCollectedByOtherUser(objectId: String) {
        guard arView != nil else { return }
        
        // Check if this object is currently placed in AR
        guard let anchor = placedBoxes[objectId] else {
            Swift.print("ℹ️ Object \(objectId) collected by another user but not currently in AR scene")
            return
        }
        
        // Get object name for logging
        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"
        
        Swift.print("🗑️ Removing object '\(objectName)' (ID: \(objectId)) from AR - collected by another user")
        
        // Remove from AR scene
        anchor.removeFromParent()
        
        // Remove from tracking dictionaries
        placedBoxes.removeValue(forKey: objectId)
        findableObjects.removeValue(forKey: objectId)
        objectsInViewport.remove(objectId)
        
        // Also remove from distance tracker if applicable
        distanceTracker?.foundLootBoxes.insert(objectId)
        if let textEntity = distanceTracker?.distanceTextEntities[objectId] {
            textEntity.removeFromParent()
            distanceTracker?.distanceTextEntities.removeValue(forKey: objectId)
        }
        
        Swift.print("✅ Object '\(objectName)' removed from AR scene")
    }
    
    // Clear found loot boxes set - makes objects tappable again after reset
    func clearFoundLootBoxes() {
        distanceTracker?.clearFoundLootBoxes()
        tapHandler?.foundLootBoxes.removeAll()
    }
    
    // Remove all placed objects from AR scene and clear tracking dictionaries
    // This allows objects to be re-placed at their proper GPS locations after reset
    func removeAllPlacedObjects() {
        guard arView != nil else { return }
        
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
        stopPeriodicGrounding()
    }

    /// Timer for periodic grounding checks
    private var groundingTimer: Timer?

    /// Track when we last checked grounding for each object (to avoid excessive raycasting)
    private var lastGroundingCheck: [String: Date] = [:]

    /// Starts periodic grounding checks to ensure objects stay on surfaces
    /// DISABLED: Periodic grounding causes objects to move when camera moves
    /// Objects are now placed once and never moved to ensure stability
    private func startPeriodicGrounding() {
        // DISABLED: Periodic grounding causes drift
        // Objects are placed at final positions and never modified
        // This ensures maximum stability and prevents objects from moving when camera moves
        Swift.print("⏸️ Periodic grounding DISABLED - objects stay fixed at placement position for maximum stability")
    }

    /// Stops periodic grounding checks
    private func stopPeriodicGrounding() {
        groundingTimer?.invalidate()
        groundingTimer = nil
        Swift.print("⏹️ Stopped periodic grounding checks")
    }

    /// Performs a grounding check on all placed objects
    /// DISABLED: This function is disabled to prevent objects from moving after placement
    /// Objects are placed once at their final position and never modified
    private func performGroundingCheck() {
        // DISABLED: Moving objects after placement causes drift
        // Objects maintain their exact placement position for maximum stability
    }

    /// Re-grounds all placed objects immediately (called when new planes detected)
    /// DISABLED: This function is disabled to prevent objects from moving after placement
    /// Objects are placed once at their final position and never modified
    private func regroundAllObjects() {
        // DISABLED: Moving objects after placement causes drift
        // Objects maintain their exact placement position for maximum stability
        Swift.print("⏸️ Re-grounding disabled - objects stay fixed at placement position")
    }
    
    /// Enters degraded AR-only mode when GPS is unavailable
    /// In this mode, objects are placed relative to AR origin (0,0,0) without GPS coordinates
    private func enterDegradedMode(cameraPos: SIMD3<Float>, frame: ARFrame) {
        guard arOriginLocation == nil else { return } // Already set
        
        isDegradedMode = true
        
        // Set AR origin to current camera position (0,0,0 in AR space)
        // This is the AR session origin, not a GPS location
        arOriginLocation = nil // No GPS in degraded mode
        arOriginSetTime = Date()
        
        // Set fixed ground level using surface detection or camera estimate
        let groundLevel: Float
        if let surfaceY = groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
            groundLevel = surfaceY
            Swift.print("📍 Degraded mode: Ground level from surface detection: \(String(format: "%.2f", groundLevel))m")
        } else {
            groundLevel = cameraPos.y - 1.5
            Swift.print("📍 Degraded mode: Ground level estimated: \(String(format: "%.2f", groundLevel))m")
        }
        
        arOriginGroundLevel = groundLevel
        geospatialService?.enterDegradedMode(groundLevel: groundLevel)
        precisionPositioningService?.setAROriginGroundLevel(groundLevel) // Legacy compatibility
        
        Swift.print("⚠️ ENTERED DEGRADED MODE (AR-only, no GPS)")
        Swift.print("   Objects will be placed relative to AR origin (0,0,0)")
        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED - never changes)")
        Swift.print("   GPS-based objects will not be placed in this mode")
        Swift.print("   AR-only objects (tap-to-place, randomize) will work normally")
    }
    
    /// Legacy function - kept for compatibility but disabled
    private func regroundAllObjectsLegacy() {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        var regroundedCount = 0

        for (locationId, anchor) in placedBoxes {
            // Get anchor's current position
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let currentX = anchorTransform.columns.3.x
            let currentZ = anchorTransform.columns.3.z
            let currentY = anchorTransform.columns.3.y

            // Try to find a surface at this X/Z position
            if let surfaceY = groundingService?.findHighestBlockingSurface(x: currentX, z: currentZ, cameraPos: cameraPos) {
                // Check if object is significantly above the detected surface (floating)
                let heightDifference = currentY - surfaceY

                // DISABLED: Never re-ground objects - they should stay exactly where they were placed
                // Objects should NEVER move after being placed, especially for the user who placed them
                // if heightDifference > 0.05 { // More than 5cm above surface = floating
                //     Swift.print("🔧 Immediate re-ground '\(locationId)': Y=\(String(format: "%.2f", currentY)) → Y=\(String(format: "%.2f", surfaceY)) (dropped \(String(format: "%.2f", heightDifference))m)")
                //     anchor.transform.translation = SIMD3<Float>(currentX, surfaceY, currentZ)
                //     regroundedCount += 1
                //     lastGroundingCheck[locationId] = Date()
                // }
            }
        }

        if regroundedCount > 0 {
            Swift.print("✅ Immediate re-ground: Fixed \(regroundedCount) floating object(s)")
        }
    }
    
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard let arView = arView else { return }

        // PERFORMANCE: Logging disabled - print statements are EXTREMELY expensive (blocks main thread)
        // 677 print statements in codebase causing major freezing
        // Only log critical errors and performance metrics
        let debugLogging = false // Set to true only when actively debugging

        if debugLogging {
            Swift.print("🔍 checkAndPlaceBoxes called:")
            Swift.print("   Nearby: \(nearbyLocations.count), Placed: \(placedBoxes.count)")
        }

        // CRITICAL: Only remove objects that are no longer in the nearbyLocations list AND are not manually placed
        // Manually placed objects (with AR coordinates) should NEVER be removed or moved
        let nearbyLocationIds = Set(nearbyLocations.map { $0.id })
        var objectsToRemove: [String] = []
        var manuallyPlacedObjects: Set<String> = []

        for (locationId, _) in placedBoxes {
            // Check if this object was manually placed (has AR coordinates)
            // Manually placed objects should NEVER be removed OR re-placed
            if let existingLocation = locationManager?.locations.first(where: { $0.id == locationId }) {
                let isManuallyPlaced = existingLocation.ar_offset_x != nil &&
                                      existingLocation.ar_offset_y != nil &&
                                      existingLocation.ar_offset_z != nil

                if isManuallyPlaced {
                    manuallyPlacedObjects.insert(locationId)
                }
            }

            // If this placed object is not in the current nearby locations list, check if it should be removed
            if !nearbyLocationIds.contains(locationId) {
                // Never remove manually placed objects
                if manuallyPlacedObjects.contains(locationId) {
                    continue
                }

                // Only remove objects that weren't manually placed
                objectsToRemove.append(locationId)
            }
        }

        // Remove the unselected objects from the scene (but never manually placed ones)
        for locationId in objectsToRemove {
            if let anchor = placedBoxes[locationId] {
                anchor.removeFromParent()
                placedBoxes.removeValue(forKey: locationId)
                findableObjects.removeValue(forKey: locationId)
                objectsInViewport.remove(locationId)
            }
        }

        // Allow GPS-based loot boxes even when spheres are active
        // Limit to maximum 6 objects total (3 spheres + 3 GPS boxes)
        guard placedBoxes.count < 6 else {
            return
        }

        for location in nearbyLocations {
            // Stop if we've reached the limit
            guard placedBoxes.count < 6 else { break }

            // Skip locations that are already placed (double-check to prevent duplicates)
            // CRITICAL: Never re-place objects that are already placed - they should stay fixed
            // This is especially important for manually placed objects with AR coordinates
            if placedBoxes[location.id] != nil {
                continue
            }

            // Skip tap-created locations (lat: 0, lon: 0) - they're placed manually via tap
            // These should not be placed again by checkAndPlaceBoxes
            if location.latitude == 0 && location.longitude == 0 {
                continue
            }

            // Skip if already collected (critical check to prevent re-placement after finding)
            if location.collected {
                continue
            }
            
            // CRITICAL: Check for GPS collision - if another object with same/similar GPS coordinates is already placed OR in the current batch
            // Instead of skipping, offset the location by 5m in a random direction
            var locationToPlace = location
            if location.latitude != 0 && location.longitude != 0 {
                let newLoc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                var offsetApplied = false
                
                // First check against already-placed objects
                for (existingId, _) in placedBoxes {
                    // Find the location for this existing object
                    if let existingLocation = nearbyLocations.first(where: { $0.id == existingId }) {
                        // Check if GPS coordinates are very close (within 1 meter)
                        let existingLoc = CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude)
                        let gpsDistance = existingLoc.distance(from: newLoc)

                        if gpsDistance < 1.0 {
                            // Offset by 5 meters in a random direction
                            let randomBearing = Double.random(in: 0..<360) // Random direction 0-360 degrees
                            let offsetCoordinate = newLoc.coordinate.coordinate(atDistance: 5.0, atBearing: randomBearing)
                            
                            // Create a new location with offset coordinates
                            locationToPlace = LootBoxLocation(
                                id: location.id,
                                name: location.name,
                                type: location.type,
                                latitude: offsetCoordinate.latitude,
                                longitude: offsetCoordinate.longitude,
                                radius: location.radius,
                                collected: location.collected,
                                source: location.source
                            )
                            // Copy AR-related properties if they exist
                            locationToPlace.grounding_height = location.grounding_height
                            locationToPlace.ar_origin_latitude = location.ar_origin_latitude
                            locationToPlace.ar_origin_longitude = location.ar_origin_longitude
                            locationToPlace.ar_offset_x = location.ar_offset_x
                            locationToPlace.ar_offset_y = location.ar_offset_y
                            locationToPlace.ar_offset_z = location.ar_offset_z
                            locationToPlace.ar_placement_timestamp = location.ar_placement_timestamp

                            offsetApplied = true
                            break
                        }
                    }
                }

                // Also check against other locations in the current batch (to prevent placing duplicates in same loop)
                if !offsetApplied {
                    for otherLocation in nearbyLocations {
                        // Skip self and already-placed objects (we checked those above)
                        if otherLocation.id == location.id || placedBoxes[otherLocation.id] != nil {
                            continue
                        }

                        // Check if GPS coordinates are very close (within 1 meter)
                        let otherLoc = CLLocation(latitude: otherLocation.latitude, longitude: otherLocation.longitude)
                        let gpsDistance = newLoc.distance(from: otherLoc)

                        if gpsDistance < 1.0 {
                            // Offset by 5 meters in a random direction
                            let randomBearing = Double.random(in: 0..<360) // Random direction 0-360 degrees
                            let offsetCoordinate = newLoc.coordinate.coordinate(atDistance: 5.0, atBearing: randomBearing)
                            
                            // Create a new location with offset coordinates
                            locationToPlace = LootBoxLocation(
                                id: location.id,
                                name: location.name,
                                type: location.type,
                                latitude: offsetCoordinate.latitude,
                                longitude: offsetCoordinate.longitude,
                                radius: location.radius,
                                collected: location.collected,
                                source: location.source
                            )
                            // Copy AR-related properties if they exist
                            locationToPlace.grounding_height = location.grounding_height
                            locationToPlace.ar_origin_latitude = location.ar_origin_latitude
                            locationToPlace.ar_origin_longitude = location.ar_origin_longitude
                            locationToPlace.ar_offset_x = location.ar_offset_x
                            locationToPlace.ar_offset_y = location.ar_offset_y
                            locationToPlace.ar_offset_z = location.ar_offset_z
                            locationToPlace.ar_placement_timestamp = location.ar_placement_timestamp

                            offsetApplied = true
                            break
                        }
                    }
                }
            }

            // Skip AR-only items that are already placed (they're placed directly in randomizeLootBoxes)
            // BUT: Don't skip spheres with valid GPS coordinates - they should be placed via GPS
            // Spheres from the API/map have GPS coordinates and should appear in AR
            if location.isAROnly && location.type != .sphere {
                continue
            }

            // Determine placement method based on type
            // Use locationToPlace (which may have been offset to avoid GPS collisions)
            if locationToPlace.type == .sphere {
                // Spheres with GPS coordinates should be placed via GPS positioning
                if locationToPlace.latitude != 0 || locationToPlace.longitude != 0 {
                    placeARSphereAtLocation(locationToPlace, in: arView)
                } else {
                    // Sphere with no GPS - skip it (should be placed via randomizeLootBoxes)
                    continue
                }
            } else {
                placeLootBoxAtLocation(locationToPlace, in: arView)
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Swift.print("⏱️ [PERF] checkAndPlaceBoxes took \(String(format: "%.1f", elapsed))ms for \(nearbyLocations.count) nearby locations")
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
        // Keep GPS-based locations and manually-added map markers
        let oldCount = locationManager.locations.count
        locationManager.locations.removeAll { location in
            // Remove temporary AR-only items (randomized), but keep map-added items
            location.isTemporary && location.isAROnly
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
            // If no surface detected, use default height and rely on periodic grounding to fix later
            let surfaceY: Float
            var usedDefaultHeight = false
            if let detectedY = groundingService?.findHighestBlockingSurface(x: randomX, z: randomZ, cameraPos: cameraPos) {
                surfaceY = detectedY
                Swift.print("✅ Found surface at attempt \(attempts) - Y: \(String(format: "%.2f", surfaceY))")
            } else {
                // Use default ground height - object will be adjusted later by periodic grounding
                let objectTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest, .sphere, .cube]
                let selectedType = objectTypes.randomElement() ?? .sphere
                surfaceY = groundingService?.getDefaultGroundHeight(for: selectedType, cameraPos: cameraPos) ?? (cameraPos.y - 1.5)
                usedDefaultHeight = true
                Swift.print("⚠️ No surface at attempt \(attempts) - using default height Y=\(String(format: "%.2f", surfaceY)) (will auto-adjust later)")
            }

            let cameraY = cameraPos.y

            // Reject surfaces too far away (more than 2m above or below camera)
            // BUT allow default heights since they're calculated relative to camera
            let heightDiff = abs(surfaceY - cameraY)
            if !usedDefaultHeight && heightDiff > 2.0 {
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
            let objectTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest, .lootChest, .sphere, .cube]
            let selectedType = objectTypes.randomElement() ?? .chalice
            
            // Use the factory's itemDescription() to get the proper name for this type
            // This ensures each type gets its unique description (e.g., "Golden Chalice" not just "Chalice")
            let factory = selectedType.factory
            let baseName = factory.itemDescription()

            // Add unique suffix to prevent duplicate names
            // Use the placement count to ensure uniqueness
            let itemName = "\(baseName) #\(placedCount + 1)"
            
            let newLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: itemName, // Use the factory's description to ensure proper naming
                type: selectedType,
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0, // Large radius since we're not using GPS
                source: .arRandomized // Randomized AR item
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

    // MARK: - AR-Enhanced Location
    
    /// Get AR-enhanced GPS location (more accurate than raw GPS)
    /// Converts current AR camera position to GPS coordinates using AR origin
    /// Returns nil if AR origin not set or AR not available
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let arOrigin = arOriginLocation else {
            return nil
        }
        
        // Get current camera position in AR world space
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Convert AR position to GPS coordinates
        // AR origin is at (0,0,0) in AR space, so camera position is the offset
        let distance = sqrt(cameraPos.x * cameraPos.x + cameraPos.z * cameraPos.z) // Horizontal distance
        let bearing = atan2(Double(cameraPos.x), -Double(cameraPos.z)) * 180.0 / .pi // Bearing in degrees (0 = north)
        let normalizedBearing = (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
        
        // Calculate GPS coordinate from AR origin
        let enhancedGPS = arOrigin.coordinate.coordinate(atDistance: Double(distance), atBearing: normalizedBearing)
        
        return (
            latitude: enhancedGPS.latitude,
            longitude: enhancedGPS.longitude,
            arOffsetX: Double(cameraPos.x),
            arOffsetY: Double(cameraPos.y),
            arOffsetZ: Double(cameraPos.z)
        )
    }
    
    // MARK: - Object Recognition (delegated to ARObjectRecognizer)
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // CRITICAL: Set AR origin on first frame if not set - NEVER change it after
        // Changing the AR origin causes all objects to drift/shift position
        // Supports two modes:
        // 1. Accurate mode: Wait for GPS with good accuracy (< 7.5m) for precise AR-to-GPS conversion
        // 2. Degraded mode: Use AR-only positioning if GPS unavailable after timeout
        
        if arOriginLocation == nil {
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            
            // Try to get GPS location
            if let userLocation = userLocationManager?.currentLocation {
                // Check GPS accuracy - for < 7.5m resolution, we need < 7.5m GPS accuracy
                if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 7.5 {
                    // ACCURATE MODE: GPS available with good accuracy
                    // Step 1: Set ENU origin from GPS (geospatial coordinate frame)
                    if geospatialService?.setENUOrigin(from: userLocation) == true {
                        arOriginLocation = userLocation
                        arOriginSetTime = Date()
                        isDegradedMode = false
                        
                        // Step 2: Set AR session origin (VIO tracking origin at 0,0,0)
                        // Set fixed ground level at AR origin (using surface detection if available)
                        let groundLevel: Float
                        if let surfaceY = groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
                            // Use detected surface for accurate ground level
                            groundLevel = surfaceY
                            Swift.print("📍 AR Origin ground level from surface detection: \(String(format: "%.2f", groundLevel))m")
                        } else {
                            // Fallback: estimate from camera position
                            groundLevel = cameraPos.y - 1.5
                            Swift.print("📍 AR Origin ground level estimated: \(String(format: "%.2f", groundLevel))m (camera Y: \(String(format: "%.2f", cameraPos.y))m)")
                        }
                        
                        arOriginGroundLevel = groundLevel
                        geospatialService?.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
                        precisionPositioningService?.setAROriginGroundLevel(groundLevel) // Legacy compatibility
                        
                        Swift.print("✅ AR Origin SET (ACCURATE MODE) at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
                        Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED - never changes)")
                        Swift.print("   ⚠️ AR origin will NOT change - all objects positioned relative to this fixed point")
                        Swift.print("   📐 Using ENU coordinate system for geospatial positioning")
                    }
                } else {
                    // GPS available but accuracy too low
                    // Wait up to 10 seconds for better GPS, then enter degraded mode
                    let waitTime: TimeInterval = 10.0
                    if let setTime = arOriginSetTime {
                        if Date().timeIntervalSince(setTime) > waitTime {
                            // Timeout reached - enter degraded mode
                            enterDegradedMode(cameraPos: cameraPos, frame: frame)
                        } else {
                            Swift.print("⏳ Waiting for better GPS accuracy (current: \(String(format: "%.2f", userLocation.horizontalAccuracy))m, need: < 7.5m)")
                        }
                    } else {
                        // First time seeing low accuracy - start timer
                        arOriginSetTime = Date()
                        Swift.print("⚠️ GPS accuracy too low: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                        Swift.print("   Will wait \(Int(waitTime))s for better GPS, then enter degraded AR-only mode")
                    }
                }
            } else {
                // No GPS location available
                // Wait up to 5 seconds for GPS, then enter degraded mode
                let waitTime: TimeInterval = 5.0
                if let setTime = arOriginSetTime {
                    if Date().timeIntervalSince(setTime) > waitTime {
                        // Timeout reached - enter degraded mode
                        enterDegradedMode(cameraPos: cameraPos, frame: frame)
                    } else {
                        Swift.print("⏳ Waiting for GPS location...")
                    }
                } else {
                    // First time - start timer
                    arOriginSetTime = Date()
                    Swift.print("⚠️ No GPS location available")
                    Swift.print("   Will wait \(Int(waitTime))s for GPS, then enter degraded AR-only mode")
                }
            }
        }
        
        // Step 5.5: Check if we should exit degraded mode (GPS accuracy improved)
        // Note: This check happens even when arOriginLocation == nil because degraded mode sets it to nil
        // The existing code above will also try to set origin, but this provides explicit degraded mode exit
        if isDegradedMode, let userLocation = userLocationManager?.currentLocation {
            // Use hysteresis: require better accuracy (< 6.5m) to exit degraded mode than to enter (< 7.5m)
            // This prevents rapid mode switching when GPS accuracy fluctuates around the threshold
            if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 6.5 {
                // GPS accuracy improved significantly - exit degraded mode and set AR origin
                let cameraTransform = frame.camera.transform
                let cameraPos = SIMD3<Float>(
                    cameraTransform.columns.3.x,
                    cameraTransform.columns.3.y,
                    cameraTransform.columns.3.z
                )
                
                // Set ENU origin from GPS (geospatial coordinate frame)
                if geospatialService?.setENUOrigin(from: userLocation) == true {
                    arOriginLocation = userLocation
                    arOriginSetTime = Date()
                    isDegradedMode = false
                    
                    // Set fixed ground level
                    let groundLevel: Float
                    if let surfaceY = groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
                        groundLevel = surfaceY
                        Swift.print("📍 Exiting degraded mode: Ground level from surface detection: \(String(format: "%.2f", groundLevel))m")
                    } else {
                        groundLevel = cameraPos.y - 1.5
                        Swift.print("📍 Exiting degraded mode: Ground level estimated: \(String(format: "%.2f", groundLevel))m")
                    }
                    
                    arOriginGroundLevel = groundLevel
                    geospatialService?.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
                    precisionPositioningService?.setAROriginGroundLevel(groundLevel)
                    
                    Swift.print("✅ EXITED DEGRADED MODE - GPS accuracy improved!")
                    Swift.print("   AR Origin SET at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
                    Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                    Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED)")
                    Swift.print("   GPS-based objects can now be placed")
                }
            } else if userLocation.horizontalAccuracy >= 0 {
                // Still in degraded mode, but log current accuracy for debugging
                // Only log occasionally to avoid spam (every 5 seconds)
                if let lastLog = lastDegradedModeLogTime, Date().timeIntervalSince(lastLog) < 5.0 {
                    // Skip logging
                } else {
                    lastDegradedModeLogTime = Date()
                    Swift.print("⏳ Still in degraded mode - GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m (need: < 6.5m to exit)")
                }
            }
        }
        
        // Step 6: Apply smooth corrections when better GPS arrives (no teleporting)
        // Check if we have a better GPS fix than when origin was set
        if let geospatial = geospatialService,
           geospatial.hasENUOrigin,
           let userLocation = userLocationManager?.currentLocation,
           let origin = arOriginLocation,
           userLocation.horizontalAccuracy < origin.horizontalAccuracy {
            // Better GPS available - compute smooth correction
            if let correction = geospatial.computeSmoothCorrection(from: userLocation) {
                Swift.print("🔧 Applying smooth correction for better GPS accuracy")
                Swift.print("   Correction offset: (\(String(format: "%.4f", correction.x)), \(String(format: "%.4f", correction.y)), \(String(format: "%.4f", correction.z)))m")
                
                // Apply correction to all placed objects (smooth, not teleport)
                // Note: In practice, you might want to animate this over time
                for (locationId, anchor) in placedBoxes {
                    let currentTransform = anchor.transformMatrix(relativeTo: nil)
                    let currentPos = SIMD3<Float>(
                        currentTransform.columns.3.x,
                        currentTransform.columns.3.y,
                        currentTransform.columns.3.z
                    )
                    let correctedPos = currentPos + correction
                    anchor.transform.translation = correctedPos
                }
                
                Swift.print("✅ Applied smooth correction to \(placedBoxes.count) object(s)")
            }
        }
        
        // Perform object recognition on camera frame (throttled to improve framerate)
        // Only run recognition every 2 seconds to reduce CPU usage
        let now = Date()
        if now.timeIntervalSince(lastRecognitionTime) > 2.0 {
            lastRecognitionTime = now
            objectRecognizer?.performObjectRecognition(on: frame.capturedImage)
        }

        // Check for nearby locations when AR is tracking
        if frame.camera.trackingState == .normal,
           let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            
            // Throttle box placement checks to improve framerate
            // Only check every 2 seconds instead of every frame (60fps)
            // Objects don't need frequent re-placement checks
            let placementNow = Date()
            if shouldForceReplacement || placementNow.timeIntervalSince(lastPlacementCheck) > 2.0 {
                lastPlacementCheck = placementNow
                
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
            }

            // No automatic sphere spawning - user must add items manually via map
            // if !hasAutoRandomized && placedBoxes.isEmpty {
            //     Swift.print("🎯 AR tracking stable - auto-spawning 3 spheres")
            //     randomizeLootBoxes()
            // }
            
            // Check viewport visibility and play chime when objects enter
            // Throttle to every 1.0 seconds to improve framerate (was 0.5s)
            // Viewport checking is expensive (screen projections) and doesn't need high frequency
            let now = Date()
            if now.timeIntervalSince(lastViewportCheck) > 1.0 {
                lastViewportCheck = now
                checkViewportVisibility()
            }
        }
    }
    
    // Handle AR anchor updates - remove any unwanted plane anchors (especially ceilings)
    // Also re-ground objects when new horizontal planes are detected
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Check if any new anchors are horizontal planes
        var hasNewHorizontalPlane = false
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor,
               planeAnchor.alignment == .horizontal {
                hasNewHorizontalPlane = true
                Swift.print("🆕 New horizontal plane detected - will re-ground floating objects")
                break
            }
        }

        // If new horizontal plane detected, re-ground all placed objects
        if hasNewHorizontalPlane {
            regroundAllObjects()
        }
        
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
        if let arError = error as? ARError {
            let errorCode = arError.code
            var errorDescription = "Unknown AR error"
            
            switch arError.code {
            case .unsupportedConfiguration:
                errorDescription = "AR configuration not supported on this device"
            case .sensorUnavailable:
                errorDescription = "AR sensor unavailable - camera or motion sensors not available"
            case .sensorFailed:
                errorDescription = "AR sensor failed - camera or motion sensors failed"
            case .cameraUnauthorized:
                errorDescription = "Camera access denied - check camera permissions"
            case .worldTrackingFailed:
                errorDescription = "World tracking failed - unable to track position"
            case .invalidReferenceImage:
                errorDescription = "Invalid reference image"
            case .invalidReferenceObject:
                errorDescription = "Invalid reference object"
            case .invalidWorldMap:
                errorDescription = "Invalid world map"
            case .invalidConfiguration:
                errorDescription = "Invalid AR configuration"
            case .insufficientFeatures:
                errorDescription = "Insufficient features - not enough visual features to track"
            case .objectMergeFailed:
                errorDescription = "Object merge failed"
            case .fileIOFailed:
                errorDescription = "File I/O failed"
            case .requestFailed:
                errorDescription = "AR request failed"
            case .invalidCollaborationData:
                errorDescription = "Invalid collaboration data"
            case .geoTrackingNotAvailableAtLocation:
                errorDescription = "GeoTracking not available at this location"
            case .geoTrackingFailed:
                errorDescription = "GeoTracking failed"
            @unknown default:
                errorDescription = "Unknown AR error code: \(errorCode.rawValue)"
            }
            
            Swift.print("❌ [AR Session Error] \(errorDescription) (ARError code: \(errorCode.rawValue))")
            let nsError = arError as NSError
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                Swift.print("   Underlying error: \(underlyingError.localizedDescription)")
            }
            if let failureReason = nsError.localizedFailureReason {
                Swift.print("   Failure reason: \(failureReason)")
            }
            if let recoverySuggestion = nsError.localizedRecoverySuggestion {
                Swift.print("   Recovery suggestion: \(recoverySuggestion)")
            }
        } else {
            Swift.print("❌ [AR Session Error] \(error.localizedDescription)")
            Swift.print("   Error type: \(type(of: error))")
            
            // Check for FigCaptureSourceRemote errors (camera capture errors)
            let errorString = String(describing: error)
            if errorString.contains("FigCaptureSourceRemote") || errorString.contains("err=-12784") {
                Swift.print("   ⚠️ Camera capture error detected - this may be a temporary camera issue")
                Swift.print("   This error (err=-12784) is often related to camera resource conflicts")
            }
        }
        
        // Try to restart the session
        Swift.print("🔄 [AR Session] Attempting to restart AR session...")
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for wall detection (occlusion)
            config.environmentTexturing = .automatic
            
            // Apply selected lens if available
            if let locationManager = locationManager,
               let selectedLensId = locationManager.selectedARLens,
               let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
                config.videoFormat = videoFormat
            }
            
            arView.session.run(config, options: [.resetTracking])
            Swift.print("✅ [AR Session] AR session restart initiated")
        } else {
            Swift.print("⚠️ [AR Session] Cannot restart - ARView is nil")
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        Swift.print("⚠️ [AR Session] AR Session was interrupted")
        Swift.print("   This usually happens when the app goes to background or another app uses the camera")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        Swift.print("✅ [AR Session] AR Session interruption ended, restarting...")
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for wall detection (occlusion)
            config.environmentTexturing = .automatic
            
            // Apply selected lens if available
            if let locationManager = locationManager,
               let selectedLensId = locationManager.selectedARLens,
               let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
                config.videoFormat = videoFormat
            }
            
            arView.session.run(config, options: [.resetTracking])
            Swift.print("✅ [AR Session] AR session restarted after interruption")
        } else {
            Swift.print("⚠️ [AR Session] Cannot restart - ARView is nil")
        }
    }
    
    // MARK: - Loot Box Placement
    private func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        // CRITICAL: Check if already placed to prevent infinite loops
        if placedBoxes[location.id] != nil {
            return // Already placed, skip silently
        }

        // Check AR frame availability
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': AR frame not available")
            Swift.print("   AR session configuration: \(arView.session.configuration != nil ? "configured" : "not configured")")
            Swift.print("   This usually means AR is still initializing or was interrupted")
            return
        }
        
        // Check user location availability
        guard let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': User location not available")
            Swift.print("   GPS status: \(userLocationManager?.authorizationStatus == .authorizedWhenInUse || userLocationManager?.authorizationStatus == .authorizedAlways ? "authorized" : "not authorized")")
            Swift.print("   This usually means GPS is still acquiring location or permissions were denied")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // CRITICAL: Use AR coordinates first for mm-precision (primary)
        // Only fall back to GPS if AR coordinates aren't available
        if let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude,
           let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z {
            // AR coordinates available - use them for mm-precision placement
            let arOriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)
            
            // INDOOR vs OUTDOOR placement strategy:
            // - < 12m from AR origin: INDOOR - Use AR coordinates for mm/cm precision
            // - >= 12m from AR origin: OUTDOOR - Use GPS coordinates (acceptable GPS accuracy)
            let useARCoordinates: Bool
            let arPosition = SIMD3<Float>(Float(arOffsetX), Float(arOffsetY), Float(arOffsetZ))
            let distanceFromOrigin = length(arPosition)
            
            if let currentAROrigin = arOriginLocation {
                // Compare AR origins - if they match, we can use AR coordinates directly
                let originDistance = currentAROrigin.distance(from: arOriginGPS)
                
                // Use AR coordinates if:
                // 1. AR origin matches (same session) AND object is < 12m (indoor precision)
                // 2. OR object is < 12m from stored AR origin (indoor placement)
                useARCoordinates = (originDistance < 1.0 && distanceFromOrigin < 12.0) || distanceFromOrigin < 12.0
                
                if useARCoordinates {
                    if originDistance < 1.0 {
                        Swift.print("✅ INDOOR placement (< 12m): Using AR coordinates for mm/cm-precision")
                        Swift.print("   AR origin match: distance=\(String(format: "%.3f", originDistance))m (same session)")
                    } else {
                        Swift.print("✅ INDOOR placement (< 12m): Using stored AR coordinates for mm/cm-precision")
                    }
                    Swift.print("   Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m")
                    Swift.print("   AR offset: (\(String(format: "%.4f", arOffsetX)), \(String(format: "%.4f", arOffsetY)), \(String(format: "%.4f", arOffsetZ)))m")
                } else {
                    Swift.print("🌍 OUTDOOR placement (>= 12m): Using GPS coordinates")
                    Swift.print("   Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m")
                    Swift.print("   GPS accuracy acceptable for outdoor distances")
                }
            } else {
                // No current AR origin - check if object is within 12m of stored AR origin
                useARCoordinates = distanceFromOrigin < 12.0
                
                if useARCoordinates {
                    Swift.print("✅ INDOOR placement (< 12m): Using stored AR coordinates for mm/cm-precision")
                    Swift.print("   Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m")
                } else {
                    Swift.print("🌍 OUTDOOR placement (>= 12m): Using GPS coordinates")
                    Swift.print("   Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m")
                }
            }
            
            if useARCoordinates {
                // Use stored AR coordinates directly (mm-precision) - NEVER re-ground
                // This preserves the exact placement position where the user placed it
                // Objects should NEVER move after being placed, especially for the user who placed them
                let arPosition = SIMD3<Float>(
                    Float(arOffsetX),
                    Float(arOffsetY),
                    Float(arOffsetZ)
                )
                
                // Use exact stored position - don't re-ground to preserve user's placement
                Swift.print("✅ [Placement] Using exact stored AR coordinates for \(location.name) (mm-precision, no re-grounding)")
                Swift.print("   Object ID: \(location.id)")
                Swift.print("   Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                Swift.print("   Object will stay fixed at this position (never moves)")
                
                placeBoxAtPosition(arPosition, location: location, in: arView)
                
                // Log location again after 1 second to verify it's still there
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    await MainActor.run {
                        if let anchor = placedBoxes[location.id] {
                            let currentPos = anchor.position
                            let isStillInScene = anchor.parent != nil
                            Swift.print("📍 [Placement] Object '\(location.name)' location after 1 second:")
                            Swift.print("   AR Position: X=\(String(format: "%.4f", currentPos.x))m, Y=\(String(format: "%.4f", currentPos.y))m, Z=\(String(format: "%.4f", currentPos.z))m")
                            Swift.print("   Still in scene: \(isStillInScene ? "YES" : "NO")")
                            Swift.print("   Anchor parent: \(anchor.parent != nil ? "exists" : "nil")")
                            if !isStillInScene {
                                Swift.print("   ⚠️ WARNING: Object was removed from scene!")
                            } else if abs(currentPos.x - arPosition.x) > 0.001 || abs(currentPos.y - arPosition.y) > 0.001 || abs(currentPos.z - arPosition.z) > 0.001 {
                                Swift.print("   ⚠️ WARNING: Object moved! Original: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z))), Current: (\(String(format: "%.4f", currentPos.x)), \(String(format: "%.4f", currentPos.y)), \(String(format: "%.4f", currentPos.z)))")
                            } else {
                                Swift.print("   ✅ Object still at original position")
                            }
                        } else {
                            // Check if object was collected (normal case - not an error)
                            let wasCollected = locationManager?.locations.first(where: { $0.id == location.id })?.collected ?? false
                            if wasCollected {
                                Swift.print("   ℹ️ Object '\(location.name)' was collected (removed from placedBoxes - this is normal)")
                            } else if findableObjects[location.id] == nil {
                                Swift.print("   ⚠️ WARNING: Object '\(location.name)' not found in placedBoxes and not in findableObjects - may have been removed unexpectedly")
                            } else {
                                Swift.print("   ℹ️ Object '\(location.name)' not in placedBoxes but still in findableObjects (may be in transition)")
                            }
                        }
                    }
                }
                return
            }
        }
        
        // Fallback to GPS-based placement if AR coordinates not available
        if location.latitude != 0 || location.longitude != 0 {
            // CRITICAL: Require AR origin to be set before placing GPS-based objects
            // In degraded mode, GPS-based objects cannot be placed
            if isDegradedMode {
                Swift.print("⚠️ Cannot place GPS-based object '\(location.name)': Operating in degraded AR-only mode")
                Swift.print("   GPS-based objects require accurate GPS fix (< 7.5m accuracy)")
                Swift.print("   Use AR-only placement (tap-to-place or randomize) instead")
                return
            }
            
            guard let arOrigin = arOriginLocation else {
                Swift.print("⚠️ Cannot place \(location.name): AR origin not set yet")
                Swift.print("   Waiting for AR origin to be established (requires GPS accuracy < 7.5m)")
                Swift.print("   Will enter degraded mode if GPS unavailable")
                return
            }
            
            // Use ENU-based geospatial service for GPS to AR conversion
            let targetLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let distance = userLocation.distance(from: targetLocation)
            
            Swift.print("📍 Placing \(location.name) at GPS distance \(String(format: "%.2f", distance))m")
            Swift.print("   Using fixed AR origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
            
            // Step 1: Convert GPS to ENU, then ENU to AR (new architecture)
            var precisePosition: SIMD3<Float>?
            if let geospatial = geospatialService, geospatial.hasENUOrigin {
                // Use new ENU-based conversion
                if let arPos = geospatial.convertGPSToAR(targetLocation) {
                    precisePosition = arPos
                    Swift.print("✅ Using ENU coordinate system for GPS conversion")
                }
            }
            
            // Fallback to legacy precision positioning service if ENU not available
            if precisePosition == nil {
                if let legacyPosition = precisionPositioningService?.convertGPSToARPosition(
                    targetGPS: targetLocation,
                    userGPS: userLocation,
                    cameraTransform: cameraTransform,
                    arOriginGPS: arOrigin
                ) {
                    precisePosition = legacyPosition
                    Swift.print("⚠️ Using legacy precision positioning service (ENU not available)")
                }
            }
            
            if let precisePosition = precisePosition {
                // CRITICAL: If object already has AR coordinates stored, use them instead of re-converting GPS
                // This prevents objects from moving when GPS-to-AR conversion gives slightly different results
                let finalPosition: SIMD3<Float>
                
                if let storedArX = location.ar_offset_x,
                   let storedArY = location.ar_offset_y,
                   let storedArZ = location.ar_offset_z {
                    // Object has stored AR coordinates - use them directly to prevent movement
                    finalPosition = SIMD3<Float>(Float(storedArX), Float(storedArY), Float(storedArZ))
                    Swift.print("✅ Using stored AR coordinates for \(location.type.displayName) (prevents movement from GPS conversion)")
                    Swift.print("   Stored position: (\(String(format: "%.4f", finalPosition.x)), \(String(format: "%.4f", finalPosition.y)), \(String(format: "%.4f", finalPosition.z)))m")
                } else {
                    // No stored AR coordinates - this is first placement, detect surface and store result
                    if distance < 5.0 {
                        // Close proximity: detect surface for first placement
                        let surfaceY = groundingService?.findSurfaceOrDefault(
                            x: precisePosition.x,
                            z: precisePosition.z,
                            cameraPos: cameraPos,
                            objectType: location.type
                        ) ?? precisePosition.y
                        finalPosition = SIMD3<Float>(precisePosition.x, surfaceY, precisePosition.z)
                        // PERFORMANCE: Logging disabled - runs in placement loop
                    } else {
                        // Far distance: use fixed ground level for stability
                        if let fixedGroundLevel = arOriginGroundLevel {
                            finalPosition = SIMD3<Float>(precisePosition.x, fixedGroundLevel, precisePosition.z)
                            Swift.print("✅ First placement: Using fixed AR origin ground level")
                        } else if let surfaceY = precisionPositioningService?.getPreciseSurfaceHeight(
                            x: precisePosition.x,
                            z: precisePosition.z,
                            cameraPos: cameraPos
                        ) {
                            finalPosition = SIMD3<Float>(precisePosition.x, surfaceY, precisePosition.z)
                            Swift.print("✅ First placement: Using detected surface")
                        } else {
                            Swift.print("❌ Cannot place \(location.type.displayName): No surface or ground level available")
                            return
                        }
                    }
                    
                    // Store AR coordinates after first placement so object never moves
                    // PERFORMANCE: Logging disabled
                }
                
                // Check distance from camera BEFORE placing (early rejection)
                let distanceFromCamera = length(finalPosition - cameraPos)
                if distanceFromCamera < 3.0 {
                    // PERFORMANCE: Logging disabled - this runs in retry loop
                    return
                }
                
                // PERFORMANCE: Logging disabled
                placeBoxAtPosition(finalPosition, location: location, in: arView)
                return
            } else {
                // Precision positioning service failed - cannot place object accurately
                Swift.print("❌ Cannot place \(location.name): Precision positioning service failed")
                Swift.print("   Object placement requires proper AR origin and ground level initialization")
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
        // CRITICAL: Check if already placed to prevent infinite loops
        if placedBoxes[location.id] != nil {
            return // Already placed, skip silently
        }

        // Check AR frame availability
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ [Placement] Cannot place sphere '\(location.name)': AR frame not available")
            Swift.print("   AR session configuration: \(arView.session.configuration != nil ? "configured" : "not configured")")
            Swift.print("   This usually means AR is still initializing or was interrupted")
            return
        }
        
        // Check user location availability
        guard let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ [Placement] Cannot place sphere '\(location.name)': User location not available")
            Swift.print("   GPS status: \(userLocationManager?.authorizationStatus == .authorizedWhenInUse || userLocationManager?.authorizationStatus == .authorizedAlways ? "authorized" : "not authorized")")
            Swift.print("   This usually means GPS is still acquiring location or permissions were denied")
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // CRITICAL: Use AR coordinates first for mm-precision (primary)
        // Only fall back to GPS if AR coordinates aren't available
        if let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude,
           let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z {
            // AR coordinates available - use them for mm-precision placement
            let arOriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)
            
            // Check if AR origin matches current AR session origin
            let useARCoordinates: Bool
            if let currentAROrigin = arOriginLocation {
                let originDistance = currentAROrigin.distance(from: arOriginGPS)
                useARCoordinates = originDistance < 1.0 // Within 1m = same AR session origin
                
                if useARCoordinates {
                    Swift.print("✅ Using AR coordinates for mm-precision sphere placement: \(location.name)")
                    Swift.print("   AR offset: (\(String(format: "%.4f", arOffsetX)), \(String(format: "%.4f", arOffsetY)), \(String(format: "%.4f", arOffsetZ)))m")
                }
            } else {
                useARCoordinates = true
            }
            
            if useARCoordinates {
                // Use stored AR coordinates directly (mm-precision) - NO re-grounding
                // This preserves the exact placement position where the user placed it
                let arPosition = SIMD3<Float>(
                    Float(arOffsetX),
                    Float(arOffsetY),
                    Float(arOffsetZ)
                )
                
                // Use exact stored Y position - don't re-ground to preserve user's placement
                Swift.print("✅ Using exact stored AR coordinates for sphere (mm-precision, no re-grounding)")
                Swift.print("   Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                
                // Create sphere at exact AR position
                let sphereRadius: Float = 0.15
                let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
                var sphereMaterial = SimpleMaterial()
                sphereMaterial.color = .init(tint: .orange)
                sphereMaterial.roughness = 0.2
                sphereMaterial.metallic = 0.3
                
                let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
                sphere.name = location.id
                
                // Place anchor at exact AR position - sphere base will be at arPosition.y
                let anchor = AnchorEntity(world: arPosition)
                // Position sphere so its base (bottom) is at the anchor position (center of shadow X)
                sphere.position = SIMD3<Float>(0, sphereRadius, 0)
                
                let light = PointLightComponent(color: .orange, intensity: 200)
                sphere.components.set(light)
                
                anchor.addChild(sphere)
                arView.scene.addAnchor(anchor)
                placedBoxes[location.id] = anchor
                
                environmentManager?.applyUniformLuminanceToNewEntity(anchor)
                
                findableObjects[location.id] = FindableObject(
                    locationId: location.id,
                    anchor: anchor,
                    sphereEntity: sphere,
                    container: nil,
                    location: location
                )
                
                findableObjects[location.id]?.onFoundCallback = { [weak self] id in
                    DispatchQueue.main.async {
                        if let locationManager = self?.locationManager {
                            locationManager.markCollected(id)
                        }
                    }
                }
                
                Swift.print("✅ Placed AR sphere '\(location.name)' using stored AR coordinates at (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f",    arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                return
            }
        }
        
        // Fallback to GPS-based placement if AR coordinates not available
        // Check if we're in degraded mode
        if isDegradedMode {
            Swift.print("⚠️ Cannot place GPS-based sphere '\(location.name)': Operating in degraded AR-only mode")
            return
        }
        
        let locationCLLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        
        // Use precision positioning service for inch-level accuracy
        guard let precisePosition = precisionPositioningService?.convertGPSToARPosition(
            targetGPS: locationCLLocation,
            userGPS: userLocation,
            cameraTransform: cameraTransform,
            arOriginGPS: arOriginLocation
        ) else {
            Swift.print("⚠️ Precision positioning failed for sphere, using fallback")
            // Fallback to simple GPS conversion
            guard let arOrigin = arOriginLocation else {
                Swift.print("⚠️ No AR origin set for sphere placement")
                return
            }
            let distance = arOrigin.distance(from: locationCLLocation)
            let bearing = arOrigin.bearing(to: locationCLLocation)
            let x = Float(distance * sin(bearing * .pi / 180.0))
            let z = Float(distance * cos(bearing * .pi / 180.0))
            
            // Use fixed ground level if available, otherwise detect surface
            let groundY: Float
            if let fixedGroundLevel = arOriginGroundLevel {
                groundY = fixedGroundLevel
                Swift.print("✅ Using fixed AR origin ground level for sphere: Y=\(String(format: "%.2f", groundY))")
            } else if let surfaceY = groundingService?.findHighestBlockingSurface(x: x, z: z, cameraPos: cameraPos) {
                groundY = surfaceY
            } else {
                groundY = cameraPos.y - 1.5
            }
            
            let sphereRadius: Float = 0.15
            let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
            var sphereMaterial = SimpleMaterial()
            sphereMaterial.color = .init(tint: .orange)
            sphereMaterial.roughness = 0.2
            sphereMaterial.metallic = 0.3
            let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
            sphere.name = location.id
            let anchor = AnchorEntity(world: SIMD3<Float>(x, groundY, z))
            sphere.position = SIMD3<Float>(0, sphereRadius, 0)
            let light = PointLightComponent(color: .orange, intensity: 200)
            sphere.components.set(light)
            anchor.addChild(sphere)
            arView.scene.addAnchor(anchor)
            placedBoxes[location.id] = anchor
            environmentManager?.applyUniformLuminanceToNewEntity(anchor)
            findableObjects[location.id] = FindableObject(
                locationId: location.id,
                anchor: anchor,
                sphereEntity: sphere,
                container: nil,
                location: location
            )
            findableObjects[location.id]?.onFoundCallback = { [weak self] id in
                DispatchQueue.main.async {
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(id)
                    }
                }
            }
            return
        }
        
        let distance = userLocation.distance(from: locationCLLocation)
        Swift.print("🎯 Placing AR sphere '\(location.name)' using precision positioning")
        Swift.print("   GPS distance: \(String(format: "%.2f", distance))m")
        Swift.print("   Precise AR position: (\(String(format: "%.4f", precisePosition.x)), \(String(format: "%.4f", precisePosition.y)), \(String(format: "%.4f", precisePosition.z)))")

        // Create sphere at calculated position
        let sphereRadius: Float = 0.15 // Smaller sphere for GPS-located items
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: .orange)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = location.id

        // Use precise position with fixed ground level for stability
        // Prefer fixed ground level to prevent objects from moving when camera moves
        let groundY: Float
        if distance < 5.0 {
            // Close proximity: precision service already handled surface detection
            // But prefer fixed ground level if available for stability
            if let fixedGroundLevel = arOriginGroundLevel {
                groundY = fixedGroundLevel
                Swift.print("✅ Using fixed AR origin ground level for close sphere (ensures stability)")
            } else {
                groundY = precisePosition.y
            }
        } else {
            // Far distance: prefer fixed ground level, fallback to surface detection
            if let fixedGroundLevel = arOriginGroundLevel {
                groundY = fixedGroundLevel
                Swift.print("✅ Using fixed AR origin ground level for far sphere (ensures stability)")
            } else if let surfaceY = precisionPositioningService?.getPreciseSurfaceHeight(
                x: precisePosition.x,
                z: precisePosition.z,
                cameraPos: cameraPos
            ) {
                groundY = surfaceY
            } else if let surfaceY = groundingService?.findHighestBlockingSurface(x: precisePosition.x, z: precisePosition.z, cameraPos: cameraPos) {
                groundY = surfaceY
            } else {
                groundY = cameraPos.y - 1.5
                Swift.print("⚠️ No surface found for sphere - using fallback height")
            }
        }

        // Create anchor at grounded position
        let anchor = AnchorEntity(world: SIMD3<Float>(precisePosition.x, groundY, precisePosition.z))

        // Position sphere relative to anchor so bottom sits flat on surface
        sphere.position = SIMD3<Float>(0, sphereRadius, 0) // Bottom of sphere touches surface

        // Add point light to make it visible
        let light = PointLightComponent(color: .orange, intensity: 200)
        sphere.components.set(light)

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

        Swift.print("✅ Placed AR sphere '\(location.name)' at AR position (\(String(format: "%.2f", precisePosition.x)), \(String(format: "%.2f", precisePosition.z)))")
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

        // CRITICAL: Always ensure object is grounded on a horizontal surface
        // This ensures artifacts sit on the ground or whatever horizontal surface is beneath them
        var groundedPosition = boxPosition
        
        // Always try to find and use the actual detected surface first
        if let surfaceY = groundingService?.findSurfaceOrDefault(
            x: boxPosition.x,
            z: boxPosition.z,
            cameraPos: cameraPos,
            objectType: location.type
        ) {
            // Use detected surface Y coordinate - object will sit on this surface
            groundedPosition = SIMD3<Float>(boxPosition.x, surfaceY, boxPosition.z)
            Swift.print("✅ Grounded object on detected horizontal surface at Y: \(String(format: "%.2f", surfaceY))")
        } else {
            // Fallback: should not reach here as findSurfaceOrDefault always returns a value
            // But keep this for safety
            let defaultY = groundingService?.getDefaultGroundHeight(for: location.type, cameraPos: cameraPos) ?? (cameraPos.y - 1.5)
            groundedPosition = SIMD3<Float>(boxPosition.x, defaultY, boxPosition.z)
            Swift.print("⚠️ Grounding fallback - using default height: Y=\(String(format: "%.2f", defaultY))")
        }
        
        // Verify object is not floating (should be at or very close to detected surface)
        let heightDifference = abs(groundedPosition.y - boxPosition.y)
        if heightDifference > 0.1 {
            Swift.print("📏 Grounding adjustment: Y changed by \(String(format: "%.3f", heightDifference))m to sit on surface")
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
        case .templeRelic, .treasureChest, .lootChest, .lootCart:
            selectedObjectType = .treasureBox
        }

        Swift.print("🎲 Placing \(selectedObjectType) (\(location.type.displayName)) for \(location.name)")
        Swift.print("   Location ID: \(location.id)")
        Swift.print("   Location type: \(location.type)")
        Swift.print("   Selected object type: \(selectedObjectType)")

        // Use factory to create entity - each factory encapsulates its own creation logic
        Swift.print("🎯 Creating \(location.type.displayName) using factory for \(location.name)")
        Swift.print("   Location type: \(location.type), Factory type: \(type(of: location.type.factory))")
        // Calculate size multiplier to ensure final size doesn't exceed 2 feet (0.61m)
        // Max multiplier = 0.61 / baseSize, capped at 1.0
        let baseSize = location.type.size
        let maxMultiplier = min(1.0, 0.61 / baseSize) // Ensure final size <= 0.61m
        let minMultiplier = max(0.5, maxMultiplier * 0.7) // Keep some variety but stay under limit
        let sizeMultiplier = Float.random(in: minMultiplier...maxMultiplier) // Vary size for variety, capped at 2 feet
        let factory = location.type.factory
        
        // CRITICAL: Verify each type uses its correct factory to ensure proper separation
        // Check factory type name to ensure correct factory is being used
        // Note: This verification could be removed if we trust the registry, but it's useful for debugging
        let factoryTypeName = String(describing: type(of: factory))
        Swift.print("✅ Using factory \(factoryTypeName) for \(location.type.displayName)")
        
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
        
        // Database indicators removed - no longer adding visual indicators to objects
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
                    if child is ModelEntity,
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
                // Check for remaining temporary AR items
                let remainingItems = self.placedBoxes.keys.filter { locationId in
                    if let location = self.locationManager?.locations.first(where: { $0.id == locationId }) {
                        return location.isTemporary && location.isAROnly
                    }
                    return false
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
                id: UUID().uuidString,
                name: "Mysterious Sphere",
                type: .sphere,
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0, // Large radius since we're not using GPS
                source: .arManual // Manually placed AR sphere
            )
            // Add to locationManager so it counts toward the total
            // Note: Temporary AR items won't sync to API (by design)
            locationManager.addLocation(newLocation)
            Swift.print("✅ Created new location for sphere: \(newLocation.id)")
            Swift.print("   📍 Note: Temporary AR sphere will NOT sync to API")
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
            if locationManager?.locations.first(where: { $0.id == item.id }) != nil {
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
              let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ Cannot place AR item: AR not ready or no user location")
            return
        }
        let _ = locationManager // Location manager checked but unused in this scope

        // Limit to maximum objects
        guard placedBoxes.count < 6 else {
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
