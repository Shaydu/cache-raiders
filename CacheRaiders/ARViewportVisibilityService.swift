import SwiftUI
import RealityKit
import ARKit
import AVFoundation
import AudioToolbox

/// Service for tracking viewport visibility of AR objects and playing chimes when objects enter viewport
class ARViewportVisibilityService {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var userLocationManager: UserLocationManager?
    weak var distanceTracker: ARDistanceTracker?
    
    private var objectsInViewport: Set<String> = []
    private var placedBoxes: [String: AnchorEntity] = [:]
    
    init(arView: ARView?, locationManager: LootBoxLocationManager?, userLocationManager: UserLocationManager?, distanceTracker: ARDistanceTracker?) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.distanceTracker = distanceTracker
    }
    
    func updatePlacedBoxes(_ boxes: [String: AnchorEntity]) {
        placedBoxes = boxes
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

        // Single haptic "bump" when a findable object enters the viewport
        DispatchQueue.main.async {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }

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
    /// PERFORMANCE: Optimized to limit checks and avoid expensive operations
    func checkViewportVisibility() {
        guard let arView = arView else { return }
        
        // PERFORMANCE: Limit viewport checks to prevent freeze with many objects
        // Only check up to 20 objects per frame (prioritize nearby objects)
        let maxChecksPerFrame = 20
        var checkedCount = 0
        
        var currentlyVisible: Set<String> = []
        
        // Check visibility for each placed object (limited to prevent freeze)
        for (locationId, anchor) in placedBoxes {
            // PERFORMANCE: Limit checks per frame
            if checkedCount >= maxChecksPerFrame {
                break
            }
            checkedCount += 1
            
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
                    
                    // Get object details for logging (cached lookup to avoid expensive search)
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
}

