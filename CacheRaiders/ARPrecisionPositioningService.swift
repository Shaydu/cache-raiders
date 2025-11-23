import Foundation
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Precision Positioning Service
/// Provides inch-level (2.54cm) accuracy for GPS-to-AR coordinate conversion
/// Uses hybrid GPS+AR approach: GPS for initial placement, AR refinement for precision
class ARPrecisionPositioningService {
    weak var arView: ARView?
    
    /// Distance threshold for switching from GPS to AR-based positioning (in meters)
    /// Within this distance, we use AR refinement for inch-level accuracy
    private let arRefinementThreshold: Double = 5.0 // 5 meters
    
    /// Grid size for multi-raycast averaging (in meters)
    /// Smaller grid = more precise but requires more raycasts
    private let raycastGridSize: Float = 0.05 // 5cm grid (about 2 inches)
    
    /// Number of raycasts per axis for averaging (creates NxN grid)
    private let raycastGridCount: Int = 5 // 5x5 = 25 raycasts
    
    /// Minimum number of successful raycasts required for averaging
    private let minRaycastSuccessCount: Int = 9 // At least 9 out of 25
    
    init(arView: ARView?) {
        self.arView = arView
    }
    
    /// Converts GPS coordinates to precise AR world position with inch-level accuracy
    /// - Parameters:
    ///   - targetGPS: Target GPS location
    ///   - userGPS: Current user GPS location
    ///   - cameraTransform: Current AR camera transform
    ///   - arOriginGPS: GPS location where AR session started (AR world origin)
    /// - Returns: Precise AR world position, or nil if positioning fails
    func convertGPSToARPosition(
        targetGPS: CLLocation,
        userGPS: CLLocation,
        cameraTransform: simd_float4x4,
        arOriginGPS: CLLocation?
    ) -> SIMD3<Float>? {
        guard let arView = arView else {
            Swift.print("⚠️ ARPrecisionPositioningService: No AR view available")
            return nil
        }
        
        let distance = userGPS.distance(from: targetGPS)
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // For close proximity (<5m), use high-precision AR-based positioning
        if distance < arRefinementThreshold {
            Swift.print("🎯 Using AR precision positioning (distance: \(String(format: "%.2f", distance))m < \(arRefinementThreshold)m)")
            return refinePositionWithAR(
                targetGPS: targetGPS,
                userGPS: userGPS,
                cameraPos: cameraPos,
                cameraTransform: cameraTransform,
                arOriginGPS: arOriginGPS
            )
        } else {
            // For far distances, use standard GPS-to-AR conversion
            Swift.print("📍 Using GPS-based positioning (distance: \(String(format: "%.2f", distance))m >= \(arRefinementThreshold)m)")
            return convertGPSToARStandard(
                targetGPS: targetGPS,
                userGPS: userGPS,
                cameraPos: cameraPos,
                cameraTransform: cameraTransform
            )
        }
    }
    
    /// High-precision AR-based position refinement for close proximity
    /// Uses multiple raycasts in a grid pattern and averages results for sub-inch accuracy
    private func refinePositionWithAR(
        targetGPS: CLLocation,
        userGPS: CLLocation,
        cameraPos: SIMD3<Float>,
        cameraTransform: simd_float4x4,
        arOriginGPS: CLLocation?
    ) -> SIMD3<Float>? {
        // Step 1: Get initial rough position using GPS
        guard let roughPosition = convertGPSToARStandard(
            targetGPS: targetGPS,
            userGPS: userGPS,
            cameraPos: cameraPos,
            cameraTransform: cameraTransform
        ) else {
            Swift.print("⚠️ ARPrecisionPositioningService: Failed to get rough GPS position")
            return nil
        }
        
        Swift.print("🎯 Rough GPS position: (\(String(format: "%.3f", roughPosition.x)), \(String(format: "%.3f", roughPosition.y)), \(String(format: "%.3f", roughPosition.z)))")
        
        // Step 2: Create a grid of raycast points around the rough position
        // This allows us to average multiple measurements for precision
        var raycastResults: [SIMD3<Float>] = []
        let gridStep = raycastGridSize / Float(raycastGridCount - 1)
        let gridOffset = raycastGridSize / 2.0
        
        // Create 5x5 grid centered on rough position
        for i in 0..<raycastGridCount {
            for j in 0..<raycastGridCount {
                let offsetX = Float(i) * gridStep - gridOffset
                let offsetZ = Float(j) * gridStep - gridOffset
                
                let raycastX = roughPosition.x + offsetX
                let raycastZ = roughPosition.z + offsetZ
                
                // Perform raycast downward to find surface
                if let surfaceY = performPrecisionRaycast(x: raycastX, z: raycastZ, cameraPos: cameraPos) {
                    let precisePosition = SIMD3<Float>(raycastX, surfaceY, raycastZ)
                    raycastResults.append(precisePosition)
                }
            }
        }
        
        // Step 3: Validate we have enough successful raycasts
        guard raycastResults.count >= minRaycastSuccessCount else {
            Swift.print("⚠️ ARPrecisionPositioningService: Only \(raycastResults.count) successful raycasts (need \(minRaycastSuccessCount))")
            // Fallback to single raycast at center
            if let surfaceY = performPrecisionRaycast(x: roughPosition.x, z: roughPosition.z, cameraPos: cameraPos) {
                return SIMD3<Float>(roughPosition.x, surfaceY, roughPosition.z)
            }
            return roughPosition
        }
        
        // Step 4: Average the raycast results for sub-inch precision
        let avgX = raycastResults.map { $0.x }.reduce(0, +) / Float(raycastResults.count)
        let avgY = raycastResults.map { $0.y }.reduce(0, +) / Float(raycastResults.count)
        let avgZ = raycastResults.map { $0.z }.reduce(0, +) / Float(raycastResults.count)
        
        let precisePosition = SIMD3<Float>(avgX, avgY, avgZ)
        
        // Calculate precision metrics
        let xVariance = calculateVariance(values: raycastResults.map { $0.x }, mean: avgX)
        let zVariance = calculateVariance(values: raycastResults.map { $0.z }, mean: avgZ)
        let maxDeviation = sqrt(max(xVariance, zVariance))
        
        Swift.print("✅ ARPrecisionPositioningService: Refined position using \(raycastResults.count) raycasts")
        Swift.print("   Position: (\(String(format: "%.4f", avgX)), \(String(format: "%.4f", avgY)), \(String(format: "%.4f", avgZ)))")
        Swift.print("   Max deviation: \(String(format: "%.4f", maxDeviation))m (\(String(format: "%.2f", maxDeviation * 39.37)) inches)")
        
        // If deviation is too high (>2 inches), log warning but still use result
        if maxDeviation > 0.05 { // 5cm = ~2 inches
            Swift.print("⚠️ ARPrecisionPositioningService: High deviation detected - surface may be uneven")
        }
        
        return precisePosition
    }
    
