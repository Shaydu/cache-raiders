import SwiftUI
import RealityKit
import ARKit
import CoreLocation

/// Helper for AR-enhanced location calculations
class ARLocationHelper {
    weak var arView: ARView?
    var arOriginLocation: CLLocation?
    
    init(arView: ARView?, arOriginLocation: CLLocation?) {
        self.arView = arView
        self.arOriginLocation = arOriginLocation
    }
    
    /// Get AR-enhanced GPS location (more accurate than raw GPS)
    /// Converts current AR camera position to GPS coordinates using AR origin
    /// Returns nil if AR origin not set or AR not available
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let arOrigin = arOriginLocation else {
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
}

