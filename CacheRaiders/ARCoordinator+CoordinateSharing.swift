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
        guard let service = self.coordinateSharingService,
              let arView = arView,
              let locationManager = locationManager else {
            print("⚠️ Coordinate sharing service, ARView, or locationManager not available")
            return
        }

        // Configure the service with dependencies
        service.configure(
            with: arView,
            webSocketService: WebSocketService.shared,
            apiService: APIService.shared,
            locationManager: locationManager
        )

        // Set up session delegate for collaboration data
        arView.session.delegate = self

        // Initialize cloud geo anchor tracking if available
        setupCloudGeoAnchors()

        print("✅ ARCoordinator coordinate sharing integration initialized")
    }

    /// Shares current AR origin with other devices
    /// - Parameter arOrigin: The AR origin GPS coordinates
    func shareAROrigin(_ arOrigin: CLLocation) {
        self.coordinateSharingService?.shareAROrigin(arOrigin)
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
        self.coordinateSharingService?.updateObjectCoordinates(
            objectId: objectId,
            gpsCoordinates: gpsCoordinates,
            arOffset: arOffset,
            arOrigin: arOrigin
        )
    }

    /// Captures and shares the current AR world map
    func captureAndShareWorldMap() async {
        await self.coordinateSharingService?.shareWorldMap()
    }

    /// Starts collaborative AR session
    func startCollaborativeSession() {
        self.coordinateSharingService?.startCollaborativeSession()
    }

    /// Stops collaborative AR session
    func stopCollaborativeSession() {
        self.coordinateSharingService?.stopCollaborativeSession()
    }

    /// Gets diagnostic information about coordinate sharing
    func getCoordinateSharingDiagnostics() -> [String: Any]? {
        return self.coordinateSharingService?.getDiagnostics()
    }

    // MARK: - ARSessionDelegate for Collaboration

    /// Handles AR session collaboration data
    func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        self.coordinateSharingService?.handleCollaborationData(data)
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

 7. Use cloud geo anchors (recommended):
    // For stable multi-user object placement:
    if isCloudGeoAnchorsAvailable {
        let anchor = try await placeObjectWithCloudGeoAnchor(
            objectId: "treasure_123",
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 10.0
        )
    }
*/

    // MARK: - Cloud Geo Anchors

    /// Sets up cloud geo anchor tracking for stable multi-user AR
    private func setupCloudGeoAnchors() {
        guard let service = self.coordinateSharingService else {
            print("⚠️ Coordinate sharing service not available for cloud geo anchors")
            return
        }

        // Check if cloud geo tracking is available
        if service.isCloudGeoTrackingAvailable {
            Task { [weak self] in
                do {
                    try await self?.coordinateSharingService?.startCloudGeoTracking()
                    print("🛰️ Cloud geo tracking enabled for stable AR anchoring")

                    // Request sync of existing cloud anchors
                    try await self?.coordinateSharingService?.requestCloudGeoAnchorSync()
                } catch {
                    print("⚠️ Failed to start cloud geo tracking: \(error.localizedDescription)")
                    print("   Falling back to traditional AR anchoring")
                }
            }
        } else {
            print("📍 Cloud geo tracking not supported on this device")
            print("   Using traditional AR anchoring")
        }
    }

    /// Creates a cloud geo anchor for object placement (preferred method)
    func placeObjectWithCloudGeoAnchor(objectId: String,
                                      coordinate: CLLocationCoordinate2D,
                                      altitude: CLLocationDistance = 0,
                                      arOffset: SIMD3<Float> = .zero) async throws -> AnchorEntity {

        guard let service = self.coordinateSharingService else {
            throw NSError(domain: "ARCoordinator",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Coordinate sharing service not available"])
        }

        return try await service.createCloudGeoAnchor(
            for: objectId,
            at: coordinate,
            altitude: altitude,
            arOffset: arOffset
        )
    }

    /// Updates a cloud geo anchor position
    func updateCloudGeoAnchor(objectId: String,
                             coordinate: CLLocationCoordinate2D,
                             altitude: CLLocationDistance = 0) async throws {

        guard let service = self.coordinateSharingService else { return }

        try await service.updateCloudGeoAnchor(
            objectId: objectId,
            coordinate: coordinate,
            altitude: altitude
        )
    }

    /// Checks if cloud geo anchors are available and working
    var isCloudGeoAnchorsAvailable: Bool {
        return self.coordinateSharingService?.isCloudGeoTrackingAvailable ?? false
    }

    var isCloudGeoAnchorsEnabled: Bool {
        return self.coordinateSharingService?.isCloudGeoTrackingEnabled ?? false
    }
}
