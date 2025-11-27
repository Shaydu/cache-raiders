import RealityKit
import ARKit
import UIKit

// MARK: - AR Lighting Service
/// Manages lighting in AR scenes to ensure proper shading, colors, and rendering
/// Provides directional light (sun), ambient light, and image-based lighting
class ARLightingService {
    weak var arView: ARView?
    private var sunAnchor: AnchorEntity?
    private var ambientLightAnchor: AnchorEntity?

    /// Whether ambient lighting is currently disabled
    private var isAmbientLightingDisabled: Bool = false

    init(arView: ARView?) {
        self.arView = arView
    }

    /// Sets up all lighting for the AR scene
    /// - Parameter disableAmbient: If true, disables ambient/environment lighting (but keeps directional light for visibility)
    func setupLighting(disableAmbient: Bool = false) {
        guard let arView = arView else {
            Swift.print("⚠️ ARLightingService: No AR view available")
            return
        }

        isAmbientLightingDisabled = disableAmbient

        // Remove existing lights if re-initializing
        removeLighting()

        // 1. Add directional light (sun) - CRITICAL for proper shading and colors
        addDirectionalLight(to: arView)

        // 2. Add ambient light for fill lighting (unless disabled)
        if !disableAmbient {
            addAmbientLight(to: arView)
        }

        // 3. Configure image-based lighting for realistic reflections (unless disabled)
        if !disableAmbient {
            configureImageBasedLighting(for: arView)
        } else {
            // Even with ambient disabled, set a minimal IBL for basic reflections
            configureMinimalImageBasedLighting(for: arView)
        }

        Swift.print("✅ ARLightingService: Lighting setup complete (ambient disabled: \(disableAmbient))")
    }

    /// Adds a directional light (sun) to the scene
    /// This is the primary light source that creates shadows and defines object form
    private func addDirectionalLight(to arView: ARView) {
        // Create directional light entity (acts like the sun)
        let sunlight = DirectionalLight()

        // Configure light properties
        sunlight.light.color = .white
        sunlight.light.intensity = 2000 // Bright sunlight (lumens)
        sunlight.light.isRealWorldProxy = false // This is a virtual light, not tracking real sun

        // Enable shadows for depth and realism
        sunlight.shadow = DirectionalLightComponent.Shadow(
            maximumDistance: 10.0, // Shadow distance in meters
            depthBias: 2.0 // Prevents shadow acne
        )

        // Position the sun at an angle (45 degrees from above, slightly to the side)
        // This creates nice shading that defines object shapes
        let angleFromAbove: Float = -.pi / 3 // 60 degrees from horizontal
        let sideAngle: Float = .pi / 4 // 45 degrees rotation around Y axis

        // Combine rotations: first tilt down, then rotate around
        let tiltRotation = simd_quatf(angle: angleFromAbove, axis: [1, 0, 0])
        let turnRotation = simd_quatf(angle: sideAngle, axis: [0, 1, 0])
        sunlight.orientation = turnRotation * tiltRotation

        // Create anchor for the sun (positioned at world origin, orientation matters not position)
        sunAnchor = AnchorEntity(world: .zero)
        sunAnchor?.addChild(sunlight)
        arView.scene.addAnchor(sunAnchor!)

        Swift.print("✅ Directional light (sun) added - intensity: \(sunlight.light.intensity) lumens")
    }

    /// Adds ambient light for fill lighting (soft light that prevents pure black shadows)
    private func addAmbientLight(to arView: ARView) {
        // Create ambient light entity (provides base illumination from all directions)
        let ambientLight = PointLightComponent(
            color: UIColor(white: 0.95, alpha: 1.0), // Slightly warm white
            intensity: 300, // Moderate intensity - fills shadows without overpowering
            attenuationRadius: 100.0 // Very large radius (essentially infinite for our purposes)
        )

        // Create entity to hold the ambient light
        let ambientEntity = Entity()
        ambientEntity.components.set(ambientLight)
        ambientEntity.position = [0, 2, 0] // Position 2 meters above origin

        // Create anchor for ambient light
        ambientLightAnchor = AnchorEntity(world: .zero)
        ambientLightAnchor?.addChild(ambientEntity)
        arView.scene.addAnchor(ambientLightAnchor!)

        Swift.print("✅ Ambient light added - intensity: \(ambientLight.intensity) lumens")
    }

    /// Configures image-based lighting (IBL) for realistic reflections and ambient lighting
    /// IBL uses the real environment to light virtual objects
    private func configureImageBasedLighting(for arView: ARView) {
        // Use automatic environment probe (captures real world lighting)
        // This is enabled by ARWorldTrackingConfiguration.environmentTexturing = .automatic

        // Boost the intensity of environment lighting for better visibility
        arView.environment.lighting.intensityExponent = 1.5 // 50% brighter than default

        // Use the camera feed's lighting information
        // This is already handled by environmentTexturing = .automatic in ARWorldTrackingConfiguration

        Swift.print("✅ Image-based lighting configured - intensity exponent: 1.5")
    }

    /// Configures minimal IBL even when ambient lighting is disabled
    /// This ensures objects still have basic reflections and aren't completely flat
    private func configureMinimalImageBasedLighting(for arView: ARView) {
        // Use a much lower intensity when ambient is disabled
        arView.environment.lighting.intensityExponent = 0.5 // 50% of default (quite dim)

        Swift.print("✅ Minimal image-based lighting configured - intensity exponent: 0.5")
    }

    /// Removes all lighting from the scene
    func removeLighting() {
        if let sunAnchor = sunAnchor {
            arView?.scene.removeAnchor(sunAnchor)
            self.sunAnchor = nil
            Swift.print("🧹 Removed directional light")
        }

        if let ambientAnchor = ambientLightAnchor {
            arView?.scene.removeAnchor(ambientAnchor)
            self.ambientLightAnchor = nil
            Swift.print("🧹 Removed ambient light")
        }
    }

    /// Updates lighting when ambient lighting setting changes
    /// - Parameter disableAmbient: New ambient lighting setting
    func updateAmbientLighting(disableAmbient: Bool) {
        guard disableAmbient != isAmbientLightingDisabled else {
            return // No change needed
        }

        Swift.print("🔄 Updating ambient lighting setting: \(disableAmbient ? "disabled" : "enabled")")

        // Re-setup all lighting with new setting
        setupLighting(disableAmbient: disableAmbient)
    }

    /// Adjusts directional light intensity (for day/night simulation if needed)
    /// - Parameter intensity: Light intensity in lumens (default: 2000)
    func setDirectionalLightIntensity(_ intensity: Float) {
        guard let sunAnchor = sunAnchor else { return }

        for child in sunAnchor.children {
            if let directionalLight = child as? DirectionalLight {
                directionalLight.light.intensity = intensity
                Swift.print("🔆 Directional light intensity updated: \(intensity) lumens")
            }
        }
    }

    /// Adjusts directional light color (for sunrise/sunset effects if needed)
    /// - Parameter color: Light color
    func setDirectionalLightColor(_ color: UIColor) {
        guard let sunAnchor = sunAnchor else { return }

        for child in sunAnchor.children {
            if let directionalLight = child as? DirectionalLight {
                directionalLight.light.color = color
                Swift.print("🎨 Directional light color updated")
            }
        }
    }
}
