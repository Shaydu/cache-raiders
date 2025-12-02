import AVFoundation
import AudioToolbox
import UIKit
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Audio Manager
class ARAudioManager {

    private weak var arCoordinator: ARCoordinatorCore?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore) {
        self.arCoordinator = arCoordinator
    }

    // MARK: - Audio Session Management

    /// Setup audio session for AR sounds
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session: \(error)")
        }
    }

    // MARK: - Viewport Chime System

    /// Play a chime sound when an object enters the viewport
    /// Uses a different, gentler sound than the treasure found sound
    func playViewportChime(for locationId: String) {
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session for chime: \(error)")
        }

        // Get object details for logging
        let location = arCoordinator?.locationManager?.locations.first(where: { $0.id == locationId })
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

    // MARK: - Viewport Visibility Checking

    /// Check if an object is currently visible in the viewport
    func isObjectInViewport(locationId: String, anchor: AnchorEntity) -> Bool {
        guard let arView = arCoordinator?.arView,
              let frame = arView.session.currentFrame else { return false }

        // Get camera position and forward direction
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Camera forward direction is the negative Z axis in camera space (columns.2)
        // Transform to world space to get the direction vector
        let forwardDirection = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )

        // Get object world position
        let anchorTransform = anchor.transformMatrix(relativeTo: nil)
        let objectPosition = SIMD3<Float>(
            anchorTransform.columns.3.x,
            anchorTransform.columns.3.y,
            anchorTransform.columns.3.z
        )

        // Vector from camera to object
        let toObject = objectPosition - cameraPos

        // Check if object is in front of camera (dot product > 0)
        let dotProduct = dot(forwardDirection, toObject)
        if dotProduct <= 0 {
            return false // Object is behind camera or outside view
        }

        // Check if the projected point is within the viewport bounds
        let viewWidth = CGFloat(arView.bounds.width)
        let viewHeight = CGFloat(arView.bounds.height)

        // Add a small margin to account for object size (objects slightly off-screen still count)
        let margin: CGFloat = 50.0 // 50 point margin

        // Project object position to screen coordinates
        guard let screenPoint = arView.project(objectPosition) else {
            return false
        }

        // Break down the complex expression into sub-expressions to help compiler type-checking
        let xInBounds = screenPoint.x >= -margin && screenPoint.x <= viewWidth + margin
        let yInBounds = screenPoint.y >= -margin && screenPoint.y <= viewHeight + margin
        let isInViewport = xInBounds && yInBounds

        return isInViewport
    }

    /// Check viewport visibility for all placed objects and play chime when objects enter
    /// PERFORMANCE: Optimized to limit checks and avoid expensive operations
    func checkViewportVisibility() {
        guard let arView = arCoordinator?.arView,
              let findableObjects = arCoordinator?.findableObjects,
              let distanceTracker = arCoordinator?.distanceTracker,
              let locationManager = arCoordinator?.locationManager,
              let userLocationManager = arCoordinator?.userLocationManager else { return }

        // PERFORMANCE: Limit viewport checks to prevent freeze with many objects
        // Only check up to 20 objects per frame (prioritize nearby objects)
        let maxChecksPerFrame = 20
        var checkedCount = 0

        var currentlyVisible: Set<String> = []

        // Check visibility for each placed object (limited to prevent freeze)
        for (locationId, findable) in findableObjects {
            let anchor = findable.anchor
            // PERFORMANCE: Limit checks per frame
            if checkedCount >= maxChecksPerFrame {
                break
            }
            checkedCount += 1

            // Skip if already found/collected
            if distanceTracker.foundLootBoxes.contains(locationId) {
                continue
            }

            // Check if object is in viewport
            if isObjectInViewport(locationId: locationId, anchor: anchor) {
                currentlyVisible.insert(locationId)

                // If object just entered viewport (wasn't visible before), play chime and log details
                if !(arCoordinator?.objectsInViewport.contains(locationId) ?? false) {
                    playViewportChime(for: locationId)

                    // DEBUG: Check AR scene state when chime plays
                    if let arCoordinator = arCoordinator as? ARCoordinator {
                        Swift.print("🔔 DEBUG: Object entered viewport, checking scene state...")
                        arCoordinator.debugARSceneState()
                    }

                    // Get object details for logging (cached lookup to avoid expensive search)
                    let location = locationManager.locations.first(where: { $0.id == locationId })
                    let objectName = location?.name ?? "Unknown"
                    let objectType = location?.type.displayName ?? "Unknown Type"

                    // Calculate distance if user location is available
                    var distanceInfo = ""
                    if let userLocation = userLocationManager.currentLocation,
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
        arCoordinator?.objectsInViewport = currentlyVisible
    }

    // MARK: - Throttled Viewport Checking

    /// Check viewport visibility with throttling to improve performance
    func checkViewportVisibilityThrottled() {
        guard let lastViewportCheck = arCoordinator?.lastViewportCheck else { return }

        // PERFORMANCE: Throttle viewport checks to improve framerate
        // Only check every 0.5 seconds (2 FPS) to avoid performance impact
        let now = Date()
        if now.timeIntervalSince(lastViewportCheck) >= 0.5 {
            arCoordinator?.lastViewportCheck = now
            checkViewportVisibility()
        }
    }
}

