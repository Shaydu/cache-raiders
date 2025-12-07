import ARKit
import RealityKit

// MARK: - AR Session Manager
class ARSessionManager: NSObject, ARSessionDelegate {

    private weak var arCoordinator: ARCoordinatorCore?
    private var stateManager: ARStateManager?
    private var audioManager: ARAudioManager?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore, stateManager: ARStateManager, audioManager: ARAudioManager) {
        self.arCoordinator = arCoordinator
        self.stateManager = stateManager
        self.audioManager = audioManager
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        handleFrameUpdate(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        handleAnchorsAdded(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        handleAnchorsUpdated(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        handleAnchorsRemoved(anchors)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        handleSessionFailure(error)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        handleSessionInterruption()
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        handleSessionInterruptionEnded()
    }

    // MARK: - Frame Update Handling

    private func handleFrameUpdate(_ frame: ARFrame) {
        // Set AR origin on first frame if not set
        setupAROriginIfNeeded(frame)

        // Check viewport visibility with throttling
        audioManager?.checkViewportVisibilityThrottled()

        // Perform object recognition with throttling (only if enabled)
        if stateManager?.shouldPerformObjectRecognition() == true &&
           arCoordinator?.locationManager?.enableObjectRecognition == true {
            arCoordinator?.objectRecognizer?.performObjectRecognition(on: frame.capturedImage)
        }
    }

    private func setupAROriginIfNeeded(_ frame: ARFrame) {
        guard arCoordinator?.arOriginLocation == nil else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Try to get GPS location
        if let userLocation = arCoordinator?.userLocationManager?.currentLocation {
            // Check GPS accuracy
            if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 7.5 {
                // Accurate mode
                setAccurateAROrigin(userLocation, cameraPos: cameraPos)
            } else {
                // Low accuracy - handle timeout
                handleLowGPSAccuracy(userLocation, frame: frame)
            }
        } else {
            // No GPS - handle timeout
            handleNoGPSLocation(cameraPos: cameraPos, frame: frame)
        }

        // Check if we should exit degraded mode
        checkExitDegradedMode(frame)
    }

    private func setAccurateAROrigin(_ userLocation: CLLocation, cameraPos: SIMD3<Float>) {
        guard let geospatialService = arCoordinator?.geospatialService,
              geospatialService.setENUOrigin(from: userLocation) else { return }

        arCoordinator?.arOriginLocation = userLocation
        arCoordinator?.arOriginSetTime = Date()
        arCoordinator?.isDegradedMode = false

        // Set ground level
        let groundLevel: Float
        if let surfaceY = arCoordinator?.groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
            groundLevel = surfaceY
        } else {
            groundLevel = cameraPos.y - 1.5
        }

        arCoordinator?.arOriginGroundLevel = groundLevel
        geospatialService.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
        arCoordinator?.precisionPositioningService?.setAROriginGroundLevel(groundLevel)

        Swift.print("✅ AR Origin SET (ACCURATE MODE) at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
        Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m")
    }

    private func handleLowGPSAccuracy(_ userLocation: CLLocation, frame: ARFrame) {
        let waitTime: TimeInterval = 10.0
        if let setTime = arCoordinator?.arOriginSetTime {
            if Date().timeIntervalSince(setTime) > waitTime {
                enterDegradedMode(cameraPos: SIMD3<Float>(0, 0, 0), frame: frame)
            }
        } else {
            arCoordinator?.arOriginSetTime = Date()
            Swift.print("⚠️ GPS accuracy too low: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
        }
    }

    private func handleNoGPSLocation(cameraPos: SIMD3<Float>, frame: ARFrame) {
        let waitTime: TimeInterval = 5.0
        if let setTime = arCoordinator?.arOriginSetTime {
            if Date().timeIntervalSince(setTime) > waitTime {
                enterDegradedMode(cameraPos: cameraPos, frame: frame)
            }
        } else {
            arCoordinator?.arOriginSetTime = Date()
            Swift.print("⚠️ No GPS location available")
        }
    }

    private func checkExitDegradedMode(_ frame: ARFrame) {
        guard arCoordinator?.isDegradedMode == true,
              let userLocation = arCoordinator?.userLocationManager?.currentLocation,
              userLocation.horizontalAccuracy >= 0,
              userLocation.horizontalAccuracy < 6.5 else { return }

        exitDegradedMode(userLocation, frame: frame)
    }

    private func enterDegradedMode(cameraPos: SIMD3<Float>, frame: ARFrame) {
        // Set degraded mode origin
        arCoordinator?.arOriginLocation = CLLocation(latitude: 0, longitude: 0) // Dummy location
        arCoordinator?.arOriginSetTime = Date()
        arCoordinator?.isDegradedMode = true

        // Set ground level
        let groundLevel: Float = cameraPos.y - 1.5
        arCoordinator?.arOriginGroundLevel = groundLevel

        Swift.print("⚠️ ENTERED DEGRADED MODE - AR-only positioning")
        Swift.print("   No GPS available or accuracy too low")
        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m")
    }

    private func exitDegradedMode(_ userLocation: CLLocation, frame: ARFrame) {
        guard let geospatialService = arCoordinator?.geospatialService,
              geospatialService.setENUOrigin(from: userLocation) else { return }

        arCoordinator?.arOriginLocation = userLocation
        arCoordinator?.arOriginSetTime = Date()
        arCoordinator?.isDegradedMode = false

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        let groundLevel: Float
        if let surfaceY = arCoordinator?.groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
            groundLevel = surfaceY
        } else {
            groundLevel = cameraPos.y - 1.5
        }

        arCoordinator?.arOriginGroundLevel = groundLevel
        geospatialService.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
        arCoordinator?.precisionPositioningService?.setAROriginGroundLevel(groundLevel)

        Swift.print("✅ EXITED DEGRADED MODE - GPS accuracy improved!")
        Swift.print("   AR Origin SET at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
    }

    // MARK: - Anchor Handling

    private func handleAnchorsAdded(_ anchors: [ARAnchor]) {
        guard let arView = arCoordinator?.arView, let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Check for new horizontal planes
        let hasNewHorizontalPlane = anchors.contains { anchor in
            if let planeAnchor = anchor as? ARPlaneAnchor {
                return planeAnchor.alignment == .horizontal
            }
            return false
        }

        if hasNewHorizontalPlane {
            Swift.print("🆕 New horizontal plane detected")
            // Note: regroundAllObjects() would be called here in the full implementation
        }

        // Process plane anchors
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor, planeAnchor.alignment == .horizontal {
                processHorizontalPlane(planeAnchor, cameraPos: cameraPos)
            }
        }
    }

    private func processHorizontalPlane(_ planeAnchor: ARPlaneAnchor, cameraPos: SIMD3<Float>) {
        let planeY = planeAnchor.transform.columns.3.y
        let planeHeight = planeAnchor.planeExtent.height
        let planeWidth = planeAnchor.planeExtent.width

        let isCeiling = planeY > cameraPos.y + 0.5
        let isTooLarge = planeHeight > 8.0 || planeWidth > 8.0
        let isTooSmall = planeHeight < 0.3 || planeWidth < 0.3

        if isCeiling || isTooLarge || isTooSmall {
            Swift.print("🗑️ Removing horizontal plane: ceiling=\(isCeiling), too_large=\(isTooLarge), too_small=\(isTooSmall)")
        } else {
            Swift.print("✅ Keeping horizontal plane: Y=\(String(format: "%.2f", planeY)), size=\(String(format: "%.2f", planeWidth))x\(String(format: "%.2f", planeHeight))")

            // DISABLED: Auto-randomization - only manual object placement allowed
            // Previously: Auto-randomize spheres if needed
            // if !(arCoordinator?.hasAutoRandomized ?? false) && arCoordinator?.placedBoxes.isEmpty ?? true {
            //     Swift.print("🎯 Auto-randomizing spheres on detected surface!")
            //     DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            //         self?.arCoordinator?.hasAutoRandomized = true
            //         // Note: randomizeLootBoxes() would be called here in the full implementation
            //     }
            // }
        }
    }

    private func handleAnchorsUpdated(_ anchors: [ARAnchor]) {
        // Handle anchor updates if needed
        // This is typically used for plane anchor geometry updates
    }

    private func handleAnchorsRemoved(_ anchors: [ARAnchor]) {
        // Handle anchor removal if needed
    }

    // MARK: - Session State Handling

    private func handleSessionFailure(_ error: Error) {
        Swift.print("❌ AR Session failed: \(error.localizedDescription)")

        // Reset AR origin on session failure
        arCoordinator?.arOriginLocation = nil
        arCoordinator?.arOriginSetTime = nil
        arCoordinator?.isDegradedMode = false
        arCoordinator?.arOriginGroundLevel = nil

        // Attempt to restart session if we have a saved configuration
        if let config = arCoordinator?.savedARConfiguration {
            Swift.print("🔄 Attempting to restart AR session...")
            arCoordinator?.arView?.session.run(config)
        }
    }

    private func handleSessionInterruption() {
        Swift.print("⏸️ AR Session interrupted")

        // Pause heavy processing during interruption
        // Note: Additional interruption handling would go here
    }

    private func handleSessionInterruptionEnded() {
        Swift.print("▶️ AR Session interruption ended")

        // Resume normal processing
        // Reset AR origin timestamp to allow re-establishing origin
        arCoordinator?.arOriginSetTime = nil

        // Note: Additional recovery logic would go here
    }
}
