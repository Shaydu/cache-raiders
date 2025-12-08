import Foundation
import SwiftUI
import Combine
import RealityKit
import ARKit
import CoreLocation
import AudioToolbox

// MARK: - AR Distance Tracker
/// Handles distance calculation, direction tracking, and text overlays
class ARDistanceTracker: ObservableObject {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var userLocationManager: UserLocationManager?
    weak var treasureHuntService: TreasureHuntService?
    
    var placedBoxes: [String: AnchorEntity] = [:]
    var distanceTextEntities: [String: ModelEntity] = [:]
    var foundLootBoxes: Set<String> = []
    var proximitySoundPlayed: Set<String> = []
    private var lastDistanceText: [String: String] = [:] // Cache last text to avoid recreating textures
    
    // PERFORMANCE: Cache texture resources to avoid expensive texture recreation
    private var textureCache: [String: TextureResource] = [:]
    private let maxTextureCacheSize = 50 // Limit cache size to prevent memory issues
    
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    var currentTargetObjectNameBinding: Binding<String?>?
    var currentTargetObjectBinding: Binding<LootBoxLocation?>?

    @Published var nearestObjectDirection: Double? = nil
    @Published var currentTargetObjectName: String? = nil
    @Published var currentTargetObject: LootBoxLocation? = nil

    private var distanceLogger: Timer?
    private var previousDistance: Double?
    private var audioPingService: AudioPingService?

    // Coordinate system health monitoring
    private var coordinateDriftWarnings: Int = 0
    private var lastCoordinateDriftWarning: TimeInterval = 0
    
