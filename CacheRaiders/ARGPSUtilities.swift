import Foundation
import CoreLocation
import RealityKit
import ARKit

/// Utility class for AR-GPS coordinate conversions and GPS correction operations
class ARGPSUtilities {

    // MARK: - GPS Correction

    /// Corrects GPS coordinates by calculating the offset needed to place object at intended AR position
    /// This compensates for GPS inaccuracy by measuring the difference between where GPS placement
    /// put the object vs where the user actually placed it in ARPlacementView
    /// - Parameters:
    ///   - location: The location object being corrected
    ///   - intendedARPosition: The intended AR position where user placed the object
    ///   - arOrigin: The GPS location of the AR origin point
    ///   - cameraTransform: Current camera transform (for logging)
    static func correctGPSCoordinates(
        location: LootBoxLocation,
        intendedARPosition: SIMD3<Float>,
        arOrigin: CLLocation,
        cameraTransform: simd_float4x4
    ) {
        // Convert intended AR position back to GPS coordinates
        // This gives us the "corrected" GPS coordinates that would place the object
        // at the intended AR position when converted back through GPS->AR conversion

        // Calculate offset from AR origin (0,0,0) to intended position
        let offset = intendedARPosition

        // Convert offset to distance and bearing
        let distanceX = Double(offset.x)
        let distanceZ = Double(offset.z)
        let distance = sqrt(distanceX * distanceX + distanceZ * distanceZ)

        // Calculate bearing from AR origin
        // In AR space: +X = East, +Z = North
        let bearingRad = atan2(distanceX, distanceZ)
        let bearingDeg = bearingRad * 180.0 / .pi
        let compassBearing = (bearingDeg + 360).truncatingRemainder(dividingBy: 360)

        // Calculate corrected GPS coordinate from AR origin
        let correctedCoordinate = arOrigin.coordinate.coordinate(atDistance: distance, atBearing: compassBearing)

        Swift.print("   📍 Calculated corrected GPS coordinates:")
        Swift.print("      Original GPS: (\(String(format: "%.6f", location.latitude)), \(String(format: "%.6f", location.longitude)))")
        Swift.print("      Corrected GPS: (\(String(format: "%.6f", correctedCoordinate.latitude)), \(String(format: "%.6f", correctedCoordinate.longitude)))")
        Swift.print("      Distance from AR origin: \(String(format: "%.4f", distance))m")
        Swift.print("      Bearing: \(String(format: "%.1f", compassBearing))°")

        // Update GPS coordinates in the API
        Task {
            do {
                try await APIService.shared.updateObjectLocation(
                    objectId: location.id,
                    latitude: correctedCoordinate.latitude,
                    longitude: correctedCoordinate.longitude
                )
                Swift.print("   ✅ GPS coordinates corrected and saved to API")

                // Note: LocationManager reloading would happen in the calling context
            } catch {
                Swift.print("   ❌ Failed to update corrected GPS coordinates: \(error)")
            }
        }
    }

    // MARK: - AR-Enhanced Location

    /// Gets AR-enhanced GPS location (more accurate than raw GPS)
    /// Converts current AR camera position to GPS coordinates using AR origin
    /// - Parameters:
    ///   - arView: The AR view
    ///   - frame: Current AR frame
    ///   - arOrigin: The GPS location of the AR origin point
    /// - Returns: Tuple with enhanced GPS coordinates and AR offsets, or nil if not available
    static func getAREnhancedLocation(arView: ARView, frame: ARFrame, arOrigin: CLLocation) -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Convert AR camera position back to GPS coordinates
        guard let enhancedGPS = ARMathUtilities.convertARToGPS(arPosition: cameraPos, arOrigin: arOrigin) else {
            return nil
        }

        return (
            latitude: enhancedGPS.latitude,
            longitude: enhancedGPS.longitude,
            arOffsetX: Double(cameraPos.x),
            arOffsetY: Double(cameraPos.y),
            arOffsetZ: Double(cameraPos.z)
        )
    }

    // MARK: - Distance Calculations

    /// Calculates the distance between two GPS coordinates
    /// - Parameters:
    ///   - coordinate1: First GPS coordinate
    ///   - coordinate2: Second GPS coordinate
    /// - Returns: Distance in meters
    static func distanceBetweenGPSCoordinates(_ coordinate1: CLLocationCoordinate2D, _ coordinate2: CLLocationCoordinate2D) -> Double {
        let location1 = CLLocation(latitude: coordinate1.latitude, longitude: coordinate1.longitude)
        let location2 = CLLocation(latitude: coordinate2.latitude, longitude: coordinate2.longitude)
        return location1.distance(from: location2)
    }

    /// Calculates the bearing (direction) from one GPS coordinate to another
    /// - Parameters:
    ///   - from: Starting GPS coordinate
    ///   - to: Target GPS coordinate
    /// - Returns: Bearing in degrees (0 = North, 90 = East, 180 = South, 270 = West)
    static func bearingFromGPSCoordinate(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let lon2 = to.longitude * .pi / 180.0

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let bearing = atan2(y, x) * 180.0 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Accuracy Validation

    /// Checks if GPS accuracy is sufficient for AR operations
    /// - Parameter location: The location to check
    /// - Returns: True if accuracy is acceptable, false otherwise
    static func isGPSAccuracySufficient(_ location: CLLocation) -> Bool {
        // Accept up to 20m for better UX (consistent with placement view)
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 20.0
    }

    /// Gets a description of GPS accuracy level
    /// - Parameter accuracy: Horizontal accuracy in meters
    /// - Returns: Human-readable accuracy description
    static func getGPSAccuracyDescription(_ accuracy: Double) -> String {
        if accuracy < 0 {
            return "unknown"
        } else if accuracy < 5.0 {
            return "excellent (< 5m)"
        } else if accuracy < 10.0 {
            return "good (< 10m)"
        } else if accuracy < 20.0 {
            return "fair (< 20m)"
        } else {
            return "poor (> 20m)"
        }
    }
}