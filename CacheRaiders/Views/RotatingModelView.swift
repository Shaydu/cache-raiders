import SwiftUI
import RealityKit

// MARK: - Rotating 3D Model View
/// SwiftUI view that displays a rotating 3D model loaded from a .usdz file
struct RotatingModelView: View {
    let modelName: String
    let size: Float
    @State private var modelEntity: ModelEntity?

    // Gesture state for user interactions
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1.0
    @State private var rotationAngle: Angle = .zero
    @State private var lastDragValue: CGSize = .zero
    @State private var currentScale: CGFloat = 1.0
    @State private var isUserInteracting = false

    var body: some View {
        ZStack {
            if let entity = modelEntity {
                RealityView { content in
                    content.add(entity)
                    // Only start auto-rotation if user is not interacting
                    if !isUserInteracting {
                        startRotationAnimation(for: entity)
                    }
                } update: { content in
                    // Update transforms when gesture state changes
                    if let entity = content.entities.first {
                        applyUserTransforms(to: entity)
                    }
                }
                .frame(width: 200, height: 200)
                .cornerRadius(12)
                .gesture(
                    SimultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                                isUserInteracting = true
                            }
                            .onEnded { value in
                                // Update persistent rotation - increased sensitivity
                                rotationAngle += Angle(degrees: Double(value.translation.width) * 2.0)
                                lastDragValue = .zero

                                // Reset interaction flag after a delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    isUserInteracting = false
                                }
                            },
                        MagnificationGesture()
                            .updating($magnification) { value, state, _ in
                                state = value
                                isUserInteracting = true
                            }
                            .onEnded { value in
                                currentScale *= value

                                // Reset interaction flag after a delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    isUserInteracting = false
                                }
                            }
                    )
                )
            } else {
                // Loading placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 200, height: 200)

                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
        }
        .onAppear {
            loadModel()
        }
    }

    private func loadModel() {
        Task {
            do {
                // Try to load the model from bundle
                guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "usdz") else {
                    print("❌ Could not find \(modelName).usdz in bundle")
                    // Create a fallback cube if model not found
                    createFallbackModel()
                    return
                }

                let loadedEntity = try await Entity.load(contentsOf: modelURL)
                await MainActor.run {
                    if let modelEntity = findFirstModelEntity(in: loadedEntity) {
                        // Scale the model appropriately
                        modelEntity.scale = SIMD3<Float>(repeating: size / 0.5) // Adjust scale based on desired size
                        self.modelEntity = modelEntity
                        print("✅ Loaded 3D model: \(modelName)")
                    } else {
                        print("❌ No ModelEntity found in loaded model")
                        createFallbackModel()
                    }
                }
            } catch {
                print("❌ Error loading model \(modelName): \(error)")
                await MainActor.run {
                    createFallbackModel()
                }
            }
        }
    }

    private func findFirstModelEntity(in entity: Entity) -> ModelEntity? {
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

    private func createFallbackModel() {
        // Create a simple cube as fallback
        let mesh = MeshResource.generateBox(size: size)
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor.blue.withAlphaComponent(0.8))
        material.roughness = 0.3
        material.metallic = 0.5

        let cubeEntity = ModelEntity(mesh: mesh, materials: [material])
        self.modelEntity = cubeEntity
        print("ℹ️ Using fallback cube model")
    }

    private func startRotationAnimation(for entity: ModelEntity) {
        // Create combined 3D rotation animation (X and Y axes)
        let rotationAnimation = FromToByAnimation<Transform>(
            from: Transform(rotation: .init(angle: 0, axis: SIMD3<Float>(0, 1, 0))),
            to: Transform(rotation: .init(angle: .pi * 2, axis: SIMD3<Float>(0.5, 1, 0.3))),
            duration: 4.0,
            timing: .linear,
            repeatMode: .repeat
        )

        guard let animationResource = try? AnimationResource.generate(with: rotationAnimation) else {
            print("❌ Failed to create rotation animation")
            return
        }

        // Play the repeating animation
        entity.playAnimation(animationResource)
        print("✅ Started 3D rotation animation")
    }

    private func applyUserTransforms(to entity: Entity) {
        // Calculate total rotation (persistent + current gesture)
        let gestureRotation = Double(dragOffset.width) * 0.02 // More responsive rotation
        let totalRotationAngle = rotationAngle.radians + gestureRotation
        let rotation = Transform(rotation: .init(angle: Float(totalRotationAngle),
                                               axis: SIMD3<Float>(0, 1, 0)))

        // Calculate total scale (persistent + current gesture)
        let totalScale = currentScale * magnification
        let clampedScale = max(0.3, min(3.0, Float(totalScale))) // Clamp scale between 0.3x and 3.0x

        // Apply combined transforms
        entity.transform = Transform(scale: SIMD3<Float>(repeating: clampedScale),
                                   rotation: rotation.rotation)
    }
}


// MARK: - Preview
struct RotatingModelView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            RotatingModelView(modelName: "Chalice", size: 0.3)
            Text("Rotating 3D Model")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}