    init(arView: ARView?, locationManager: LootBoxLocationManager?, userLocationManager: UserLocationManager?, treasureHuntService: TreasureHuntService? = nil) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.treasureHuntService = treasureHuntService
        self.audioPingService = AudioPingService.shared
    }
    
    /// Start distance logging
    func startDistanceLogging() {
        // Check every 1.0 seconds for better performance
        // Reduced from 0.5s to improve framerate - distance calculations are expensive
        distanceLogger = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.logDistanceToNearestLootBox()
            // Also update distance text overlays at same interval (moved from occlusion manager)
            self?.updateDistanceTexts()
        }
    }
    
    /// Stop distance logging
    func stopDistanceLogging() {
        distanceLogger?.invalidate()
        audioPingService?.stop()
    }
    
    /// Clear found loot boxes set
    func clearFoundLootBoxes() {
        foundLootBoxes.removeAll()
        proximitySoundPlayed.removeAll()
        Swift.print("🔄 Cleared found loot boxes set - objects are now tappable again")
    }
    
    /// Update distance texts for all loot boxes
    func updateDistanceTexts() {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard let arView = arView, let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Validate camera position - AR coordinates should be reasonable (< 10,000 units)
        let maxReasonableCoordinate: Float = 10000.0
        guard abs(cameraPosition.x) < maxReasonableCoordinate &&
              abs(cameraPosition.y) < maxReasonableCoordinate &&
              abs(cameraPosition.z) < maxReasonableCoordinate else {
            monitorCoordinateSystemHealth(cameraPosition: cameraPosition)
            Swift.print("⚠️ Invalid camera position in updateDistanceTexts, skipping")
            return
        }
        
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
            
            // PERFORMANCE: Only update texture if text changed (texture creation is expensive)
            if lastDistanceText[locationId] != distanceText {
                lastDistanceText[locationId] = distanceText
                
                // PERFORMANCE: Use cached texture if available, otherwise create new one
                let newMaterial = createTextMaterial(text: distanceText, cacheKey: distanceText)
                if var model = textEntity.model {
                    model.materials = [newMaterial]
                    textEntity.model = model
                }
            }
            
            // Make text face camera (billboard effect)
            let directionToCamera = normalize(cameraPosition - boxPosition)
            // Calculate rotation to face camera (simplified - just rotate around Y axis)
            let angle = atan2(directionToCamera.x, directionToCamera.z)
            textEntity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        if elapsed > 5.0 { // Only log if takes more than 5ms
            Swift.print("⏱️ [PERF] updateDistanceTexts took \(String(format: "%.1f", elapsed))ms for \(placedBoxes.count) objects")
        }
    }
    
    /// Updates the direction to the selected object (if any) or nearest placed object
    func updateNearestObjectDirection() {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            nearestObjectDirection = nil
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Validate camera position - AR coordinates should be reasonable (< 10,000 units)
        let maxReasonableCoordinate: Float = 10000.0
        guard abs(cameraPos.x) < maxReasonableCoordinate &&
              abs(cameraPos.y) < maxReasonableCoordinate &&
              abs(cameraPos.z) < maxReasonableCoordinate else {
            monitorCoordinateSystemHealth(cameraPosition: cameraPos)
            Swift.print("⚠️ Invalid camera position in updateNearestObjectDirection, skipping")
            nearestObjectDirection = nil
            return
        }

        // Get forward vector for orientation
        let cameraForward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)

        // Use user's compass heading to align navigation with real world direction
        // This matches the admin panel's calculation (heading + 180° adjustment)
        var forward = cameraForward
        if let userHeading = userLocationManager?.heading {
            // Convert compass heading to radians and add 180° (same as admin panel)
            let adjustedHeadingRadians = (Double(userHeading) + 180.0) * .pi / 180.0

            // Create a forward vector aligned with user's compass heading
            // In AR space: -Z is typically north, +X is east
            let compassForwardX = Float(sin(adjustedHeadingRadians))  // East component
            let compassForwardZ = Float(-cos(adjustedHeadingRadians)) // North component (negative because -Z is north)
            forward = SIMD3<Float>(compassForwardX, 0, compassForwardZ)

            print("🧭 [Navigation] Using compass heading: \(String(format: "%.1f", userHeading))° → adjusted: \(String(format: "%.1f", (userHeading + 180.0).truncatingRemainder(dividingBy: 360.0)))°")
        } else {
            print("🧭 [Navigation] No compass heading available, using camera forward vector")
        }

        // Check for selected object first, otherwise find nearest
        var targetPosition: SIMD3<Float>? = nil
        
        // Priority 1: Selected object (if one is selected)
        if let selectedId = locationManager.selectedDatabaseObjectId {
            // First try to find the selected object in placedBoxes (AR coordinates)
            if let anchor = placedBoxes[selectedId],
               let _ = locationManager.locations.first(where: { $0.id == selectedId && !$0.collected }) {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                var objectPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Find the actual object position (chalice, treasure box, or sphere)
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        if modelEntity.name == selectedId {
                            let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                            objectPos = SIMD3<Float>(
                                objectTransform.columns.3.x,
                                objectTransform.columns.3.y,
                                objectTransform.columns.3.z
                            )
                            break
                        } else if modelEntity.components[PointLightComponent.self] != nil && modelEntity.name == selectedId {
                            let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                            objectPos = SIMD3<Float>(
                                objectTransform.columns.3.x,
                                objectTransform.columns.3.y,
                                objectTransform.columns.3.z
                            )
                            break
                        }
                    }
                }
                
                targetPosition = objectPos
            } else if let location = locationManager.locations.first(where: { $0.id == selectedId && !$0.collected }),
                      let userLocation = userLocationManager?.currentLocation,
                      location.latitude != 0 || location.longitude != 0 {
                // Selected object not placed yet, but we have GPS coordinates - calculate direction from GPS
                // Convert GPS to AR position if possible, otherwise use GPS bearing
                let targetLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                let distance = userLocation.distance(from: targetLocation)
                let bearing = userLocation.bearing(to: targetLocation)
                
                // Try to convert GPS to AR position if we have AR origin
                // For now, use a simplified approach: place target at estimated distance in front
                // This is a fallback when the object isn't placed yet
                let estimatedDistance = min(Float(distance), 50.0) // Cap at 50m for AR space
                let _ = normalize(SIMD3<Float>(forward.x, 0, forward.z))
                
                // Calculate direction based on GPS bearing
                // Convert bearing (0° = north) to AR space direction
                let bearingRad = Float(bearing * .pi / 180.0)
                let northDirection = SIMD3<Float>(0, 0, -1) // ARKit's -Z is typically north
                let eastDirection = SIMD3<Float>(1, 0, 0) // ARKit's +X is typically east
                
                // Calculate target direction in AR space from GPS bearing
                let targetDirection = cos(bearingRad) * northDirection + sin(bearingRad) * eastDirection
                let normalizedTargetDir = normalize(targetDirection)
                
                // Position target at estimated distance in the calculated direction
                // Use camera Y position for height (assume same level)
                targetPosition = cameraPos + normalizedTargetDir * estimatedDistance
                targetPosition?.y = cameraPos.y // Keep at camera height
            }
        }
        
        // Priority 2: Nearest uncollected object (if no selected object or selected not found)
        // Only check placed boxes if we have any, and if no selected object is being tracked
        if targetPosition == nil && !placedBoxes.isEmpty {
            var nearestDistance: Float = .infinity
            
            for (locationId, anchor) in placedBoxes {
                // Skip if already collected
                guard locationManager.locations.first(where: { $0.id == locationId && !$0.collected }) != nil else {
                    continue
                }
                
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                var objectPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Find the actual object position (chalice, treasure box, or sphere)
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        if modelEntity.name == locationId {
                            let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                            objectPos = SIMD3<Float>(
                                objectTransform.columns.3.x,
                                objectTransform.columns.3.y,
                                objectTransform.columns.3.z
                            )
                            break
                        } else if modelEntity.components[PointLightComponent.self] != nil && modelEntity.name == locationId {
                            let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                            objectPos = SIMD3<Float>(
                                objectTransform.columns.3.x,
                                objectTransform.columns.3.y,
                                objectTransform.columns.3.z
                            )
                            break
                        }
                    }
                }
                
                let distance = length(objectPos - cameraPos)
                if distance < nearestDistance {
                    nearestDistance = distance
                    targetPosition = objectPos
                }
            }
        }

        guard let targetPos = targetPosition else {
            nearestObjectDirection = nil
            return
        }

        // Calculate direction vector from camera to target
        let directionVector = targetPos - cameraPos
        let horizontalDirection = SIMD3<Float>(directionVector.x, 0, directionVector.z)

        if length(horizontalDirection) < 0.1 {
            // Directly above/below - can't determine horizontal direction
            nearestObjectDirection = nil
            return
        }

        // Normalize the horizontal direction
        let normalizedDirection = normalize(horizontalDirection)

        // Calculate angle using AR position (most accurate for placed objects)
        // Convert direction vector to angle

        // Calculate angle from forward direction (use horizontal component only)
        let horizontalForward = SIMD3<Float>(forward.x, 0, forward.z)
        let angleRad = atan2(horizontalDirection.x * horizontalForward.z - horizontalDirection.z * horizontalForward.x,
                            horizontalDirection.x * horizontalForward.x + horizontalDirection.z * horizontalForward.z)

        var angle = Float(angleRad * 180.0 / .pi)

        // Normalize to 0-360 range
        if angle < 0 {
            angle += 360
        }

        print("🧭 [Navigation] AR-based direction: \(String(format: "%.1f", angle))°")

        // Use precise angle without snapping for accurate navigation
        nearestObjectDirection = Double(angle)
        
        // Update binding
        DispatchQueue.main.async { [weak self] in
            self?.nearestObjectDirectionBinding?.wrappedValue = self?.nearestObjectDirection
        }
    }
    
    // MARK: - Private Methods
    
    private func logDistanceToNearestLootBox() {
        // DEAD MEN'S SECRETS MODE: If we have a map and treasure location, always use GPS (treasure location)
        if let locationManager = locationManager,
           locationManager.gameMode == .deadMensSecrets,
           let treasureHuntService = treasureHuntService,
           treasureHuntService.shouldShowNavigation,
           let userLocation = userLocationManager?.currentLocation {
            calculateDistanceUsingGPS(userLocation: userLocation)
            return
        }
        
        // Try to use AR world coordinates first (more accurate for AR), fallback to GPS
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            // Fallback to GPS if AR not available
            guard let userLocation = userLocationManager?.currentLocation else {
                DispatchQueue.main.async { [weak self] in
                    self?.distanceToNearestBinding?.wrappedValue = nil
                    self?.temperatureStatusBinding?.wrappedValue = nil
                    self?.nearestObjectDirectionBinding?.wrappedValue = nil
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

        // Validate camera position - AR coordinates should be reasonable (< 10,000 units)
        let maxReasonableCoordinate: Float = 10000.0
        guard abs(cameraPosition.x) < maxReasonableCoordinate &&
              abs(cameraPosition.y) < maxReasonableCoordinate &&
              abs(cameraPosition.z) < maxReasonableCoordinate else {
            monitorCoordinateSystemHealth(cameraPosition: cameraPosition)
            Swift.print("⚠️ Invalid camera position in logDistanceToNearestLootBox, skipping")
            // Clear distance binding to prevent showing invalid distances
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
                self?.nearestObjectDirectionBinding?.wrappedValue = nil
            }
            return
        }
        
        // Priority 1: Check for selected object first
        var targetBox: (location: LootBoxLocation, distance: Double, anchor: AnchorEntity)? = nil
        
        if let selectedId = locationManager.selectedDatabaseObjectId,
           let anchor = placedBoxes[selectedId],
           let location = locationManager.locations.first(where: { $0.id == selectedId && !$0.collected }) {
            // Get anchor position in AR world space
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let anchorPosition = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )

            // Find the actual object position (chalice, treasure box, or sphere)
            var objectPosition = anchorPosition
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity {
                    // Check for loot box containers (chalice or treasure box)
                    if modelEntity.name == selectedId {
                        let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                        objectPosition = SIMD3<Float>(
                            objectTransform.columns.3.x,
                            objectTransform.columns.3.y,
                            objectTransform.columns.3.z
                        )
                        break
                    }
                    // Check for standalone spheres
                    else if modelEntity.components[PointLightComponent.self] != nil && modelEntity.name == selectedId {
                        let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                        objectPosition = SIMD3<Float>(
                            objectTransform.columns.3.x,
                            objectTransform.columns.3.y,
                            objectTransform.columns.3.z
                        )
                        break
                    }
                }
            }

            // Calculate distance in AR world space (meters) - use object position for accuracy
            let rawDistance = Double(length(objectPosition - cameraPosition))

            // Validate distance to prevent extreme values from corrupted coordinate systems
            // AR coordinate systems can drift and produce distances in millions/billions of meters
            // Cap at reasonable maximum for AR navigation (500m - beyond this objects aren't visible anyway)
            let maxReasonableDistance: Double = 500.0
            let distance = min(rawDistance, maxReasonableDistance)

            // If distance was capped, log a warning
            if rawDistance > maxReasonableDistance {
                Swift.print("⚠️ AR Distance capped: raw=\(String(format: "%.0f", rawDistance))m, capped=\(String(format: "%.1f", distance))m")
                Swift.print("   Camera pos: (\(String(format: "%.1f", cameraPosition.x)), \(String(format: "%.1f", cameraPosition.y)), \(String(format: "%.1f", cameraPosition.z)))")
                Swift.print("   Object pos: (\(String(format: "%.1f", objectPosition.x)), \(String(format: "%.1f", objectPosition.y)), \(String(format: "%.1f", objectPosition.z)))")
            }
            targetBox = (location: location, distance: distance, anchor: anchor)
        }
        
        // Priority 2: If no selected object or selected not found, find nearest uncollected loot box
        if targetBox == nil {
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

            // Find the actual object position (chalice, treasure box, or sphere)
            var objectPosition = anchorPosition
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity {
                    // Check for loot box containers (chalice or treasure box)
                    if modelEntity.name == locationId {
                        let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                        objectPosition = SIMD3<Float>(
                            objectTransform.columns.3.x,
                            objectTransform.columns.3.y,
                            objectTransform.columns.3.z
                        )
                        break
                    }
                    // Check for standalone spheres
                    else if modelEntity.name == locationId && modelEntity.components[PointLightComponent.self] != nil {
                        let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                        objectPosition = SIMD3<Float>(
                            objectTransform.columns.3.x,
                            objectTransform.columns.3.y,
                            objectTransform.columns.3.z
                        )
                        break
                    }
                }
            }

            // Calculate distance in AR world space (meters) - use object position for accuracy
            let rawDistance = Double(length(objectPosition - cameraPosition))

            // Validate distance to prevent extreme values from corrupted coordinate systems
            let maxReasonableDistance: Double = 500.0
            let distance = min(rawDistance, maxReasonableDistance)

            // If distance was capped, log a warning (but don't spam logs)
            if rawDistance > maxReasonableDistance && rawDistance.truncatingRemainder(dividingBy: 1000) < 1.0 {
                Swift.print("⚠️ AR Distance capped in nearest calc: raw=\(String(format: "%.0f", rawDistance))m, capped=\(String(format: "%.1f", distance))m")
            }
                
                if distance < minDistance {
                    minDistance = distance
                    targetBox = (location: location, distance: distance, anchor: anchor)
                }
            }
        }
        
        // If we found a box in AR space, use that
        if let nearest = targetBox {
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
                self?.nearestObjectDirectionBinding?.wrappedValue = nil
            }
        }
    }
    
    private func calculateDistanceUsingGPS(userLocation: CLLocation) {
        guard let locationManager = locationManager else {
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
                self?.nearestObjectDirectionBinding?.wrappedValue = nil
            }
            return
        }
        
        // Check if we have a valid GPS fix (horizontal accuracy should be reasonable)
        guard userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 100 else {
            DispatchQueue.main.async { [weak self] in
                self?.distanceToNearestBinding?.wrappedValue = nil
                self?.temperatureStatusBinding?.wrappedValue = nil
                self?.nearestObjectDirectionBinding?.wrappedValue = nil
            }
            return
        }
        
        // DEAD MEN'S SECRETS MODE: If we have a map and treasure location, use that instead
        if locationManager.gameMode == .deadMensSecrets,
           let treasureHuntService = treasureHuntService,
           treasureHuntService.shouldShowNavigation,
           let treasureLocation = treasureHuntService.treasureLocation {
            // Use treasure location for navigation
            let distance = treasureHuntService.getDistanceToTreasure(from: userLocation) ?? 0
            let direction = treasureHuntService.getDirectionToTreasure(from: userLocation)
            
            // Create a temporary LootBoxLocation for temperature calculation
            let tempLocation = LootBoxLocation(
                id: "treasure-clue",
                name: "Treasure Clue",
                type: .treasureChest,
                latitude: treasureLocation.coordinate.latitude,
                longitude: treasureLocation.coordinate.longitude,
                radius: 100
            )
            
            // Update with treasure location
            updateTemperatureStatus(currentDistance: distance, location: tempLocation)
            
            // Update direction binding
            DispatchQueue.main.async { [weak self] in
                self?.nearestObjectDirectionBinding?.wrappedValue = direction
            }
            return
        }
        
        // Priority 1: Check for selected object first
        var targetLocation: (location: LootBoxLocation, distance: Double)? = nil
        
        if let selectedId = locationManager.selectedDatabaseObjectId,
           let selectedLocation = locationManager.locations.first(where: { $0.id == selectedId && !$0.collected }) {
            // Validate user location coordinates
            let validCoordinates = userLocation.coordinate.latitude.isFinite &&
                                  userLocation.coordinate.longitude.isFinite

            if !validCoordinates {
                print("⚠️ [Distance Tracker] Invalid user location coordinates, using GPS distance fallback")
            }

            // CRITICAL FIX: For AR-placed objects, calculate distance in AR space, not GPS space
            // GPS coordinates for AR-placed objects are estimates and can be very inaccurate
            let distance: Double
            if selectedLocation.hasARData, let arDistance = selectedLocation.arDistance(from: userLocation, arOrigin: locationManager.sharedAROrigin) {
                // Calculate AR distance using AR coordinates for millimeter precision
                distance = arDistance
                print("🎯 [Distance] Using AR distance: \(String(format: "%.2f", distance))m (\(formatDistance(distance))) for object \(selectedLocation.name)")
            } else {
                // Fall back to GPS distance for non-AR objects
                distance = userLocation.distance(from: selectedLocation.location)
                print("📍 [Distance] Using GPS distance: \(String(format: "%.2f", distance))m (\(formatDistance(distance))) for object \(selectedLocation.name)")
            }
            targetLocation = (location: selectedLocation, distance: distance)
        }
        
        // Priority 2: If no selected object or selected not found, find nearest uncollected loot box
        if targetLocation == nil {
            let uncollectedLocations = locationManager.locations.filter { !$0.collected }
            guard !uncollectedLocations.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    self?.distanceToNearestBinding?.wrappedValue = nil
                    self?.temperatureStatusBinding?.wrappedValue = nil
                    self?.nearestObjectDirectionBinding?.wrappedValue = nil
                }
                return
            }
            
            let distances = uncollectedLocations.map { location in
                (location: location, distance: userLocation.distance(from: location.location))
            }
            
            // Find the nearest location
            guard let nearest = distances.min(by: { $0.distance < $1.distance }) else {
                DispatchQueue.main.async { [weak self] in
                    self?.distanceToNearestBinding?.wrappedValue = nil
                    self?.temperatureStatusBinding?.wrappedValue = nil
                    self?.nearestObjectDirectionBinding?.wrappedValue = nil
                }
                return
            }
            
            targetLocation = (location: nearest.location, distance: nearest.distance)
        }
        
        // Update with target location (selected or nearest)
        if let target = targetLocation {
            updateTemperatureStatus(currentDistance: target.distance, location: target.location)
        }
    }
    
    private func updateTemperatureStatus(currentDistance: Double, location: LootBoxLocation) {
        // Update temperature status without distance (distance shown separately in UI)
        var status: String?
        if let previous = previousDistance {
            // We have a previous distance to compare - show warmer/colder
            // Use a threshold to avoid flickering (only show change if difference is significant)
            // 1.5 feet threshold (approximately 0.46m)
            let threshold: Double = 0.46 // ~1.5 feet
            if currentDistance < previous - threshold {
                status = "🔥 Warmer"
            } else if currentDistance > previous + threshold {
                status = "❄️ Colder"
            } else {
                // Within threshold - don't show anything
                status = nil
            }
            previousDistance = currentDistance
        } else {
            // First reading - don't show status yet, just store it for next comparison
            previousDistance = currentDistance
            status = nil // Don't show anything until we have a comparison
        }

        // Update current target object name and object
        currentTargetObjectName = location.name
        currentTargetObject = location

        // Check for proximity (within 3 feet = ~0.91m) - play sound only (no auto-collection)
        // User must tap to collect boxes
        if currentDistance <= 0.91 && !proximitySoundPlayed.contains(location.id) {
            playProximitySound(for: location, distance: currentDistance)
            proximitySoundPlayed.insert(location.id)
            // NOTE: Auto-collection disabled - user must tap to collect
        }

        // Update direction to nearest object
        updateNearestObjectDirection()

        // Update audio ping service if audio mode is enabled
        if let locationManager = locationManager, locationManager.enableAudioMode {
            audioPingService?.updateDistance(currentDistance)
            // Start if not already running (will be checked internally)
            audioPingService?.start()
        } else {
            audioPingService?.stop()
        }

        // Update bindings
        DispatchQueue.main.async { [weak self] in
            self?.distanceToNearestBinding?.wrappedValue = currentDistance
            self?.temperatureStatusBinding?.wrappedValue = status
            self?.currentTargetObjectNameBinding?.wrappedValue = self?.currentTargetObjectName
            self?.currentTargetObjectBinding?.wrappedValue = self?.currentTargetObject
            if let direction = self?.nearestObjectDirection {
                self?.nearestObjectDirectionBinding?.wrappedValue = direction
            } else {
                self?.nearestObjectDirectionBinding?.wrappedValue = nil
            }
        }
    }
    
    /// Plays a sound when user is within 0.91m (3 feet) of a loot box
    private func playProximitySound(for location: LootBoxLocation, distance: Double) {
        // Play a subtle proximity sound (different from opening sound)
        // System sound 1054 is a bell-like notification sound (lower pitch)
        AudioServicesPlaySystemSound(1054) // System sound for proximity/notification
        Swift.print("🔔 SOUND: Proximity bell (system sound 1054)")
        Swift.print("   Trigger: Within 0.91m (3 feet) of loot box")
        Swift.print("   Object: \(location.name) (\(location.type.displayName))")
        Swift.print("   Distance: \(String(format: "%.2f", distance))m")
        Swift.print("   Location ID: \(location.id)")
    }
    
    // MARK: - Helper Methods
    
    /// Helper function to convert meters to feet and inches
    private func metersToFeetAndInches(_ meters: Double) -> (feet: Int, inches: Int) {
        let totalInches = meters * 39.3701 // 1 meter = 39.3701 inches
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        return (feet: feet, inches: inches)
    }
    
    /// Helper function to format distance as feet and inches string
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
    
    /// Creates a 3D text entity for displaying distance
    func createDistanceTextEntity() -> ModelEntity {
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
    /// PERFORMANCE: Uses texture cache to avoid expensive recreation
    private func createTextMaterial(text: String, cacheKey: String? = nil) -> SimpleMaterial {
        let key = cacheKey ?? text
        
        // PERFORMANCE: Check cache first to avoid expensive texture creation
        if let cachedTexture = textureCache[key] {
            var material = SimpleMaterial()
            material.color = .init(texture: .init(cachedTexture))
            material.roughness = 0.1
            material.metallic = 0.0
            return material
        }
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
                
                // PERFORMANCE: Cache the texture for future use
                // Only cache if we have space (prevent memory issues)
                if textureCache.count < maxTextureCacheSize {
                    textureCache[key] = texture
                } else {
                    // Cache is full - remove oldest entry (simple FIFO)
                    // In practice, this rarely happens since we only cache unique distance texts
                    if let firstKey = textureCache.keys.first {
                        textureCache.removeValue(forKey: firstKey)
                        textureCache[key] = texture
                    }
                }
            } catch {
                print("⚠️ Failed to create texture from text: \(error)")
                material.color = .init(tint: .white)
            }
        }
        material.roughness = 0.1
        material.metallic = 0.0
        
        return material
    }
    
    /// Clears the texture cache (call when memory is low or when resetting)
    func clearTextureCache() {
        textureCache.removeAll()
        Swift.print("🧹 ARDistanceTracker: Texture cache cleared")
    }

    /// Monitor coordinate system health and suggest recovery when coordinates drift too far
    private func monitorCoordinateSystemHealth(cameraPosition: SIMD3<Float>) {
        let maxReasonableCoordinate: Float = 10000.0
        let isCoordinateDrifted = abs(cameraPosition.x) >= maxReasonableCoordinate ||
                                  abs(cameraPosition.y) >= maxReasonableCoordinate ||
                                  abs(cameraPosition.z) >= maxReasonableCoordinate

        if isCoordinateDrifted {
            coordinateDriftWarnings += 1
            let currentTime = Date().timeIntervalSince1970

            // Only log warnings every 30 seconds to avoid spam
            if currentTime - lastCoordinateDriftWarning > 30.0 {
                lastCoordinateDriftWarning = currentTime
                Swift.print("🚨 AR Coordinate System Drift Detected!")
                Swift.print("   Camera position: (\(String(format: "%.0f", cameraPosition.x)), \(String(format: "%.0f", cameraPosition.y)), \(String(format: "%.0f", cameraPosition.z)))")
                Swift.print("   Warning count: \(coordinateDriftWarnings)")
                Swift.print("   💡 Suggestion: Reset AR tracking to recover coordinate system")
                Swift.print("   This can happen during long AR sessions or tracking interruptions")

                // Reset warning counter periodically
                if coordinateDriftWarnings > 10 {
                    coordinateDriftWarnings = 0
                    Swift.print("🔄 Reset coordinate drift warning counter")
                }
            }
        } else {
            // Reset warning counter when coordinates are healthy again
            if coordinateDriftWarnings > 0 {
                coordinateDriftWarnings = 0
                Swift.print("✅ AR coordinate system recovered to normal range")
            }
        }
    }

    deinit {
        distanceLogger?.invalidate()
    }
}

