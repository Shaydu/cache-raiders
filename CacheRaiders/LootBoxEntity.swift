import RealityKit
import ARKit
import simd
import AVFoundation

// MARK: - Loot Box Type (Archaeological Artifacts)
enum LootBoxType: String, CaseIterable, Codable {
    case goldenIdol = "Golden Idol"
    case ancientArtifact = "Ancient Artifact"
    case templeRelic = "Temple Relic"
    case puzzleBox = "Puzzle Box"
    case stoneTablet = "Stone Tablet"
    
    var color: UIColor {
        switch self {
        case .goldenIdol: return UIColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1.0) // Gold
        case .ancientArtifact: return UIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1.0) // Bronze
        case .templeRelic: return UIColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1.0) // Dark stone
        case .puzzleBox: return UIColor(red: 0.7, green: 0.5, blue: 0.3, alpha: 1.0) // Weathered wood
        case .stoneTablet: return UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0) // Stone gray
        }
    }
    
    var glowColor: UIColor {
        switch self {
        case .goldenIdol: return UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Amber
        case .ancientArtifact: return UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0) // Orange glow
        case .templeRelic: return UIColor(red: 0.8, green: 0.6, blue: 0.4, alpha: 1.0) // Warm stone
        case .puzzleBox: return UIColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1.0) // Golden
        case .stoneTablet: return UIColor(red: 0.6, green: 0.8, blue: 0.9, alpha: 1.0) // Mystical blue
        }
    }
    
    var size: Float {
        switch self {
        case .goldenIdol: return 0.3
        case .ancientArtifact: return 0.4
        case .templeRelic: return 0.45
        case .puzzleBox: return 0.38
        case .stoneTablet: return 0.5
        }
    }
}

// MARK: - Loot Box Container
struct LootBoxContainer {
    let container: ModelEntity
    let box: ModelEntity
    let lid: ModelEntity
    let prize: ModelEntity
}

// MARK: - Loot Box Entity
class LootBoxEntity {
    static func createLootBox(type: LootBoxType, id: String, sizeMultiplier: Float = 1.0) -> LootBoxContainer {
        // Determine container type based on loot box type
        // Use chalice for golden idol, box for others
        switch type {
        case .goldenIdol:
            return ChaliceLootContainer.create(type: type, id: id, sizeMultiplier: sizeMultiplier)
        case .ancientArtifact, .templeRelic, .puzzleBox, .stoneTablet:
            return BoxLootContainer.create(type: type, id: id, sizeMultiplier: sizeMultiplier)
        }
    }
    
