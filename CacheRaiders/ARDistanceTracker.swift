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
    
    @Published var nearestObjectDirection: Double? = nil
    @Published var currentTargetObjectName: String? = nil

    private var distanceLogger: Timer?
    private var previousDistance: Double?
    private var audioPingService: AudioPingService?
    
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

        // Get forward vector for orientation
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)

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
                currentTargetObjectName = locationManager.locations.first(where: { $0.id == selectedId && !$0.collected })?.name
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
                currentTargetObjectName = location.name
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
            currentTargetObjectName = nil
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

        // Calculate angle in screen space for UI arrow
        // The icon "location.north.line.fill" points up by default
        // We need to calculate the angle where:
        // - 0° = up (target is straight ahead/forward)
        // - 90° = right (target is to the right)
        // - 180° = down (target is behind)
        // - 270° = left (target is to the left)
        
        // Get camera's right and forward vectors (horizontal only)
        let cameraForward = normalize(SIMD3<Float>(forward.x, 0, forward.z))
        let cameraRight = normalize(cross(SIMD3<Float>(0, 1, 0), cameraForward))

        // Project target direction onto camera's right and forward vectors
        let rightComponent = dot(normalizedDirection, cameraRight)  // + = right, - = left
        let forwardComponent = dot(normalizedDirection, cameraForward)  // + = forward, - = behind

        // Calculate angle in screen space
        // For screen coordinates: atan2(y, x) where:
        // - y = forwardComponent (positive = forward = up on screen)
        // - x = rightComponent (positive = right)
        // But we want: 0° = up (forward), 90° = right
        // So: angle = atan2(forwardComponent, rightComponent)
        // However, atan2 gives: 0° = +x (right), 90° = +y (up)
        // We want: 0° = up, 90° = right
        // So we need: angle = atan2(rightComponent, forwardComponent) + 90°
        // Or simpler: angle = atan2(forwardComponent, rightComponent) - 90°
        // Actually, let's use: angle = atan2(rightComponent, forwardComponent)
        // This gives: 0° when forward, 90° when right, 180° when behind, 270° when left
        // But icon points up, so we need to rotate: angle = atan2(rightComponent, forwardComponent) - 90°
        var angle = atan2(rightComponent, forwardComponent) * 180.0 / .pi - 90.0

        // Normalize to 0-360 range
        if angle < 0 {
            angle += 360
        }

        // Snap to 15-degree intervals for better accuracy while still being smooth
        // Round to nearest 15° (0°, 15°, 30°, 45°, 60°, 75°, 90°, etc.)
        let interval: Float = 15.0
        angle = round(angle / interval) * interval

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
            let distance = Double(length(objectPosition - cameraPosition))
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
                let distance = Double(length(objectPosition - cameraPosition))
                
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
            let distance = userLocation.distance(from: selectedLocation.location)
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
    
    deinit {
        distanceLogger?.invalidate()
    }
}

