import RealityKit
import UIKit
import AVFoundation

// MARK: - Loot Box Factory Protocol
/// Protocol for creating findable objects - eliminates need for exhaustive switch statements
/// Each factory encapsulates its own sounds, animations, and behaviors
protocol LootBoxFactory {
    /// Creates the entity for this loot box type
    func createEntity(location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float) -> (entity: ModelEntity, findableObject: FindableObject)
    
    /// Creates a container if this type uses containers (returns nil for simple objects like spheres/cubes)
    func createContainer(location: LootBoxLocation, sizeMultiplier: Float) -> LootBoxContainer?
    
    /// Animates the "find" behavior for this object type
    /// - Parameters:
    ///   - entity: The entity to animate (could be container or simple entity)
    ///   - container: Optional container if this type uses containers
    ///   - tapWorldPosition: World position where user tapped (for confetti)
    ///   - onComplete: Callback when animation completes
    func animateFind(entity: ModelEntity, container: LootBoxContainer?, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void)
    
    /// Starts a continuous loop animation for the entity (e.g., rotation, floating)
    /// This animation runs continuously while the entity exists
    /// - Parameter entity: The entity to animate
    func animateLoop(entity: ModelEntity)
    
    /// Plays the sound effect for finding this object type
    func playFindSound()
    
    /// Returns the icon name for map display
    var iconName: String { get }
    
    /// Returns model names if this type uses USDZ models
    var modelNames: [String] { get }
    
    /// Returns the description/name for this item type
    func itemDescription() -> String
}

// MARK: - Factory Implementations

struct ChaliceFactory: LootBoxFactory {
    var iconName: String { "cup.and.saucer.fill" }
    var modelNames: [String] { ["Chalice", "Chalice-basic"] }
    
    func itemDescription() -> String {
        return ["Sacred Chalice", "Ancient Chalice", "Golden Chalice"].randomElement() ?? "Sacred Chalice"
    }
    
    func createEntity(location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float) -> (entity: ModelEntity, findableObject: FindableObject) {
        // Create container with custom open behavior
        let container = createContainer(location: location, sizeMultiplier: sizeMultiplier)!
        let entity = container.container
        entity.name = location.id
        entity.position = SIMD3<Float>(0, 0, 0)
        
        let findableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: nil,
            container: container,
            location: location
        )
        
        return (entity, findableObject)
    }
    
    func createContainer(location: LootBoxLocation, sizeMultiplier: Float) -> LootBoxContainer? {
        let baseContainer = ChaliceLootContainer.create(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
        // Replace the open closure with our own implementation
        return LootBoxContainer(
            container: baseContainer.container,
            box: baseContainer.box,
            lid: baseContainer.lid,
            prize: baseContainer.prize,
            builtInAnimation: baseContainer.builtInAnimation,
            open: { container, onComplete in
                self.openChalice(container: container, onComplete: onComplete)
            }
        )
    }
    
    func animateFind(entity: ModelEntity, container: LootBoxContainer?, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        // Create confetti effect
        let parentEntity = container?.container.parent ?? entity.parent ?? entity
        let confettiPosition: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            let parentTransform = parentEntity.transformMatrix(relativeTo: nil)
            let parentWorldPos = SIMD3<Float>(
                parentTransform.columns.3.x,
                parentTransform.columns.3.y,
                parentTransform.columns.3.z
            )
            confettiPosition = tapPos - parentWorldPos
        } else {
            confettiPosition = entity.position
        }
        LootBoxAnimation.createConfettiEffect(at: confettiPosition, parent: parentEntity)
        
        // Play sound
        playFindSound()
        
        // Open the chalice
        if let container = container {
            openChalice(container: container, onComplete: onComplete)
        } else {
            onComplete()
        }
    }
    
    func animateLoop(entity: ModelEntity) {
        // Chalices don't have continuous loop animations
        // (They have floating animation managed by ChaliceLootContainer)
    }
    
    func playFindSound() {
        LootBoxAnimation.playOpeningSound()
    }
    
    private func openChalice(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        container.prize.isEnabled = true
        
        let prizeStartPos = container.prize.position
        let prizeEndPos = SIMD3<Float>(prizeStartPos.x, prizeStartPos.y + 0.4, prizeStartPos.z)
        
        let prizeTransform = Transform(
            scale: container.prize.scale,
            rotation: container.prize.orientation,
            translation: prizeEndPos
        )
        
        container.prize.move(
            to: prizeTransform,
            relativeTo: container.container,
            duration: 1.0,
            timingFunction: .easeOut
        )
        
        animatePrizeRotation(prize: container.prize, duration: 1.0)
        
        var completionCalled = false
        let safeCompletion = {
            if !completionCalled {
                completionCalled = true
                onComplete()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            safeCompletion()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            safeCompletion()
        }
    }
    
    private func animatePrizeRotation(prize: ModelEntity, duration: Float) {
        var currentRotation: Float = 0
        let rotationSpeed: Float = Float.pi * 2 / duration
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            currentRotation += rotationSpeed * 0.016
            if currentRotation >= Float.pi * 2 {
                timer.invalidate()
                prize.orientation = simd_quatf(angle: Float.pi * 2, axis: SIMD3<Float>(0, 1, 0))
            } else {
                prize.orientation = simd_quatf(angle: currentRotation, axis: SIMD3<Float>(0, 1, 0))
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration)) {
            timer.invalidate()
        }
    }
}

