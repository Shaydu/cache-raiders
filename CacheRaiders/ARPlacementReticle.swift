import Foundation
import RealityKit
import ARKit
import Combine

/// Manages a visual reticle/cursor that shows where objects will be placed
class ARPlacementReticle: ObservableObject {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?

    private var reticleAnchor: AnchorEntity?
    private var reticleEntity: ModelEntity?
    private var distanceLabel: ModelEntity?

    private var isActive: Bool = false

    // Smoothing/easing for reticle movement
    private var targetPosition: SIMD3<Float>?
    private let smoothingFactor: Float = 0.15 // Lower = smoother but slower (0.0-1.0)

    // Published properties for SwiftUI binding
    @Published var currentPosition: SIMD3<Float>?
    @Published var distanceFromCamera: Float?
    @Published var heightFromGround: Float?

    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        self.arView = arView
        self.locationManager = locationManager

        // Listen for ambient light setting changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ambientLightSettingChanged),
            name: NSNotification.Name("AmbientLightSettingChanged"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Shows the placement reticle
    func show() {
        guard let arView = arView else { return }

        isActive = true

        // Create reticle if it doesn't exist
        if reticleAnchor == nil {
            createReticle(in: arView)
        }

        // Make visible
        reticleEntity?.isEnabled = true
        distanceLabel?.isEnabled = true

        Swift.print("✅ Placement reticle shown")
    }

    /// Hides the placement reticle
    func hide() {
        isActive = false
        reticleEntity?.isEnabled = false
        distanceLabel?.isEnabled = false

        Swift.print("⏹️ Placement reticle hidden")
    }

    /// Updates the reticle position to show where an object would be placed
    /// Call this every frame when placement mode is active
    func update() {
        guard isActive,
              let arView = arView,
              let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Raycast from center of screen to find placement surface
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

        if let raycastResult = arView.raycast(from: screenCenter, allowing: .estimatedPlane, alignment: .horizontal).first {
            // Found a surface - place reticle on it
            let hitY = raycastResult.worldTransform.columns.3.y

            // Only show if surface is below camera (not a ceiling)
            if hitY < cameraPos.y - 0.2 {
                let hitPosition = SIMD3<Float>(
                    raycastResult.worldTransform.columns.3.x,
                    raycastResult.worldTransform.columns.3.y,
                    raycastResult.worldTransform.columns.3.z
                )

                updateReticlePosition(hitPosition, cameraPos: cameraPos)
                return
            }
        }

        // No surface found - place reticle at fixed distance from camera
        let forward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        let distance: Float = 2.0 // 2 meters in front of camera
        let targetPosition = cameraPos + forward * distance

        // Adjust Y to be at reasonable ground height
        let groundY = cameraPos.y - 1.5
        let adjustedPosition = SIMD3<Float>(targetPosition.x, groundY, targetPosition.z)

        updateReticlePosition(adjustedPosition, cameraPos: cameraPos)
    }

    /// Gets the current placement position (where object would be placed)
    func getPlacementPosition() -> SIMD3<Float>? {
        guard let anchor = reticleAnchor else { return nil }
        // Get anchor's world position using transform matrix
        // The reticle entity has a Y offset of 0.01m for visibility, but X/Z are at anchor origin
        let transform = anchor.transformMatrix(relativeTo: nil)
        let anchorWorldPos = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y, // Anchor Y (ground level)
            transform.columns.3.z
        )
        return anchorWorldPos
    }

    /// Gets the distance from camera to placement point
    func getPlacementDistance() -> Float? {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let placementPos = getPlacementPosition() else { return nil }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        return length(placementPos - cameraPos)
    }

    // MARK: - Private Methods

