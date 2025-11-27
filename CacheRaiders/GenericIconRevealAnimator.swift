import RealityKit
import Foundation

/// Helper responsible for revealing the actual object when using a generic cache icon (doubloon).
/// Call this after the user finds the object, once confetti / sounds have been triggered.
struct GenericIconRevealAnimator {
    /// Animates the real object rising up from the generic icon and performing a 360° spin.
    ///
    /// - Parameters:
    ///   - realEntity: The actual object model to reveal (e.g., chest, chalice).
    ///   - genericEntity: The generic icon entity (e.g., doubloon) the user tapped on.
    ///   - anchor: The anchor that owns these entities.
    ///   - heightOffset: How high above the original position to raise the real object.
    ///   - duration: Duration of the rise + spin animation.
    ///   - completion: Called when the animation finishes (or times out).
    static func reveal(
        realEntity: ModelEntity,
        from genericEntity: ModelEntity,
        in anchor: AnchorEntity,
        heightOffset: Float = 0.4,
        duration: TimeInterval = 1.0,
        completion: @escaping () -> Void
    ) {
        // Ensure entities are part of the same anchor
        guard genericEntity.parent != nil else {
            completion()
            return
        }

        // Position the real entity at the generic icon's location
        realEntity.position = genericEntity.position
        realEntity.orientation = genericEntity.orientation
        realEntity.scale = realEntity.scale // keep existing scale
        realEntity.isEnabled = true

        // Add real entity to anchor if not already present
        if realEntity.parent == nil {
            anchor.addChild(realEntity)
        }

        // Target position above the original one
        let startPosition = realEntity.position
        let endPosition = SIMD3<Float>(
            startPosition.x,
            startPosition.y + heightOffset,
            startPosition.z
        )

        // Configure transform for final position (keep scale / rotation)
        let finalTransform = Transform(
            scale: realEntity.scale,
            rotation: realEntity.orientation,
            translation: endPosition
        )

        // Animate upward motion
        realEntity.move(
            to: finalTransform,
            relativeTo: anchor,
            duration: duration,
            timingFunction: .easeOut
        )

        // Spin the object 360° over the same duration
        var elapsed: TimeInterval = 0
        let totalRotation: Float = .pi * 2
        let step: TimeInterval = 0.016

        let timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { timer in
            guard realEntity.parent != nil else {
                timer.invalidate()
                completion()
                return
            }

            elapsed += step
            let progress = min(max(elapsed / duration, 0), 1)

            let angle = totalRotation * Float(progress)
            realEntity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

            if progress >= 1.0 {
                timer.invalidate()
                completion()
            }
        }

        RunLoop.current.add(timer, forMode: .common)
    }
}




