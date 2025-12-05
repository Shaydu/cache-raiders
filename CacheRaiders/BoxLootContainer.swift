import RealityKit
import simd
import UIKit
import Foundation

// MARK: - Box Loot Container
/// A box-shaped container with a door that opens to reveal loot
class BoxLootContainer {
    static func create(type: LootBoxType, id: String, sizeMultiplier: Float = 1.0) -> LootBoxContainer {
        let container = ModelEntity()
        container.name = id
        
        let baseSize = type.size * sizeMultiplier
        
        // Load the treasure chest model
        let (box, lid, builtInAnimation) = loadTreasureChestModel(size: baseSize, type: type, id: id)
        
        // Create prize that sits inside the box
        let prize = createPrize(type: type, size: baseSize)
        prize.position = SIMD3<Float>(0, 0, 0) // Center of box
        prize.isEnabled = false // Hidden until opened
        
        // Add effects
        addEffects(to: box, type: type)
        
        // Assemble
        container.addChild(box)
        if let lid = lid {
            container.addChild(lid)
        }
        container.addChild(prize)
        
        // CRITICAL: Ensure all child entities have the ID name for tap detection
        // This ensures tap detection works even if tapping on a child entity
        box.name = id
        prize.name = id
        if let lid = lid {
            lid.name = id
        }
        
        // Create a dummy lid if model doesn't have one
        let doorLid = lid ?? ModelEntity()

        // CRITICAL: Add collision component to container for tap detection
        // The container entity needs collision so arView.entity(at:) can detect taps
        let collisionSize: Float = baseSize * 1.2 // Slightly larger than model for easier tapping
        container.collision = CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(collisionSize, collisionSize, collisionSize))])

        return LootBoxContainer(
            container: container,
            box: box,
            lid: doorLid, // Lid/door from model or dummy
            prize: prize,
            builtInAnimation: builtInAnimation, // Store built-in animation if available
            open: { container, onComplete in
                MainActor.assumeIsolated {
                    LootBoxAnimation.openBox(container: container, onComplete: onComplete)
                }
            }
        )
    }
    
    /// Loads a treasure chest USDZ model (randomly chooses between available models)
    /// Note: Make sure "Stylised_Treasure_Chest.usdz" and "Treasure_Chest.usdz" are added to the Xcode project and included in the app bundle
    private static func loadTreasureChestModel(size: Float, type: LootBoxType, id: String) -> (box: ModelEntity, lid: ModelEntity?, animation: AnimationResource?) {
        // Use factory to get model names (eliminates switch statement)
        let factory = type.factory
        let availableModels = factory.modelNames
        
        guard !availableModels.isEmpty else {
            print("⚠️ No models available for type \(type.displayName)")
            return (createFallbackBox(size: size, color: factory.color, glowColor: factory.glowColor, id: id), createDoor(size: size, color: factory.color, glowColor: factory.glowColor), nil)
        }
        
        // For treasureChest type, always use first model (Treasure_Chest)
        // For lootChest type, use Stylized_Container
        // For other types, randomly choose between available models
        let selectedModel: String
        if type == .treasureChest {
            selectedModel = availableModels[0]
        } else if type == .lootChest {
            selectedModel = "Stylized_Container"
        } else {
            selectedModel = availableModels.randomElement() ?? availableModels[0]
        }
        
        // Try to load the selected model
        guard let modelURL = Bundle.main.url(forResource: selectedModel, withExtension: "usdz") else {
            // Try the other model if first one fails
            let fallbackModel = selectedModel == "Stylised_Treasure_Chest" ? "Treasure_Chest" : "Stylised_Treasure_Chest"
            guard let fallbackURL = Bundle.main.url(forResource: fallbackModel, withExtension: "usdz") else {
                print("⚠️ Could not find any treasure chest model in bundle")
                print("   Make sure Stylised_Treasure_Chest.usdz and/or Treasure_Chest.usdz are added to the Xcode project")
                print("   Using fallback procedural box")
                return (createFallbackBox(size: size, color: type.color, glowColor: type.glowColor, id: id), createDoor(size: size, color: type.color, glowColor: type.glowColor), nil)
            }
            
            return loadChestModelFromURL(fallbackURL, size: size, type: type, modelName: fallbackModel, id: id)
        }
        
        return loadChestModelFromURL(modelURL, size: size, type: type, modelName: selectedModel, id: id)
    }
    
    /// Helper function to load a chest model from a URL
    private static func loadChestModelFromURL(_ modelURL: URL, size: Float, type: LootBoxType, modelName: String, id: String) -> (box: ModelEntity, lid: ModelEntity?, animation: AnimationResource?) {
        do {
            // Load the model entity - Entity.loadModel returns a ModelEntity
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)
            
            // CRITICAL FIX: Always wrap the loaded entity to preserve its coordinate system
            // USDZ files often have their own scene hierarchy and positioning
            // This ensures scaling works correctly and the model doesn't appear enormous
            let wrapperEntity = ModelEntity()
            wrapperEntity.name = id // Set name on wrapper for tap detection
            
            // Add the loaded entity as a child to preserve its relative positioning
            wrapperEntity.addChild(loadedEntity)
            
            // Scale the wrapper to match desired size
            // For treasure chests, the USDZ model is typically much larger than expected
            // Apply appropriate scale to achieve 2-3 feet (0.61-0.91m) final size
            let baseScale: Float = 1.0  // Base scale for other object types
            
            // Treasure chests and loot chests need scale reduction to achieve proper size
            // The 0.4x multiplier compensates for USDZ models being larger than expected
            let chestScale: Float = (type == .treasureChest || type == .lootChest) ? 0.4 : baseScale
            
            // Scale the wrapper (not the child) so all children scale uniformly
            wrapperEntity.scale = SIMD3<Float>(repeating: size * chestScale)
            
            Swift.print("📦 Scaled \(type.displayName) model to size: \(String(format: "%.3f", size))m (scale factor: \(String(format: "%.6f", size * chestScale)))")
            
            // Ensure wrapper is right-side up (not upside down)
            wrapperEntity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            
            // Find the actual model entity within the loaded hierarchy for lid extraction
            let modelEntity: ModelEntity
            if let model = findFirstModelEntity(in: loadedEntity) {
                // Use the first found ModelEntity with a mesh (the actual 3D model)
                modelEntity = model
            } else {
                // If no child ModelEntity found, use the loaded entity directly
                modelEntity = loadedEntity as ModelEntity
            }
            
            // Try to find the lid in the model hierarchy
            // Common names for lids: "lid", "Lid", "top", "Top", "door", "Door", "chest_lid", etc.
            var lidEntity: ModelEntity? = nil
            lidEntity = findEntity(named: "lid", in: modelEntity) ??
                       findEntity(named: "Lid", in: modelEntity) ??
                       findEntity(named: "top", in: modelEntity) ??
                       findEntity(named: "Top", in: modelEntity) ??
                       findEntity(named: "door", in: modelEntity) ??
                       findEntity(named: "Door", in: modelEntity) ??
                       findEntity(named: "chest_lid", in: modelEntity) ??
                       findEntity(named: "Chest_Lid", in: modelEntity)
            
            // Check for built-in animations BEFORE extracting lid (animations might be on the whole model)
            var builtInAnimation: AnimationResource? = nil
            let availableAnimations = modelEntity.availableAnimations
            if !availableAnimations.isEmpty {
                // Use the first available animation (typically the opening animation)
                builtInAnimation = availableAnimations[0]
                print("✅ Found \(availableAnimations.count) built-in animation(s) in model \(modelName) - will use for opening")
            }
            
            // If lid found, remove it from parent so we can animate it separately
            if let lid = lidEntity {
                lid.removeFromParent()
                print("✅ Found and extracted lid from treasure chest model: \(modelName)")
            } else {
                print("ℹ️ No lid found in model \(modelName) - chest may open differently or lid is part of main mesh")
            }
            
            // Apply materials while preserving original textures and colors
            applyMaterials(to: wrapperEntity, color: type.color, glowColor: type.glowColor)
            
            // CRITICAL: Name is already set on wrapperEntity above for tap detection
            // The tap handler walks up the hierarchy, so it will find the wrapper with matching ID
            
            // Store animation in a custom component or return it separately
            // For now, we'll need to modify the return type to include the animation
            // But since we can't change the return type easily, let's store it in the model entity
            // We'll access it later through the container
            return (wrapperEntity, lidEntity, builtInAnimation)
        } catch {
            print("❌ Error loading treasure chest model \(modelName): \(error)")
            print("   Using fallback procedural box")
            return (createFallbackBox(size: size, color: type.color, glowColor: type.glowColor, id: id), createDoor(size: size, color: type.color, glowColor: type.glowColor), nil)
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
    
    /// Recursively searches for an entity with a specific name
    private static func findEntity(named name: String, in entity: Entity) -> ModelEntity? {
        if let modelEntity = entity as? ModelEntity, modelEntity.name == name {
            return modelEntity
        }
        
        for child in entity.children {
            if let found = findEntity(named: name, in: child) {
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
                    // Material has textures - preserve it completely to maintain original appearance
                    materials.append(material)
                } else {
                    // No textures - can enhance with lighting properties
                    // Only apply subtle enhancements, don't override colors completely
                    if var simpleMaterial = material as? SimpleMaterial {
                        // Enhance lighting properties without overriding original color
                        simpleMaterial.roughness = 0.4 // Moderate roughness for realistic shading
                        simpleMaterial.metallic = 0.3 // Slight metallic sheen
                        materials.append(simpleMaterial)
                    } else if var pbr = material as? PhysicallyBasedMaterial {
                        // Enhance PBR lighting properties
                        pbr.roughness = .init(floatLiteral: 0.4)
                        pbr.metallic = .init(floatLiteral: 0.3)
                        materials.append(pbr)
                    } else {
                        // For other materials, preserve them completely
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
    
    /// Fallback: creates a procedural box if model can't be loaded
    private static func createFallbackBox(size: Float, color: UIColor, glowColor: UIColor, id: String) -> ModelEntity {
        let box = createBox(size: size, color: color, glowColor: glowColor)
        box.name = id // Set name for tap detection
        return box
    }
    
    private static func createBox(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Main box body
        let boxMesh = MeshResource.generateBox(
            width: size * 0.6,
            height: size * 0.6,
            depth: size * 0.6,
            cornerRadius: size * 0.05
        )
        
        var boxMaterial = SimpleMaterial()
        boxMaterial.color = .init(tint: color)
        boxMaterial.roughness = 0.4
        boxMaterial.metallic = 0.3
        
        let boxEntity = ModelEntity(mesh: boxMesh, materials: [boxMaterial])
        
        // Add decorative corners
        let cornerSize = size * 0.08
        let cornerPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.3, size * 0.3, size * 0.3),   // Top front right
            SIMD3<Float>(-size * 0.3, size * 0.3, size * 0.3),  // Top front left
            SIMD3<Float>(size * 0.3, -size * 0.3, size * 0.3),  // Bottom front right
            SIMD3<Float>(-size * 0.3, -size * 0.3, size * 0.3), // Bottom front left
            SIMD3<Float>(size * 0.3, size * 0.3, -size * 0.3),  // Top back right
            SIMD3<Float>(-size * 0.3, size * 0.3, -size * 0.3),  // Top back left
            SIMD3<Float>(size * 0.3, -size * 0.3, -size * 0.3), // Bottom back right
            SIMD3<Float>(-size * 0.3, -size * 0.3, -size * 0.3)  // Bottom back left
        ]
        
        for position in cornerPositions {
            let corner = createCorner(size: cornerSize, glowColor: glowColor)
            corner.position = position
            boxEntity.addChild(corner)
        }
        
        // Add glowing seams/cracks
        addGlowingSeams(to: boxEntity, size: size, glowColor: glowColor)
        
        return boxEntity
    }
    
    private static func createDoor(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Door panel (slightly inset from box edge)
        let doorMesh = MeshResource.generateBox(
            width: size * 0.55,
            height: size * 0.55,
            depth: size * 0.05,
            cornerRadius: size * 0.03
        )
        
        var doorMaterial = SimpleMaterial()
        doorMaterial.color = .init(tint: color)
        doorMaterial.roughness = 0.4
        doorMaterial.metallic = 0.3
        
        let doorEntity = ModelEntity(mesh: doorMesh, materials: [doorMaterial])
        
        // Add door handle
        let handleMesh = MeshResource.generateSphere(radius: size * 0.03)
        var handleMaterial = SimpleMaterial()
        handleMaterial.color = .init(tint: glowColor)
        handleMaterial.roughness = 0.0
        handleMaterial.metallic = 1.0
        
        let handleEntity = ModelEntity(mesh: handleMesh, materials: [handleMaterial])
        handleEntity.position = SIMD3<Float>(size * 0.2, 0, size * 0.03)
        doorEntity.addChild(handleEntity)
        
        // Add decorative lock/keyhole
        let lockMesh = MeshResource.generateBox(
            width: size * 0.08,
            height: size * 0.12,
            depth: size * 0.02,
            cornerRadius: size * 0.01
        )
        let lockEntity = ModelEntity(mesh: lockMesh, materials: [handleMaterial])
        lockEntity.position = SIMD3<Float>(-size * 0.15, 0, size * 0.03)
        doorEntity.addChild(lockEntity)
        
        // Add glowing runes/symbols on door
        for i in 0..<4 {
            let angle = Float(i) * (Float.pi * 2 / 4)
            let rune = createRune(size: size, glowColor: glowColor)
            rune.position = SIMD3<Float>(
                cos(angle) * size * 0.15,
                sin(angle) * size * 0.15,
                size * 0.03
            )
            doorEntity.addChild(rune)
        }
        
        return doorEntity
    }
    
    private static func createCorner(size: Float, glowColor: UIColor) -> ModelEntity {
        let cornerMesh = MeshResource.generateBox(size: size)
        var cornerMaterial = SimpleMaterial()
        cornerMaterial.color = .init(tint: glowColor)
        cornerMaterial.roughness = 0.2
        cornerMaterial.metallic = 0.8
        
        return ModelEntity(mesh: cornerMesh, materials: [cornerMaterial])
    }
    
    private static func createRune(size: Float, glowColor: UIColor) -> ModelEntity {
        let runeMesh = MeshResource.generateBox(
            width: size * 0.04,
            height: size * 0.06,
            depth: size * 0.01,
            cornerRadius: size * 0.01
        )
        var runeMaterial = SimpleMaterial()
        runeMaterial.color = .init(tint: glowColor)
        runeMaterial.roughness = 0.0
        
        let runeEntity = ModelEntity(mesh: runeMesh, materials: [runeMaterial])
        
        // Add point light for glow
        let light = PointLightComponent(color: glowColor, intensity: 50)
        runeEntity.components.set(light)
        
        return runeEntity
    }
    
    private static func addGlowingSeams(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // Add glowing seams where light escapes
        let seamPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.3, 0, size * 0.3),   // Right side
            SIMD3<Float>(-size * 0.3, 0, size * 0.3), // Left side
            SIMD3<Float>(0, size * 0.3, size * 0.3),   // Top
            SIMD3<Float>(0, -size * 0.3, size * 0.3)   // Bottom
        ]
        
        for position in seamPositions {
            let seam = MeshResource.generateBox(
                width: size * 0.02,
                height: size * 0.4,
                depth: size * 0.01
            )
            var seamMaterial = SimpleMaterial()
            seamMaterial.color = .init(tint: glowColor)
            seamMaterial.roughness = 0.0
            
            let seamEntity = ModelEntity(mesh: seam, materials: [seamMaterial])
            seamEntity.position = position
            entity.addChild(seamEntity)
        }
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
        
        // DISABLED: Floating animation causes objects to float above ground
        // addFloatingAnimation(to: entity)
    }
    
    private static func addFloatingAnimation(to entity: ModelEntity) {
        let baseY = entity.position.y
        var offset: Float = 0
        
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak entity] timer in
            guard let entity = entity, entity.parent != nil else {
                timer.invalidate()
                return
            }
            
            offset += 0.03
            entity.position.y = baseY + sin(offset) * 0.05
        }
    }
}

