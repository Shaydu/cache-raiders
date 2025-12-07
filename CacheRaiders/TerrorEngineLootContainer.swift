import RealityKit
import simd
import UIKit
import Foundation

// MARK: - Terror Engine Loot Container
/// A terror engine container that checks for and uses built-in USDZ animations
class TerrorEngineLootContainer {
    static func create(type: LootBoxType, id: String, sizeMultiplier: Float = 1.0) -> LootBoxContainer {
        let container = ModelEntity()
        container.name = id

        let baseSize = type.size * sizeMultiplier

        // Load the terror engine model
        let (engine, builtInAnimation) = loadTerrorEngineModel(size: baseSize, type: type)

        // Create prize that appears when engine is "activated"
        let prize = createPrize(type: type, size: baseSize)
        prize.position = SIMD3<Float>(0, baseSize * 0.4, 0) // Above the engine
        prize.isEnabled = false // Hidden until activated

        // Add effects
        addEffects(to: engine, type: type)

        // Assemble (no lid for terror engine - it's a single animated model)
        container.addChild(engine)
        container.addChild(prize)

        // Create a dummy lid entity for compatibility with LootBoxContainer
        let dummyLid = ModelEntity()

        // CRITICAL: Add collision component to container for tap detection
        let collisionSize: Float = baseSize * 1.2 // Slightly larger than model for easier tapping
        container.collision = CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(collisionSize, collisionSize, collisionSize))])

        return LootBoxContainer(
            container: container,
            box: engine,
            lid: dummyLid,
            prize: prize,
            builtInAnimation: builtInAnimation,
            open: { container, onComplete in
                MainActor.assumeIsolated {
                    LootBoxAnimation.openTerrorEngine(container: container, onComplete: onComplete)
                }
            }
        )
    }

    /// Loads a terror engine USDZ model and checks for built-in animations
    private static func loadTerrorEngineModel(size: Float, type: LootBoxType) -> (ModelEntity, AnimationResource?) {
        let modelNames = ["Terror_Engine_-_Leather_Ghost"]

        for modelName in modelNames {
            if let modelURL = Bundle.main.url(forResource: modelName, withExtension: "usdz") {
                do {
                    // Load the model entity
                    let loadedEntity = try Entity.loadModel(contentsOf: modelURL)

                    // CRITICAL FIX: Always wrap the loaded entity to preserve its coordinate system
                    let wrapperEntity = ModelEntity()

                    // Add the loaded entity as a child to preserve its relative positioning
                    wrapperEntity.addChild(loadedEntity)

                    // Scale the wrapper to match desired size
                    wrapperEntity.scale = SIMD3<Float>(repeating: size)

                    // Ensure wrapper is right-side up
                    wrapperEntity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))

                    // Apply materials while preserving original textures and colors
                    applyMaterials(to: wrapperEntity, color: type.color, glowColor: type.glowColor)

                    // Check for built-in animations
                    var builtInAnimation: AnimationResource? = nil
                    if let modelEntity = findFirstModelEntity(in: wrapperEntity) {
                        let availableAnimations = modelEntity.availableAnimations
                        if !availableAnimations.isEmpty {
                            builtInAnimation = availableAnimations[0]
                            print("✅ Found \(availableAnimations.count) built-in animation(s) in Terror Engine model - will use for activation!")
                        }
                    }

                    print("✅ Loaded Terror Engine model: \(modelName) (wrapped to preserve coordinates)")
                    return (wrapperEntity, builtInAnimation)
                } catch {
                    print("❌ Error loading Terror Engine model \(modelName): \(error)")
                    continue
                }
            } else {
                print("⚠️ Terror Engine model \(modelName).usdz not found in bundle")
            }
        }

        print("❌ No Terror Engine models found, using fallback procedural engine")
        return (createFallbackTerrorEngine(size: size, color: type.color, glowColor: type.glowColor), nil)
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
                    if let simpleMaterial = material as? SimpleMaterial {
                        // Enhance lighting properties without overriding original color
                        materials.append(simpleMaterial)
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

    /// Fallback: creates a procedural terror engine if model can't be loaded
    private static func createFallbackTerrorEngine(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Create a dark mechanical engine-like structure
        let engine = ModelEntity()

        // Main body (dark metal block)
        let bodyMesh = MeshResource.generateBox(width: size * 0.8, height: size * 0.6, depth: size * 0.6, cornerRadius: 0.02)
        var bodyMaterial = SimpleMaterial()
        bodyMaterial.color = .init(tint: color)
        bodyMaterial.roughness = 0.8
        bodyMaterial.metallic = 0.6

        let bodyEntity = ModelEntity(mesh: bodyMesh, materials: [bodyMaterial])
        engine.addChild(bodyEntity)

        // Add mechanical details (gears, pipes, etc.)
        for i in 0..<4 {
            let gear = createGear(size: size, glowColor: glowColor)
            let angle = Float(i) * (Float.pi / 2)
            gear.position = SIMD3<Float>(
                cos(angle) * size * 0.25,
                size * 0.1,
                sin(angle) * size * 0.25
            )
            engine.addChild(gear)
        }

        // Add glowing runes/symbols
        for i in 0..<3 {
            let rune = createRune(size: size, glowColor: glowColor)
            rune.position = SIMD3<Float>(
                0,
                size * 0.25,
                Float(i - 1) * size * 0.15
            )
            engine.addChild(rune)
        }

        return engine
    }

    private static func createGear(size: Float, glowColor: UIColor) -> ModelEntity {
        let gearMesh = MeshResource.generateCylinder(height: size * 0.05, radius: size * 0.08)
        var gearMaterial = SimpleMaterial()
        gearMaterial.color = .init(tint: UIColor.darkGray)
        gearMaterial.roughness = 0.7
        gearMaterial.metallic = 0.8

        let gearEntity = ModelEntity(mesh: gearMesh, materials: [gearMaterial])

        // Add glowing center
        let center = MeshResource.generateCylinder(height: size * 0.06, radius: size * 0.03)
        var centerMaterial = SimpleMaterial()
        centerMaterial.color = .init(tint: glowColor)
        centerMaterial.roughness = 0.0

        let centerEntity = ModelEntity(mesh: center, materials: [centerMaterial])
        gearEntity.addChild(centerEntity)

        return gearEntity
    }

    private static func createRune(size: Float, glowColor: UIColor) -> ModelEntity {
        let runeMesh = MeshResource.generateBox(width: size * 0.1, height: size * 0.02, depth: size * 0.15)
        var runeMaterial = SimpleMaterial()
        runeMaterial.color = .init(tint: glowColor)
        runeMaterial.roughness = 0.0

        let runeEntity = ModelEntity(mesh: runeMesh, materials: [runeMaterial])

        // Add point light for glow
        let light = PointLightComponent(color: glowColor, intensity: 200)
        runeEntity.components.set(light)

        return runeEntity
    }

    private static func createPrize(type: LootBoxType, size: Float) -> ModelEntity {
        let prizeSize = size * 0.15
        let prizeMesh = MeshResource.generateSphere(radius: prizeSize)

        var prizeMaterial = SimpleMaterial()
        prizeMaterial.color = .init(tint: type.color)
        prizeMaterial.roughness = 0.1
        prizeMaterial.metallic = 0.9

        let prizeEntity = ModelEntity(mesh: prizeMesh, materials: [prizeMaterial])

        // Add intense glow effect for terror engine prize
        let light = PointLightComponent(color: type.glowColor, intensity: 500)
        prizeEntity.components.set(light)

        return prizeEntity
    }

    private static func addEffects(to entity: ModelEntity, type: LootBoxType) {
        // Add point light for dramatic glow
        let light = PointLightComponent(color: type.glowColor, intensity: 400)
        entity.components.set(light)

        // Add floating animation
        addFloatingAnimation(to: entity)
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
            entity.position.y = baseY + sin(offset) * 0.03
        }
    }
}