    // Extract lid from box entity (finds and removes skull lid)
    private static func extractLid(from box: ModelEntity, type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity? {
        let size = type.size * sizeMultiplier
        // Find the skull lid child (it's positioned at size * 0.35 on Y axis)
        for child in box.children {
            if abs(child.position.y - size * 0.35) < 0.1 {
                // This is likely the lid
                if let modelEntity = child as? ModelEntity {
                    modelEntity.removeFromParent()
                    return modelEntity
                }
            }
        }
        
        // If no lid found, create one
        return createLid(type: type, sizeMultiplier: sizeMultiplier)
    }
    
    // Create a separate lid entity
    private static func createLid(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier
        let lidBase = MeshResource.generateBox(
            width: size * 0.4,
            height: size * 0.15,
            depth: size * 0.4,
            cornerRadius: 0.05
        )
        
        var lidMaterial = SimpleMaterial()
        lidMaterial.color = .init(tint: UIColor(red: 0.25, green: 0.2, blue: 0.15, alpha: 1.0))
        lidMaterial.roughness = 0.8
        lidMaterial.metallic = 0.1
        
        let lidEntity = ModelEntity(mesh: lidBase, materials: [lidMaterial])
        lidEntity.position = SIMD3<Float>(0, size * 0.35, 0)
        
        // Add skull decoration to lid
        addSkullLid(to: lidEntity, size: size, glowColor: type.glowColor)
        
        return lidEntity
    }
    
    // Create prize entity (the artifact inside)
    private static func createPrize(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier * 0.6 // Smaller than box
        
        let prizeMesh: MeshResource
        var prizeMaterial = SimpleMaterial()
        
        switch type {
        case .goldenIdol:
            prizeMesh = MeshResource.generateBox(width: size * 0.4, height: size * 0.6, depth: size * 0.3, cornerRadius: 0.05)
            prizeMaterial.color = .init(tint: type.color)
            prizeMaterial.roughness = 0.2
            prizeMaterial.metallic = 0.8
        case .ancientArtifact:
            prizeMesh = MeshResource.generateBox(width: size * 0.5, height: size * 0.4, depth: size * 0.4, cornerRadius: 0.03)
            prizeMaterial.color = .init(tint: type.color)
            prizeMaterial.roughness = 0.3
            prizeMaterial.metallic = 0.6
        case .templeRelic:
            prizeMesh = MeshResource.generateBox(width: size * 0.4, height: size * 0.5, depth: size * 0.4, cornerRadius: 0.04)
            prizeMaterial.color = .init(tint: type.color)
            prizeMaterial.roughness = 0.4
            prizeMaterial.metallic = 0.5
        case .puzzleBox:
            prizeMesh = MeshResource.generateBox(width: size * 0.45, height: size * 0.35, depth: size * 0.45, cornerRadius: 0.05)
            prizeMaterial.color = .init(tint: type.color)
            prizeMaterial.roughness = 0.5
            prizeMaterial.metallic = 0.4
        case .stoneTablet:
            prizeMesh = MeshResource.generateBox(width: size * 0.6, height: size * 0.2, depth: size * 0.4, cornerRadius: 0.02)
            prizeMaterial.color = .init(tint: type.color)
            prizeMaterial.roughness = 0.6
            prizeMaterial.metallic = 0.3
        }
        
        let prizeEntity = ModelEntity(mesh: prizeMesh, materials: [prizeMaterial])
        
        // Add glow effect to prize
        var glowMaterial = SimpleMaterial()
        glowMaterial.color = .init(tint: type.glowColor)
        glowMaterial.roughness = 0.0
        glowMaterial.metallic = 0.0
        
        // Add floating animation (using timer-based approach for compatibility)
        addPrizeFloatingAnimation(to: prizeEntity)
        
        return prizeEntity
    }
    
    // MARK: - Dark & Mysterious Details (Helper Functions)
    private static func addSkullLid(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // Create skull decoration on top of box
        let skullBase = MeshResource.generateBox(
            width: size * 0.4,
            height: size * 0.15,
            depth: size * 0.4,
            cornerRadius: 0.05
        )
        
        var skullMaterial = SimpleMaterial()
        skullMaterial.color = .init(tint: UIColor(red: 0.25, green: 0.2, blue: 0.15, alpha: 1.0)) // Dark bone color
        skullMaterial.roughness = 0.8
        skullMaterial.metallic = 0.1
        
        let skullEntity = ModelEntity(mesh: skullBase, materials: [skullMaterial])
        skullEntity.position = SIMD3<Float>(0, size * 0.35, 0)
        entity.addChild(skullEntity)
        
        // Add glowing eye sockets
        let leftEye = MeshResource.generateSphere(radius: size * 0.04)
        let rightEye = MeshResource.generateSphere(radius: size * 0.04)
        
        var eyeMaterial = SimpleMaterial()
        eyeMaterial.color = .init(tint: glowColor, texture: nil)
        eyeMaterial.roughness = 0.0
        
        let leftEyeEntity = ModelEntity(mesh: leftEye, materials: [eyeMaterial])
        leftEyeEntity.position = SIMD3<Float>(-size * 0.12, size * 0.35, size * 0.2)
        entity.addChild(leftEyeEntity)
        
        let rightEyeEntity = ModelEntity(mesh: rightEye, materials: [eyeMaterial])
        rightEyeEntity.position = SIMD3<Float>(size * 0.12, size * 0.35, size * 0.2)
        entity.addChild(rightEyeEntity)
    }
    
    private static func addGlowingCracks(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // Add glowing cracks where light escapes
        let crackPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.3, size * 0.1, size * 0.35), // Front crack
            SIMD3<Float>(-size * 0.3, -size * 0.1, size * 0.35), // Front crack 2
            SIMD3<Float>(size * 0.35, size * 0.2, 0), // Side crack
            SIMD3<Float>(-size * 0.35, -size * 0.2, 0), // Side crack 2
        ]
        
