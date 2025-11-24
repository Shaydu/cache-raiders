import Foundation
import RealityKit
import ARKit

// MARK: - AR Occlusion Manager
/// Manages occlusion detection to hide loot boxes behind walls
class AROcclusionManager {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var distanceTracker: ARDistanceTracker?
    private var occlusionPlanes: [UUID: AnchorEntity] = [:]
    private var occlusionCheckTimer: Timer?
    
    var placedBoxes: [String: AnchorEntity] = [:]
    
    init(arView: ARView?, locationManager: LootBoxLocationManager?, distanceTracker: ARDistanceTracker? = nil) {
        self.arView = arView
        self.locationManager = locationManager
        self.distanceTracker = distanceTracker
    }
    
    /// Start occlusion checking to hide loot boxes behind walls
    func startOcclusionChecking() {
        // Check occlusion periodically (every 1.0 seconds)
        // Reduced from 0.5s to improve framerate - raycasting is expensive
        // Occlusion doesn't need to update frequently - 1 FPS is sufficient
        occlusionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkOcclusionForPlacedBoxes()
        }
    }
    
    /// Stop occlusion checking
    func stopOcclusionChecking() {
        occlusionCheckTimer?.invalidate()
    }
    
    /// Remove all existing occlusion planes
    func removeAllOcclusionPlanes(quiet: Bool = false) {
        guard let arView = arView else { return }
        
        var removedCount = 0
        
        // Remove all tracked occlusion planes
        removedCount += occlusionPlanes.count
        for (_, anchor) in occlusionPlanes {
            anchor.removeFromParent()
        }
        occlusionPlanes.removeAll()
        
        // Also remove any orphaned occlusion planes from the scene
        // Iterate over all anchors in the scene and check for occlusion entities
        let anchors = Array(arView.scene.anchors)
        for anchor in anchors {
            // Remove occlusion entities recursively
            removeOcclusionEntities(from: anchor, removedCount: &removedCount)
            
            // Also check if anchor itself is an occlusion plane anchor (from ARPlaneAnchor)
            if let anchorEntity = anchor as? AnchorEntity {
                // Remove the entire anchor if it only contains occlusion planes
                let hasNonOcclusionChildren = anchorEntity.children.contains { child in
                    if let modelEntity = child as? ModelEntity,
                       let model = modelEntity.model {
                        return !model.materials.contains(where: { $0 is OcclusionMaterial })
                    }
                    return true
                }
                
                if !hasNonOcclusionChildren && !anchorEntity.children.isEmpty {
                    // This anchor only has occlusion planes - remove it entirely
                    if !quiet {
                        Swift.print("🗑️ Removing occlusion-only anchor")
                    }
                    anchorEntity.removeFromParent()
                    removedCount += 1
                }
            }
        }
        
        // Only print if something was removed or if not in quiet mode
        if removedCount > 0 {
            if !quiet {
                Swift.print("🧹 Removed \(removedCount) occlusion plane(s)")
            }
        } else if !quiet {
            Swift.print("🧹 Removed all occlusion planes")
        }
    }
    
    /// Recursively find and remove any entities with OcclusionMaterial or suspiciously large planes
    private func removeOcclusionEntities(from entity: Entity, removedCount: inout Int) {
        // Make a copy of children array before iterating (to avoid mutation issues)
        let children = Array(entity.children)
        
        // First, recursively process children
        for child in children {
            removeOcclusionEntities(from: child, removedCount: &removedCount)
        }
        
        // Then check this entity itself
        if let modelEntity = entity as? ModelEntity,
           let model = modelEntity.model {
            // Check if any material is OcclusionMaterial
            if model.materials.contains(where: { $0 is OcclusionMaterial }) {
                let entityName = entity.name.isEmpty ? "unnamed" : entity.name
                print("🗑️ Found and removing occlusion entity: \(entityName)")
                entity.removeFromParent()
                removedCount += 1
                return
            }
            
            // Also check for suspiciously large plane meshes (likely ceiling planes)
            let mesh = model.mesh
            let bounds = mesh.bounds
            let size = bounds.extents
            let maxDimension = max(size.x, max(size.y, size.z))
            if maxDimension > 3.0 {
                let entityName = entity.name.isEmpty ? "unnamed" : entity.name
                print("🗑️ Found and removing large plane entity (likely ceiling): \(entityName), size=\(String(format: "%.2f", maxDimension))m")
                entity.removeFromParent()
                removedCount += 1
                return
            }
        }
    }
    
    /// Check occlusion for all placed boxes
    func checkOcclusionForPlacedBoxes() {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard let arView = arView, let frame = arView.session.currentFrame else { return }

        // PERFORMANCE: Distance text updates moved to distance tracker's own timer (1s interval)
        // Only update direction here (lightweight calculation)
        distanceTracker?.updateNearestObjectDirection()
        
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Check each placed loot box for occlusion and camera collision
        for (locationId, anchor) in placedBoxes {
            // Get anchor position in world space
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let anchorPosition = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )
            
            // Find the actual object position (chalice, treasure box, or sphere)
            var objectPosition = anchorPosition
            var hasContainer = false
            
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity {
                    // Check if this is a loot box container (chalice or treasure box)
                    if modelEntity.name == locationId {
                        // This is the loot box container - get its world position
                        let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                        objectPosition = SIMD3<Float>(
                            objectTransform.columns.3.x,
                            objectTransform.columns.3.y,
                            objectTransform.columns.3.z
                        )
                        hasContainer = true
                        break
                    }
                    // Check for standalone spheres
                    else if modelEntity.name == locationId && modelEntity.components[PointLightComponent.self] != nil {
                        let objectTransform = modelEntity.transformMatrix(relativeTo: nil)
                        objectPosition = SIMD3<Float>(
                            objectTransform.columns.3.x,
                            objectTransform.columns.3.y,
                            objectTransform.columns.3.z
                        )
                        break
                    }
                }
            }
            
            let direction = objectPosition - cameraPosition
            let distance = length(direction)
            
            // COLLISION DETECTION: Hide objects when camera is too close (within their boundary)
            // Different object types have different sizes
            let buffer: Float = 0.1 // Reduced buffer - only hide when actually inside object
            var minDistanceForObject: Float
            
            // Get the actual object size from the container
            // Objects can be 0.25m to 0.61m (2 feet) in size, so we need to calculate based on actual size
            if hasContainer {
                // For containers (chalice or treasure box), get the actual size
                // The container's scale or bounds would give us the actual size
                // For now, use a safe estimate based on max possible size (0.61m = 2 feet)
                // Using half the max size (0.305m) as radius, plus small buffer
                minDistanceForObject = 0.25 + buffer // Reduced to 0.35m - only hide when very close
            } else {
                // Standalone sphere - use sphere radius
                minDistanceForObject = 0.15 + buffer // 0.15m radius + buffer = 0.25m total
            }
            
            // Check if camera is too close to the object
            let isCameraTooClose = distance < minDistanceForObject
            
            // If camera is too close, hide all children to prevent camera from appearing inside
            if isCameraTooClose {
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        modelEntity.isEnabled = false
                    } else {
                        child.isEnabled = false
                    }
                }
                continue // Skip occlusion check if camera is too close
            }
            
            // Skip occlusion check if box is too far
            guard distance > 0.1 && distance < 50.0 else {
                // Show all children if too far (no occlusion check needed)
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        modelEntity.isEnabled = true
                    } else {
                        child.isEnabled = true
                    }
                }
                continue
            }
            
            // Check if occlusion is disabled in settings
            let occlusionDisabled = locationManager?.disableOcclusion ?? false
            
            // If occlusion is disabled, always show objects
            if occlusionDisabled {
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity {
                        modelEntity.isEnabled = true
                    } else {
                        child.isEnabled = true
                    }
                }
                continue
            }
            
            let normalizedDirection = direction / distance
            
            // Perform raycast from camera to object position to check for walls
            // Use vertical plane detection to find walls
            let raycastQuery = ARRaycastQuery(
                origin: cameraPosition,
                direction: normalizedDirection,
                allowing: .estimatedPlane,
                alignment: .vertical // Check for vertical planes (walls)
            )
            
            let raycastResults = arView.session.raycast(raycastQuery)
            
            // If we hit a vertical plane (wall) before reaching the object, hide it
            var isOccluded = false
            for result in raycastResults {
                // Check if the hit point is closer than the object (wall is between camera and object)
                let hitPoint = SIMD3<Float>(
                    result.worldTransform.columns.3.x,
                    result.worldTransform.columns.3.y,
                    result.worldTransform.columns.3.z
                )
                let hitDistance = length(hitPoint - cameraPosition)
                
                // If wall is closer than object (with some tolerance), object is occluded
                if hitDistance < distance - 0.3 { // 0.3m tolerance
                    isOccluded = true
                    break
                }
            }
            
            // Show/hide all children based on occlusion
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity {
                    modelEntity.isEnabled = !isOccluded
                } else {
                    child.isEnabled = !isOccluded
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        if elapsed > 10.0 { // Only log if takes more than 10ms
            Swift.print("⏱️ [PERF] checkOcclusionForPlacedBoxes took \(String(format: "%.1f", elapsed))ms for \(placedBoxes.count) objects")
        }
    }

    deinit {
        occlusionCheckTimer?.invalidate()
    }
}

