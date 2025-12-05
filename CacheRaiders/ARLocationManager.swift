import CoreLocation
import ARKit
import RealityKit

// MARK: - AR Location Manager
class ARLocationManager {

    private weak var arCoordinator: ARCoordinatorCore?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore) {
        self.arCoordinator = arCoordinator
    }

    // MARK: - AR-Enhanced Location

    /// Get AR-enhanced GPS location (more accurate than raw GPS)
    /// Converts current AR camera position to GPS coordinates using AR origin
    /// Returns nil if AR origin not set or AR not available
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        guard let arView = arCoordinator?.arView,
              let frame = arView.session.currentFrame,
              let arOrigin = arCoordinator?.arOriginLocation else {
            return nil
        }

        // Get current camera position in AR world space
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Convert AR position to GPS coordinates
        // AR origin is at (0,0,0) in AR space, so camera position is the offset
        let distance = sqrt(cameraPos.x * cameraPos.x + cameraPos.z * cameraPos.z) // Horizontal distance
        let bearing = atan2(Double(cameraPos.x), -Double(cameraPos.z)) * 180.0 / .pi // Bearing in degrees (0 = north)
        let normalizedBearing = (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)

        // Calculate GPS coordinate from AR origin
        let enhancedGPS = arOrigin.coordinate.coordinate(atDistance: Double(distance), atBearing: normalizedBearing)

        return (
            latitude: enhancedGPS.latitude,
            longitude: enhancedGPS.longitude,
            arOffsetX: Double(cameraPos.x),
            arOffsetY: Double(cameraPos.y),
            arOffsetZ: Double(cameraPos.z)
        )
    }

    // MARK: - GPS Correction

    /// Corrects GPS coordinates by calculating the offset needed to place object at intended AR position
    /// This compensates for GPS inaccuracy by measuring the difference between where GPS placement
    /// put the object vs where the user actually placed it in ARPlacementView
    func correctGPSCoordinates(
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
                    location: CLLocation(latitude: correctedCoordinate.latitude, longitude: correctedCoordinate.longitude)
                )
                Swift.print("   ✅ GPS coordinates corrected and saved to API")

                // Reload locations to pick up the corrected coordinates
                await arCoordinator?.locationManager?.loadLocationsFromAPI(userLocation: arCoordinator?.userLocationManager?.currentLocation)
                Swift.print("   🔄 Locations reloaded with corrected GPS coordinates")

            } catch {
                Swift.print("   ❌ Failed to update GPS coordinates: \(error)")
            }
        }
    }

    /// Get the distance from AR origin to a given AR position
    func distanceFromAROrigin(_ arPosition: SIMD3<Float>) -> Double {
        let distance = sqrt(arPosition.x * arPosition.x + arPosition.z * arPosition.z)
        return Double(distance)
    }

    /// Get the bearing from AR origin to a given AR position (in degrees, 0 = north)
    func bearingFromAROrigin(_ arPosition: SIMD3<Float>) -> Double {
        let bearing = atan2(Double(arPosition.x), Double(arPosition.z)) * 180.0 / .pi
        return (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    /// Convert AR position to GPS coordinates using AR origin
    func arPositionToGPS(_ arPosition: SIMD3<Float>, arOrigin: CLLocation) -> CLLocationCoordinate2D {
        let distance = distanceFromAROrigin(arPosition)
        let bearing = bearingFromAROrigin(arPosition)
        return arOrigin.coordinate.coordinate(atDistance: distance, atBearing: bearing)
    }

    /// Convert GPS coordinate to AR position relative to AR origin
    func gpsToARPosition(coordinate: CLLocationCoordinate2D, arOrigin: CLLocation) -> SIMD3<Float> {
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = arOrigin.distance(from: targetLocation)
        let bearing = arOrigin.bearing(to: targetLocation)

        // Convert bearing to AR space (0 = north/+Z, 90 = east/+X)
        let arBearingRad = (bearing - 90.0) * .pi / 180.0 // Subtract 90 to convert from north-based to east-based
        let arX = Float(distance * sin(arBearingRad))
        let arZ = Float(distance * cos(arBearingRad))

        return SIMD3<Float>(arX, 0, arZ) // Y=0 for ground level initially
    }

    /// Check if GPS coordinates are valid
    func isValidGPSCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        return coordinate.latitude >= -90 && coordinate.latitude <= 90 &&
               coordinate.longitude >= -180 && coordinate.longitude <= 180
    }

    /// Check if AR origin is set and valid
    var hasValidAROrigin: Bool {
        guard let arOrigin = arCoordinator?.arOriginLocation else { return false }
        return isValidGPSCoordinate(arOrigin.coordinate)
    }
}

