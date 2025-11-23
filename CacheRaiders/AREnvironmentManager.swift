import SwiftUI
import RealityKit
import ARKit

// MARK: - AR Environment Manager
/// Manages AR environment settings including ambient light
class AREnvironmentManager {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    
    // Uniform luminance value when ambient light is disabled (0.0 to 1.0)
    private let uniformLuminance: Float = 0.4 // 40% brightness for objects when ambient is disabled
    
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
            Swift.print("🌑 Ambient light disabled - applying uniform luminance to all existing and new objects")
            applyUniformLuminanceToScene()
        } else {
            // When ambient light is re-enabled, restore materials on all objects
            Swift.print("☀️ Ambient light enabled - restoring materials on all existing objects")
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
    
    /// Recursively restores materials by converting UnlitMaterial back to SimpleMaterial
    private func restoreMaterials(to entity: Entity) {
        // Apply to this entity if it's a ModelEntity
        if let modelEntity = entity as? ModelEntity,
           var model = modelEntity.model {
            var updatedMaterials: [RealityKit.Material] = []

            for material in model.materials {
                if let unlitMaterial = material as? UnlitMaterial {
                    // Convert UnlitMaterial back to SimpleMaterial to restore lighting
                    var simpleMaterial = SimpleMaterial()
                    simpleMaterial.color = unlitMaterial.color
                    simpleMaterial.roughness = 0.4 // Default roughness
                    simpleMaterial.metallic = 0.3 // Default metallic
                    updatedMaterials.append(simpleMaterial)
                } else {
                    // Keep other material types as-is
                    updatedMaterials.append(material)
                }
            }

            model.materials = updatedMaterials
            modelEntity.model = model
        }

        // Recursively apply to all children
        for child in entity.children {
            restoreMaterials(to: child)
        }
    }
    
    /// Recursively applies uniform luminance to an entity and all its children
    private func applyUniformLuminance(to entity: Entity) {
        // Apply to this entity if it's a ModelEntity
        if let modelEntity = entity as? ModelEntity,
           var model = modelEntity.model {
            var updatedMaterials: [RealityKit.Material] = []

            for material in model.materials {
                if let simpleMaterial = material as? SimpleMaterial {
                    // Convert SimpleMaterial to UnlitMaterial to ignore all lighting
                    // This makes the material render at full brightness regardless of ambient light
                    var unlitMaterial = UnlitMaterial()
                    unlitMaterial.color = simpleMaterial.color
                    updatedMaterials.append(unlitMaterial)
                } else if let unlitMaterial = material as? UnlitMaterial {
                    // Already unlit, keep as-is
                    updatedMaterials.append(unlitMaterial)
                } else {
                    // For other material types, keep original
                    updatedMaterials.append(material)
                }
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

