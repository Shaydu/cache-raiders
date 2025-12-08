import RealityKit
import simd
import UIKit
import Foundation

// MARK: - Turkey Loot Container
/// A turkey-shaped container that holds loot inside
class TurkeyLootContainer {
    static func create(type: LootBoxType, id: String, sizeMultiplier: Float = 1.0) -> LootBoxContainer {
        let container = ModelEntity()
        container.name = id
        
        let finalSize = type.arSize * sizeMultiplier
        
        // Load the turkey model (returns entity and any built-in animations)
        let (turkey, builtInAnimation, isFallback) = loadTurkeyModel(size: finalSize, type: type, id: id)

        // Create prize that sits inside/on the turkey
        let prize = createPrize(type: type, size: finalSize)
        prize.position = SIMD3<Float>(0, finalSize * 0.3, 0) // Above the turkey
        prize.isEnabled = false // Hidden until opened
        
        // Add effects (but reduce/disable light if using fallback sphere to avoid hiding the model)
        if isFallback {
            // Fallback sphere - disable light completely so the sphere is visible, not just a light spot
            print("⚠️ Using fallback turkey model - light disabled to show geometry")
            // Don't add any light - just let the sphere be visible with its material
        } else {
            // Real model loaded - use full effects
            addEffects(to: turkey, type: type)
        }
        
        // Assemble (no lid for turkey - prize is revealed by glowing/rising)
        container.addChild(turkey)
        container.addChild(prize)
        
        // CRITICAL: Ensure all child entities have the ID name for tap detection
        turkey.name = id
        prize.name = id
        
        // CRITICAL: Ensure container and all children are enabled and visible
        container.isEnabled = true
        turkey.isEnabled = true
        
        // CRITICAL: Add collision component to container for tap detection
        // This ensures the tap handler can detect taps on the turkey
        let containerCollisionSize: Float = finalSize * 1.2 // Slightly larger for easier tapping
        container.collision = CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(containerCollisionSize, containerCollisionSize, containerCollisionSize))])
        
        // Create a dummy lid entity for compatibility with LootBoxContainer
        let dummyLid = ModelEntity()
        
        return LootBoxContainer(
            container: container,
            box: turkey,
            lid: dummyLid,
            prize: prize,
            builtInAnimation: builtInAnimation, // Store built-in animation if available
            open: { container, onComplete in
                MainActor.assumeIsolated {
                    LootBoxAnimation.openChalice(container: container, onComplete: onComplete)
                }
            }
        )
    }
    
    /// Loads the turkey USDZ model and returns the entity with any built-in animations
    /// Returns: (entity, animation, isFallback)
    private static func loadTurkeyModel(size: Float, type: LootBoxType, id: String) -> (entity: ModelEntity, animation: AnimationResource?, isFallback: Bool) {
        // Try models in order of preference (Dancing_Turkey has animation, so try it first)
        let modelNames = ["Dancing_Turkey", "Turkey_Rigged"]
        
        var modelURL: URL?
        var selectedModelName: String?
        
        // Try each model until we find one that exists
        for modelName in modelNames {
            if let url = Bundle.main.url(forResource: modelName, withExtension: "usdz") {
                modelURL = url
                selectedModelName = modelName
                break
            }
        }
        
        guard let modelURL = modelURL, let modelName = selectedModelName else {
            print("❌ TURKEY MODEL NOT FOUND IN BUNDLE")
            print("   Tried models: \(modelNames.joined(separator: ", "))")
            print("   This means the model file(s) exist in the project but are NOT included in the app target")
            print("   FIX: In Xcode -> Select Dancing_Turkey.usdz (or Turkey_Rigged.usdz) -> File Inspector -> Target Membership -> ✅ Check your app target")
            print("   Using fallback procedural model (brown sphere)")
            print("   ⚠️ The white point you see is the fallback sphere - fix the target membership to load the real model")
            return (createFallbackTurkey(size: size, color: type.color, glowColor: type.glowColor, id: id), nil, true)
        }
        
        print("✅ Found turkey model in bundle: \(modelName).usdz")
        
        let (entity, animation) = loadModelFromURL(modelURL, size: size, type: type, modelName: modelName, id: id)
        return (entity, animation, false) // false = not a fallback
    }
    
    /// Helper function to load a model from a URL
    private static func loadModelFromURL(_ modelURL: URL, size: Float, type: LootBoxType, modelName: String, id: String) -> (entity: ModelEntity, animation: AnimationResource?) {
        do {
            // Load the model entity
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)
            
            // CRITICAL FIX: Always wrap the loaded entity to preserve its coordinate system
            // USDZ files often have their own scene hierarchy and positioning
            // Use ModelEntity for wrapper to match LootBoxContainer.box type requirement
            let wrapperEntity = ModelEntity()
            wrapperEntity.name = id // Set name on wrapper for tap detection
            wrapperEntity.isEnabled = true // Ensure wrapper is enabled
            
            // Find the actual model entity within the loaded hierarchy for animation detection
            // This must be done BEFORE wrapping, as we need to check animations on the actual model
            let modelEntity: ModelEntity
            if let model = findFirstModelEntity(in: loadedEntity) {
                modelEntity = model
            } else {
                // Use the loaded entity directly - it's guaranteed to be a ModelEntity
                modelEntity = loadedEntity as ModelEntity
            }
            
            // CRITICAL: Ensure the loaded entity and all its children are enabled and visible
            modelEntity.isEnabled = true
            // Recursively enable all children
            func enableAllChildren(_ entity: Entity) {
                entity.isEnabled = true
                for child in entity.children {
                    enableAllChildren(child)
                }
            }
            enableAllChildren(loadedEntity)
            
            // Add the loaded entity as a child to preserve its relative positioning
            wrapperEntity.addChild(loadedEntity)
            
            // Check for built-in animations BEFORE wrapping
            // Rigged models often have animations that should loop continuously
            var builtInAnimation: AnimationResource? = nil
            let availableAnimations = modelEntity.availableAnimations
            if !availableAnimations.isEmpty {
                // Use the first available animation (typically the main animation)
                builtInAnimation = availableAnimations[0]
                print("✅ Found \(availableAnimations.count) built-in animation(s) in turkey model \(modelName) - will loop continuously")
            } else {
                print("ℹ️ No built-in animations found in turkey model \(modelName)")
            }
            
            // Scale the wrapper to match desired size
            // For USDZ models, scale to match the desired size
            // Turkey models may be large, so apply a scale multiplier similar to chests
            // Use a reasonable scale factor to ensure the turkey is visible
            // Increased scale to make turkey more visible (was 0.5, now 1.0 to match size parameter)
            let turkeyScale: Float = 1.0  // Scale multiplier for turkey models
            let finalScale = size * turkeyScale
            wrapperEntity.scale = SIMD3<Float>(repeating: finalScale)
            
            print("📏 Turkey scale: baseSize=\(size)m, scaleFactor=\(turkeyScale), finalScale=\(finalScale)m")
            
            // CRITICAL: Add collision component for tap detection
            // The wrapper entity needs collision so arView.entity(at:) can detect taps
            // Use a box collision that approximates the turkey's size
            let collisionSize: Float = size * 1.2 // Slightly larger than model for easier tapping
            wrapperEntity.collision = CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(collisionSize, collisionSize, collisionSize))])
            
            // Ensure wrapper is right-side up (not upside down)
            wrapperEntity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            
            // CRITICAL: Preserve original textures and colors
            // Only enhance lighting properties, don't override textures
            // The model should have its own textures baked in
            applyMaterials(to: loadedEntity, color: type.color, glowColor: type.glowColor)
            
            // CRITICAL: Verify the model entity has a visual representation
            if let modelEntity = findFirstModelEntity(in: loadedEntity) {
                if modelEntity.model == nil {
                    print("⚠️ WARNING: Model entity has no model component - may not be visible!")
                } else {
                    print("✅ Model entity has model component - should be visible")
                }
            }
            
            print("✅ Loaded turkey model: \(modelName) (wrapped to preserve coordinates)")
            print("   Wrapper scale: \(finalScale)")
            print("   Wrapper isEnabled: \(wrapperEntity.isEnabled)")
            print("   Wrapper has \(wrapperEntity.children.count) children")
            print("   Loaded entity type: \(Swift.type(of: loadedEntity))")
            let loadedModelEntity = loadedEntity as ModelEntity
            print("   Loaded entity isEnabled: \(loadedModelEntity.isEnabled)")
            print("   Loaded entity has model: \(loadedModelEntity.model != nil)")
            
            // CRITICAL DEBUG: Print the entire hierarchy
            func printHierarchy(_ entity: Entity, indent: String = "") {
                print("\(indent)\(Swift.type(of: entity)): name=\(entity.name), isEnabled=\(entity.isEnabled)")
                if let modelEntity = entity as? ModelEntity {
                    print("\(indent)  hasModel=\(modelEntity.model != nil)")
                }
                for child in entity.children {
                    printHierarchy(child, indent: indent + "  ")
                }
            }
            print("📦 Turkey entity hierarchy:")
            printHierarchy(wrapperEntity)
            
            return (wrapperEntity, builtInAnimation)
        } catch {
            print("❌ ERROR LOADING TURKEY MODEL: \(error)")
            print("   Model file: \(modelName).usdz")
            print("   Error details: \(error.localizedDescription)")
            print("   This could mean:")
            print("   1. The USDZ file is corrupted or invalid")
            print("   2. The file format is not compatible")
            print("   3. The file is too large or has unsupported features")
            print("   Using fallback procedural model (sphere)")
            print("   ⚠️ The white point you see is the fallback sphere - the model file may be invalid")
            // Return fallback entity - the caller will handle isFallback flag
            return (createFallbackTurkey(size: size, color: type.color, glowColor: type.glowColor, id: id), nil)
        }
    }
    
    /// Finds the first ModelEntity in a hierarchy
    private static func findFirstModelEntity(in entity: Entity) -> ModelEntity? {
        if let modelEntity = entity as? ModelEntity {
            return modelEntity
        }
        
        for child in entity.children {
            if let found = findFirstModelEntity(in: child) {
                return found
            }
        }
        
        return nil
    }
    
    /// Applies materials to the model entities while preserving original textures and colors
    /// This preserves the original appearance of USDZ models while enhancing lighting properties
    private static func applyMaterials(to entity: Entity, color: UIColor, glowColor: UIColor) {
        if let modelEntity = entity as? ModelEntity, var model = modelEntity.model {
            // Preserve original materials but enhance lighting properties
            var materials: [Material] = []
            for material in model.materials {
                // Check if material has textures - if so, preserve completely
                var hasTexture = false
                
                if let simpleMaterial = material as? SimpleMaterial {
                    hasTexture = simpleMaterial.color.texture != nil
                } else if let pbr = material as? PhysicallyBasedMaterial {
                    hasTexture = pbr.baseColor.texture != nil || 
                                pbr.normal.texture != nil || 
                                pbr.roughness.texture != nil ||
                                pbr.metallic.texture != nil
                }
                
                if hasTexture {
                    // Material has textures - preserve it completely
                    print("✅ Preserving textured material for turkey (has textures)")
                    materials.append(material)
                } else {
                    // No textures - can safely enhance with lighting properties
                    if var simpleMaterial = material as? SimpleMaterial {
                        // Only apply subtle tint, preserve original color
                        // Don't override completely - just enhance
                        simpleMaterial.roughness = 0.4
                        simpleMaterial.metallic = 0.3
                        materials.append(simpleMaterial)
                    } else if var pbr = material as? PhysicallyBasedMaterial {
                        pbr.roughness = .init(floatLiteral: 0.4)
                        pbr.metallic = .init(floatLiteral: 0.3)
                        materials.append(pbr)
                    } else {
                        materials.append(material)
                    }
                }
            }
            model.materials = materials
            modelEntity.model = model
        }
        
        // Recursively apply to children
        for child in entity.children {
            applyMaterials(to: child, color: color, glowColor: glowColor)
        }
    }
    
    /// Fallback: creates a procedural turkey if model can't be loaded
    private static func createFallbackTurkey(size: Float, color: UIColor, glowColor: UIColor, id: String) -> ModelEntity {
        // Create a visible sphere as fallback (make sure it's large enough to see)
        // Use a minimum radius to ensure visibility - make it clearly visible
        // IMPORTANT: Make fallback sphere large enough to be clearly visible, not just a white point
        let minRadius: Float = 0.25 // At least 25cm radius (larger so it's clearly visible as a sphere)
        let radius = max(size * 0.5, minRadius)
        let turkeyMesh = MeshResource.generateSphere(radius: radius)
        var turkeyMaterial = SimpleMaterial()
        turkeyMaterial.color = .init(tint: color)
        turkeyMaterial.roughness = 0.4
        turkeyMaterial.metallic = 0.3
        
        let turkeyEntity = ModelEntity(mesh: turkeyMesh, materials: [turkeyMaterial])
        turkeyEntity.name = id
        
        // IMPORTANT: No light effects added here - caller will handle effects based on isFallback flag
        // The fallback should be clearly visible, not just a light spot
        print("⚠️ WARNING: Using fallback turkey model (sphere, radius: \(radius)m) - USDZ model not found or failed to load")
        print("   To fix: Add Turkey_Rigged.usdz to Xcode project and ensure it's in the app target")
        print("   Fallback sphere should be visible as a colored sphere, not just a white point")
        
        return turkeyEntity
    }
    
    private static func createPrize(type: LootBoxType, size: Float) -> ModelEntity {
        let prizeSize = size * 0.25
        let prizeMesh = MeshResource.generateSphere(radius: prizeSize)
        
        var prizeMaterial = SimpleMaterial()
        prizeMaterial.color = .init(tint: type.color)
        prizeMaterial.roughness = 0.1
        prizeMaterial.metallic = 0.9
        
        let prizeEntity = ModelEntity(mesh: prizeMesh, materials: [prizeMaterial])
        
        // Add glow effect
        let light = PointLightComponent(color: type.glowColor, intensity: 300)
        prizeEntity.components.set(light)
        
        return prizeEntity
    }
    
    private static func addEffects(to entity: ModelEntity, type: LootBoxType) {
        // Add point light for dramatic glow
        let light = PointLightComponent(color: type.glowColor, intensity: 400)
        entity.components.set(light)
    }
}

