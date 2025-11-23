import RealityKit
import AVFoundation
import AudioToolbox
import UIKit
import Foundation

// MARK: - Loot Box Opening Animation
class LootBoxAnimation {
    
    /// Animates the opening of a loot box with lid opening, sound, and prize reveal
    /// - Parameters:
    ///   - container: The loot box container with box, lid, and prize entities
    ///   - location: The loot box location information
    ///   - tapWorldPosition: Optional world position where user tapped (for confetti)
    ///   - onComplete: Callback when animation completes
    static func openLootBox(
        container: LootBoxContainer,
        location: LootBoxLocation,
        tapWorldPosition: SIMD3<Float>? = nil,
        onComplete: @escaping () -> Void
    ) {
        // Play opening sound
        playOpeningSound()
        
        // Create confetti effect at tap position if provided, otherwise at container position
        let parentEntity = container.container.parent ?? container.container
        let confettiPosition: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            // Convert world position to relative position
            let parentTransform = parentEntity.transformMatrix(relativeTo: nil)
            let parentWorldPos = SIMD3<Float>(
                parentTransform.columns.3.x,
                parentTransform.columns.3.y,
                parentTransform.columns.3.z
            )
            confettiPosition = tapPos - parentWorldPos
        } else {
            confettiPosition = container.container.position
        }
        createConfettiEffect(at: confettiPosition, parent: parentEntity)
        
