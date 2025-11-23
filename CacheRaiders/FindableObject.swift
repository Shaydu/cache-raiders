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
    
    /// Triggers the find behavior: sound, confetti, animation, increment count, disappear
    func find(onComplete: @escaping () -> Void) {
        let objectName = location?.name ?? "Treasure"
        
        Swift.print("🎉 Finding object: \(objectName)")
        
        // BASIC FINDABLE BEHAVIOR #1: Play sound immediately
        Swift.print("🔊 Playing opening sound...")
        LootBoxAnimation.playOpeningSound()
        
        // BASIC FINDABLE BEHAVIOR #2: Create confetti effect immediately
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
        
        // BASIC FINDABLE BEHAVIOR #3: Trigger find animation (sphere animation if available)
        if let orb = orb {
            // Animate sphere "find" animation (+25% for 0.5s, ease out, then pop by shrinking 100%)
            LootBoxAnimation.animateSphereFind(orb: orb) {
                // BASIC FINDABLE BEHAVIOR #4: Increment found count for ALL findable objects
                if let foundLocation = self.location {
                    self.onFoundCallback?(foundLocation.id)
                }
                
                // Handle container opening if this is a treasure box/chalice
                if let container = self.container,
                   let foundLocation = self.location {
                    // Open the loot box with confetti
                    LootBoxAnimation.openLootBox(container: container, location: foundLocation, tapWorldPosition: anchorWorldPos) {
                        // Animation complete - remove the box
                        self.anchor.removeFromParent()
                        onComplete()
                    }
                } else {
                    // No container - just remove the anchor (sphere or other findable disappears)
                    self.anchor.removeFromParent()
                    onComplete()
                }
            }
        } else {
            // No sphere to animate, but still increment count and handle container
            if let foundLocation = location {
                onFoundCallback?(foundLocation.id)
            }
            
            // Handle container opening if this is a treasure box/chalice
            if let container = container,
               let foundLocation = location {
                LootBoxAnimation.openLootBox(container: container, location: foundLocation, tapWorldPosition: anchorWorldPos) {
                    self.anchor.removeFromParent()
                    onComplete()
                }
            } else {
                // No container and no sphere - just remove it
                anchor.removeFromParent()
                onComplete()
            }
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


