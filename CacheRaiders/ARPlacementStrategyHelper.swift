import RealityKit
import ARKit

/// Helper for determining object placement strategies based on environment
class ARPlacementStrategyHelper {
    
    /// Generate position for indoor placement (simplified approach)
    static func generateIndoorPosition(cameraPos: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> (x: Float, z: Float) {
        // Simplified indoor placement: just place closer to camera in a smaller area
        // Avoid complex wall boundary calculations that might be failing
        Swift.print("🏠 Using simplified indoor placement")

        let randomDistance = Float.random(in: minDistance...min(maxDistance, 4.0)) // Limit to 4m indoors
        let randomAngle = Float.random(in: 0...(2 * Float.pi)) // Any direction

        let x = cameraPos.x + randomDistance * cos(randomAngle)
        let z = cameraPos.z + randomDistance * sin(randomAngle)

        Swift.print("🏠 Indoor position: distance \(String(format: "%.1f", randomDistance))m, angle \(String(format: "%.1f", randomAngle * 180 / .pi))°")
        return (x, z)
    }

    /// Check if a position is within room boundaries defined by walls
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

    /// Get placement strategy - simplified for reliable sphere spawning
    static func getPlacementStrategy(isIndoors: Bool, searchDistance: Float) -> (minDistance: Float, maxDistance: Float, strategy: String) {
        // Use indoor-like distances for reliable sphere spawning
        return (
            minDistance: 1.0, // Minimum 1 meter
            maxDistance: 8.0,  // Maximum 8 meters (reasonable for indoor spaces)
            strategy: "INDOOR-FRIENDLY MODE - close placement for spheres"
        )
    }
}

