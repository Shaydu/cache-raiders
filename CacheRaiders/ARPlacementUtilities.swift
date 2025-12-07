import Foundation
import RealityKit
import ARKit
import CoreLocation

/// Utility class for AR object placement operations and strategies
class ARPlacementUtilities {

    // MARK: - Placement Strategies

    /// Gets placement strategy based on indoor/outdoor detection and search distance
    /// - Parameters:
    ///   - isIndoors: Whether placement is happening indoors
    ///   - searchDistance: Current search distance setting
    /// - Returns: Tuple with min/max distances and strategy description
    static func getPlacementStrategy(isIndoors: Bool, searchDistance: Float) -> (minDistance: Float, maxDistance: Float, strategy: String) {
        // Use indoor-like distances for reliable sphere spawning
        return (
            minDistance: 1.0, // Minimum 1 meter
            maxDistance: 8.0,  // Maximum 8 meters (reasonable for indoor spaces)
            strategy: "INDOOR-FRIENDLY MODE - close placement for spheres"
        )
    }

    /// Generates a position for indoor placement
    /// - Parameters:
    ///   - cameraPos: Current camera position
    ///   - minDistance: Minimum distance from camera
    ///   - maxDistance: Maximum distance from camera
    /// - Returns: X,Z coordinates for placement (Y will be determined by grounding)
    static func generateIndoorPosition(cameraPos: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> (x: Float, z: Float) {
        Swift.print("🏠 Using simplified indoor placement")

        let randomDistance = Float.random(in: minDistance...min(maxDistance, 4.0)) // Limit to 4m indoors
        let randomAngle = Float.random(in: 0...(2 * Float.pi)) // Any direction

        let x = cameraPos.x + randomDistance * cos(randomAngle)
        let z = cameraPos.z + randomDistance * sin(randomAngle)

        Swift.print("🏠 Indoor position: distance \(String(format: "%.1f", randomDistance))m, angle \(String(format: "%.1f", randomAngle * 180 / .pi))°")
        return (x, z)
    }

    /// Generates a position for outdoor placement
    /// - Parameters:
    ///   - cameraPos: Current camera position
    ///   - minDistance: Minimum distance from camera
    ///   - maxDistance: Maximum distance from camera
    /// - Returns: X,Z coordinates for placement (Y will be determined by grounding)
    static func generateOutdoorPosition(cameraPos: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> (x: Float, z: Float) {
        let randomDistance = Float.random(in: minDistance...maxDistance)
        let randomAngle = Float.random(in: 0...(2 * Float.pi))

        let x = cameraPos.x + randomDistance * cos(randomAngle)
        let z = cameraPos.z + randomDistance * sin(randomAngle)

        return (x, z)
    }

    // MARK: - Room Boundary Checks

    /// Checks if a position is within room boundaries defined by walls
    /// - Parameters:
    ///   - x: X coordinate to test
    ///   - z: Z coordinate to test
    ///   - cameraPos: Current camera position (for Y reference)
    ///   - walls: Array of AR plane anchors representing walls
    /// - Returns: True if position is within bounds, false otherwise
    static func isPositionWithinRoomBounds(x: Float, z: Float, cameraPos: SIMD3<Float>, walls: [ARPlaneAnchor]) -> Bool {
        let testPos = SIMD3<Float>(x, cameraPos.y, z)

        // For each wall, check if the position is on the correct side
        for wall in walls {
            let wallTransform = wall.transform
            let wallPosition = SIMD3<Float>(
                wallTransform.columns.3.x,
                wallTransform.columns.3.y,
                wallTransform.columns.3.z
            )

            // Get wall normal (direction the wall is facing)
            let wallNormal = SIMD3<Float>(
                wallTransform.columns.2.x,
                wallTransform.columns.2.y,
                wallTransform.columns.2.z
            )

            // Vector from wall to test position
            let toTestPos = testPos - wallPosition

            // If the dot product is positive, the position is on the "outside" of the wall
            // We want positions on the "inside" (negative dot product)
            let dotProduct = dot(wallNormal, toTestPos)

            // Allow some tolerance - if clearly outside, reject
            if dotProduct > 1.0 { // More than 1m outside the wall
                return false
            }
        }

        return true // Position is within bounds or no clear boundary violation
    }

    // MARK: - Collision Detection

    /// Checks if a position would collide with existing objects
    /// - Parameters:
    ///   - position: Position to check
    ///   - existingAnchors: Dictionary of existing object anchors
    ///   - minHorizontalSeparation: Minimum horizontal distance between objects
    ///   - minVerticalSeparation: Minimum vertical distance (prevents stacking)
    /// - Returns: True if position is valid (no collision), false if collision detected
    static func isValidPlacementPosition(
        _ position: SIMD3<Float>,
        existingAnchors: [String: AnchorEntity],
        minHorizontalSeparation: Float = 3.0,
        minVerticalSeparation: Float = 1.0
    ) -> Bool {
        for (existingId, existingAnchor) in existingAnchors {
            let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
            let existingPos = SIMD3<Float>(
                existingTransform.columns.3.x,
                existingTransform.columns.3.y,
                existingTransform.columns.3.z
            )

            // Calculate horizontal distance (X-Z plane)
            let horizontalDistance = ARMathUtilities.horizontalDistanceBetween(position, existingPos)

            // Calculate vertical distance (Y-axis)
            let verticalDistance = abs(position.y - existingPos.y)

            // Check both horizontal and vertical separation
            if horizontalDistance < minHorizontalSeparation {
                Swift.print("⚠️ Rejected placement - too close horizontally to existing object '\(existingId)'")
                Swift.print("   Horizontal distance: \(String(format: "%.2f", horizontalDistance))m (minimum: \(minHorizontalSeparation)m)")
                return false
            }

            // Also check if objects are stacking vertically (same X-Z position but different Y)
            if horizontalDistance < 0.5 && verticalDistance < minVerticalSeparation {
                Swift.print("⚠️ Rejected placement - stacking detected with existing object '\(existingId)'")
                Swift.print("   Vertical distance: \(String(format: "%.2f", verticalDistance))m (minimum: \(minVerticalSeparation)m)")
                return false
            }
        }

        return true
    }

    // MARK: - Grounding

    /// Finds the appropriate ground height for object placement
    /// - Parameters:
    ///   - x: X coordinate
    ///   - z: Z coordinate
    ///   - cameraPos: Camera position for reference
    ///   - objectType: Type of object being placed (affects grounding strategy)
    /// - Returns: Ground Y coordinate, or nil if no surface found
    static func findGroundHeight(x: Float, z: Float, cameraPos: SIMD3<Float>, objectType: LootBoxType) -> Float? {
        // This would typically use grounding service logic
        // For now, return a default height relative to camera
        let defaultHeight = cameraPos.y - 1.5 // 1.5m below camera

        // Object type specific adjustments
        switch objectType {
        case .chalice, .templeRelic, .turkey:
            return defaultHeight + 0.1 // Slightly higher for standing objects
        case .treasureChest, .lootChest, .lootCart, .terrorEngine:
            return defaultHeight - 0.1 // Slightly lower for box-like objects
        case .sphere, .cube:
            return defaultHeight // Default height for geometric objects
        }
    }

    // MARK: - Object Centering

    /// Centers an object on its base relative to the anchor position
    /// This ensures objects appear centered on crosshairs/placement reticle
    /// - Parameters:
    ///   - entity: The entity to center
    ///   - anchor: The anchor the entity is attached to
    static func centerEntityOnBase(entity: ModelEntity, anchor: AnchorEntity) {
        // Calculate the horizontal bounds of the entity relative to anchor
        let entityBounds = entity.visualBounds(relativeTo: anchor)
        let entityCenterX = (entityBounds.min.x + entityBounds.max.x) / 2.0
        let entityCenterZ = (entityBounds.min.z + entityBounds.max.z) / 2.0

        // Offset the entity so its center aligns with the anchor position (crosshairs)
        entity.position.x -= entityCenterX
        entity.position.z -= entityCenterZ

        Swift.print("🎯 [Centering] Object centered on crosshairs:")
        Swift.print("   Entity bounds: X=[\(String(format: "%.3f", entityBounds.min.x)), \(String(format: "%.3f", entityBounds.max.x))], Z=[\(String(format: "%.3f", entityBounds.min.z)), \(String(format: "%.3f", entityBounds.max.z))]")
        Swift.print("   Entity center: X=\(String(format: "%.3f", entityCenterX)), Z=\(String(format: "%.3f", entityCenterZ))")
        Swift.print("   Applied offset: X=\(String(format: "%.3f", -entityCenterX)), Z=\(String(format: "%.3f", -entityCenterZ))")
    }
}