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
    
    // MARK: - Performance Optimization: Raycast Caching & Throttling
    
    /// Cache for raycast results to avoid expensive repeated raycasts
    /// Key: grid position string "xGrid_zGrid", Value: (y coordinate, timestamp)
    private var raycastCache: [String: (y: Float, timestamp: Date)] = [:]
    
    /// Cache timeout - results are valid for this duration
    private let cacheTimeout: TimeInterval = 0.5 // 500ms cache validity
    
    /// Grid size for cache keys (0.5m grid - positions within 0.5m share same cache entry)
    private let cacheGridSize: Float = 0.5
    
    /// Throttling: minimum time between raycast operations
    private let minRaycastInterval: TimeInterval = 0.1 // Max 10 raycasts per second
    
    /// Last time a raycast was performed (for throttling)
    private var lastRaycastTime: Date = Date()
    
    /// Track if we're currently performing a raycast (prevent concurrent calls)
    private var isRaycasting: Bool = false
    
    init(arView: ARView?) {
        self.arView = arView
    }
    
    /// Finds the highest horizontal surface that blocks the floor at the given X/Z coordinates.
    /// If no surface blocks the floor, returns the floor position.
    /// Uses multiple raycast strategies to ensure reliable surface detection.
    /// PERFORMANCE: Uses caching and throttling to prevent freezes from excessive raycasts.
    /// - Parameters:
    ///   - x: X coordinate in AR world space
    ///   - z: Z coordinate in AR world space
    ///   - cameraPos: Current camera position (used for raycast origin and validation)
    ///   - silent: If true, suppresses warning logs (used for fallback searches)
    /// - Returns: The Y coordinate of the surface to place the object on, or nil if no valid surface found
    func findHighestBlockingSurface(x: Float, z: Float, cameraPos: SIMD3<Float>, silent: Bool = false) -> Float? {
        guard let arView = arView else {
            if !silent {
                Swift.print("⚠️ ARGroundingService: No AR view available")
            }
            return nil
        }
        
        // PERFORMANCE: Check cache first to avoid expensive raycasts
        let cacheKey = "\(Int(x / cacheGridSize))_\(Int(z / cacheGridSize))"
        let now = Date()
        
        if let cached = raycastCache[cacheKey],
           now.timeIntervalSince(cached.timestamp) < cacheTimeout {
            // Return cached result if still valid
            return cached.y
        }
        
        // PERFORMANCE: Throttle raycasts to prevent excessive calls
        let timeSinceLastRaycast = now.timeIntervalSince(lastRaycastTime)
        if timeSinceLastRaycast < minRaycastInterval {
            // Too soon since last raycast - return cached value or default
            if let cached = raycastCache[cacheKey] {
                // Use cached value even if slightly expired (better than blocking)
                return cached.y
            }
            // No cache available - return default height to avoid blocking
            // This prevents freeze when called too frequently
            return cameraPos.y - 1.5 // Default ground height
        }
        
        // Prevent concurrent raycasts
        guard !isRaycasting else {
            // If raycast in progress, return cached or default
            if let cached = raycastCache[cacheKey] {
                return cached.y
            }
            return cameraPos.y - 1.5
        }
        
        isRaycasting = true
        lastRaycastTime = now
        defer { isRaycasting = false }
        
        // Strategy 1: Raycast downward from above the target position
        let raycastOrigin = SIMD3<Float>(x, cameraPos.y + 1.0, z)
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0),
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        // Get all raycast results (not just the first one)
        var raycastResults = arView.session.raycast(raycastQuery)
        
        // Strategy 2: If no results from center, try nearby positions in a small grid pattern
        // PERFORMANCE: Limit to 3 additional attempts instead of 9 to reduce cost
        if raycastResults.isEmpty {
            let searchOffsets: [SIMD2<Float>] = [
                SIMD2<Float>(0.2, 0),
                SIMD2<Float>(-0.2, 0),
                SIMD2<Float>(0, 0.2),
                SIMD2<Float>(0, -0.2)
            ]
            
            for offset in searchOffsets {
                let offsetX = x + offset.x
                let offsetZ = z + offset.y
                let offsetOrigin = SIMD3<Float>(offsetX, cameraPos.y + 1.0, offsetZ)
                let offsetQuery = ARRaycastQuery(
                    origin: offsetOrigin,
                    direction: SIMD3<Float>(0, -1, 0),
                    allowing: .estimatedPlane,
                    alignment: .horizontal
                )
                raycastResults.append(contentsOf: arView.session.raycast(offsetQuery))
                if !raycastResults.isEmpty {
                    break // Found at least one result, proceed
                }
            }
        }
        
        guard !raycastResults.isEmpty else {
            // Only log if this is the primary search (not a fallback search)
            if !silent {
                Swift.print("⚠️ ARGroundingService: No horizontal surfaces found at position (x: \(String(format: "%.2f", x)), z: \(String(format: "%.2f", z)))")
            }
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
            if !silent {
                Swift.print("⚠️ ARGroundingService: No valid horizontal surfaces found (all were ceilings)")
            }
            return nil
        }
        
        // Find all surfaces that are at or near the target X/Z position (within tolerance)
        // These are surfaces that the object would actually rest on
        var surfacesAtTargetPosition: [(y: Float, transform: simd_float4x4)] = []

        for surface in validSurfaces {
            let surfaceY = surface.y
            let surfaceTransform = surface.transform
            let surfaceX = surfaceTransform.columns.3.x
            let surfaceZ = surfaceTransform.columns.3.z

            // Check if this surface is at the target X/Z position (within tolerance)
            let horizontalDistance = sqrt(
                pow(surfaceX - x, 2) + pow(surfaceZ - z, 2)
            )

            if horizontalDistance <= horizontalTolerance {
                surfacesAtTargetPosition.append(surface)
                // Only log success for primary searches to reduce verbosity
                if !silent {
                    Swift.print("✅ ARGroundingService: Found surface at target position - Y: \(String(format: "%.2f", surfaceY)), distance: \(String(format: "%.2f", horizontalDistance))m")
                }
            }
        }

        // If no surfaces found at target position, use the nearest valid surface (within expanded tolerance)
        if surfacesAtTargetPosition.isEmpty {
            // Find the closest surface within expanded tolerance (1.0m)
            let expandedTolerance: Float = 1.0
            var closestSurface: (y: Float, distance: Float)?
            
            for surface in validSurfaces {
                let surfaceTransform = surface.transform
                let surfaceX = surfaceTransform.columns.3.x
                let surfaceZ = surfaceTransform.columns.3.z
                let horizontalDistance = sqrt(
                    pow(surfaceX - x, 2) + pow(surfaceZ - z, 2)
                )
                
                if horizontalDistance <= expandedTolerance {
                    if closestSurface == nil || horizontalDistance < closestSurface!.distance {
                        closestSurface = (surface.y, horizontalDistance)
                    }
                }
            }
            
            if let closest = closestSurface {
                let resultY = closest.y
                // Cache the result
                raycastCache[cacheKey] = (resultY, now)
                if !silent {
                    Swift.print("✅ ARGroundingService: Using closest surface near target position - Y: \(String(format: "%.2f", resultY)), distance: \(String(format: "%.2f", closest.distance))m")
                }
                return resultY
            }
            
            // Final fallback: use the lowest valid surface (floor)
            let floorY = validSurfaces.first!.y
            // Cache the result
            raycastCache[cacheKey] = (floorY, now)
            if !silent {
                Swift.print("✅ ARGroundingService: No surfaces at target position, using floor at Y: \(String(format: "%.2f", floorY))")
            }
            return floorY
        }

        // Sort surfaces at target position by Y (highest to lowest)
        let sortedSurfaces = surfacesAtTargetPosition.sorted { $0.y > $1.y }

        // Return the HIGHEST surface at the target position (this is the topmost plane the object should rest on)
        let highestSurface = sortedSurfaces.first!
        let resultY = highestSurface.y
        
        // PERFORMANCE: Cache the result for future calls
        raycastCache[cacheKey] = (resultY, now)
        
        // Clean old cache entries periodically (keep cache size manageable)
        if raycastCache.count > 50 {
            let cutoffTime = now.addingTimeInterval(-cacheTimeout * 2)
            raycastCache = raycastCache.filter { $0.value.timestamp > cutoffTime }
        }
        
        if !silent {
            Swift.print("✅ ARGroundingService: Using highest surface at target position - Y: \(String(format: "%.2f", resultY))")
        }
        return resultY
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
            // Use silent mode for fallback searches to reduce log spam
            if let surfaceY = findHighestBlockingSurface(x: searchX, z: searchZ, cameraPos: cameraPos, silent: true) {
                return surfaceY
            }
        }

        return nil
    }

    /// Returns a default ground height based on object type when no surface is detected
    /// Uses camera position as reference
    /// - Parameters:
    ///   - objectType: The type of object being placed
    ///   - cameraPos: Current camera position
    /// - Returns: A default Y coordinate for placing the object
    func getDefaultGroundHeight(for objectType: LootBoxType, cameraPos: SIMD3<Float>) -> Float {
        switch objectType {
        case .sphere, .cube:
            // Small objects: place slightly below camera (as if on a low table/surface)
            return cameraPos.y - 0.8
        case .chalice, .turkey:
            // Medium height objects
            return cameraPos.y - 1.0
        case .treasureChest, .lootChest, .templeRelic, .lootCart, .terrorEngine:
            // Larger containers: place on floor
            return cameraPos.y - 1.5
        case .yourMom:
            // Your mom objects: place at default height
            return cameraPos.y - 1.2
        }
    }

    /// Returns a default ground height for NPCs when no surface is detected
    /// - Parameters:
    ///   - npcName: The name/type of NPC being placed ("skeleton" or "corgi")
    ///   - cameraPos: Current camera position
    /// - Returns: A default Y coordinate for placing the NPC
    func getDefaultGroundHeightForNPC(npcName: String, cameraPos: SIMD3<Float>) -> Float {
        switch npcName.lowercased() {
        case "skeleton":
            // Skeleton: tall character, place on floor
            return cameraPos.y - 1.5
        case "corgi", "traveller":
            // Corgi: small character, place slightly above floor for better visibility
            return cameraPos.y - 0.8
        default:
            // Default for unknown NPCs
            return cameraPos.y - 1.2
        }
    }

    /// Finds surface or returns default ground height
    /// This is the ultimate fallback - always returns a valid Y coordinate
    /// - Parameters:
    ///   - x: X coordinate in AR world space
    ///   - z: Z coordinate in AR world space
    ///   - cameraPos: Current camera position
    ///   - objectType: The type of object being placed (for default height)
    /// - Returns: The Y coordinate to place the object at
    func findSurfaceOrDefault(x: Float, z: Float, cameraPos: SIMD3<Float>, objectType: LootBoxType) -> Float {
        // Try to find actual surface (silent mode to reduce log spam)
        if let surfaceY = findHighestBlockingSurface(x: x, z: z, cameraPos: cameraPos, silent: true) {
            return surfaceY
        }

        // Try wider search (already uses silent mode internally)
        if let surfaceY = findSurfaceWithFallback(centerX: x, centerZ: z, cameraPos: cameraPos) {
            Swift.print("✅ ARGroundingService: Found surface via fallback search")
            return surfaceY
        }

        // Use default height for object type
        let defaultY = getDefaultGroundHeight(for: objectType, cameraPos: cameraPos)
        Swift.print("⚠️ ARGroundingService: No surface detected - using default height for \(objectType.displayName): Y=\(String(format: "%.2f", defaultY))")
        return defaultY
    }

    /// Finds surface or returns default ground height for NPCs
    /// This is the ultimate fallback - always returns a valid Y coordinate
    /// - Parameters:
    ///   - x: X coordinate in AR world space
    ///   - z: Z coordinate in AR world space
    ///   - cameraPos: Current camera position
    ///   - npcName: The name/type of NPC being placed (for default height)
    /// - Returns: The Y coordinate to place the NPC at
    func findSurfaceOrDefaultForNPC(x: Float, z: Float, cameraPos: SIMD3<Float>, npcName: String) -> Float {
        // Try to find actual surface (silent mode to reduce log spam)
        if let surfaceY = findHighestBlockingSurface(x: x, z: z, cameraPos: cameraPos, silent: true) {
            return surfaceY
        }

        // Try wider search (already uses silent mode internally)
        if let surfaceY = findSurfaceWithFallback(centerX: x, centerZ: z, cameraPos: cameraPos) {
            Swift.print("✅ ARGroundingService: Found surface via fallback search for \(npcName)")
            return surfaceY
        }

        // Use default height for NPC type
        let defaultY = getDefaultGroundHeightForNPC(npcName: npcName, cameraPos: cameraPos)
        Swift.print("⚠️ ARGroundingService: No surface detected - using default height for \(npcName): Y=\(String(format: "%.2f", defaultY))")
        return defaultY
    }
    
    /// Clears the raycast cache
    /// Call this when AR session resets or when you want to force fresh raycasts
    func clearCache() {
        raycastCache.removeAll()
        Swift.print("🧹 ARGroundingService: Raycast cache cleared")
    }
}