        // Determine animation type based on loot box type
        switch location.type {
        case .goldenIdol:
            openChalice(container: container, onComplete: onComplete)
        case .ancientArtifact, .templeRelic, .puzzleBox, .stoneTablet:
            openBox(container: container, onComplete: onComplete)
        case .sphere:
            // Spheres don't need opening animation - just complete immediately
            onComplete()
        }
    }
    
    /// Animates the sphere "find" animation: +25% size for 0.5s, ease out, then pop by shrinking 100%
    /// - Parameters:
    ///   - orb: The sphere entity to animate
    ///   - onComplete: Callback when animation completes
    static func animateSphereFind(orb: ModelEntity, onComplete: @escaping () -> Void) {
        let startScale = orb.scale
        let growDuration: TimeInterval = 0.5 // Grow phase: 0.5 seconds
        let shrinkDuration: TimeInterval = 0.3 // Shrink phase: 0.3 seconds for quick pop
        let totalDuration = growDuration + shrinkDuration
        
        var elapsed: TimeInterval = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            elapsed += 0.016
            
            if elapsed <= growDuration {
                // Phase 1: Grow to 125% over 0.5 seconds with ease out
                let growProgress = Float(min(elapsed / growDuration, 1.0))
                // Ease out cubic
                let easedProgress = 1.0 - pow(1.0 - growProgress, 3.0)
                let scale = startScale * (1.0 + easedProgress * 0.25) // Grow 25%
                orb.scale = scale
            } else {
                // Phase 2: Pop by shrinking 100% (to 0%) with ease out
                let shrinkProgress = Float(min((elapsed - growDuration) / shrinkDuration, 1.0))
                // Ease out cubic for the pop
                let easedProgress = 1.0 - pow(1.0 - shrinkProgress, 3.0)
                let scale = startScale * 1.25 * (1.0 - easedProgress) // Shrink from 125% to 0
                orb.scale = scale
                
                // Fade out during shrink phase
                let fadeProgress = shrinkProgress
                if var model = orb.model {
                    var materials: [Material] = []
                    for material in model.materials {
                        if var simpleMaterial = material as? SimpleMaterial {
                            let alpha = 1.0 - CGFloat(fadeProgress)
                            simpleMaterial.color = .init(
                                tint: simpleMaterial.color.tint.withAlphaComponent(alpha)
                            )
                            materials.append(simpleMaterial)
                        } else {
                            materials.append(material)
                        }
                    }
                    model.materials = materials
                    orb.model = model
                }
                
                // Fade out light during shrink
                if var light = orb.components[PointLightComponent.self] {
                    light.intensity = Float(200 * (1.0 - fadeProgress))
                    orb.components[PointLightComponent.self] = light
                }
            }
            
            if elapsed >= totalDuration {
                timer.invalidate()
                orb.isEnabled = false
                onComplete()
            }
        }
        
        // Safety: invalidate after duration
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            timer.invalidate()
        }
    }
    
    /// Animates the orange orb indicator disappearing (grow 25%, then shrink to 0 with easing)
    /// - Parameters:
    ///   - orb: The orb entity to animate
    ///   - onComplete: Callback when animation completes
    static func animateOrbDisappearing(orb: ModelEntity, onComplete: @escaping () -> Void) {
        let startScale = orb.scale
        let duration: TimeInterval = 1.5
        let growPhase: TimeInterval = 0.3 // First 0.3 seconds to grow 25%
        let shrinkPhase: TimeInterval = duration - growPhase // Remaining time to shrink to 0
        
        var elapsed: TimeInterval = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            elapsed += 0.016
            let totalProgress = Float(min(elapsed / duration, 1.0))
            
            if elapsed <= growPhase {
                // Phase 1: Grow to 125% (ease out)
                let growProgress = Float(elapsed / growPhase)
                // Ease out cubic
                let easedProgress = 1.0 - pow(1.0 - growProgress, 3.0)
                let scale = startScale * (1.0 + easedProgress * 0.25) // Grow 25%
                orb.scale = scale
            } else {
                // Phase 2: Shrink from 125% to 0 (ease in)
                let shrinkProgress = Float((elapsed - growPhase) / shrinkPhase)
                // Ease in cubic
                let easedProgress = pow(shrinkProgress, 3.0)
                let scale = startScale * 1.25 * (1.0 - easedProgress) // Shrink from 125% to 0
                orb.scale = scale
                
                // Fade out during shrink phase
                let fadeProgress = shrinkProgress
                if var model = orb.model {
                    var materials: [Material] = []
                    for material in model.materials {
                        if var simpleMaterial = material as? SimpleMaterial {
                            let alpha = 1.0 - CGFloat(fadeProgress)
                            simpleMaterial.color = .init(
                                tint: simpleMaterial.color.tint.withAlphaComponent(alpha)
                            )
                            materials.append(simpleMaterial)
                        } else {
                            materials.append(material)
                        }
                    }
                    model.materials = materials
                    orb.model = model
                }
                
                // Fade out light during shrink
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
        
        // Safety: invalidate after duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            timer.invalidate()
        }
    }
    
    /// Opens a skull container - lid rotates upward
    private static func openSkull(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        // Animate lid opening upward (rotate around X axis at the back edge)
        let lidRotationAngle = -Float.pi / 2.5 // Open lid about 72 degrees
        
        let lidOpenTransform = Transform(
            scale: container.lid.scale,
            rotation: simd_quatf(angle: lidRotationAngle, axis: SIMD3<Float>(1, 0, 0)),
            translation: container.lid.position
        )
        
        container.lid.move(
            to: lidOpenTransform,
            relativeTo: container.container,
            duration: 0.8,
            timingFunction: .easeOut
        )
        
        // After lid opens, show and animate prize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            container.prize.isEnabled = true
            animatePrizeReveal(container: container, onComplete: onComplete)
        }
    }
    
    /// Opens a chalice container - prize rises up from inside
    private static func openChalice(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        // No lid to open - prize just rises up and glows
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
        
        // Rotate prize as it rises
        animatePrizeRotation(prize: container.prize, duration: 1.0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            onComplete()
        }
    }
    
    /// Opens a box container - door swings open
    private static func openBox(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        // Animate door swinging open (rotate around Y axis on the left side)
        let doorRotationAngle = Float.pi / 2.2 // Open door about 82 degrees
        
        // Get door's current position and calculate pivot (left edge)
        let doorPos = container.lid.position
        
        // Create rotation around the pivot point
        let doorOpenTransform = Transform(
            scale: container.lid.scale,
            rotation: simd_quatf(angle: doorRotationAngle, axis: SIMD3<Float>(0, 1, 0)),
            translation: doorPos
        )
        
        // Animate door opening
        container.lid.move(
            to: doorOpenTransform,
            relativeTo: container.container,
            duration: 0.8,
            timingFunction: .easeOut
        )
        
        // After door opens, show and animate prize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            container.prize.isEnabled = true
            animatePrizeReveal(container: container, onComplete: onComplete)
        }
    }
    
    /// Animates prize reveal (rising up and rotating)
    private static func animatePrizeReveal(container: LootBoxContainer, onComplete: @escaping () -> Void) {
        let prizeStartPos = container.prize.position
        let prizeEndPos = SIMD3<Float>(prizeStartPos.x, prizeStartPos.y + 0.5, prizeStartPos.z)
        
        let prizeTransform = Transform(
            scale: container.prize.scale,
            rotation: container.prize.orientation,
            translation: prizeEndPos
        )
        
        container.prize.move(
            to: prizeTransform,
            relativeTo: container.container,
            duration: 1.2,
            timingFunction: .easeOut
        )
        
        animatePrizeRotation(prize: container.prize, duration: 1.2)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            onComplete()
        }
    }
    
    /// Animates prize rotation
    private static func animatePrizeRotation(prize: ModelEntity, duration: Float) {
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
    
    /// Plays the opening sound effect and haptic feedback
    static func playOpeningSound() {
        // Play haptic feedback (vibration) for collection
        let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
        impactFeedback.impactOccurred()
        
        // Also play a success notification haptic for extra feedback
        let notificationFeedback = UINotificationFeedbackGenerator()
        notificationFeedback.notificationOccurred(.success)
        
        // Play custom level-up sound
        if let url = Bundle.main.url(forResource: "810753__mokasza__level-up-01", withExtension: "mp3") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.play()
            } catch {
                print("⚠️ Could not play level-up sound: \(error)")
                // Fallback to system sound
                AudioServicesPlaySystemSound(1057)
            }
        } else {
            // Try alternative filename (without the long prefix)
            if let url = Bundle.main.url(forResource: "level-up-01", withExtension: "mp3") {
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.prepareToPlay()
                    player.play()
                } catch {
                    print("⚠️ Could not play level-up sound: \(error)")
                    AudioServicesPlaySystemSound(1057)
                }
            } else {
                print("⚠️ Level-up sound file not found in bundle")
                // Fallback to system sound
                AudioServicesPlaySystemSound(1057)
            }
        }
    }
    
    /// Creates a confetti effect at the specified position
    /// - Parameters:
    ///   - position: The position relative to parent where confetti should appear
    ///   - parent: The parent entity to attach confetti to
    static func createConfettiEffect(at position: SIMD3<Float>, parent: Entity) {
        // Confetti colors - vibrant celebration colors
        let confettiColors: [UIColor] = [
            .systemRed, .systemBlue, .systemGreen, .systemYellow,
            .systemOrange, .systemPurple, .systemPink, .cyan
        ]
        
        // Create confetti particles
        let particleCount = 50
        
        for i in 0..<particleCount {
            // Random color
            let color = confettiColors[i % confettiColors.count]
            
            // Create small confetti piece (small box or sphere)
            let particleSize: Float = 0.02 // 2cm pieces
            let particleMesh = MeshResource.generateBox(
                width: particleSize * Float.random(in: 0.5...1.5),
                height: particleSize * Float.random(in: 0.5...1.5),
                depth: particleSize * Float.random(in: 0.5...1.5)
            )
            
            var particleMaterial = SimpleMaterial()
            particleMaterial.color = .init(tint: color)
            particleMaterial.roughness = 0.3
            particleMaterial.metallic = 0.2
            
            let particle = ModelEntity(mesh: particleMesh, materials: [particleMaterial])
            
            // Set initial position relative to parent (at the loot box location)
            particle.position = position
            
            // Random initial velocity direction (burst outward)
            let angle1 = Float.random(in: 0...(Float.pi * 2)) // Horizontal angle
            let angle2 = Float.random(in: -Float.pi/4...(Float.pi/2)) // Vertical angle (mostly upward)
            let speed = Float.random(in: 2.0...5.0) // Initial speed
            
            let velocity = SIMD3<Float>(
                cos(angle1) * cos(angle2) * speed,
                sin(angle2) * speed,
                sin(angle1) * cos(angle2) * speed
            )
            
            parent.addChild(particle)
            
            // Animate confetti particle
            animateConfettiParticle(particle: particle, velocity: velocity, index: i)
        }
    }
    
    /// Animates a single confetti particle with physics-like motion
    private static func animateConfettiParticle(particle: ModelEntity, velocity: SIMD3<Float>, index: Int) {
        let startPosition = particle.position
        var currentVelocity = velocity
        let gravity: Float = -9.8 * 0.5 // Gravity (scaled down for AR)
        var currentPosition = startPosition
        let rotationVelocity = SIMD3<Float>(
            Float.random(in: -5...5),
            Float.random(in: -5...5),
            Float.random(in: -5...5)
        )
        var currentRotation = SIMD3<Float>(0, 0, 0)
        
        let startTime = Date()
        let duration: TimeInterval = 2.0 // Confetti falls for 2 seconds
        
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak particle] timer in
            guard let particle = particle, particle.parent != nil else {
                timer.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= duration {
                // Fade out and remove
                particle.removeFromParent()
                timer.invalidate()
                return
            }
            
            // Update velocity (apply gravity)
            currentVelocity.y += Float(gravity * 0.016)
            
            // Update position
            currentPosition += currentVelocity * 0.016
            
            // Update rotation (combine rotations around each axis)
            currentRotation += rotationVelocity * 0.016
            
            // Create quaternion from euler angles (apply rotations in order: X, Y, Z)
            let qx = simd_quatf(angle: currentRotation.x, axis: SIMD3<Float>(1, 0, 0))
            let qy = simd_quatf(angle: currentRotation.y, axis: SIMD3<Float>(0, 1, 0))
            let qz = simd_quatf(angle: currentRotation.z, axis: SIMD3<Float>(0, 0, 1))
            particle.orientation = qz * qy * qx // Combine rotations
            
            // Apply position
            particle.position = currentPosition
            
            // Fade out in the last 0.5 seconds
            if elapsed >= duration - 0.5 {
                let fadeProgress = Float((elapsed - (duration - 0.5)) / 0.5)
                if var model = particle.model {
                    var materials: [Material] = []
                    for material in model.materials {
                        if var simpleMaterial = material as? SimpleMaterial {
                            let alpha = 1.0 - fadeProgress
                            simpleMaterial.color = .init(
                                tint: simpleMaterial.color.tint.withAlphaComponent(CGFloat(alpha))
                            )
                            materials.append(simpleMaterial)
                        } else {
                            materials.append(material)
                        }
                    }
                    model.materials = materials
                    particle.model = model
                }
            }
        }
    }
}

