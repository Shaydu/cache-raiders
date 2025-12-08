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
    func find(tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void)
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
    /// This is the main entry point - confetti and sound are handled by factory methods
    func find(tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
        let objectName = itemDescription()

        Swift.print("🎉 Finding object: \(objectName)")

        // NOTE: Confetti and sound effects are now handled by individual factory methods
        // to ensure proper timing and prevent duplicate effects

        // Perform find animation (which includes confetti, sound, and object removal)
        performFindAnimation(tapWorldPosition: tapWorldPosition, onComplete: onComplete)
    }
    
    /// Performs the find animation based on location type
    /// This method can be overridden by child classes to customize animation behavior
    /// - Parameters:
    ///   - tapWorldPosition: The world position where the user tapped (for confetti positioning)
    ///   - onComplete: Callback when animation completes
    func performFindAnimation(tapWorldPosition: SIMD3<Float>?, onComplete: @escaping () -> Void) {
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

        // Use tap position for confetti if available, otherwise fall back to anchor position
        // This ensures confetti originates from where the user actually tapped on the object
        let confettiWorldPos: SIMD3<Float>
        if let tapPos = tapWorldPosition {
            confettiWorldPos = tapPos
            Swift.print("🎊 Using tap position for confetti: (\(String(format: "%.2f", tapPos.x)), \(String(format: "%.2f", tapPos.y)), \(String(format: "%.2f", tapPos.z)))")
        } else {
            // Fallback to anchor position if no tap position available
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            confettiWorldPos = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )
            Swift.print("🎊 Using anchor position for confetti (fallback): (\(String(format: "%.2f", confettiWorldPos.x)), \(String(format: "%.2f", confettiWorldPos.y)), \(String(format: "%.2f", confettiWorldPos.z)))")
        }
        
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
                Swift.print("🗑️ Removing anchor from scene: \(self.anchor.name)")
                Swift.print("   Anchor has \(self.anchor.children.count) children before removal")
                Swift.print("   Anchor parent: \(self.anchor.parent != nil ? "has parent" : "no parent")")
                self.anchor.removeFromParent()
                self.onFoundCallback?(location.id)
                Swift.print("✅ Anchor removal completed")
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
            ) {
                // Remove the generic icon once the real object has been revealed
                genericIcon.removeFromParent()

                // After reveal, run the normal factory animation on the real container
                factory.animateFind(
                    entity: container.container,
                    container: container,
                    tapWorldPosition: confettiWorldPos
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
            tapWorldPosition: confettiWorldPos
        ) {
            safeCompletion()
        }
        
        // Safety timeout: remove anchor after 5 seconds even if animation doesn't complete
        // (accounts for confetti 2.5s + animation 1.2s + buffer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            Swift.print("⏰ Safety timeout triggered - forcing object removal")
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

// MARK: - Polymorphic Findable Factory
extension FindableObject {
    /// Polymorphic factory method to create any type of findable object
    /// This eliminates the need for type-specific creation logic and makes all creation object-type agnostic
    ///
    /// - Parameters:
    ///   - findableType: The LootBoxType that determines what kind of findable object to create
    ///   - location: The LootBoxLocation containing metadata for the object
    ///   - anchor: The AnchorEntity to attach the object to
    ///   - sizeMultiplier: Size scaling factor (default: 1.0)
    /// - Returns: A Findable object of the appropriate type, fully configured and ready to use
    static func createNewFindable(findableType: LootBoxType, location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float = 1.0) -> Findable {
        // Get the factory for this type - this is where polymorphism happens
        let factory = findableType.factory

        // Create the entity and findable object using the factory
        let (entity, findableObject) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: sizeMultiplier)

        // Attach the visual entity to the anchor
        anchor.addChild(entity)

        // Ensure the entity is enabled and visible
        entity.isEnabled = true

        // Return the findable object (which implements the Findable protocol)
        return findableObject
    }

    /// Convenience method to create a findable object from a location (infers type from location.type)
    /// - Parameters:
    ///   - location: The LootBoxLocation containing both type and metadata
    ///   - anchor: The AnchorEntity to attach the object to
    ///   - sizeMultiplier: Size scaling factor (default: 1.0)
    /// - Returns: A Findable object configured for the location
    static func createFromLocation(_ location: LootBoxLocation, anchor: AnchorEntity, sizeMultiplier: Float = 1.0) -> Findable {
        return createNewFindable(findableType: location.type, location: location, anchor: anchor, sizeMultiplier: sizeMultiplier)
    }
}



