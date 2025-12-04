import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - Environment Service
class AREnvironmentService: NSObject, AREnvironmentServiceProtocol {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private weak var coordinatorCore: ARCoordinatorCore?
    private weak var objectPlacementService: ARObjectPlacementServiceProtocol?

    // Thread safety for service references
    private let serviceAccessQueue = DispatchQueue(label: "com.cacheraiders.environment.serviceAccess", attributes: .concurrent)

    // Thread-safe access to object placement service
    private func getObjectPlacementService() -> ARObjectPlacementServiceProtocol? {
        var service: ARObjectPlacementServiceProtocol?
        serviceAccessQueue.sync {
            service = self.objectPlacementService
        }
        return service
    }

    // Environment settings
    private var ambientLightEnabled: Bool = true
    private var occlusionEnabled: Bool = true
    private var sceneReconstructionEnabled: Bool = true
    
    // Throttling for placement checks
    private var lastPlacementCheckTime: Date = Date.distantPast
    private var arOriginSetTime: Date?  // Track when we started waiting for GPS
    
    func setup(locationManager: LootBoxLocationManager, arView: ARView) {
        self.locationManager = locationManager
        self.arView = arView
    }
    
    // Environment configuration methods will be moved here from ARCoordinator
    func configureARSession() -> ARWorldTrackingConfiguration {
        // Implementation to be moved from ARCoordinator
        let config = ARWorldTrackingConfiguration()
        return config
    }
    
    func updateAmbientLight() {
        // Implementation to be moved from ARCoordinator
    }
    
    func updateSceneReconstruction() {
        // Implementation to be moved from ARCoordinator
    }
    
    func applyLensConfiguration(selectedLensId: String?) -> ARWorldTrackingConfiguration {
        // Implementation to be moved from ARCoordinator
        let config = ARWorldTrackingConfiguration()
        return config
    }
    
    // Utility methods for environment management
    func supportsSceneReconstruction() -> Bool {
        // Implementation to be moved from ARCoordinator
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
    
    func resetARSession(options: ARSession.RunOptions = []) {
        // Implementation to be moved from ARCoordinator
    }

    // MARK: - AREnvironmentServiceProtocol Methods
    
    func configureEnvironment() {
        // Implementation moved from ARCoordinator
        if let arView = arView {
            let config = configureARSession()
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            updateAmbientLight()
            updateOcclusion()
            updateSceneReconstruction()
        }
    }
    
    func updateOcclusion() {
        // Implementation moved from ARCoordinator
        if occlusionEnabled {
            arView?.environment.sceneUnderstanding.options.insert([.occlusion, .collision])
        } else {
            arView?.environment.sceneUnderstanding.options.remove([.occlusion, .collision])
        }
    }
    
    func recognizeObjects(in frame: ARFrame) {
        // Implementation to be added from ARCoordinator
        // Object recognition logic goes here
    }
    
    func setAROriginGroundLevel(_ groundLevel: Float) {
        // Implementation to be added - this method sets the AR origin ground level
        // This can be used for environment configuration based on ground level
    }
    
    // MARK: - ARSessionService Methods
    
    private var environmentFrameCount = 0
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Log first frame to confirm environment service is receiving updates
        environmentFrameCount += 1
        if environmentFrameCount == 1 {
            print("🌍 [AREnvironmentService] First frame update received - environment service active!")
        }

        // CRITICAL: Set up GPS origin if not already set
        setupGPSOriginIfNeeded(frame)

        // Check and place nearby objects every 3 seconds using throttling
        checkAndPlaceNearbyObjectsWithThrottling(frame)

        // Update occlusion and object recognition
        updateOcclusion()
        recognizeObjects(in: frame)
    }

    private var gpsOriginCheckCount = 0
    private func setupGPSOriginIfNeeded(_ frame: ARFrame) {
        guard let coordinator = coordinatorCore,
              let userLocationManager = coordinator.userLocationManager,
              let userLocation = userLocationManager.currentLocation,
              let geospatialService = coordinator.geospatialService else {
            gpsOriginCheckCount += 1
            if gpsOriginCheckCount == 1 {
                print("⚠️ [AREnvironmentService] GPS origin check failed - missing dependencies")
            }
            return
        }

        // Only set origin if not already set and GPS accuracy is good
        if coordinator.arOriginLocation == nil && userLocation.horizontalAccuracy > 0 && userLocation.horizontalAccuracy < 50 {
            // Set ENU origin from GPS location
            if geospatialService.setENUOrigin(from: userLocation) {
                // Save AR origin location to coordinator
                coordinator.arOriginLocation = userLocation

                Swift.print("✅ GPS Origin SET at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
                Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
            }
        }
    }

    private var placementCheckCount = 0
    private func checkAndPlaceNearbyObjects(_ frame: ARFrame) {
        guard let coordinator = coordinatorCore,
              let userLocationManager = coordinator.userLocationManager,
              let userLocation = userLocationManager.currentLocation,
              let locationManager = coordinator.locationManager,
              coordinator.arOriginLocation != nil,
              let objectPlacementService = getObjectPlacementService() else {
            placementCheckCount += 1
            if placementCheckCount == 1 {
                print("⏳ [AREnvironmentService] Object placement check waiting for GPS origin...")
            }
            return
        }

        // Log first successful placement check
        placementCheckCount += 1
        if placementCheckCount == 1 {
            print("🎯 [AREnvironmentService] First placement check - GPS origin ready, checking for nearby objects...")
        }

        // Get nearby locations
        let nearbyLocations = locationManager.getNearbyLocations(userLocation: userLocation)

        if placementCheckCount == 1 && !nearbyLocations.isEmpty {
            print("📍 [AREnvironmentService] Found \(nearbyLocations.count) nearby objects to place in AR")
        }

        // Call checkAndPlaceBoxes on the object placement service
        objectPlacementService.checkAndPlaceBoxes(
            userLocation: userLocation,
            nearbyLocations: nearbyLocations
        )
    }
    
    private func checkAndPlaceNearbyObjectsWithThrottling(_ frame: ARFrame) {
        // Throttle placement checks to every 3 seconds
        let currentTime = Date()
        let timeSinceLastCheck = currentTime.timeIntervalSince(lastPlacementCheckTime)
        
        if timeSinceLastCheck >= 3.0 {
            lastPlacementCheckTime = currentTime
            checkAndPlaceNearbyObjects(frame)
        }
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Implementation moved from ARCoordinator
        // Handle AR anchor additions
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Implementation moved from ARCoordinator
        // Handle AR anchor updates
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Implementation moved from ARCoordinator
        // Handle AR anchor removals
    }
    
    // MARK: - ARServiceProtocol Methods
    
    func configure(with coordinator: ARCoordinatorCoreProtocol) {
        // Store coordinator as ARCoordinatorCore type for full access
        if let core = coordinator as? ARCoordinatorCore {
            self.coordinatorCore = core
        }

        // Store reference to object placement service (thread-safe)
        serviceAccessQueue.async(flags: .barrier) {
            self.objectPlacementService = coordinator.services.objectPlacement
        }

        if let locationManager = coordinator.locationManager {
            setup(locationManager: locationManager, arView: coordinator.arView!)
        }
    }
    
    func cleanup() {
        arView = nil
        locationManager = nil
    }
}