struct TreasureChestFactory: LootBoxFactory {
    var iconName: String { "shippingbox.fill" }
    var modelNames: [String] { ["Treasure_Chest"] }
    
    func itemDescription() -> String {
        return ["Treasure Chest", "Ancient Chest", "Locked Chest"].randomElement() ?? "Treasure Chest"
    }
    
    func createEntity(location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float) -> (entity: ModelEntity, findableObject: FindableObject) {
        let container = createContainer(location: location, sizeMultiplier: sizeMultiplier)!
        let entity = container.container
        entity.name = location.id
        entity.position = SIMD3<Float>(0, 0, 0)
        
        let findableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: nil,
            container: container,
            location: location
        )
        
        return (entity, findableObject)
    }
    
    func createContainer(location: LootBoxLocation, sizeMultiplier: Float) -> LootBoxContainer? {
        let baseContainer = BoxLootContainer.create(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
        return LootBoxContainer(
            container: baseContainer.container,
            box: baseContainer.box,
            lid: baseContainer.lid,
            prize: baseContainer.prize,
            builtInAnimation: baseContainer.builtInAnimation,
            open: { container, onComplete in
                self.openBox(container: container, onComplete: onComplete)
            }
        )
    }
    
    func animateFind(entity: ModelEntity, container: LootBoxContainer?, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        let parentEntity = container?.container.parent ?? entity.parent ?? entity
        let confettiPosition: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            let parentTransform = parentEntity.transformMatrix(relativeTo: nil)
            let parentWorldPos = SIMD3<Float>(
                parentTransform.columns.3.x,
                parentTransform.columns.3.y,
                parentTransform.columns.3.z
            )
            confettiPosition = tapPos - parentWorldPos
        } else {
            confettiPosition = entity.position
        }
        LootBoxAnimation.createConfettiEffect(at: confettiPosition, parent: parentEntity)
        playFindSound()
        
        if let container = container {
            openBox(container: container, onComplete: onComplete)
        } else {
            onComplete()
        }
    }
    
    func animateLoop(entity: ModelEntity) {
        // Treasure chests don't have continuous loop animations
    }
    
    func playFindSound() {
        LootBoxAnimation.playOpeningSound()
    }
    
    private func openBox(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        if let animation = container.builtInAnimation {
            let estimatedDuration: TimeInterval = 2.0
            var isLooping = true
            
            func loopAnimation() {
                guard isLooping else { return }
                let _ = container.box.playAnimation(animation, transitionDuration: 0.1, startsPaused: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration) {
                    loopAnimation()
                }
            }
            
            let _ = container.box.playAnimation(animation, transitionDuration: 0.2, startsPaused: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration) {
                loopAnimation()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration * 2.5) {
                isLooping = false
                container.prize.isEnabled = true
                self.animatePrizeReveal(container: container, onComplete: onComplete)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration * 4.0) {
                isLooping = false
                onComplete()
            }
            return
        }
        
        // Custom animation
        let lidPos = container.lid.position
        let isTreasureChest = lidPos.y > 0.1
        
        if isTreasureChest {
            let lidRotationAngle = -Float.pi / 2.5
            let lidOpenTransform = Transform(
                scale: container.lid.scale,
                rotation: simd_quatf(angle: lidRotationAngle, axis: SIMD3<Float>(1, 0, 0)),
                translation: lidPos
            )
            container.lid.move(to: lidOpenTransform, relativeTo: container.container, duration: 0.8, timingFunction: .easeOut)
        } else {
            let doorRotationAngle = Float.pi / 2.2
            let doorOpenTransform = Transform(
                scale: container.lid.scale,
                rotation: simd_quatf(angle: doorRotationAngle, axis: SIMD3<Float>(0, 1, 0)),
                translation: lidPos
            )
            container.lid.move(to: doorOpenTransform, relativeTo: container.container, duration: 0.8, timingFunction: .easeOut)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            container.prize.isEnabled = true
            self.animatePrizeReveal(container: container, onComplete: onComplete)
        }
    }
    
    private func animatePrizeReveal(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        let prizeStartPos = container.prize.position
        let prizeEndPos = SIMD3<Float>(prizeStartPos.x, prizeStartPos.y + 0.5, prizeStartPos.z)
        let prizeTransform = Transform(scale: container.prize.scale, rotation: container.prize.orientation, translation: prizeEndPos)
        container.prize.move(to: prizeTransform, relativeTo: container.container, duration: 1.2, timingFunction: .easeOut)
        animatePrizeRotation(prize: container.prize, duration: 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            onComplete()
        }
    }
    
    private func animatePrizeRotation(prize: ModelEntity, duration: Float) {
        var currentRotation: Float = 0
        let rotationSpeed: Float = Float.pi * 2 / duration
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            currentRotation += rotationSpeed * 0.016
            if currentRotation >= Float.pi * 2 {
                timer.invalidate()
                prize.orientation = simd_quatf(angle: Float.pi * 2, axis: SIMD3<Float>(0, 1, 0))
            } else {
                prize.orientation = simd_quatf(angle: currentRotation, axis: SIMD3<Float>(0, 1, 0))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration)) {
            timer.invalidate()
        }
    }
}

