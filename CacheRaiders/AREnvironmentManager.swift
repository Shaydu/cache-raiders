import SwiftUI
import RealityKit
import ARKit

// MARK: - AR Environment Manager
/// Manages AR environment settings including ambient light
class AREnvironmentManager {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    
    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        self.arView = arView
        self.locationManager = locationManager
    }
    
    /// Update scene ambient lighting based on settings
    func updateAmbientLight() {
        guard let arView = arView else { return }
        
        let disableAmbient = locationManager?.disableAmbientLight ?? false
        
        // Reconfigure AR session to enable/disable environment texturing
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = disableAmbient ? .none : .automatic
        
        arView.session.run(config, options: [])
        Swift.print(disableAmbient ? "🌑 Ambient light disabled - environment texturing set to .none" : "☀️ Ambient light enabled - using automatic environment texturing")
    }
}