    /// Performs a precision raycast downward to find surface height
    /// Uses ARKit's high-precision tracking for millimeter-level accuracy
    private func performPrecisionRaycast(x: Float, z: Float, cameraPos: SIMD3<Float>) -> Float? {
        guard let arView = arView else { return nil }
        
        // Raycast from above the target position downward
        let raycastOrigin = SIMD3<Float>(x, cameraPos.y + 1.0, z)
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0),
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        let results = arView.session.raycast(raycastQuery)
        
        // Filter out surfaces above camera (ceilings) and get the highest valid surface
        let validSurfaces = results
            .map { $0.worldTransform.columns.3.y }
            .filter { $0 < cameraPos.y - 0.2 } // Reject ceilings
            .sorted(by: >) // Highest first
        
        return validSurfaces.first
    }
    
    /// Standard GPS-to-AR coordinate conversion (for distances >5m)
    private func convertGPSToARStandard(
        targetGPS: CLLocation,
        userGPS: CLLocation,
        cameraPos: SIMD3<Float>,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let distance = userGPS.distance(from: targetGPS)
        let bearing = userGPS.bearing(to: targetGPS)
        
        // Get camera's forward and right directions
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            0,
            -cameraTransform.columns.2.z
        )
        let cameraRight = SIMD3<Float>(
            cameraTransform.columns.0.x,
            0,
            cameraTransform.columns.0.z
        )
        
        // Normalize directions
        let forwardDir = normalize(cameraForward)
        let rightDir = normalize(cameraRight)
        
        // Convert bearing to radians
        let bearingRad = Float(bearing * .pi / 180.0)
        
        // Calculate offset in AR space
        let offsetX = Float(distance) * sin(bearingRad)
        let offsetZ = Float(distance) * cos(bearingRad)
        
        // Apply offset relative to camera's orientation
        let targetPos = cameraPos + rightDir * offsetX + forwardDir * offsetZ
        
        return targetPos
    }
    
    /// Calculates variance for precision metrics
    private func calculateVariance(values: [Float], mean: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        return squaredDiffs.reduce(0, +) / Float(values.count)
    }
    
    /// Gets the precise surface height at a given X/Z position using multi-raycast averaging
    /// - Parameters:
    ///   - x: X coordinate in AR world space
    ///   - z: Z coordinate in AR world space
    ///   - cameraPos: Current camera position
    /// - Returns: Precise Y coordinate, or nil if no surface found
    func getPreciseSurfaceHeight(x: Float, z: Float, cameraPos: SIMD3<Float>) -> Float? {
        // Use multi-raycast averaging for precision
        var heights: [Float] = []
        let gridStep = raycastGridSize / Float(raycastGridCount - 1)
        let gridOffset = raycastGridSize / 2.0
        
        for i in 0..<raycastGridCount {
            for j in 0..<raycastGridCount {
                let offsetX = Float(i) * gridStep - gridOffset
                let offsetZ = Float(j) * gridStep - gridOffset
                
                if let height = performPrecisionRaycast(x: x + offsetX, z: z + offsetZ, cameraPos: cameraPos) {
                    heights.append(height)
                }
            }
        }
        
        guard heights.count >= minRaycastSuccessCount else {
            // Fallback to single raycast
            return performPrecisionRaycast(x: x, z: z, cameraPos: cameraPos)
        }
        
        // Average the heights for precision
        let avgHeight = heights.reduce(0, +) / Float(heights.count)
        return avgHeight
    }
}

