import SwiftUI
import RealityKit
import ARKit
import CoreLocation

/// Service for correcting GPS coordinates based on AR placement accuracy
class ARGPSCorrectionService {
    weak var locationManager: LootBoxLocationManager?
    weak var userLocationManager: UserLocationManager?
    
    init(locationManager: LootBoxLocationManager?, userLocationManager: UserLocationManager?) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
    }
    
    /// Correct GPS coordinates based on intended AR position
    /// This compensates for GPS inaccuracy by measuring the difference between
    /// where GPS-based placement put the object vs where the user actually placed it
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
                    latitude: correctedCoordinate.latitude,
                    longitude: correctedCoordinate.longitude
                )
                Swift.print("   ✅ GPS coordinates corrected and saved to API")

                // Reload locations to pick up the corrected coordinates
                await locationManager?.loadLocationsFromAPI(userLocation: userLocationManager?.currentLocation)
                Swift.print("   🔄 Locations reloaded with corrected GPS coordinates")
            } catch {
                Swift.print("   ❌ Failed to update corrected GPS coordinates: \(error)")
            }
        }
    }
}