struct TempleRelicFactory: LootBoxFactory {
    var iconName: String { "building.columns.fill" }
    var modelNames: [String] { ["Stylised_Treasure_Chest", "Treasure_Chest"] }
    
    func itemDescription() -> String {
        return ["Temple Relic", "Sacred Relic", "Temple Treasure"].randomElement() ?? "Temple Relic"
    }
    
    func createEntity(location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float) -> (entity: ModelEntity, findableObject: FindableObject) {
        let container = createContainer(location: location, sizeMultiplier: sizeMultiplier)!
        let entity = container.container
        entity.name = location.id
        entity.position = SIMD3<Float>(0, 0, 0)
        
        let findableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: nil,
            container: container,
            location: location
        )
        
        return (entity, findableObject)
    }
    
    func createContainer(location: LootBoxLocation, sizeMultiplier: Float) -> LootBoxContainer? {
        let baseContainer = BoxLootContainer.create(type: location.type, id: location.id, sizeMultiplier: sizeMultiplier)
        return LootBoxContainer(
            container: baseContainer.container,
            box: baseContainer.box,
            lid: baseContainer.lid,
            prize: baseContainer.prize,
            builtInAnimation: baseContainer.builtInAnimation,
            open: { container, onComplete in
                self.openBox(container: container, onComplete: onComplete)
            }
        )
    }
    
    func animateFind(entity: ModelEntity, container: LootBoxContainer?, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        let parentEntity = container?.container.parent ?? entity.parent ?? entity
        let confettiPosition: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            let parentTransform = parentEntity.transformMatrix(relativeTo: nil)
            let parentWorldPos = SIMD3<Float>(
                parentTransform.columns.3.x,
                parentTransform.columns.3.y,
                parentTransform.columns.3.z
            )
            confettiPosition = tapPos - parentWorldPos
        } else {
            confettiPosition = entity.position
        }
        LootBoxAnimation.createConfettiEffect(at: confettiPosition, parent: parentEntity)
        playFindSound()
        
        if let container = container {
            openBox(container: container, onComplete: onComplete)
        } else {
            onComplete()
        }
    }
    
    func animateLoop(entity: ModelEntity) {
        // Temple relics don't have continuous loop animations
    }
    
    func playFindSound() {
        LootBoxAnimation.playOpeningSound()
    }
    
    private func openBox(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        if let animation = container.builtInAnimation {
            let estimatedDuration: TimeInterval = 2.0
            var isLooping = true
            
            func loopAnimation() {
                guard isLooping else { return }
                let _ = container.box.playAnimation(animation, transitionDuration: 0.1, startsPaused: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration) {
                    loopAnimation()
                }
            }
            
            let _ = container.box.playAnimation(animation, transitionDuration: 0.2, startsPaused: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration) {
                loopAnimation()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration * 2.5) {
                isLooping = false
                container.prize.isEnabled = true
                self.animatePrizeReveal(container: container, onComplete: onComplete)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedDuration * 4.0) {
                isLooping = false
                onComplete()
            }
            return
        }
        
        // Custom animation
        let lidPos = container.lid.position
        let isTreasureChest = lidPos.y > 0.1
        
        if isTreasureChest {
            let lidRotationAngle = -Float.pi / 2.5
            let lidOpenTransform = Transform(
                scale: container.lid.scale,
                rotation: simd_quatf(angle: lidRotationAngle, axis: SIMD3<Float>(1, 0, 0)),
                translation: lidPos
            )
            container.lid.move(to: lidOpenTransform, relativeTo: container.container, duration: 0.8, timingFunction: .easeOut)
        } else {
            let doorRotationAngle = Float.pi / 2.2
            let doorOpenTransform = Transform(
                scale: container.lid.scale,
                rotation: simd_quatf(angle: doorRotationAngle, axis: SIMD3<Float>(0, 1, 0)),
                translation: lidPos
            )
            container.lid.move(to: doorOpenTransform, relativeTo: container.container, duration: 0.8, timingFunction: .easeOut)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            container.prize.isEnabled = true
            self.animatePrizeReveal(container: container, onComplete: onComplete)
        }
    }
    
    private func animatePrizeReveal(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        let prizeStartPos = container.prize.position
        let prizeEndPos = SIMD3<Float>(prizeStartPos.x, prizeStartPos.y + 0.5, prizeStartPos.z)
        let prizeTransform = Transform(scale: container.prize.scale, rotation: container.prize.orientation, translation: prizeEndPos)
        container.prize.move(to: prizeTransform, relativeTo: container.container, duration: 1.2, timingFunction: .easeOut)
        animatePrizeRotation(prize: container.prize, duration: 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            onComplete()
        }
    }
    
    private func animatePrizeRotation(prize: ModelEntity, duration: Float) {
        var currentRotation: Float = 0
        let rotationSpeed: Float = Float.pi * 2 / duration
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            currentRotation += rotationSpeed * 0.016
            if currentRotation >= Float.pi * 2 {
                timer.invalidate()
                prize.orientation = simd_quatf(angle: Float.pi * 2, axis: SIMD3<Float>(0, 1, 0))
            } else {
                prize.orientation = simd_quatf(angle: currentRotation, axis: SIMD3<Float>(0, 1, 0))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration)) {
            timer.invalidate()
        }
    }
}

