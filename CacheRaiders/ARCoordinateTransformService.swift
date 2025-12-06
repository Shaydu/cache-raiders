import Foundation
import CoreLocation
import simd

// MARK: - AR Coordinate Transform Service
/// Handles coordinate transformations between different AR sessions for cross-user consistency
/// This service ensures that objects placed by one user appear in the correct location for other users
class ARCoordinateTransformService {

    // MARK: - Singleton
    static let shared = ARCoordinateTransformService()

    private init() {
        Swift.print("🔄 ARCoordinateTransformService initialized")
    }

    // MARK: - Coordinate Transformation

    /// Transforms AR coordinates from one AR session's origin to another
    /// - Parameters:
    ///   - storedPosition: Original AR position (relative to stored origin)
    ///   - storedOrigin: GPS location where object was originally placed
    ///   - currentOrigin: GPS location of current AR session
    ///   - geospatialService: Service for GPS/ENU conversions
    /// - Returns: Transformed AR position for current session, or original if transform fails
    func transformARCoordinates(
        storedPosition: SIMD3<Float>,
        storedOrigin: CLLocation,
        currentOrigin: CLLocation,
        geospatialService: ARGeospatialService?
    ) -> SIMD3<Float> {

        let originDistance = currentOrigin.distance(from: storedOrigin)

        // If origins are essentially the same (<1m), no transformation needed
        if originDistance < 1.0 {
            Swift.print("   ✅ AR origins match (<1m apart) - using stored coordinates directly")
            return storedPosition
        }

        // Origins are different - transform coordinates using ENU system
        guard let geospatialService = geospatialService,
              let storedOriginENU = geospatialService.convertGPSToENU(storedOrigin) else {
            Swift.print("   ⚠️ Could not convert stored origin to ENU - using stored position directly")
            return storedPosition
        }

        Swift.print("   🔄 Transforming coordinates between AR sessions:")
        Swift.print("      Stored origin: (\(String(format: "%.6f", storedOrigin.coordinate.latitude)), \(String(format: "%.6f", storedOrigin.coordinate.longitude)))")
        Swift.print("      Current origin: (\(String(format: "%.6f", currentOrigin.coordinate.latitude)), \(String(format: "%.6f", currentOrigin.coordinate.longitude)))")
        Swift.print("      Origin distance: \(String(format: "%.3f", originDistance))m")
        Swift.print("      Stored origin in current ENU: (\(String(format: "%.3f", storedOriginENU.x))m E, \(String(format: "%.3f", storedOriginENU.y))m N)")

        // Transform AR coordinates from stored origin's coordinate system to current origin's system
        // ARKit coordinate system: +X = East, +Y = Up, +Z = -North
        // ENU coordinate system: +E = East, +N = North, +U = Up

        // storedPosition is relative to storedOrigin in ARKit coords
        // storedOriginENU is the offset from currentOrigin to storedOrigin in ENU coords

        // Convert stored AR position to ENU offset from stored origin
        let storedARInENU = SIMD3<Double>(
            Double(storedPosition.x),     // East component stays the same
            -Double(storedPosition.z),    // North component (ARKit Z is -North)
            Double(storedPosition.y)      // Up component stays the same
        )

        // Add the stored origin's ENU offset to get absolute position in current ENU
        let absoluteENU = SIMD3<Double>(
            storedOriginENU.x + storedARInENU.x,
            storedOriginENU.y + storedARInENU.y,
            storedOriginENU.z + storedARInENU.z
        )

        // Convert back to ARKit coordinates
        let transformedPosition = SIMD3<Float>(
            Float(absoluteENU.x),    // East → X
            Float(absoluteENU.z),    // Up → Y
            -Float(absoluteENU.y)    // North → -Z
        )

        Swift.print("      Original AR position: (\(String(format: "%.3f", storedPosition.x)), \(String(format: "%.3f", storedPosition.y)), \(String(format: "%.3f", storedPosition.z)))m")
        Swift.print("      Transformed AR position: (\(String(format: "%.3f", transformedPosition.x)), \(String(format: "%.3f", transformedPosition.y)), \(String(format: "%.3f", transformedPosition.z)))m")
        Swift.print("      Δ Position: (\(String(format: "%.3f", transformedPosition.x - storedPosition.x)), \(String(format: "%.3f", transformedPosition.y - storedPosition.y)), \(String(format: "%.3f", transformedPosition.z - storedPosition.z)))m")

        return transformedPosition
    }

