import SwiftUI
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Coordinator
class ARCoordinator: NSObject, ARSessionDelegate {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var placedBoxes: [String: AnchorEntity] = [:]
    
    func setupARView(_ arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearbyLocations: Binding<[LootBoxLocation]>) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.nearbyLocationsBinding = nearbyLocations
        
        // Monitor AR session
        arView.session.delegate = self
    }
    
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        guard let arView = arView, let locationManager = locationManager else { return }
        
        for location in nearbyLocations {
            // Check if user is at this location and box hasn't been placed
            if locationManager.isAtLocation(location, userLocation: userLocation) &&
               placedBoxes[location.id] == nil &&
               !location.collected {
                placeLootBoxAtLocation(location, in: arView)
            }
        }
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Check for nearby locations when AR is tracking
        if frame.camera.trackingState == .normal,
           let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("❌ AR Session failed: \(error.localizedDescription)")
        // Try to restart the session
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
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
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking])
        }
    }
    
    // MARK: - Loot Box Placement
    private func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // Place box in front of camera when at location
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        let up = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
        
        let boxPosition = cameraPos + forward * 1.5 - up * 0.2
        
        var boxTransform = matrix_identity_float4x4
        boxTransform.columns.3 = SIMD4<Float>(boxPosition.x, boxPosition.y, boxPosition.z, 1.0)
        
        let anchor = AnchorEntity(world: boxTransform)
        let box = LootBoxEntity.createLootBox(type: location.type, id: location.id)
        
        anchor.addChild(box)
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        
        print("✅ Placed \(location.name) at location: \(location.latitude), \(location.longitude)")
    }
    
    // MARK: - Tap Handling
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        guard let arView = arView else { return }
        let tapLocation = sender.location(in: arView)
        
        // Check if tapped on existing loot box
        if let entity = arView.entity(at: tapLocation) {
            let idString = entity.name
            
            // Try to find in location manager first
            if let locationManager = locationManager,
               let location = locationManager.locations.first(where: { $0.id == idString }) {
                locationManager.markCollected(idString)
                
                // Remove the anchor
                if let anchor = placedBoxes[idString] {
                    anchor.removeFromParent()
                    placedBoxes.removeValue(forKey: idString)
                }
                
                print("🎉 Collected: \(location.name)")
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

