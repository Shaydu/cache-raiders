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
    
    /// Handles container opening and anchor removal with safety timeout
    /// - Parameters:
    ///   - container: The loot box container to open (if any)
    ///   - foundLocation: The location that was found
    ///   - anchorWorldPos: World position of the anchor for confetti
    ///   - onComplete: Completion callback
    private func handleContainerOpeningAndRemoval(
        container: LootBoxContainer?,
        foundLocation: LootBoxLocation?,
        anchorWorldPos: SIMD3<Float>,
        onComplete: @escaping () -> Void
    ) {
        if let container = container,
           let foundLocation = foundLocation {
            // Safety: ensure anchor is removed even if animation fails
            var completionCalled = false
            let safeCompletion = {
                if !completionCalled {
                    completionCalled = true
                    self.anchor.removeFromParent()
                    onComplete()
                }
            }
            
            // Open the loot box with confetti
            LootBoxAnimation.openLootBox(container: container, location: foundLocation, tapWorldPosition: anchorWorldPos) {
                safeCompletion()
            }
            
            // Safety timeout: remove anchor after 3 seconds even if animation doesn't complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                safeCompletion()
            }
        } else {
            // No container - just remove the anchor (sphere or other findable disappears)
            anchor.removeFromParent()
            onComplete()
        }
    }
    
    /// Triggers the find behavior: sound, confetti, animation, increment count, disappear
    func find(onComplete: @escaping () -> Void) {
        let objectName = location?.name ?? "Treasure"
        
        Swift.print("🎉 Finding object: \(objectName)")
        
        // BASIC FINDABLE BEHAVIOR #1: Create confetti effect immediately
        // (Sound will play automatically when confetti is created)
        Swift.print("🎊 Creating confetti effect...")
        let parentEntity = anchor
        let confettiRelativePos = SIMD3<Float>(0, 0.15, 0) // At object center
        LootBoxAnimation.createConfettiEffect(at: confettiRelativePos, parent: parentEntity)
        
        // Get anchor world position for confetti
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
        
        // BASIC FINDABLE BEHAVIOR #3: Trigger find animation
        // Priority: If container exists, play opening animation first, then mark as found
        // Otherwise, if sphere exists, play sphere animation, then mark as found
        
        if let container = container, let foundLocation = location {
            // For containers (treasure chests, chalices, etc.):
            // 1. Play opening animation
            // 2. Mark as found callback is called (location already marked as collected in findLootBox)
            // 3. Then remove/disappear
            Swift.print("📦 Opening container for: \(objectName)")
            Swift.print("   Container has box: \(container.box.name), lid: \(container.lid.name), prize: \(container.prize.name)")
            Swift.print("   Built-in animation available: \(container.builtInAnimation != nil)")
            handleContainerOpeningAndRemoval(
                container: container,
                foundLocation: foundLocation,
                anchorWorldPos: anchorWorldPos
            ) {
                // Callback to update found count (location already marked as collected)
                Swift.print("✅ Animation complete for: \(objectName)")
                self.onFoundCallback?(foundLocation.id)
                onComplete()
            }
        } else if let orb = orb {
            // For spheres: play sphere animation, then mark as found
            LootBoxAnimation.animateSphereFind(orb: orb) {
                // BASIC FINDABLE BEHAVIOR #4: Increment found count for ALL findable objects
                if let foundLocation = self.location {
                    self.onFoundCallback?(foundLocation.id)
                }
                
                // Handle container opening and removal (shared logic) - in case there's a container too
                self.handleContainerOpeningAndRemoval(
                    container: self.container,
                    foundLocation: self.location,
                    anchorWorldPos: anchorWorldPos,
                    onComplete: onComplete
                )
            }
        } else {
            // No sphere or container - just mark as found and complete
            if let foundLocation = location {
                onFoundCallback?(foundLocation.id)
            }
            
            // Handle container opening and removal (shared logic) - fallback
            handleContainerOpeningAndRemoval(
                container: container,
                foundLocation: location,
                anchorWorldPos: anchorWorldPos,
                onComplete: onComplete
            )
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



