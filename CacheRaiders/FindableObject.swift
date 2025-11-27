import RealityKit
import Foundation

// MARK: - Findable Protocol
/// Protocol defining basic requirements for all findable objects
protocol Findable {
    var locationId: String { get }
    var anchor: AnchorEntity { get }
    var sphereEntity: ModelEntity? { get }
    var container: LootBoxContainer? { get }
    var location: LootBoxLocation? { get }
    
    /// Returns the description of this item - all items must have a description
    /// - Returns: A non-empty description string for this item
    func itemDescription() -> String
    
    /// Triggers the find behavior: sound, confetti, animation, increment count, disappear
    func find(onComplete: @escaping () -> Void)
}

// MARK: - Findable Object Base Class
/// Base class for all findable objects (treasure boxes, chalices, spheres, etc.)
/// Encapsulates common findable behavior:
/// - Not spawning on top of camera (minimum 5m distance)
/// - All being clickable
/// - Triggering find animations
/// - Incrementing found items counter
class FindableObject: Findable {
    let locationId: String
    let anchor: AnchorEntity
    var sphereEntity: ModelEntity?
    var container: LootBoxContainer?
    var location: LootBoxLocation?
    
    /// Callback for when object is found (to update location manager)
    var onFoundCallback: ((String) -> Void)?
    
    init(locationId: String, anchor: AnchorEntity, sphereEntity: ModelEntity? = nil, container: LootBoxContainer? = nil, location: LootBoxLocation? = nil) {
        self.locationId = locationId
        self.anchor = anchor
        self.sphereEntity = sphereEntity
        self.container = container
        self.location = location
    }
    
    /// Returns the description of this item
    /// Override this method in subclasses to provide custom descriptions
    /// Default implementation uses the factory pattern based on location type
    /// - Returns: A non-empty description string for this item
    func itemDescription() -> String {
        guard let location = location else {
            // Fallback: if no location, return generic description
            // This should rarely happen as all items should have a location
            return "Mysterious Treasure"
        }
        // Use factory to get the description - each factory provides its own description
        return location.type.factory.itemDescription()
    }
    
    /// Triggers the find behavior: sound, confetti, animation, increment count, disappear
    /// This is the main entry point - confetti and sound are default behaviors for all findables
    func find(onComplete: @escaping () -> Void) {
        let objectName = itemDescription()
        
        Swift.print("🎉 Finding object: \(objectName)")
        
        // DEFAULT BEHAVIOR #1: Create confetti effect immediately
        // (Sound will play automatically when confetti is created)
        Swift.print("🎊 Creating confetti effect...")
        
        // Get world position of anchor before it's removed
        let anchorTransform = anchor.transformMatrix(relativeTo: nil)
        let anchorWorldPos = SIMD3<Float>(
            anchorTransform.columns.3.x,
            anchorTransform.columns.3.y + 0.15, // Slightly above object center
            anchorTransform.columns.3.z
        )
        
        // Create confetti at world position using temporary anchor approach
        // This will persist even after the object anchor is removed
        if let scene = anchor.scene {
            // Create temporary anchor at world position for confetti
            let confettiAnchor = AnchorEntity(world: anchorWorldPos)
            scene.addAnchor(confettiAnchor)
            
            // Create confetti relative to this temporary anchor
            LootBoxAnimation.createConfettiEffect(at: SIMD3<Float>(0, 0, 0), parent: confettiAnchor)
            
            // Auto-remove confetti anchor after animation completes (2 seconds + buffer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                confettiAnchor.removeFromParent()
            }
        } else {
            // Fallback: use legacy approach with original anchor
            LootBoxAnimation.createConfettiEffect(at: SIMD3<Float>(0, 0.15, 0), parent: anchor)
        }
        
