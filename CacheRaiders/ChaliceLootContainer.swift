import RealityKit
import simd
import UIKit
import Foundation

// MARK: - Chalice Loot Container
/// A chalice-shaped container that holds loot inside
class ChaliceLootContainer {
    static func create(type: LootBoxType, id: String, sizeMultiplier: Float = 1.0) -> LootBoxContainer {
        let container = ModelEntity()
        container.name = id
        
        let baseSize = type.size * sizeMultiplier
        
        // Load the chalice model
        let chalice = loadChaliceModel(size: baseSize, type: type)
        
        // Create prize that sits inside the chalice
        let prize = createPrize(type: type, size: baseSize)
        prize.position = SIMD3<Float>(0, baseSize * 0.2, 0) // Inside the chalice
        prize.isEnabled = false // Hidden until opened
        
        // Add effects
        addEffects(to: chalice, type: type)
        
        // Assemble (no lid for chalice - prize is revealed by glowing/rising)
        container.addChild(chalice)
        container.addChild(prize)
        
        // Create a dummy lid entity for compatibility with LootBoxContainer
        let dummyLid = ModelEntity()
        
        return LootBoxContainer(
            container: container,
            box: chalice,
            lid: dummyLid,
            prize: prize,
            builtInAnimation: nil,
            open: { container, onComplete in
                MainActor.assumeIsolated {
                    LootBoxAnimation.openChalice(container: container, onComplete: onComplete)
                }
            }
        )
    }
    
    /// Loads a chalice USDZ model (randomly chooses between available models)
    /// Note: Make sure "Chalice.usdz" and "Chalice-basic.usdz" are added to the Xcode project and included in the app bundle
    private static func loadChaliceModel(size: Float, type: LootBoxType) -> ModelEntity {
        // List of available chalice models (in order of preference)
        let chaliceModels = ["Chalice", "Chalice-basic"]
        
        // Randomly select a model (or try them in order if random fails)
        let selectedModel = chaliceModels.randomElement() ?? chaliceModels[0]
        
        // Try to load the selected model
        guard let modelURL = Bundle.main.url(forResource: selectedModel, withExtension: "usdz") else {
            // Try the other model if first one fails
            let fallbackModel = selectedModel == "Chalice" ? "Chalice-basic" : "Chalice"
            guard let fallbackURL = Bundle.main.url(forResource: fallbackModel, withExtension: "usdz") else {
                print("⚠️ Could not find any chalice model in bundle")
                print("   Make sure Chalice.usdz and/or Chalice-basic.usdz are added to the Xcode project")
                print("   Using fallback procedural chalice")
                return createFallbackChalice(size: size, color: type.color, glowColor: type.glowColor)
            }
            
            return loadModelFromURL(fallbackURL, size: size, type: type, modelName: fallbackModel)
        }
        
        return loadModelFromURL(modelURL, size: size, type: type, modelName: selectedModel)
    }
    
