import Foundation
import RealityKit
import ARKit
import CoreLocation

// MARK: - ARCoordinator Coordinate Sharing Extension
/// Extension to ARCoordinator that integrates with ARCoordinateSharingService
/// This extracts coordinate sharing logic from the main coordinator class
extension ARCoordinator {

    // MARK: - Coordinate Sharing Integration

    /// Initializes coordinate sharing service integration
    func setupCoordinateSharing() {
        guard let coordinateSharingService = coordinateSharingService,
              let arView = arView,
              let locationManager = locationManager else {
            print("⚠️ Coordinate sharing service, ARView, or locationManager not available")
            return
        }

        // Configure the service with dependencies
        coordinateSharingService.configure(
            with: arView,
            webSocketService: WebSocketService.shared,
            apiService: APIService.shared,
            locationManager: locationManager
        )

        // Set up session delegate for collaboration data
        arView.session.delegate = self

        print("✅ ARCoordinator coordinate sharing integration initialized")
    }

    /// Shares current AR origin with other devices
    /// - Parameter arOrigin: The AR origin GPS coordinates
    func shareAROrigin(_ arOrigin: CLLocation) {
        coordinateSharingService?.shareAROrigin(arOrigin)
    }

    /// Updates object coordinates across all devices
    /// - Parameters:
    ///   - objectId: The object ID
    ///   - gpsCoordinates: GPS coordinates
    ///   - arOffset: AR offset coordinates (optional)
    ///   - arOrigin: AR origin coordinates (optional)
    func updateObjectCoordinates(objectId: String,
                                gpsCoordinates: CLLocationCoordinate2D,
                                arOffset: SIMD3<Double>? = nil,
                                arOrigin: CLLocation? = nil) {
        coordinateSharingService?.updateObjectCoordinates(
            objectId: objectId,
            gpsCoordinates: gpsCoordinates,
            arOffset: arOffset,
            arOrigin: arOrigin
        )
    }

    /// Captures and shares the current AR world map
    func captureAndShareWorldMap() async {
        await coordinateSharingService?.shareWorldMap()
    }

    /// Starts collaborative AR session
    func startCollaborativeSession() {
        coordinateSharingService?.startCollaborativeSession()
    }

    /// Stops collaborative AR session
    func stopCollaborativeSession() {
        coordinateSharingService?.stopCollaborativeSession()
    }

    /// Gets diagnostic information about coordinate sharing
    func getCoordinateSharingDiagnostics() -> [String: Any]? {
        return coordinateSharingService?.getDiagnostics()
    }

    // MARK: - ARSessionDelegate for Collaboration

    /// Handles AR session collaboration data
    func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        coordinateSharingService?.handleCollaborationData(data)
    }

    // MARK: - Legacy Integration Points

    /// Legacy method for sharing AR origin - now delegates to coordinate sharing service
    func legacyShareAROrigin(_ arOrigin: CLLocation) {
        // This replaces the old logic:
        // locationManager?.sharedAROrigin = userLocation

        shareAROrigin(arOrigin)
    }

    /// Legacy method for coordinate correction - now delegates to coordinate sharing service
    func legacyCorrectGPSCoordinates(location: LootBoxLocation,
                                    intendedARPosition: SIMD3<Float>,
                                    arOrigin: CLLocation,
                                    cameraTransform: simd_float4x4) {

        // Extract the coordinate correction logic that was previously inline
        let offset = intendedARPosition
        let distanceX = Double(offset.x)
        let distanceZ = Double(offset.z)
        let distance = sqrt(distanceX * distanceX + distanceZ * distanceZ)

        let bearingRad = atan2(distanceX, distanceZ)
        let bearingDeg = bearingRad * 180.0 / .pi
        let compassBearing = (bearingDeg + 360).truncatingRemainder(dividingBy: 360)

        let correctedCoordinate = arOrigin.coordinate.coordinate(atDistance: distance, atBearing: compassBearing)

        // Use the coordinate sharing service to update coordinates
        updateObjectCoordinates(
            objectId: location.id,
            gpsCoordinates: correctedCoordinate,
            arOffset: SIMD3<Double>(Double(offset.x), Double(offset.y), Double(offset.z)),
            arOrigin: arOrigin
        )

        Swift.print("✅ GPS coordinates corrected via coordinate sharing service")
    }
}

// MARK: - Note
/// The coordinateSharingService property is now implemented as a stored property
/// in the main ARCoordinator class (line 30)

// MARK: - Usage Examples

/*
 USAGE IN ARCoordinator:

 1. Add property to ARCoordinator class:
    private let coordinateSharingService = ARCoordinateSharingService()

 2. Initialize in setupARCoordinator():
    setupCoordinateSharing()

 3. Replace old AR origin sharing:
    // OLD:
    locationManager?.sharedAROrigin = userLocation

    // NEW:
    shareAROrigin(userLocation)

 4. Replace coordinate updates:
    // OLD:
    try await APIService.shared.updateObjectLocation(...)

    // NEW:
    updateObjectCoordinates(
        objectId: location.id,
        gpsCoordinates: correctedCoordinate,
        arOffset: SIMD3<Double>(x, y, z),
        arOrigin: arOrigin
    )

 5. Add world map sharing:
    // When user taps "Share World Map" button:
    captureAndShareWorldMap()

 6. Add collaborative sessions:
    // When starting multi-player mode:
    startCollaborativeSession()
*/