struct SphereFactory: LootBoxFactory {
    var iconName: String { "circle.fill" }
    var modelNames: [String] { [] }
    
    func itemDescription() -> String {
        return "Mysterious Sphere"
    }
    
    func createEntity(location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float) -> (entity: ModelEntity, findableObject: FindableObject) {
        let sphereRadius = Float.random(in: 0.15...0.3)
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        
        sphereMaterial.color = .init(tint: location.type.color)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = location.id
        sphere.position = SIMD3<Float>(0, sphereRadius, 0)

        let light = PointLightComponent(color: location.type.glowColor, intensity: 200)
        sphere.components.set(light)

        let findableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: nil,
            location: location
        )
        
        return (sphere, findableObject)
    }
    
    func createContainer(location: LootBoxLocation, sizeMultiplier: Float) -> LootBoxContainer? {
        return nil // Spheres don't use containers
    }
    
    func animateFind(entity: ModelEntity, container: LootBoxContainer?, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        let parentEntity = entity.parent ?? entity
        let confettiPosition: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            let parentTransform = parentEntity.transformMatrix(relativeTo: nil)
            let parentWorldPos = SIMD3<Float>(
                parentTransform.columns.3.x,
                parentTransform.columns.3.y,
                parentTransform.columns.3.z
            )
            confettiPosition = tapPos - parentWorldPos
        } else {
            confettiPosition = entity.position
        }
        LootBoxAnimation.createConfettiEffect(at: confettiPosition, parent: parentEntity)
        playFindSound()
        animateSphereFind(orb: entity, onComplete: onComplete)
    }
    
    func animateLoop(entity: ModelEntity) {
        // Spheres don't have continuous loop animations
    }
    
    func playFindSound() {
        LootBoxAnimation.playOpeningSound()
    }
    
    private func animateSphereFind(orb: ModelEntity, onComplete: @escaping () -> Void) {
        let startScale = orb.scale
        let growDuration: TimeInterval = 0.5
        let shrinkDuration: TimeInterval = 0.3
        let totalDuration = growDuration + shrinkDuration
        
        var elapsed: TimeInterval = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            elapsed += 0.016
            let totalProgress = elapsed / totalDuration
            
            if elapsed <= growDuration {
                let growProgress = Float(min(elapsed / growDuration, 1.0))
                let easedProgress = 1.0 - pow(1.0 - growProgress, 3.0)
                let scale = startScale * (1.0 + 0.25 * easedProgress)
                orb.scale = scale
            } else {
                let shrinkProgress = Float((elapsed - growDuration) / shrinkDuration)
                let easedProgress = pow(shrinkProgress, 3.0)
                let scale = startScale * 1.25 * (1.0 - easedProgress)
                orb.scale = scale
                
                let fadeProgress = shrinkProgress
                if var model = orb.model {
                    var materials: [RealityKit.Material] = []
                    for material in model.materials {
                        if var simpleMaterial = material as? SimpleMaterial {
                            let alpha = 1.0 - CGFloat(fadeProgress)
                            simpleMaterial.color = .init(tint: simpleMaterial.color.tint.withAlphaComponent(alpha))
                            materials.append(simpleMaterial)
                        } else {
                            materials.append(material)
                        }
                    }
                    model.materials = materials
                    orb.model = model
                }
                
                if var light = orb.components[PointLightComponent.self] {
                    light.intensity = Float(200 * (1.0 - fadeProgress))
                    orb.components[PointLightComponent.self] = light
                }
            }
            
            if totalProgress >= 1.0 {
                timer.invalidate()
                orb.isEnabled = false
                onComplete()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            timer.invalidate()
        }
    }
}

