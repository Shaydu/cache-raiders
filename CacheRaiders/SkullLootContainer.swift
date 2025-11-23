import RealityKit
import simd
import UIKit
import Foundation

// MARK: - Skull Loot Container
/// A skull-shaped container with a removable lid on top that opens to reveal loot
class SkullLootContainer {
    static func create(type: LootBoxType, id: String, sizeMultiplier: Float = 1.0) -> LootBoxContainer {
        let container = ModelEntity()
        container.name = id
        
        let baseSize = type.size * sizeMultiplier
        
        // Create skull base (the main skull body)
        let skullBase = createSkullBase(size: baseSize, color: type.color, glowColor: type.glowColor)
        
        // Create removable lid (top of skull that opens)
        let lid = createSkullLid(size: baseSize, color: type.color, glowColor: type.glowColor)
        lid.position = SIMD3<Float>(0, baseSize * 0.5, 0) // Position on top
        
        // Create prize that sits inside the skull
        let prize = createPrize(type: type, size: baseSize)
        prize.position = SIMD3<Float>(0, -baseSize * 0.1, 0) // Inside the skull
        prize.isEnabled = false // Hidden until opened
        
        // Add effects
        addEffects(to: skullBase, type: type)
        
        // Assemble
        container.addChild(skullBase)
        container.addChild(lid)
        container.addChild(prize)
        
        return LootBoxContainer(
            container: container,
            box: skullBase,
            lid: lid,
            prize: prize,
            builtInAnimation: nil,
            open: { container, onComplete in
                MainActor.assumeIsolated {
                    LootBoxAnimation.openSkull(container: container, onComplete: onComplete)
                }
            }
        )
    }
    
    private static func createSkullBase(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Main skull shape - use a sphere as base, then modify
        let skullMesh = MeshResource.generateSphere(radius: size * 0.4)
        
        var skullMaterial = SimpleMaterial()
        skullMaterial.color = .init(tint: color)
        skullMaterial.roughness = 0.3
        skullMaterial.metallic = 0.2
        
        let skullEntity = ModelEntity(mesh: skullMesh, materials: [skullMaterial])
        
        // Add jaw (lower part)
        let jawMesh = MeshResource.generateBox(
            width: size * 0.5,
            height: size * 0.2,
            depth: size * 0.4,
            cornerRadius: size * 0.1
        )
        let jawEntity = ModelEntity(mesh: jawMesh, materials: [skullMaterial])
        jawEntity.position = SIMD3<Float>(0, -size * 0.25, 0)
        skullEntity.addChild(jawEntity)
        
        // Add eye sockets with glowing eyes
        let leftEye = createGlowingEye(size: size, glowColor: glowColor)
        leftEye.position = SIMD3<Float>(-size * 0.15, size * 0.1, size * 0.35)
        skullEntity.addChild(leftEye)
        
        let rightEye = createGlowingEye(size: size, glowColor: glowColor)
        rightEye.position = SIMD3<Float>(size * 0.15, size * 0.1, size * 0.35)
        skullEntity.addChild(rightEye)
        
        // Add nose cavity
        let noseMesh = MeshResource.generateBox(
            width: size * 0.08,
            height: size * 0.15,
            depth: size * 0.1,
            cornerRadius: size * 0.02
        )
        let noseEntity = ModelEntity(mesh: noseMesh, materials: [skullMaterial])
        noseEntity.position = SIMD3<Float>(0, -size * 0.05, size * 0.35)
        skullEntity.addChild(noseEntity)
        
        return skullEntity
    }
    
    private static func createSkullLid(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Top portion of skull that acts as lid
        let lidMesh = MeshResource.generateSphere(radius: size * 0.35)
        
        var lidMaterial = SimpleMaterial()
        lidMaterial.color = .init(tint: color)
        lidMaterial.roughness = 0.3
        lidMaterial.metallic = 0.2
        
        let lidEntity = ModelEntity(mesh: lidMesh, materials: [lidMaterial])
        
        // Add decorative elements to lid
        let decorationMesh = MeshResource.generateBox(
            width: size * 0.3,
            height: size * 0.1,
            depth: size * 0.3,
            cornerRadius: size * 0.05
        )
        var decorationMaterial = SimpleMaterial()
        decorationMaterial.color = .init(tint: glowColor)
        decorationMaterial.roughness = 0.0
        
        let decoration = ModelEntity(mesh: decorationMesh, materials: [decorationMaterial])
        decoration.position = SIMD3<Float>(0, size * 0.2, 0)
        lidEntity.addChild(decoration)
        
        return lidEntity
    }
    
    private static func createGlowingEye(size: Float, glowColor: UIColor) -> ModelEntity {
        let eyeMesh = MeshResource.generateSphere(radius: size * 0.08)
        var eyeMaterial = SimpleMaterial()
        eyeMaterial.color = .init(tint: glowColor)
        eyeMaterial.roughness = 0.0
        
        let eyeEntity = ModelEntity(mesh: eyeMesh, materials: [eyeMaterial])
        
        // Add point light for glow
        let light = PointLightComponent(color: glowColor, intensity: 300)
        eyeEntity.components.set(light)
        
        return eyeEntity
    }
    
    private static func createPrize(type: LootBoxType, size: Float) -> ModelEntity {
        let prizeSize = size * 0.3
        let prizeMesh = MeshResource.generateSphere(radius: prizeSize)
        
        var prizeMaterial = SimpleMaterial()
        prizeMaterial.color = .init(tint: type.color)
        prizeMaterial.roughness = 0.1
        prizeMaterial.metallic = 0.9
        
        let prizeEntity = ModelEntity(mesh: prizeMesh, materials: [prizeMaterial])
        
        // Add glow effect
        let light = PointLightComponent(color: type.glowColor, intensity: 200)
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
            entity.position.y = baseY + sin(offset) * 0.05
        }
    }
}

