import SwiftUI
import RealityKit
import ARKit

// MARK: - AR Environment Manager
/// Manages AR environment settings including ambient light
class AREnvironmentManager {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    
    // Maximum luminance value when ambient light is disabled (1.0 = full brightness)
    private let maxLuminance: Float = 1.0 // Maximum brightness for objects when ambient is disabled
    
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
        
        if disableAmbient {
            // When ambient light is disabled, set uniform luminance on all objects
            applyUniformLuminanceToScene()
        } else {
            // When ambient light is re-enabled, restore materials on all objects
            restoreMaterialsToScene()
        }
    }
    
    /// Applies uniform luminance to all entities in the scene
    private func applyUniformLuminanceToScene() {
        guard let arView = arView else { return }
        
        // Apply to all anchors in the scene
        for anchor in arView.scene.anchors {
            applyUniformLuminance(to: anchor)
        }
    }
    
    /// Restores materials to all entities in the scene (converts UnlitMaterial back to SimpleMaterial)
    private func restoreMaterialsToScene() {
        guard let arView = arView else { return }
        
        // Apply to all anchors in the scene
        for anchor in arView.scene.anchors {
            restoreMaterials(to: anchor)
        }
    }
    
    /// Recursively restores materials by removing emissive properties and restoring normal lighting
    private func restoreMaterials(to entity: Entity) {
        // Apply to this entity if it's a ModelEntity
        if let modelEntity = entity as? ModelEntity,
           var model = modelEntity.model {
            var updatedMaterials: [RealityKit.Material] = []

            for material in model.materials {
                // Use MaterialHelper to create non-emissive material
                let restoredMaterial = MaterialHelper.createNonEmissiveMaterial(from: material)
                updatedMaterials.append(restoredMaterial)
            }

            model.materials = updatedMaterials
            modelEntity.model = model
        }

        // Recursively apply to all children
        for child in entity.children {
            restoreMaterials(to: child)
        }
    }
    
    /// Recursively applies maximum luminance to an entity and all its children
    /// Uses emissive materials to make objects glow at maximum brightness regardless of ambient light sensor
    private func applyUniformLuminance(to entity: Entity) {
        // Apply to this entity if it's a ModelEntity
        if let modelEntity = entity as? ModelEntity,
           var model = modelEntity.model {
            var updatedMaterials: [RealityKit.Material] = []

            for material in model.materials {
                // Get the base color from the material
                let baseColor = MaterialHelper.getBaseColor(from: material)
                
                // Use MaterialHelper to create emissive material with maximum intensity
                let emissiveMaterial = MaterialHelper.createEmissiveMaterial(
                    from: material,
                    emissiveColor: baseColor,
                    emissiveIntensity: maxLuminance
                )
                updatedMaterials.append(emissiveMaterial)
            }

            model.materials = updatedMaterials
            modelEntity.model = model
        }

        // Recursively apply to all children
        for child in entity.children {
            applyUniformLuminance(to: child)
        }
    }
    
    /// Applies uniform luminance to a newly created entity (call this when placing new objects)
    func applyUniformLuminanceToNewEntity(_ entity: Entity) {
        guard let locationManager = locationManager,
              locationManager.disableAmbientLight else {
            return // Only apply if ambient light is disabled
        }
        
        applyUniformLuminance(to: entity)
    }
}

