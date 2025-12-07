import Foundation
import CoreLocation
import RealityKit

/// Utility class for AR mathematical operations and coordinate conversions
class ARMathUtilities {

    // MARK: - Coordinate Conversion

    /// Converts AR world position back to GPS coordinates using AR origin
    /// - Parameters:
    ///   - arPosition: Position in AR world space (relative to AR origin at 0,0,0)
    ///   - arOrigin: GPS location of the AR origin point
    /// - Returns: GPS coordinates corresponding to the AR position
    static func convertARToGPS(arPosition: SIMD3<Float>, arOrigin: CLLocation) -> CLLocationCoordinate2D? {
        // Calculate offset from AR origin (0,0,0) to target position
        let offset = arPosition

        // Convert offset to meters (AR units are in meters)
        let distanceX = Double(offset.x)
        let distanceZ = Double(offset.z)

        // Calculate distance from AR origin
        let distance = sqrt(distanceX * distanceX + distanceZ * distanceZ)

        // Calculate bearing from AR origin
        // In AR space: +X = East, +Z = North
        let bearingRad = atan2(distanceX, distanceZ)
        let bearingDeg = bearingRad * 180.0 / .pi
        let compassBearing = (bearingDeg + 360).truncatingRemainder(dividingBy: 360)

        // Calculate GPS coordinate from AR origin GPS location
        let targetGPS = arOrigin.coordinate.coordinate(atDistance: distance, atBearing: compassBearing)

        return targetGPS
    }

    // MARK: - Distance Calculations

    /// Calculates horizontal distance (X-Z plane only) between two positions
    /// - Parameters:
    ///   - position1: First position
    ///   - position2: Second position
    /// - Returns: Horizontal distance in meters
    static func horizontalDistanceBetween(_ position1: SIMD3<Float>, _ position2: SIMD3<Float>) -> Float {
        let deltaX = position2.x - position1.x
        let deltaZ = position2.z - position1.z
        return sqrt(deltaX * deltaX + deltaZ * deltaZ)
    }
}