struct CubeFactory: LootBoxFactory {
    var iconName: String { "cube.fill" }
    var modelNames: [String] { [] }
    
    func itemDescription() -> String {
        return "Mysterious Cube"
    }
    
    func createEntity(location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float) -> (entity: ModelEntity, findableObject: FindableObject) {
        let cubeSize = Float.random(in: 0.15...0.3)
        let cubeMesh = MeshResource.generateBox(width: cubeSize, height: cubeSize, depth: cubeSize, cornerRadius: 0.01)
        
        // Use UnlitMaterial for translucent glow effect (ignores external lighting, glows from within)
        var cubeMaterial = UnlitMaterial()
        let sourceColor = location.type.color
        
        // Extract RGB components from UIColor
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        sourceColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        cubeMaterial.color = .init(
            tint: UIColor(
                red: red,
                green: green,
                blue: blue,
                alpha: 0.8 // Semi-transparent for translucency effect
            )
        )
        
        let cube = ModelEntity(mesh: cubeMesh, materials: [cubeMaterial])
        cube.name = location.id
        cube.position = SIMD3<Float>(0, cubeSize / 2, 0)

        // Add point light INSIDE the cube for internal glow effect
        let lightEntity = ModelEntity()
        lightEntity.position = SIMD3<Float>(0, 0, 0) // Center of cube
        let internalLight = PointLightComponent(color: location.type.glowColor, intensity: 800)
        lightEntity.components.set(internalLight)
        cube.addChild(lightEntity)

        // Start continuous loop animation (rotation for cubes)
        animateLoop(entity: cube)

        let findableObject = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: cube,
            container: nil,
            location: location
        )
        