    private func createReticle(in arView: ARView) {
        // Create anchor at origin (will be moved)
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))

        // Create reticle visual - a glowing ring with crosshairs
        let reticle = createReticleVisual()
        reticle.position = SIMD3<Float>(0, 0.01, 0) // Slightly above ground to prevent z-fighting

        anchor.addChild(reticle)
        arView.scene.addAnchor(anchor)

        self.reticleAnchor = anchor
        self.reticleEntity = reticle

        // Initially hidden
        reticle.isEnabled = false
    }

    private func createReticleVisual() -> ModelEntity {
        // Create a ring shape for the reticle
        let outerRadius: Float = 0.15
        let _: Float = 0.12 // Inner radius (unused - box mesh used instead of ring)
        let thickness: Float = 0.01

        // Create ring mesh (torus)
        let ringMesh = MeshResource.generateBox(width: outerRadius * 2, height: thickness, depth: outerRadius * 2)

        // Material - adaptive based on ambient light setting
        let material = createAdaptiveMaterial()

        let reticle = ModelEntity(mesh: ringMesh, materials: [material])

        // Add crosshairs
        let crosshairLength: Float = outerRadius
        let crosshairThickness: Float = 0.005

        // Horizontal crosshair
        let hCrosshair = MeshResource.generateBox(width: crosshairLength * 2, height: thickness, depth: crosshairThickness)
        let crosshairMaterial = createAdaptiveCrosshairMaterial()
        let hLine = ModelEntity(mesh: hCrosshair, materials: [crosshairMaterial])
        hLine.position = SIMD3<Float>(0, 0.005, 0)
        reticle.addChild(hLine)

        // Vertical crosshair
        let vCrosshair = MeshResource.generateBox(width: crosshairThickness, height: thickness, depth: crosshairLength * 2)
        let vLine = ModelEntity(mesh: vCrosshair, materials: [crosshairMaterial])
        vLine.position = SIMD3<Float>(0, 0.005, 0)
        reticle.addChild(vLine)

        // Add point light for glow effect - adaptive intensity
        let disableAmbient = locationManager?.disableAmbientLight ?? false
        let lightIntensity: Float = disableAmbient ? 300 : 100 // Brighter in dark environments
        let light = PointLightComponent(color: UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0), intensity: lightIntensity)
        reticle.components.set(light)

        // Pulse animation
        let duration: Float = 1.0
        let scaleAnimation = FromToByAnimation(
            name: "pulse",
            from: Transform(scale: SIMD3<Float>(1.0, 1.0, 1.0)),
            to: Transform(scale: SIMD3<Float>(1.1, 1.0, 1.1)),
            duration: TimeInterval(duration),
            timing: .easeInOut,
            isAdditive: false,
            bindTarget: .transform,
            repeatMode: .repeat
        )

        if let resource = try? AnimationResource.generate(with: scaleAnimation) {
            reticle.playAnimation(resource)
        }

        return reticle
    }

    private func updateReticlePosition(_ position: SIMD3<Float>, cameraPos: SIMD3<Float>) {
        guard let anchor = reticleAnchor else { return }

        // Store target position for smooth interpolation
        targetPosition = position

        // Get current position
        let currentPos = anchor.transform.translation

        // Smooth interpolation (lerp) between current and target
        // This creates an easing effect that follows the camera smoothly
        let smoothedPosition = currentPos + (position - currentPos) * smoothingFactor

        // Update anchor position with smoothed value
        anchor.transform.translation = smoothedPosition

        // Calculate distance using smoothed position for consistency
        let distance = length(smoothedPosition - cameraPos)

        // Calculate height from ground (assuming camera is at eye level, ground is ~1.5m below)
        let estimatedGroundY = cameraPos.y - 1.5
        let heightFromGround = smoothedPosition.y - estimatedGroundY

        // Publish updated values for SwiftUI using smoothed position
        DispatchQueue.main.async { [weak self] in
            self?.currentPosition = smoothedPosition
            self?.distanceFromCamera = distance
            self?.heightFromGround = heightFromGround
        }

        // Update visual feedback based on distance
        if let reticle = reticleEntity {
            // Change color based on placement validity
            if distance < 1.5 {
                // Too close - red
                updateReticleColor(reticle, color: UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.6))
            } else if distance > 10.0 {
                // Too far - yellow
                updateReticleColor(reticle, color: UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.6))
            } else {
                // Good distance - blue/green
                updateReticleColor(reticle, color: UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.6))
            }
        }
    }

    private func updateReticleColor(_ reticle: ModelEntity, color: UIColor) {
        var material = SimpleMaterial()
        material.color = .init(tint: color)
        material.roughness = 0.0
        material.metallic = 1.0
        reticle.model?.materials = [material]
    }

    /// Cleans up resources
    func cleanup() {
        reticleAnchor?.removeFromParent()
        reticleAnchor = nil
        reticleEntity = nil
        distanceLabel = nil
    }

    // MARK: - Adaptive Lighting Support

    /// Creates material that adapts to ambient light settings
    private func createAdaptiveMaterial() -> Material {
        let disableAmbient = locationManager?.disableAmbientLight ?? false

        if disableAmbient {
            // Use UnlitMaterial for visibility in dark environments
            var unlitMaterial = UnlitMaterial()
            unlitMaterial.color = .init(tint: UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.8))
            return unlitMaterial
        } else {
            // Use SimpleMaterial for normal lighting conditions
            var material = SimpleMaterial()
            material.color = .init(tint: UIColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.6))
            material.roughness = 0.0
            material.metallic = 1.0
            return material
        }
    }

    /// Creates crosshair material that adapts to ambient light settings
    private func createAdaptiveCrosshairMaterial() -> Material {
        let disableAmbient = locationManager?.disableAmbientLight ?? false

        if disableAmbient {
            // Use UnlitMaterial for visibility in dark environments
            var unlitMaterial = UnlitMaterial()
            unlitMaterial.color = .init(tint: UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0))
            return unlitMaterial
        } else {
            // Use SimpleMaterial for normal lighting conditions
            var material = SimpleMaterial()
            material.color = .init(tint: UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.8))
            material.roughness = 0.0
            material.metallic = 1.0
            return material
        }
    }

    /// Updates reticle materials when ambient light setting changes
    @objc private func ambientLightSettingChanged() {
        guard let reticle = reticleEntity else { return }

        // Update main reticle material
        let newMaterial = createAdaptiveMaterial()
        if var model = reticle.model {
            model.materials = [newMaterial]
            reticle.model = model
        }

        // Update crosshair materials
        let newCrosshairMaterial = createAdaptiveCrosshairMaterial()
        for child in reticle.children {
            if let modelEntity = child as? ModelEntity,
               var model = modelEntity.model {
                model.materials = [newCrosshairMaterial]
                modelEntity.model = model
            }
        }

        // Update light intensity
        let disableAmbient = locationManager?.disableAmbientLight ?? false
        let lightIntensity: Float = disableAmbient ? 300 : 100
        let light = PointLightComponent(color: UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0), intensity: lightIntensity)
        reticle.components.set(light)

        Swift.print("🔄 Reticle materials and lighting updated for ambient light setting change")
    }
}
