import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

/// Service for automatically upgrading GPS-only objects to AR coordinates
/// Eliminates drift by converting legacy objects when users approach them
class ARCoordinateUpgradeService: ObservableObject {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var apiService: APIService?

    @Published var upgradeProgress: Double = 0.0
    @Published var objectsUpgraded: Int = 0

    private var upgradeQueue: [LootBoxLocation] = []
    private var isProcessingQueue = false
    private var currentAROrigin: CLLocation?

    init(arView: ARView?, locationManager: LootBoxLocationManager?, apiService: APIService?) {
        self.arView = arView
        self.locationManager = locationManager
        self.apiService = apiService
        setupUpgradeMonitoring()
    }

    /// Automatically upgrade nearby GPS-only objects to AR coordinates
    func upgradeNearbyGPSObjects(userLocation: CLLocation) async {
        guard let locationManager = locationManager,
              let arView = arView,
              let apiService = apiService else { return }

        // Find GPS-only objects within upgrade range (e.g., 50 meters)
        let nearbyGPSObjects = locationManager.locations.filter { location in
            // Must be GPS-only (no AR coordinates)
            let hasARCoords = location.ar_offset_x != nil && location.ar_offset_y != nil && location.ar_offset_z != nil
            guard !hasARCoords else { return false }

            // Must be within range and not collected
            let distance = userLocation.distance(from: location.location)
            return distance <= 50.0 && !location.collected
        }

        guard !nearbyGPSObjects.isEmpty else { return }

        print("🔄 Found \(nearbyGPSObjects.count) GPS-only objects to upgrade within 50m")

        // Process upgrades one by one to avoid overwhelming AR system
        for location in nearbyGPSObjects {
            await upgradeObjectToARCoordinates(location)
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay between upgrades
        }
    }

    /// Upgrade a single GPS-only object to AR coordinates
    private func upgradeObjectToARCoordinates(_ location: LootBoxLocation) async {
        guard let arView = arView,
              let apiService = apiService,
              let locationManager = locationManager else { return }

        // Calculate AR position relative to current session
        guard let arPosition = calculateARPositionForGPSLocation(location.coordinate, in: arView) else {
            print("⚠️ Failed to calculate AR position for \(location.name)")
            return
        }

        // Update object with AR coordinates
        var updatedLocation = location
        updatedLocation.ar_origin_latitude = currentAROrigin?.coordinate.latitude
        updatedLocation.ar_origin_longitude = currentAROrigin?.coordinate.longitude
        updatedLocation.ar_offset_x = Double(arPosition.x)
        updatedLocation.ar_offset_y = Double(arPosition.y)
        updatedLocation.ar_offset_z = Double(arPosition.z)
        updatedLocation.source = .map // Mark as AR-placed
        updatedLocation.last_modified = Date()

        do {
            // Update in API
            try await apiService.updateObject(updatedLocation)

            // Update local location manager
            locationManager.updateLocation(updatedLocation)

            objectsUpgraded += 1
            upgradeProgress = Double(objectsUpgraded) / Double(locationManager.locations.count)

            print("✅ Upgraded \(location.name) from GPS-only to AR coordinates")
            print("   AR position: (\(String(format: "%.3f", arPosition.x)), \(String(format: "%.3f", arPosition.y)), \(String(format: "%.3f", arPosition.z)))")

        } catch {
            print("❌ Failed to upgrade \(location.name): \(error.localizedDescription)")
        }
    }

    /// Calculate AR position for a GPS coordinate relative to current session
    private func calculateARPositionForGPSLocation(_ coordinate: CLLocationCoordinate2D, in arView: ARView) -> SIMD3<Float>? {
        guard let frame = arView.session.currentFrame,
              let arOrigin = currentAROrigin else { return nil }

        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = arOrigin.distance(from: targetLocation)
        let bearing = arOrigin.bearing(to: targetLocation)

        // Convert to AR coordinates (ENU: East, North, Up)
        let east = Float(distance * sin(bearing * .pi / 180.0))
        let north = Float(distance * cos(bearing * .pi / 180.0))

        // Get camera position for height reference
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Use grounding service to find surface height
        let groundY = cameraPos.y - 1.5 // Default ground height

        return SIMD3<Float>(east, groundY, north)
    }

    /// Set current AR session origin
    func setAROrigin(_ origin: CLLocation) {
        currentAROrigin = origin
        print("📍 Set AR coordinate upgrade origin: \(origin.coordinate.latitude), \(origin.coordinate.longitude)")
    }

    /// Setup monitoring for when users approach GPS-only objects
    private func setupUpgradeMonitoring() {
        // This would integrate with location updates to automatically trigger upgrades
        // For now, upgrades need to be called manually when users approach objects
    }
}