        return (cube, findableObject)
    }
    
    func createContainer(location: LootBoxLocation, sizeMultiplier: Float) -> LootBoxContainer? {
        return nil // Cubes don't use containers
    }
    
    func animateFind(entity: ModelEntity, container: LootBoxContainer?, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        let parentEntity = entity.parent ?? entity
        let confettiPosition: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            let parentTransform = parentEntity.transformMatrix(relativeTo: nil)
            let parentWorldPos = SIMD3<Float>(
                parentTransform.columns.3.x,
                parentTransform.columns.3.y,
                parentTransform.columns.3.z
            )
            confettiPosition = tapPos - parentWorldPos
        } else {
            confettiPosition = entity.position
        }
        LootBoxAnimation.createConfettiEffect(at: confettiPosition, parent: parentEntity)
        playFindSound()
        
        // Simple fade out animation for cubes
        entity.move(
            to: Transform(scale: SIMD3<Float>(0, 0, 0), rotation: entity.orientation, translation: entity.position),
            relativeTo: entity.parent,
            duration: 0.5,
            timingFunction: .easeOut
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            onComplete()
        }
    }
    
    func animateLoop(entity: ModelEntity) {
        // Continuous slow rotation animation for cubes
        var currentRotation: Float = 0
        let rotationSpeed: Float = Float.pi * 2 / 10.0 // One full rotation every 10 seconds (slow)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak entity] timer in
            // Check if entity still exists and is enabled
            guard let entity = entity, entity.parent != nil, entity.isEnabled else {
                timer.invalidate()
                return
            }
            
            currentRotation += rotationSpeed * 0.016
            // Keep rotation in 0 to 2π range to prevent overflow
            if currentRotation >= Float.pi * 2 {
                currentRotation -= Float.pi * 2
            }
            
            // Rotate around Y axis (vertical axis)
            entity.orientation = simd_quatf(angle: currentRotation, axis: SIMD3<Float>(0, 1, 0))
        }
        
        // Store timer reference to prevent deallocation
        RunLoop.current.add(timer, forMode: .common)
    }
    
    func playFindSound() {
        LootBoxAnimation.playOpeningSound()
    }
}

// MARK: - LootBoxType Extension for Factory Access
extension LootBoxType {
    /// Returns the factory for this loot box type
    var factory: LootBoxFactory {
        switch self {
        case .chalice:
            return ChaliceFactory()
        case .treasureChest:
            return TreasureChestFactory()
        case .templeRelic:
            return TempleRelicFactory()
        case .sphere:
            return SphereFactory()
        case .cube:
            return CubeFactory()
        }
    }
}

