import RealityKit
import SwiftUI
import ARKit
import AudioToolbox

// MARK: - AR Text Overlay
/// Creates a 3D text overlay on a sign with dark background that appears above an entity in AR with Shadowgate-style character reveal
class ARTextOverlay {
    private var signAnchor: AnchorEntity?
    private var backgroundPlane: ModelEntity?
    private var textEntity: ModelEntity?
    private var revealTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private weak var arView: ARView?
    private weak var parentEntity: Entity?

    /// Create and attach a text overlay to an entity
    /// - Parameters:
    ///   - text: The text to display
    ///   - parentEntity: The entity to attach the text above
    ///   - arView: The AR view to add the text to
    ///   - revealSpeed: Base characters per second (default: 30)
    static func showText(
        _ text: String,
        above parentEntity: Entity,
        in arView: ARView,
        revealSpeed: Double = 30.0
    ) {
        // Remove existing text overlay if any
        if let existing = parentEntity.children.first(where: { $0.name == "textSign" }) {
            existing.removeFromParent()
        }

        // Create the sign container (will hold background + text)
        let signContainer = Entity()
        signContainer.name = "textSign"

        // Create black background plane (high contrast for readability)
        let backgroundMesh = MeshResource.generatePlane(width: 1.2, depth: 0.4, cornerRadius: 0.05)
        var backgroundMaterial = SimpleMaterial()
        backgroundMaterial.color = .init(tint: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0), texture: nil) // Pure black
        backgroundMaterial.roughness = 0.9
        backgroundMaterial.metallic = 0.0

        let backgroundPlane = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])
        backgroundPlane.name = "background"

        // Create text mesh (start with empty, will be updated during reveal)
        let font = UIFont.monospacedSystemFont(ofSize: 0.05, weight: .medium) // Smaller, monospaced font
        let textMesh = MeshResource.generateText(
            "",
            extrusionDepth: 0.001, // Very thin extrusion for flat text
            font: font,
            containerFrame: CGRect(x: -0.55, y: -0.15, width: 1.1, height: 0.3), // Centered in the sign
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

        // Create white text material (high contrast on black background)
        var textMaterial = SimpleMaterial()
        textMaterial.color = .init(tint: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0), texture: nil) // Pure white
        textMaterial.metallic = 0.0
        textMaterial.roughness = 0.2

        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        textEntity.name = "text"

        // Position text slightly in front of background (0.01m forward)
        textEntity.position = SIMD3<Float>(0, 0, 0.01)

        // Add background and text to sign container
        signContainer.addChild(backgroundPlane)
        signContainer.addChild(textEntity)

        // Position sign above parent entity (2.0m above for better visibility)
        signContainer.position = SIMD3<Float>(0, 2.0, 0)

        // Add to parent
        parentEntity.addChild(signContainer)

        // Start character-by-character reveal with sound
        let overlay = ARTextOverlay()
        overlay.textEntity = textEntity
        overlay.backgroundPlane = backgroundPlane
        overlay.arView = arView
        overlay.parentEntity = parentEntity
        overlay.startReveal(text: text, revealSpeed: revealSpeed)
        overlay.startBillboardUpdate(signContainer: signContainer)
    }

    private func startReveal(text: String, revealSpeed: Double) {
        // Cancel any existing reveal
        revealTask?.cancel()

        let baseCharactersPerSecond = revealSpeed
        let randomVariation: Double = 0.3 // 30% variance
        let punctuationPauseMultiplier: Double = 3.0

        revealTask = Task { @MainActor in
            var revealedText = ""

            for character in text {
                // Check if cancelled
                if Task.isCancelled {
                    return
                }

                revealedText.append(character)

                // Update text mesh
                if let textEntity = textEntity {
                    let font = UIFont.monospacedSystemFont(ofSize: 0.05, weight: .medium)
                    let textMesh = MeshResource.generateText(
                        revealedText,
                        extrusionDepth: 0.001,
                        font: font,
                        containerFrame: CGRect(x: -0.55, y: -0.15, width: 1.1, height: 0.3),
                        alignment: .center,
                        lineBreakMode: .byWordWrapping
                    )

                    textEntity.model?.mesh = textMesh
                }

                // Play typewriter clack sound for non-whitespace characters
                if !character.isWhitespace {
                    AudioServicesPlaySystemSound(1104) // Keyboard tap/clack sound
                }

                // Calculate variable delay (old adventure game feel)
                let baseDelay = 1.0 / baseCharactersPerSecond
                var characterDelay = baseDelay

                // Add random variation
                let randomFactor = 1.0 + Double.random(in: -randomVariation...randomVariation)
                characterDelay *= randomFactor

                // Add longer pause after punctuation
                if character == "." || character == "!" || character == "?" {
                    characterDelay *= punctuationPauseMultiplier
                } else if character == "," || character == ";" || character == ":" {
                    characterDelay *= (punctuationPauseMultiplier * 0.5)
                }

                // Wait before revealing next character
                try? await Task.sleep(nanoseconds: UInt64(characterDelay * 1_000_000_000))
            }
        }
    }

    private func startBillboardUpdate(signContainer: Entity) {
        // Cancel existing update task
        updateTask?.cancel()

        updateTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let arView = arView,
                      let frame = arView.session.currentFrame else {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    continue
                }

                // Get camera position
                let cameraTransform = frame.camera.transform
                let cameraPos = SIMD3<Float>(
                    cameraTransform.columns.3.x,
                    cameraTransform.columns.3.y,
                    cameraTransform.columns.3.z
                )

                // Get sign world position
                let signTransform = signContainer.transformMatrix(relativeTo: nil)
                let signWorldPos = SIMD3<Float>(
                    signTransform.columns.3.x,
                    signTransform.columns.3.y,
                    signTransform.columns.3.z
                )

                // Calculate direction to camera
                let toCamera = normalize(cameraPos - signWorldPos)

                // Create look-at rotation (sign faces camera)
                // We want the sign's +Z axis (front) to point at the camera
                let forward = toCamera
                let up = SIMD3<Float>(0, 1, 0)
                let right = normalize(cross(up, forward))
                let adjustedUp = cross(forward, right)

                // Build rotation matrix
                var rotationMatrix = float4x4(
                    SIMD4<Float>(right.x, right.y, right.z, 0),
                    SIMD4<Float>(adjustedUp.x, adjustedUp.y, adjustedUp.z, 0),
                    SIMD4<Float>(forward.x, forward.y, forward.z, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                )

                // Extract quaternion from rotation matrix
                signContainer.orientation = simd_quatf(rotationMatrix)

                // Update every frame (60fps = ~16ms)
                try? await Task.sleep(nanoseconds: 16_666_666)
            }
        }
    }

    func remove() {
        revealTask?.cancel()
        updateTask?.cancel()
        textEntity?.removeFromParent()
        backgroundPlane?.removeFromParent()
        signAnchor?.removeFromParent()
        textEntity = nil
        backgroundPlane = nil
        signAnchor = nil
    }

    static func removeText(from parentEntity: Entity) {
        if let existing = parentEntity.children.first(where: { $0.name == "textSign" }) {
            existing.removeFromParent()
        }
    }
}
