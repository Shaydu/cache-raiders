import Foundation
import RealityKit
import ARKit

// MARK: - AR Grounding Service
/// Handles grounding objects on horizontal surfaces (floor or highest blocking surface)
class ARGroundingService {
    weak var arView: ARView?
    
    /// Horizontal tolerance for determining if a surface "blocks" the floor (in meters)
    private let horizontalTolerance: Float = 0.5 // 50cm tolerance
    
    /// Maximum height difference from camera to consider a surface valid (in meters)
    private let maxHeightDifference: Float = 2.0
    
    init(arView: ARView?) {
        self.arView = arView
    }
    
    /// Finds the highest horizontal surface that blocks the floor at the given X/Z coordinates.
    /// If no surface blocks the floor, returns the floor position.
    /// - Parameters:
    ///   - x: X coordinate in AR world space
    ///   - z: Z coordinate in AR world space
    ///   - cameraPos: Current camera position (used for raycast origin and validation)
    /// - Returns: The Y coordinate of the surface to place the object on, or nil if no valid surface found
    func findHighestBlockingSurface(x: Float, z: Float, cameraPos: SIMD3<Float>) -> Float? {
        guard let arView = arView else {
            Swift.print("⚠️ ARGroundingService: No AR view available")
            return nil
        }
        
        // Raycast downward from above the target position to find all horizontal surfaces
        let raycastOrigin = SIMD3<Float>(x, cameraPos.y + 1.0, z)
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0),
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        // Get all raycast results (not just the first one)
        let raycastResults = arView.session.raycast(raycastQuery)
        
        guard !raycastResults.isEmpty else {
            Swift.print("⚠️ ARGroundingService: No horizontal surfaces found at position (x: \(String(format: "%.2f", x)), z: \(String(format: "%.2f", z)))")
            return nil
        }
        
        // Filter out surfaces above camera (likely ceilings) and sort by Y (lowest to highest)
        let validSurfaces = raycastResults
            .map { result -> (y: Float, transform: simd_float4x4) in
                let y = result.worldTransform.columns.3.y
                return (y: y, transform: result.worldTransform)
            }
            .filter { $0.y < cameraPos.y - 0.2 } // Reject ceilings
            .sorted { $0.y < $1.y } // Sort from lowest (floor) to highest
        
        guard !validSurfaces.isEmpty else {
            Swift.print("⚠️ ARGroundingService: No valid horizontal surfaces found (all were ceilings)")
            return nil
        }
        
        // The first surface is the floor (lowest)
        let floorY = validSurfaces.first!.y
        let floorTransform = validSurfaces.first!.transform
        
        // Check if any surface above the floor blocks it
        // A surface "blocks" the floor if it's directly above the floor position (within tolerance)
        var highestBlockingSurface: Float? = nil
        
        // Check each surface above the floor
        for surface in validSurfaces.dropFirst() {
            let surfaceY = surface.y
            let surfaceTransform = surface.transform
            let surfaceX = surfaceTransform.columns.3.x
            let surfaceZ = surfaceTransform.columns.3.z
            
            // Check if this surface is directly above the floor position (within tolerance)
            let horizontalDistance = sqrt(
                pow(surfaceX - x, 2) + pow(surfaceZ - z, 2)
            )
            
            if horizontalDistance <= horizontalTolerance {
                // This surface is directly above the floor - it blocks it
                highestBlockingSurface = surfaceY
                Swift.print("✅ ARGroundingService: Found blocking surface at Y: \(String(format: "%.2f", surfaceY)) (floor at Y: \(String(format: "%.2f", floorY)))")
            }
        }
        
        // Return the highest blocking surface, or the floor if nothing blocks it
        if let blockingY = highestBlockingSurface {
            Swift.print("✅ ARGroundingService: Using highest blocking surface at Y: \(String(format: "%.2f", blockingY))")
            return blockingY
        } else {
            Swift.print("✅ ARGroundingService: Using floor surface at Y: \(String(format: "%.2f", floorY))")
            return floorY
        }
    }
    
    /// Grounds a position by finding the highest blocking surface at the given X/Z coordinates.
    /// - Parameters:
    ///   - position: The 3D position to ground (X and Z are used, Y will be updated)
    ///   - cameraPos: Current camera position
    /// - Returns: A new position with Y updated to the surface height, or the original position if no surface found
    func groundPosition(_ position: SIMD3<Float>, cameraPos: SIMD3<Float>) -> SIMD3<Float> {
        guard let surfaceY = findHighestBlockingSurface(x: position.x, z: position.z, cameraPos: cameraPos) else {
            return position
        }
        return SIMD3<Float>(position.x, surfaceY, position.z)
    }
    
    /// Validates if a surface Y coordinate is reasonable (not too far from camera)
    /// - Parameters:
    ///   - surfaceY: The Y coordinate of the surface
    ///   - cameraY: The Y coordinate of the camera
    /// - Returns: True if the surface is within acceptable range
    func isValidSurfaceHeight(surfaceY: Float, cameraY: Float) -> Bool {
        let heightDiff = abs(surfaceY - cameraY)
        return heightDiff <= maxHeightDifference
    }
    
    /// Attempts to find a surface at multiple nearby positions (for fallback search)
    /// - Parameters:
    ///   - centerX: Center X coordinate
    ///   - centerZ: Center Z coordinate
    ///   - cameraPos: Current camera position
    ///   - searchOffsets: Array of offsets to try (defaults to 5 positions in a cross pattern)
    /// - Returns: The Y coordinate of the first valid surface found, or nil if none found
    func findSurfaceWithFallback(centerX: Float, centerZ: Float, cameraPos: SIMD3<Float>, searchOffsets: [SIMD3<Float>]? = nil) -> Float? {
        let offsets = searchOffsets ?? [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0.5, 0, 0),
            SIMD3<Float>(-0.5, 0, 0),
            SIMD3<Float>(0, 0, 0.5),
            SIMD3<Float>(0, 0, -0.5)
        ]
        
        for offset in offsets {
            let searchX = centerX + offset.x
            let searchZ = centerZ + offset.z
            if let surfaceY = findHighestBlockingSurface(x: searchX, z: searchZ, cameraPos: cameraPos) {
                return surfaceY
            }
        }
        
        return nil
    }
}