    /// Helper function to load a model from a URL
    private static func loadModelFromURL(_ modelURL: URL, size: Float, type: LootBoxType, modelName: String) -> ModelEntity {
        do {
            // Load the model entity
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)

            // CRITICAL FIX: Always wrap the loaded entity to preserve its coordinate system
            // USDZ files often have their own scene hierarchy and positioning
            let wrapperEntity = ModelEntity()

            // Add the loaded entity as a child to preserve its relative positioning
            wrapperEntity.addChild(loadedEntity)

            // Scale the wrapper to match desired size
            // For USDZ models, scale to match the desired size (no extra multiplier)
            // Size is already calculated as baseSize = type.size * sizeMultiplier
            wrapperEntity.scale = SIMD3<Float>(repeating: size) // Use size directly without extra multiplier

            // Ensure wrapper is right-side up (not upside down)
            wrapperEntity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))

            // Apply materials while preserving original textures and colors
            applyMaterials(to: wrapperEntity, color: type.color, glowColor: type.glowColor)

            print("✅ Loaded chalice model: \(modelName) (wrapped to preserve coordinates)")
            return wrapperEntity
        } catch {
            print("❌ Error loading chalice model \(modelName): \(error)")
            print("   Using fallback procedural chalice")
            return createFallbackChalice(size: size, color: type.color, glowColor: type.glowColor)
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
                    // Material has textures - preserve it completely to maintain original appearance
                    materials.append(material)
                } else {
                    // No textures - can enhance with lighting properties
                    if var simpleMaterial = material as? SimpleMaterial {
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
    
    /// Fallback: creates a procedural chalice if model can't be loaded
    private static func createFallbackChalice(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        return createChalice(size: size, color: color, glowColor: glowColor)
    }
    
    /// Helper function to generate a cylinder mesh compatible with iOS 15.6+
    /// Uses iOS 18+ API when available, falls back to MeshDescriptor for older versions
    private static func generateCylinder(height: Float, radius: Float) -> MeshResource {
        if #available(iOS 18.0, *) {
            return MeshResource.generateCylinder(height: height, radius: radius)
        } else {
            // Fallback for iOS 15.6+: Create cylinder using MeshDescriptor
            return createCylinderMesh(height: height, radius: radius)
        }
    }
    
    /// Creates a cylinder mesh using MeshDescriptor (iOS 15+)
    private static func createCylinderMesh(height: Float, radius: Float, segments: Int = 36) -> MeshResource {
        var meshDescriptor = MeshDescriptor()
        
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        
        let angleIncrement = (2.0 * Float.pi) / Float(segments)
        
        // Bottom circle center
        positions.append([0, 0, 0])
        normals.append([0, -1, 0])
        let bottomCenterIndex: UInt32 = 0
        
        // Bottom circle vertices
        for i in 0..<segments {
            let angle = Float(i) * angleIncrement
            let x = radius * cos(angle)
            let z = radius * sin(angle)
            positions.append([x, 0, z])
            normals.append([0, -1, 0])
        }
        
        // Top circle center
        let topCenterIndex = UInt32(positions.count)
        positions.append([0, height, 0])
        normals.append([0, 1, 0])
        
        // Top circle vertices
        let topStartIndex = UInt32(positions.count)
        for i in 0..<segments {
            let angle = Float(i) * angleIncrement
            let x = radius * cos(angle)
            let z = radius * sin(angle)
            positions.append([x, height, z])
            normals.append([0, 1, 0])
        }
        
        // Side vertices (duplicated for proper normals)
        let sideStartIndex = UInt32(positions.count)
        for i in 0..<segments {
            let angle = Float(i) * angleIncrement
            let x = radius * cos(angle)
            let z = radius * sin(angle)
            let normal = normalize(SIMD3<Float>(x, 0, z))
            
            positions.append([x, 0, z])
            normals.append(normal)
            positions.append([x, height, z])
            normals.append(normal)
        }
        
        // Bottom face indices
        for i in 0..<segments {
            let nextIndex = UInt32((i + 1) % segments) + 1 // +1 to skip center
            let currentIndex = UInt32(i) + 1
            indices.append(contentsOf: [bottomCenterIndex, nextIndex, currentIndex])
        }
        
        // Top face indices
        for i in 0..<segments {
            let currentIndex = topStartIndex + UInt32(i)
            let nextIndex = topStartIndex + UInt32((i + 1) % segments)
            indices.append(contentsOf: [topCenterIndex, currentIndex, nextIndex])
        }
        
        // Side face indices
        for i in 0..<segments {
            let nextI = (i + 1) % segments
            let lowerLeft = sideStartIndex + UInt32(i * 2)
            let lowerRight = sideStartIndex + UInt32(nextI * 2)
            let upperLeft = lowerLeft + 1
            let upperRight = lowerRight + 1
            
            // Two triangles per quad
            indices.append(contentsOf: [lowerLeft, upperLeft, lowerRight])
            indices.append(contentsOf: [upperLeft, upperRight, lowerRight])
        }
        
        meshDescriptor.positions = MeshBuffer(positions)
        meshDescriptor.normals = MeshBuffer(normals)
        meshDescriptor.primitives = .triangles(indices)
        
        do {
            return try MeshResource.generate(from: [meshDescriptor])
        } catch {
            print("❌ Error generating cylinder mesh: \(error)")
            // Return a simple sphere as fallback
            return MeshResource.generateSphere(radius: radius)
        }
    }
    
    private static func createChalice(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Main chalice body (cup)
        let cupMesh = generateCylinder(height: size * 0.5, radius: size * 0.25)
        
        var cupMaterial = SimpleMaterial()
        cupMaterial.color = .init(tint: color)
        cupMaterial.roughness = 0.2
        cupMaterial.metallic = 0.8
        
        let cupEntity = ModelEntity(mesh: cupMesh, materials: [cupMaterial])
        
        // Chalice base (foot)
        let baseMesh = generateCylinder(height: size * 0.1, radius: size * 0.3)
        var baseMaterial = SimpleMaterial()
        baseMaterial.color = .init(tint: color)
        baseMaterial.roughness = 0.3
        baseMaterial.metallic = 0.7
        
        let baseEntity = ModelEntity(mesh: baseMesh, materials: [baseMaterial])
        baseEntity.position = SIMD3<Float>(0, -size * 0.3, 0)
        cupEntity.addChild(baseEntity)
        
        // Chalice stem
        let stemMesh = generateCylinder(height: size * 0.2, radius: size * 0.08)
        let stemEntity = ModelEntity(mesh: stemMesh, materials: [baseMaterial])
        stemEntity.position = SIMD3<Float>(0, -size * 0.15, 0)
        cupEntity.addChild(stemEntity)
        
        // Chalice rim (decorative top edge) - using a thin cylinder as a ring
        // Create a torus-like shape using a thin cylinder rotated horizontally
        let pipeRadius = size * 0.02
        let ringRadius = size * 0.25
        let rimMesh = generateCylinder(height: pipeRadius * 2, radius: ringRadius)
        var rimMaterial = SimpleMaterial()
        rimMaterial.color = .init(tint: glowColor)
        rimMaterial.roughness = 0.0
        rimMaterial.metallic = 1.0
        
        let rimEntity = ModelEntity(mesh: rimMesh, materials: [rimMaterial])
        rimEntity.position = SIMD3<Float>(0, size * 0.25, 0)
        rimEntity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        cupEntity.addChild(rimEntity)
        
        // Add decorative gems/runes around the cup
        for i in 0..<6 {
            let angle = Float(i) * (Float.pi * 2 / 6)
            let gem = createGem(size: size, glowColor: glowColor)
            gem.position = SIMD3<Float>(
                cos(angle) * size * 0.25,
                size * 0.1,
                sin(angle) * size * 0.25
            )
            cupEntity.addChild(gem)
        }
        
        return cupEntity
    }
    
    private static func createGem(size: Float, glowColor: UIColor) -> ModelEntity {
        let gemMesh = MeshResource.generateSphere(radius: size * 0.03)
        var gemMaterial = SimpleMaterial()
        gemMaterial.color = .init(tint: glowColor)
        gemMaterial.roughness = 0.0
        gemMaterial.metallic = 1.0
        
        let gemEntity = ModelEntity(mesh: gemMesh, materials: [gemMaterial])
        
        // Add point light for glow
        let light = PointLightComponent(color: glowColor, intensity: 100)
        gemEntity.components.set(light)
        
        return gemEntity
    }
    
    private static func createPrize(type: LootBoxType, size: Float) -> ModelEntity {
        let prizeSize = size * 0.2
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
        let light = PointLightComponent(color: type.glowColor, intensity: 300)
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
            entity.position.y = baseY + sin(offset) * 0.05
        }
    }
}