        // DEFAULT BEHAVIOR #2: Perform find animation (overrideable by child classes)
        // This method determines which animation to play based on location type
        performFindAnimation(onComplete: onComplete)
    }
    
    /// Performs the find animation based on location type
    /// This method can be overridden by child classes to customize animation behavior
    /// - Parameter onComplete: Callback when animation completes
    func performFindAnimation(onComplete: @escaping () -> Void) {
        guard let location = location else {
            // No location - just complete immediately
            onFoundCallback?(locationId)
            DispatchQueue.main.async { [weak self] in
                self?.anchor.removeFromParent()
                onComplete()
            }
            return
        }
        
        let _ = itemDescription() // Object name (unused but kept for potential logging)
        
        // Get anchor world position for cleanup
        let anchorTransform = anchor.transformMatrix(relativeTo: nil)
        let anchorWorldPos = SIMD3<Float>(
            anchorTransform.columns.3.x,
            anchorTransform.columns.3.y,
            anchorTransform.columns.3.z
        )
        
        // Find the sphere entity if not already set
        var orb: ModelEntity? = sphereEntity
        if orb == nil {
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.components[PointLightComponent.self] != nil {
                    orb = modelEntity
                    break
                }
            }
        }
        
        // Use factory to handle animation - each factory encapsulates its own behavior
        Swift.print("🎭 Using factory for animation: \(location.type)")
        
        // Get the factory for this location type
        let factory = location.type.factory
        
        // Determine which entity to animate
        let entityToAnimate: ModelEntity
        if let container = container {
            entityToAnimate = container.container
        } else if let orb = orb {
            entityToAnimate = orb
        } else {
            // Fallback - shouldn't happen, but handle gracefully
            onFoundCallback?(location.id)
            DispatchQueue.main.async { [weak self] in
                self?.anchor.removeFromParent()
                onComplete()
            }
            return
        }
        
        // Safety: ensure anchor is removed even if animation fails
        var completionCalled = false
        let safeCompletion = {
            if !completionCalled {
                completionCalled = true
                self.anchor.removeFromParent()
                self.onFoundCallback?(location.id)
                onComplete()
            }
        }

        // If generic doubloon icons are enabled and we have both a generic icon and a real container,
        // first reveal the real object from the generic icon, then run the normal factory animation.
        let useGenericIcons = UserDefaults.standard.bool(forKey: "useGenericDoubloonIcons")
        if useGenericIcons,
           let container = container,
           let genericIcon = orb {
            GenericIconRevealAnimator.reveal(
                realEntity: container.container,
                from: genericIcon,
                in: anchor,
                heightOffset: 0.4,
                duration: 1.0
            ) { [weak self] in
                // Remove the generic icon once the real object has been revealed
                genericIcon.removeFromParent()

                // After reveal, run the normal factory animation on the real container
                factory.animateFind(
                    entity: container.container,
                    container: container,
                    tapWorldPosition: anchorWorldPos
                ) {
                    safeCompletion()
                }
            }

            // Safety timeout: ensure cleanup even if animations fail
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                safeCompletion()
            }

            return
        }
        
        // Default behavior: use factory to animate find behavior (includes confetti, sound, and animation)
        factory.animateFind(
            entity: entityToAnimate,
            container: container,
            tapWorldPosition: anchorWorldPos
        ) {
            safeCompletion()
        }
        
        // Safety timeout: remove anchor after 3 seconds even if animation doesn't complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            safeCompletion()
        }
    }
    
    /// Ensures object is not placed within minimum distance of camera
    /// - Parameters:
    ///   - position: Proposed position for the object
    ///   - cameraPosition: Current camera position
    ///   - minDistance: Minimum distance from camera (default 5m)
    /// - Returns: Adjusted position that respects minimum distance, or nil if too close
    static func ensureMinimumDistance(from position: SIMD3<Float>, to cameraPosition: SIMD3<Float>, minDistance: Float = 5.0) -> SIMD3<Float>? {
        let distance = length(position - cameraPosition)
        
        if distance < minDistance {
            // Move position to exactly minDistance away
            let direction = normalize(position - cameraPosition)
            let adjustedPosition = cameraPosition + direction * minDistance
            Swift.print("⚠️ Adjusted findable object position to \(minDistance)m minimum distance from camera")
            return adjustedPosition
        }
        
        return position
    }
}



