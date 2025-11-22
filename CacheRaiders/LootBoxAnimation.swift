import RealityKit
import AVFoundation
import AudioToolbox

// MARK: - Loot Box Opening Animation
class LootBoxAnimation {
    
    /// Animates the opening of a loot box with lid opening, sound, and prize reveal
    /// - Parameters:
    ///   - container: The loot box container with box, lid, and prize entities
    ///   - location: The loot box location information
    ///   - onComplete: Callback when animation completes
    static func openLootBox(
        container: LootBoxContainer,
        location: LootBoxLocation,
        onComplete: @escaping () -> Void
    ) {
        // Play opening sound
        playOpeningSound()
        
        // Determine animation type based on loot box type
        switch location.type {
        case .crystalSkull:
            openSkull(container: container, onComplete: onComplete)
        case .goldenIdol:
            openChalice(container: container, onComplete: onComplete)
        case .ancientArtifact, .templeRelic, .puzzleBox, .stoneTablet:
            openBox(container: container, onComplete: onComplete)
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
        // Pivot is on the left side of the door (negative X)
        let pivotOffset = SIMD3<Float>(-0.15, 0, 0) // Adjust based on door size
        
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
    
    /// Plays the opening sound effect
    private static func playOpeningSound() {
        // Use system sound for now (can be replaced with custom sound file)
        AudioServicesPlaySystemSound(1057) // System sound for success/collection
        
        // TODO: Replace with custom sound file if desired:
        // guard let url = Bundle.main.url(forResource: "lootBoxOpen", withExtension: "mp3") else { return }
        // let player = try? AVAudioPlayer(contentsOf: url)
        // player?.play()
    }
}