        for position in crackPositions {
            let crack = MeshResource.generateBox(width: size * 0.02, height: size * 0.15, depth: size * 0.01)
            var crackMaterial = SimpleMaterial()
            crackMaterial.color = .init(tint: glowColor, texture: nil)
            crackMaterial.roughness = 0.0
            
            let crackEntity = ModelEntity(mesh: crack, materials: [crackMaterial])
            crackEntity.position = position
            entity.addChild(crackEntity)
        }
    }
    
    private static func addIntenseGlowingCracks(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // More intense, brighter cracks
        let crackPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.25, size * 0.15, size * 0.38),
            SIMD3<Float>(-size * 0.25, -size * 0.15, size * 0.38),
            SIMD3<Float>(size * 0.38, size * 0.25, 0),
            SIMD3<Float>(-size * 0.38, -size * 0.25, 0),
            SIMD3<Float>(0, size * 0.3, size * 0.35), // Top crack
        ]
        
        for position in crackPositions {
            let crack = MeshResource.generateBox(width: size * 0.03, height: size * 0.2, depth: size * 0.015)
            var crackMaterial = SimpleMaterial()
            crackMaterial.color = .init(tint: glowColor, texture: nil)
            crackMaterial.roughness = 0.0
            
            let crackEntity = ModelEntity(mesh: crack, materials: [crackMaterial])
            crackEntity.position = position
            entity.addChild(crackEntity)
        }
    }
    
    private static func addMetalBands(to entity: ModelEntity, size: Float) {
        // Add dark metal bands around the box
        let bandPositions: [SIMD3<Float>] = [
            SIMD3<Float>(0, size * 0.25, size * 0.4), // Front band
            SIMD3<Float>(0, -size * 0.25, size * 0.4), // Front band bottom
            SIMD3<Float>(size * 0.4, 0, 0), // Side band
            SIMD3<Float>(-size * 0.4, 0, 0), // Side band
        ]
        
        for position in bandPositions {
            let band = MeshResource.generateBox(width: size * 0.05, height: size * 0.1, depth: size * 0.02)
            var bandMaterial = SimpleMaterial()
            bandMaterial.color = .init(tint: UIColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1.0)) // Dark tarnished metal
            bandMaterial.roughness = 0.7
            bandMaterial.metallic = 0.4
            
            let bandEntity = ModelEntity(mesh: band, materials: [bandMaterial])
            bandEntity.position = position
            entity.addChild(bandEntity)
        }
    }
    
    private static func addSkullDecorations(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // Add small skull decorations on the lid
        let skullPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.25, size * 0.3, size * 0.35),
            SIMD3<Float>(-size * 0.25, size * 0.3, size * 0.35),
        ]
        
        for position in skullPositions {
            let skull = MeshResource.generateBox(width: size * 0.12, height: size * 0.08, depth: size * 0.08, cornerRadius: 0.02)
            var skullMaterial = SimpleMaterial()
            skullMaterial.color = .init(tint: UIColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1.0))
            skullMaterial.roughness = 0.8
            skullMaterial.metallic = 0.1
            
            let skullEntity = ModelEntity(mesh: skull, materials: [skullMaterial])
            skullEntity.position = position
            entity.addChild(skullEntity)
            
            // Add glowing eyes
            let eye = MeshResource.generateSphere(radius: size * 0.015)
            var eyeMaterial = SimpleMaterial()
            eyeMaterial.color = .init(tint: glowColor, texture: nil)
            eyeMaterial.roughness = 0.0
            
            let eyeEntity = ModelEntity(mesh: eye, materials: [eyeMaterial])
            eyeEntity.position = SIMD3<Float>(position.x, position.y, position.z + size * 0.05)
            entity.addChild(eyeEntity)
        }
    }
    
    private static func addGlowingSeams(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // Add glowing seams where the lid meets the box
        let seamPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.4, size * 0.3, size * 0.35), // Top front
            SIMD3<Float>(-size * 0.4, size * 0.3, size * 0.35), // Top front
            SIMD3<Float>(size * 0.4, size * 0.3, -size * 0.35), // Top back
            SIMD3<Float>(-size * 0.4, size * 0.3, -size * 0.35), // Top back
        ]
        
        for position in seamPositions {
            let seam = MeshResource.generateBox(width: size * 0.02, height: size * 0.01, depth: size * 0.7)
            var seamMaterial = SimpleMaterial()
            seamMaterial.color = .init(tint: glowColor, texture: nil)
            seamMaterial.roughness = 0.0
            
            let seamEntity = ModelEntity(mesh: seam, materials: [seamMaterial])
            seamEntity.position = position
            entity.addChild(seamEntity)
        }
    }
    
    private static func addTarnishedCorners(to entity: ModelEntity, size: Float) {
        // Add tarnished metal corner reinforcements
        let cornerSize: Float = size * 0.08
        let cornerPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.4, size * 0.3, size * 0.35), // Top front right
            SIMD3<Float>(-size * 0.4, size * 0.3, size * 0.35), // Top front left
            SIMD3<Float>(size * 0.4, -size * 0.3, size * 0.35), // Bottom front right
            SIMD3<Float>(-size * 0.4, -size * 0.3, size * 0.35), // Bottom front left
        ]
        
        for position in cornerPositions {
            let corner = MeshResource.generateBox(size: cornerSize)
            var cornerMaterial = SimpleMaterial()
            cornerMaterial.color = .init(tint: UIColor(red: 0.35, green: 0.3, blue: 0.25, alpha: 1.0)) // Tarnished bronze
            cornerMaterial.roughness = 0.8
            cornerMaterial.metallic = 0.5
            
            let cornerEntity = ModelEntity(mesh: corner, materials: [cornerMaterial])
            cornerEntity.position = position
            entity.addChild(cornerEntity)
        }
    }
    
    private static func addGlowingRunes(to entity: ModelEntity, size: Float, glowColor: UIColor) {
        // Add glowing ancient runes
        let runePositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.3, size * 0.2, size * 0.36),
            SIMD3<Float>(-size * 0.3, size * 0.2, size * 0.36),
            SIMD3<Float>(size * 0.36, size * 0.2, 0),
            SIMD3<Float>(-size * 0.36, size * 0.2, 0),
        ]
        
        for position in runePositions {
            let rune = MeshResource.generateBox(width: size * 0.04, height: size * 0.06, depth: size * 0.01)
            var runeMaterial = SimpleMaterial()
            runeMaterial.color = .init(tint: glowColor, texture: nil)
            runeMaterial.roughness = 0.0
            
            let runeEntity = ModelEntity(mesh: rune, materials: [runeMaterial])
            runeEntity.position = position
            entity.addChild(runeEntity)
        }
    }
    
    // MARK: - Crystal Skull Creation
    private static func createCrystalSkull(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier
        
        // Create dark ancient box with skull lid
        let boxBase = MeshResource.generateBox(
            width: size * 0.9,
            height: size * 0.6,
            depth: size * 0.8,
            cornerRadius: 0.02
        )
        
        // Dark weathered material
        var baseMaterial = SimpleMaterial()
        baseMaterial.color = .init(tint: UIColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 1.0)) // Dark aged wood/stone
        baseMaterial.roughness = 0.9
        baseMaterial.metallic = 0.1
        
        let entity = ModelEntity(mesh: boxBase, materials: [baseMaterial])
        
        // Add skull lid decoration
        addSkullLid(to: entity, size: size, glowColor: type.glowColor)
        
        // Add glowing cracks with light shining out
        addGlowingCracks(to: entity, size: size, glowColor: type.glowColor)
        
        // Add ancient metal bands
        addMetalBands(to: entity, size: size)
        
        return entity
    }
    
    // MARK: - Golden Idol Creation
    private static func createGoldenIdol(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier
        
        // Create dark ancient chest with skull decorations
        let chestBase = MeshResource.generateBox(
            width: size * 0.85,
            height: size * 0.65,
            depth: size * 0.75,
            cornerRadius: 0.02
        )
        
        // Dark ancient material
        var baseMaterial = SimpleMaterial()
        baseMaterial.color = .init(tint: UIColor(red: 0.2, green: 0.15, blue: 0.1, alpha: 1.0)) // Dark aged bronze/wood
        baseMaterial.roughness = 0.85
        baseMaterial.metallic = 0.2
        
        let entity = ModelEntity(mesh: chestBase, materials: [baseMaterial])
        
        // Add skull decorations on lid
        addSkullDecorations(to: entity, size: size, glowColor: type.glowColor)
        
        // Add glowing seams where light escapes
        addGlowingSeams(to: entity, size: size, glowColor: type.glowColor)
        
        // Add tarnished metal corners
        addTarnishedCorners(to: entity, size: size)
        
        return entity
    }
    
    // MARK: - Ancient Artifact Creation
    private static func createAncientArtifact(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier
        
        // Create dark weathered artifact box
        let mainBody = MeshResource.generateBox(
            width: size * 0.8,
            height: size * 0.7,
            depth: size * 0.7,
            cornerRadius: 0.03
        )
        
        // Very dark, weathered material
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(red: 0.12, green: 0.1, blue: 0.08, alpha: 1.0)) // Almost black aged wood
        material.roughness = 0.95
        material.metallic = 0.05
        
        let entity = ModelEntity(mesh: mainBody, materials: [material])
        
        // Add skull lid with glowing eyes
        addSkullLid(to: entity, size: size, glowColor: type.glowColor)
        
        // Add intense light from cracks
        addIntenseGlowingCracks(to: entity, size: size, glowColor: type.glowColor)
        
        // Add ancient runes that glow
        addGlowingRunes(to: entity, size: size, glowColor: type.glowColor)
        
        return entity
    }
    
    // MARK: - Temple Relic Creation
    private static func createTempleRelic(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier
        
        // Create dark stone pedestal
        let pedestal = MeshResource.generateBox(
            width: size * 0.7,
            height: size * 0.4,
            depth: size * 0.7,
            cornerRadius: 0.05
        )
        
        // Dark weathered stone material
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(red: 0.18, green: 0.15, blue: 0.12, alpha: 1.0)) // Dark stone
        material.roughness = 0.95
        material.metallic = 0.05
        
        let entity = ModelEntity(mesh: pedestal, materials: [material])
        
        // Add dark artifact box on top with skull lid
        let artifact = MeshResource.generateBox(
            width: size * 0.5,
            height: size * 0.4,
            depth: size * 0.5,
            cornerRadius: 0.03
        )
        
        let artifactEntity = ModelEntity(mesh: artifact, materials: [material])
        artifactEntity.position = SIMD3<Float>(0, size * 0.4, 0)
        entity.addChild(artifactEntity)
        
        // Add skull lid to artifact
        addSkullLid(to: artifactEntity, size: size * 0.7, glowColor: type.glowColor)
        
        // Add glowing cracks
        addGlowingCracks(to: artifactEntity, size: size * 0.7, glowColor: type.glowColor)
        
        // Add temple carvings
        addTempleCarvings(to: entity, size: size)
        
        return entity
    }
    
    // MARK: - Puzzle Box Creation
    private static func createPuzzleBox(type: LootBoxType, sizeMultiplier: Float = 1.0) -> ModelEntity {
        let size = type.size * sizeMultiplier
        
        // Create dark ancient puzzle box
        let mainBox = MeshResource.generateBox(
            width: size,
            height: size * 0.7,
            depth: size * 0.8,
            cornerRadius: 0.02
        )
        
        // Very dark, ancient wood/stone
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 1.0))
        material.roughness = 0.9
        material.metallic = 0.1
        
        let entity = ModelEntity(mesh: mainBox, materials: [material])
        
        // Add skull lid
        addSkullLid(to: entity, size: size, glowColor: type.glowColor)
        
        // Add glowing seams
        addGlowingSeams(to: entity, size: size, glowColor: type.glowColor)
        
        // Add puzzle pieces (rotating rings/symbols)
        addPuzzlePieces(to: entity, type: type, size: size)
        
        return entity
    }
    
    // MARK: - Stone Tablet Creation
    private static func createStoneTablet(type: LootBoxType) -> ModelEntity {
        let size = type.size
        
        // Create dark weathered stone tablet
        let tablet = MeshResource.generateBox(
            width: size * 0.8,
            height: size * 0.15,
            depth: size * 0.6,
            cornerRadius: 0.01
        )
        
        // Dark ancient stone
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(red: 0.2, green: 0.18, blue: 0.15, alpha: 1.0))
        material.roughness = 0.95
        material.metallic = 0.0
        
        let entity = ModelEntity(mesh: tablet, materials: [material])
        
        // Add glowing hieroglyphic symbols
        addHieroglyphics(to: entity, type: type, size: size)
        
        // Add skull decorations on corners
        addSkullDecorations(to: entity, size: size, glowColor: type.glowColor)
        
        return entity
    }
    
    // MARK: - Detail Additions
    private static func addCrystalFacets(to entity: ModelEntity, size: Float) {
        // Add geometric crystal patterns
        let glowColor = LootBoxType.stoneTablet.glowColor // Use stoneTablet's mystical blue glow
        for i in 0..<8 {
            let facet = MeshResource.generateBox(size: size * 0.05)
            var facetMaterial = SimpleMaterial()
            facetMaterial.color = .init(tint: glowColor, texture: nil)
            facetMaterial.roughness = 0.0
            
            let angle = Float(i) * (Float.pi * 2 / 8)
            let radius: Float = size * 0.4
            let facetEntity = ModelEntity(mesh: facet, materials: [facetMaterial])
            facetEntity.position = SIMD3<Float>(
                cos(angle) * radius,
                sin(angle) * 0.2,
                sin(angle) * radius
            )
            entity.addChild(facetEntity)
        }
    }
    
    private static func addIdolDetails(to entity: ModelEntity, size: Float) {
        // Add decorative gems
        let gemPositions: [SIMD3<Float>] = [
            SIMD3<Float>(0, size * 0.3, size * 0.15), // Forehead
            SIMD3<Float>(-size * 0.15, size * 0.1, size * 0.15), // Left chest
            SIMD3<Float>(size * 0.15, size * 0.1, size * 0.15) // Right chest
        ]
        
        for position in gemPositions {
            let gem = MeshResource.generateSphere(radius: size * 0.04)
            var gemMaterial = SimpleMaterial()
            gemMaterial.color = .init(tint: .red, texture: nil)
            gemMaterial.roughness = 0.1
            gemMaterial.metallic = 1.0
            
            let gemEntity = ModelEntity(mesh: gem, materials: [gemMaterial])
            gemEntity.position = position
            entity.addChild(gemEntity)
        }
    }
    
    private static func addAncientSymbols(to entity: ModelEntity, type: LootBoxType, size: Float) {
        // Add glowing symbols around the artifact
        let symbolSize: Float = 0.02
        let symbolPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.3, size * 0.3, 0),
            SIMD3<Float>(-size * 0.3, size * 0.3, 0),
            SIMD3<Float>(size * 0.3, -size * 0.3, 0),
            SIMD3<Float>(-size * 0.3, -size * 0.3, 0)
        ]
        
        for position in symbolPositions {
            let symbol = MeshResource.generateBox(size: symbolSize)
            var symbolMaterial = SimpleMaterial()
            symbolMaterial.color = .init(tint: type.glowColor, texture: nil)
            symbolMaterial.roughness = 0.0
            
            let symbolEntity = ModelEntity(mesh: symbol, materials: [symbolMaterial])
            symbolEntity.position = position
            entity.addChild(symbolEntity)
        }
    }
    
    private static func addTempleCarvings(to entity: ModelEntity, size: Float) {
        // Add carved patterns (represented as small boxes)
        let carvingSize: Float = 0.015
        let carvingPositions: [SIMD3<Float>] = [
            SIMD3<Float>(size * 0.25, size * 0.15, size * 0.3),
            SIMD3<Float>(-size * 0.25, size * 0.15, size * 0.3),
            SIMD3<Float>(size * 0.25, -size * 0.15, size * 0.3),
            SIMD3<Float>(-size * 0.25, -size * 0.15, size * 0.3)
        ]
        
        for position in carvingPositions {
            let carving = MeshResource.generateBox(size: carvingSize)
            var carvingMaterial = SimpleMaterial()
            carvingMaterial.color = .init(tint: .darkGray, texture: nil)
            carvingMaterial.roughness = 1.0
            
            let carvingEntity = ModelEntity(mesh: carving, materials: [carvingMaterial])
            carvingEntity.position = position
            entity.addChild(carvingEntity)
        }
    }
    
    private static func addPuzzlePieces(to entity: ModelEntity, type: LootBoxType, size: Float) {
        // Add rotating puzzle rings (using thin boxes as rings)
        for i in 0..<3 {
            let ring = MeshResource.generateBox(width: size * 0.6, height: size * 0.03, depth: size * 0.6, cornerRadius: size * 0.3)
            var ringMaterial = SimpleMaterial()
            ringMaterial.color = .init(tint: type.glowColor, texture: nil)
            ringMaterial.roughness = 0.2
            ringMaterial.metallic = 0.7
            
            let ringEntity = ModelEntity(mesh: ring, materials: [ringMaterial])
            ringEntity.position = SIMD3<Float>(0, Float(i - 1) * size * 0.15, 0)
            ringEntity.orientation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            entity.addChild(ringEntity)
            
            // Animate rotation
            animatePuzzleRing(ringEntity, speed: Float(i + 1) * 0.5)
        }
    }
    
    private static func addHieroglyphics(to entity: ModelEntity, type: LootBoxType, size: Float) {
        // Add hieroglyphic symbols on the tablet
        let symbolSize: Float = 0.02
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(-size * 0.3, 0, size * 0.2),
            SIMD3<Float>(0, 0, size * 0.2),
            SIMD3<Float>(size * 0.3, 0, size * 0.2),
            SIMD3<Float>(-size * 0.3, 0, -size * 0.2),
            SIMD3<Float>(0, 0, -size * 0.2),
            SIMD3<Float>(size * 0.3, 0, -size * 0.2)
        ]
        
        for position in positions {
            let symbol = MeshResource.generateBox(size: symbolSize)
            var symbolMaterial = SimpleMaterial()
            symbolMaterial.color = .init(tint: type.glowColor, texture: nil)
            symbolMaterial.roughness = 0.0
            
            let symbolEntity = ModelEntity(mesh: symbol, materials: [symbolMaterial])
            symbolEntity.position = position
            entity.addChild(symbolEntity)
        }
    }
    
    // MARK: - Special Effects
    private static func addEffects(to entity: ModelEntity, type: LootBoxType) {
        // Add intense point light for dramatic glow
        let light = PointLightComponent(color: type.glowColor, intensity: 600)
        entity.components.set(light)
        
        // Add pulsating animation (more dramatic)
        addPulsatingGlow(to: entity, color: type.glowColor)
        
        // Add floating dust particles (more atmospheric)
        addDustParticles(to: entity, color: type.glowColor)
        
        // Add floating animation
        addFloatingAnimation(to: entity)
    }
    
    private static func addPulsatingGlow(to entity: ModelEntity, color: UIColor) {
        var baseIntensity: Float = 600
        var goingUp = true
        
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak entity] timer in
            guard let entity = entity, entity.parent != nil else {
                timer.invalidate()
                return
            }
            
            if goingUp {
                baseIntensity = 800 // Brighter peak
            } else {
                baseIntensity = 300 // Darker trough
            }
            goingUp.toggle()
            
            let light = PointLightComponent(color: color, intensity: baseIntensity)
            entity.components.set(light)
        }
    }
    
    private static func addDustParticles(to entity: ModelEntity, color: UIColor) {
        // Create floating dust motes
        for i in 0..<8 {
            let particle = MeshResource.generateSphere(radius: 0.008)
            var particleMaterial = SimpleMaterial()
            particleMaterial.color = .init(tint: color.withAlphaComponent(0.6), texture: nil)
            particleMaterial.roughness = 0.0
            
            let particleEntity = ModelEntity(mesh: particle, materials: [particleMaterial])
            
            // Position particles in a sphere around the entity
            let angle1 = Float(i) * (Float.pi * 2 / 8)
            let angle2 = Float(i % 4) * (Float.pi / 4)
            let radius: Float = 0.35
            particleEntity.position = SIMD3<Float>(
                cos(angle1) * radius * cos(angle2),
                sin(angle2) * radius + 0.2,
                sin(angle1) * radius * cos(angle2)
            )
            
            entity.addChild(particleEntity)
            
            // Animate particles floating
            animateDustParticle(particleEntity, index: i)
        }
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
    
    private static func addPrizeFloatingAnimation(to entity: ModelEntity) {
        let baseY = entity.position.y
        var offset: Float = 0
        
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak entity] timer in
            guard let entity = entity, entity.parent != nil else {
                timer.invalidate()
                return
            }
            
            offset += 0.03
            entity.position.y = baseY + sin(offset) * 0.1
        }
    }
    
    private static func animateDustParticle(_ particle: ModelEntity, index: Int) {
        let basePosition = particle.position
        var offset: Float = Float(index) * 0.5
        
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak particle] timer in
            guard let particle = particle, particle.parent != nil else {
                timer.invalidate()
                return
            }
            
            offset += 0.05
            particle.position.y = basePosition.y + sin(offset) * 0.15
            particle.position.x = basePosition.x + cos(offset * 0.7) * 0.1
        }
    }
    
    private static func animatePuzzleRing(_ ring: ModelEntity, speed: Float) {
        var rotation: Float = 0
        
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak ring] timer in
            guard let ring = ring, ring.parent != nil else {
                timer.invalidate()
                return
            }
            
            rotation += speed * 0.02
            ring.orientation = simd_quatf(angle: rotation, axis: SIMD3<Float>(0, 1, 0))
        }
    }
}
