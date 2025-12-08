import RealityKit
import UIKit

// MARK: - Model Entity Factory
/// Factory for creating and animating 3D model entities from USDZ files
class ModelEntityFactory {

    // MARK: - Model Creation

    /// Creates a ModelEntity from a USDZ model file with specified size and colors
    /// - Parameters:
    ///   - modelName: Name of the USDZ model file (without extension)
    ///   - size: Target size for the model
    ///   - color: Base color for the model
    ///   - glowColor: Glow color for the model
    /// - Returns: Configured ModelEntity
    static func createModelEntity(modelName: String, size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        do {
            // Load the USDZ model
            let modelEntity = try ModelEntity.loadModel(named: modelName)

            // Scale the model to the desired size
            let currentBounds = modelEntity.model?.mesh.bounds ?? BoundingBox(min: .zero, max: SIMD3<Float>(1, 1, 1))
            let currentSize = currentBounds.max - currentBounds.min
            let maxDimension = max(currentSize.x, max(currentSize.y, currentSize.z))
            let scale = size / maxDimension
            modelEntity.scale = SIMD3<Float>(repeating: scale)

            // Apply materials
            applyMaterials(to: modelEntity, baseColor: color, glowColor: glowColor)

            // Add glow effect
            addGlowEffect(to: modelEntity, glowColor: glowColor)

            return modelEntity

        } catch {
            Swift.print("❌ Failed to load model '\(modelName)': \(error)")

            // Fallback: create a simple colored box
            return createFallbackModel(size: size, color: color, glowColor: glowColor)
        }
    }

    // MARK: - Material Application

    private static func applyMaterials(to entity: ModelEntity, baseColor: UIColor, glowColor: UIColor) {
        // Apply base material to the model
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: baseColor)
        material.roughness = 0.7
        material.metallic = 0.3

        entity.model?.materials = [material]
    }

    private static func addGlowEffect(to entity: ModelEntity, glowColor: UIColor) {
        // Add point light for glow effect
        let light = PointLightComponent(color: glowColor, intensity: 300)
        entity.components.set(light)

        // Add subtle emissive material for glow
        if var material = entity.model?.materials.first as? PhysicallyBasedMaterial {
            material.emissiveColor = .init(color: glowColor.withAlphaComponent(0.3))
            entity.model?.materials = [material]
        }
    }

    private static func createFallbackModel(size: Float, color: UIColor, glowColor: UIColor) -> ModelEntity {
        // Create a simple box as fallback
        let mesh = MeshResource.generateBox(size: size, cornerRadius: size * 0.1)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.7
        material.metallic = 0.3
        material.emissiveColor = .init(color: glowColor.withAlphaComponent(0.2))

        let modelEntity = ModelEntity(mesh: mesh, materials: [material])

        // Add light for glow
        let light = PointLightComponent(color: glowColor, intensity: 200)
        modelEntity.components.set(light)

        return modelEntity
    }

    // MARK: - Animation Methods

    /// Animates the model when it's found (discovery animation)
    /// - Parameters:
    ///   - entity: The model entity to animate
    ///   - tapWorldPosition: Optional world position where user tapped
    ///   - onComplete: Completion callback
    static func animateModelFind(entity: ModelEntity, tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        // Scale up animation
        let scaleUp = entity.scale * 1.2
        let scaleAnimation = FromToByAnimation< SIMD3<Float> >(
            from: entity.scale,
            to: scaleUp,
            duration: 0.3,
            timing: .easeInOut
        )

        // Rotate animation
        let rotateAnimation = FromToByAnimation<simd_quatf>(
            from: entity.orientation,
            to: entity.orientation * simd_quatf(angle: .pi * 2, axis: SIMD3<Float>(0, 1, 0)),
            duration: 0.5,
            timing: .easeInOut
        )

        // Play animations
        if let scaleResource = try? AnimationResource.generate(with: scaleAnimation) {
            entity.playAnimation(scaleResource)
        }
        if let rotateResource = try? AnimationResource.generate(with: rotateAnimation) {
            entity.playAnimation(rotateResource)
        }

        // Return to normal scale after animations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let scaleDown = FromToByAnimation< SIMD3<Float> >(
                from: scaleUp,
                to: entity.scale / 1.2,
                duration: 0.3,
                timing: .easeInOut
            )
            if let scaleDownResource = try? AnimationResource.generate(with: scaleDown) {
                entity.playAnimation(scaleDownResource)
            }

            // Call completion after all animations finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onComplete()
            }
        }
    }

    /// Starts a continuous loop animation for the model (idle animation)
    /// - Parameter entity: The model entity to animate
    static func animateModelLoop(entity: ModelEntity) {
        // Gentle floating animation
        let originalPosition = entity.position
        var offset: Float = 0

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak entity] timer in
            guard let entity = entity, entity.parent != nil else {
                timer.invalidate()
                return
            }

            offset += 0.02
            let floatOffset = sin(offset) * 0.05
            entity.position = SIMD3<Float>(
                originalPosition.x,
                originalPosition.y + floatOffset,
                originalPosition.z
            )
        }

        // Gentle rotation
        let rotationAnimation = FromToByAnimation<simd_quatf>(
            from: entity.orientation,
            to: entity.orientation * simd_quatf(angle: .pi * 2, axis: SIMD3<Float>(0, 1, 0)),
            duration: 8.0,
            timing: .linear
        )

        // Loop the rotation indefinitely
        if let rotationResource = try? AnimationResource.generate(with: rotationAnimation) {
            entity.playAnimation(rotationResource.repeat())
        }
    }
}