    // MARK: - Compass-Based Rotation

    /// Rotates AR coordinates based on compass heading difference
    /// This ensures objects maintain correct orientation when viewed from different headings
    /// - Parameters:
    ///   - position: AR position to rotate
    ///   - storedHeading: Compass heading when object was placed (0-360°), or nil
    ///   - currentHeading: Current device heading (0-360°), or nil
    /// - Returns: Rotated AR position, or original if headings unavailable
    func rotateForCompassHeading(
        position: SIMD3<Float>,
        storedHeading: Double?,
        currentHeading: Double?
    ) -> SIMD3<Float> {

        // If either heading is missing, can't rotate - return original position
        guard let stored = storedHeading,
              let current = currentHeading else {
            Swift.print("      Compass rotation: skipped (heading data unavailable)")
            return position
        }

        // Calculate heading difference (how much the user has rotated)
        var headingDelta = current - stored

        // Normalize to -180° to 180°
        while headingDelta > 180 { headingDelta -= 360 }
        while headingDelta < -180 { headingDelta += 360 }

        // If heading difference is negligible (<5°), skip rotation
        if abs(headingDelta) < 5.0 {
            Swift.print("      Compass rotation: skipped (heading delta \(String(format: "%.1f", headingDelta))° < 5°)")
            return position
        }

        Swift.print("      Compass rotation: \(String(format: "%.1f", headingDelta))° (stored: \(String(format: "%.1f", stored))°, current: \(String(format: "%.1f", current))°)")

        // Convert heading delta to radians
        let angleRad = Float(headingDelta * .pi / 180.0)

        // Create rotation matrix around Y axis (vertical)
        // Rotate in XZ plane (horizontal plane)
        let cosAngle = cos(angleRad)
        let sinAngle = sin(angleRad)

        // Apply rotation: rotate coordinates around Y axis
        let rotatedX = position.x * cosAngle - position.z * sinAngle
        let rotatedZ = position.x * sinAngle + position.z * cosAngle

        let rotatedPosition = SIMD3<Float>(rotatedX, position.y, rotatedZ)

        Swift.print("      Original: (\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z)))m")
        Swift.print("      Rotated: (\(String(format: "%.3f", rotatedPosition.x)), \(String(format: "%.3f", rotatedPosition.y)), \(String(format: "%.3f", rotatedPosition.z)))m")

        return rotatedPosition
    }

    // MARK: - Combined Transformation

    /// Applies both origin transformation and compass rotation
    /// This is the main method for cross-user coordinate consistency
    /// - Parameters:
    ///   - storedPosition: Original AR position
    ///   - storedOrigin: GPS origin where object was placed
    ///   - storedHeading: Compass heading when placed
    ///   - currentOrigin: Current AR session GPS origin
    ///   - currentHeading: Current device heading
    ///   - geospatialService: Service for GPS/ENU conversions
    /// - Returns: Fully transformed AR position for current session
    func transformAndRotate(
        storedPosition: SIMD3<Float>,
        storedOrigin: CLLocation,
        storedHeading: Double?,
        currentOrigin: CLLocation,
        currentHeading: Double?,
        geospatialService: ARGeospatialService?
    ) -> SIMD3<Float> {

        Swift.print("   🔄 Full coordinate transformation:")

        // Step 1: Transform coordinates between AR origins
        let transformedPosition = transformARCoordinates(
            storedPosition: storedPosition,
            storedOrigin: storedOrigin,
            currentOrigin: currentOrigin,
            geospatialService: geospatialService
        )

        // Step 2: Apply compass rotation
        let finalPosition = rotateForCompassHeading(
            position: transformedPosition,
            storedHeading: storedHeading,
            currentHeading: currentHeading
        )

        Swift.print("   ✅ Transformation complete:")
        Swift.print("      Input: (\(String(format: "%.3f", storedPosition.x)), \(String(format: "%.3f", storedPosition.y)), \(String(format: "%.3f", storedPosition.z)))m")
        Swift.print("      Output: (\(String(format: "%.3f", finalPosition.x)), \(String(format: "%.3f", finalPosition.y)), \(String(format: "%.3f", finalPosition.z)))m")

        return finalPosition
    }
}
