import Foundation
import RealityKit
import ARKit
import simd

// MARK: - AR Direction Arrow
/// Creates and manages a 3D arrow that points to the nearest loot box
class ARDirectionArrow {
    weak var arView: ARView?
    private var arrowEntity: ModelEntity?
    private var arrowAnchor: AnchorEntity?
    
    init(arView: ARView?) {
        self.arView = arView
    }
    
    /// Creates a 3D arrow entity pointing forward
    private func createArrowEntity() -> ModelEntity {
        // Create arrow shape using a cone for the tip and a cylinder for the shaft
        let arrowLength: Float = 0.3 // 30cm arrow
        let arrowWidth: Float = 0.05 // 5cm wide
        let tipLength: Float = 0.1 // 10cm tip
        
        // Create arrow tip (cone pointing forward)
        let tipMesh = MeshResource.generateCone(
            height: tipLength,
            radius: arrowWidth * 1.5
        )
        
        // Create arrow shaft (cylinder)
        let shaftMesh = MeshResource.generateCylinder(
            height: arrowLength - tipLength,
            radius: arrowWidth * 0.5
        )
        
        // Create materials - bright, visible color
        var arrowMaterial = SimpleMaterial()
        arrowMaterial.color = .init(tint: UIColor.systemBlue)
        arrowMaterial.roughness = 0.2
        arrowMaterial.metallic = 0.8
        
        // Create tip entity
        let tipEntity = ModelEntity(mesh: tipMesh, materials: [arrowMaterial])
        tipEntity.position = SIMD3<Float>(0, 0, arrowLength / 2 - tipLength / 2)
        
        // Create shaft entity
        let shaftEntity = ModelEntity(mesh: shaftMesh, materials: [arrowMaterial])
        shaftEntity.position = SIMD3<Float>(0, 0, -(arrowLength - tipLength) / 2)
        
        // Create parent entity to hold both parts
        let arrowEntity = ModelEntity()
        arrowEntity.addChild(tipEntity)
        arrowEntity.addChild(shaftEntity)
        
        // Add a subtle glow effect with a point light
        let light = PointLightComponent(color: .blue, intensity: 100)
        arrowEntity.components.set(light)
        
        return arrowEntity
    }
    
    /// Updates the arrow to point toward the nearest object
    /// - Parameters:
    ///   - targetPosition: Position of the nearest object in AR world space
    ///   - cameraPosition: Current camera position
    ///   - cameraTransform: Current camera transform matrix
    ///   - userHeading: Optional user's compass heading in degrees (0 = north, 90 = east, etc.)
    func updateArrow(targetPosition: SIMD3<Float>, cameraPosition: SIMD3<Float>, cameraTransform: simd_float4x4, userHeading: Double? = nil) {
        guard let arView = arView else { return }
        
        // Calculate direction from camera to target
        let directionToTarget = targetPosition - cameraPosition
        let horizontalDirection = SIMD3<Float>(directionToTarget.x, 0, directionToTarget.z)
        
        // Check if target is too close or directly above/below
        let horizontalDistance = length(horizontalDirection)
        guard horizontalDistance > 0.1 else {
            // Target is directly above/below - hide arrow
            hideArrow()
            return
        }
        
        // Normalize direction
        let normalizedDirection = normalize(horizontalDirection)
        
        // Position arrow 1.5 meters in front of camera, slightly below center
        let arrowDistance: Float = 1.5
        let arrowOffsetY: Float = -0.3 // Slightly below center for better visibility
        
        // Get camera forward direction (normalized, horizontal only)
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            0,
            -cameraTransform.columns.2.z
        )

        // Use user's compass heading to align navigation with real world direction
        // This matches the admin panel's calculation (heading + 180° adjustment)
        var normalizedForward = normalize(cameraForward)
        if let userHeading = userHeading {
            // Convert compass heading to radians and add 180° (same as admin panel)
            let adjustedHeadingRadians = (userHeading + 180.0) * .pi / 180.0

            // Create a forward vector aligned with user's compass heading
            // In AR space: -Z is typically north, +X is east
            let compassForwardX = Float(sin(adjustedHeadingRadians))  // East component
            let compassForwardZ = Float(-cos(adjustedHeadingRadians)) // North component (negative because -Z is north)
            normalizedForward = SIMD3<Float>(compassForwardX, 0, compassForwardZ)
        }
        
        // Position arrow in front of camera
        let arrowPosition = cameraPosition + normalizedForward * arrowDistance + SIMD3<Float>(0, arrowOffsetY, 0)
        
        // Create or get arrow entity
        if arrowEntity == nil {
            arrowEntity = createArrowEntity()
        }
        
        guard let arrow = arrowEntity else { return }
        
        // Calculate rotation to point toward target
        // The arrow should point in the direction of normalizedDirection
        // Arrow's default forward is +Z, so we need to rotate it
        let targetDirection = normalizedDirection
        
        // Calculate angle between camera forward and target direction
        let forwardDot = dot(normalizedForward, targetDirection)
        let forwardCross = cross(normalizedForward, targetDirection)
        
        // Calculate rotation angle
        let angle = acos(min(max(forwardDot, -1.0), 1.0))
        
        // Determine rotation axis (Y-axis for horizontal rotation)
        let rotationAxis = SIMD3<Float>(0, 1, 0)
        
        // Check if we need to flip the rotation direction
        let rotationDirection: Float = forwardCross.y < 0 ? -1.0 : 1.0

        // Create rotation quaternion
        let rotation = simd_quatf(angle: angle * rotationDirection, axis: rotationAxis)
        arrow.orientation = rotation
        
        // Create or update anchor
        if arrowAnchor == nil {
            arrowAnchor = AnchorEntity(world: arrowPosition)
            arrowAnchor!.addChild(arrow)
            arView.scene.addAnchor(arrowAnchor!)
        } else {
            // Update anchor position to follow camera
            arrowAnchor!.position = arrowPosition
        }
        
        // Make arrow visible
        arrow.isEnabled = true
    }
    
    /// Hides the arrow (when no target or target is too close)
    func hideArrow() {
        arrowEntity?.isEnabled = false
    }
    
    /// Shows the arrow
    func showArrow() {
        arrowEntity?.isEnabled = true
    }
    
    /// Removes the arrow from the scene
    func removeArrow() {
        arrowAnchor?.removeFromParent()
        arrowAnchor = nil
        arrowEntity = nil
    }
}

