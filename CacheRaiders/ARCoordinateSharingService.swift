import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - AR Coordinate Sharing Service
/// Handles all AR coordinate sharing between devices including:
/// - ARWorldMap capture, storage, and synchronization
/// - Collaborative AR sessions
/// - AR origin sharing between views
/// - Coordinate reconciliation across devices
class ARCoordinateSharingService: ObservableObject {

    // MARK: - Properties

    @Published var isCollaborativeSessionActive: Bool = false
    @Published var connectedPeers: [String] = []
    @Published var sharedWorldMapAvailable: Bool = false

    private weak var arView: ARView?
    private var arSession: ARSession? {
        return arView?.session
    }

    // ARWorldMap management
    private var currentWorldMap: ARWorldMap?
    private var worldMapData: Data?

    // Collaborative session
    private var collaborationSession: NSObject? // ARSession.CollaborationData will be handled here

    // AR origin sharing
    private var sharedAROrigins: [String: CLLocation] = [:] // Key: deviceUUID, Value: AR origin GPS location

    // Coordinate reconciliation
    private let coordinateQueue = DispatchQueue(label: "com.cacheraiders.coordinateSharing", qos: .userInitiated)
    private var pendingCoordinateUpdates: [String: [String: Any]] = [:] // objectId -> coordinate data

    // Dependencies
    private weak var webSocketService: WebSocketService?
    private weak var apiService: APIService?
    private weak var locationManager: LootBoxLocationManager?

    // Cloud geo anchor services
    private var cloudGeoAnchorService: CloudGeoAnchorService?
    private var cloudAnchorSharingService: CloudAnchorSharingService?

    // MARK: - Initialization

    init(arView: ARView? = nil) {
        self.arView = arView
        setupWebSocketCallbacks()
        print("🔗 ARCoordinateSharingService initialized")
    }

    func configure(with arView: ARView,
                   webSocketService: WebSocketService,
                   apiService: APIService,
                   locationManager: LootBoxLocationManager) {
        self.arView = arView
        self.webSocketService = webSocketService
        self.apiService = apiService
        self.locationManager = locationManager

        // Initialize cloud geo anchor services
        setupCloudGeoAnchors()

        setupWebSocketCallbacks()
        print("✅ ARCoordinateSharingService configured with dependencies")
    }

    private func setupCloudGeoAnchors() {
        // Initialize cloud geo anchor service
        cloudGeoAnchorService = CloudGeoAnchorService(arView: arView)
        cloudGeoAnchorService?.configure(with: arView ?? ARView(),
                                        apiService: apiService!,
                                        webSocketService: webSocketService!)

        // Initialize cloud anchor sharing service
        cloudAnchorSharingService = CloudAnchorSharingService()
        cloudAnchorSharingService?.configure(with: apiService!,
                                           webSocketService: webSocketService!,
                                           geoAnchorService: cloudGeoAnchorService!)

        print("🛰️ Cloud geo anchor services initialized")
    }

    // MARK: - WebSocket Integration

    private func setupWebSocketCallbacks() {
        // Coordinate update events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleObjectUpdated(_:)),
            name: NSNotification.Name("WebSocketObjectUpdated"),
            object: nil
        )

        // AR origin sharing events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAROriginShared(_:)),
            name: NSNotification.Name("AROriginShared"),
            object: nil
        )

        // World map sharing events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWorldMapReceived(_:)),
            name: NSNotification.Name("WorldMapReceived"),
            object: nil
        )
    }

    // MARK: - ARWorldMap Management

    /// Captures the current AR world map for sharing
    /// - Returns: ARWorldMap data or nil if capture fails
    func captureWorldMap() async -> Data? {
        guard let session = arSession else {
            print("⚠️ No AR session available")
            return nil
        }

        return await withCheckedContinuation { continuation in
            session.getCurrentWorldMap { worldMap, error in
                if let error = error {
                    print("⚠️ Failed to capture AR world map: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let worldMap = worldMap else {
                    print("⚠️ No world map data received")
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                    self.currentWorldMap = worldMap
                    self.worldMapData = data
                    self.sharedWorldMapAvailable = true

                    print("✅ Captured AR world map (\(data.count) bytes)")
                    continuation.resume(returning: data)
                } catch {
                    print("❌ Failed to archive AR world map: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Loads a shared AR world map
    /// - Parameter worldMapData: The world map data to load
    /// - Returns: Success status
    func loadWorldMap(_ worldMapData: Data) -> Bool {
        do {
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: worldMapData) else {
                print("❌ Failed to unarchive AR world map")
                return false
            }

            // Configure session to use the world map
            let configuration = ARWorldTrackingConfiguration()
            configuration.initialWorldMap = worldMap
            configuration.isCollaborationEnabled = true

            arSession?.run(configuration, options: [.resetTracking, .removeExistingAnchors])

            self.currentWorldMap = worldMap
            self.worldMapData = worldMapData
            self.sharedWorldMapAvailable = true

            print("✅ Loaded shared AR world map")
            return true

        } catch {
            print("❌ Failed to load AR world map: \(error)")
            return false
        }
    }

    /// Shares the current world map with other devices via server
    func shareWorldMap() async {
        guard let worldMapData = await captureWorldMap() else {
            print("⚠️ No world map to share")
            return
        }

        // Upload to server
        Task {
            do {
                let deviceUUID = APIService.shared.currentUserID
                let shareData: [String: Any] = [
                    "device_uuid": deviceUUID,
                    "world_map_data": worldMapData.base64EncodedString(),
                    "timestamp": Date().ISO8601Format()
                ]

                // This would need a new API endpoint for world map sharing
                // For now, we'll use a notification approach
                NotificationCenter.default.post(
                    name: NSNotification.Name("WorldMapCaptured"),
                    object: nil,
                    userInfo: ["worldMapData": worldMapData, "deviceUUID": deviceUUID]
                )

                print("📤 Shared AR world map with other devices")

            } catch {
                print("❌ Failed to share world map: \(error)")
            }
        }
    }

    // MARK: - Collaborative Sessions

    /// Starts a collaborative AR session
    func startCollaborativeSession() {
        guard let configuration = arSession?.configuration as? ARWorldTrackingConfiguration else {
            print("⚠️ Cannot start collaborative session - no AR session")
            return
        }

        configuration.isCollaborationEnabled = true
        arSession?.run(configuration)

        isCollaborativeSessionActive = true
        print("🤝 Started collaborative AR session")
    }

    /// Stops the collaborative session
    func stopCollaborativeSession() {
        guard let configuration = arSession?.configuration as? ARWorldTrackingConfiguration else {
            return
        }

        configuration.isCollaborationEnabled = false
        arSession?.run(configuration)

        isCollaborativeSessionActive = false
        connectedPeers.removeAll()
        print("🔚 Stopped collaborative AR session")
    }

    /// Handles incoming collaboration data from other devices
    func handleCollaborationData(_ collaborationData: ARSession.CollaborationData) {
        // Apply collaboration data to local session
        arSession?.update(with: collaborationData)

        // Note: ARSession.CollaborationData doesn't contain device UUID information
        // Peer management is handled through the API service and shared AR origins
        print("📡 Received collaboration data from peer")
    }

    /// Sends collaboration data to other devices
    func sendCollaborationData(_ collaborationData: ARSession.CollaborationData) {
        // This would typically be sent via WebSocket or network
        // For now, we'll use notifications
        NotificationCenter.default.post(
            name: NSNotification.Name("CollaborationDataAvailable"),
            object: nil,
            userInfo: ["collaborationData": collaborationData]
        )
    }

    // MARK: - AR Origin Sharing

    /// Shares the current AR origin with other devices
    /// - Parameter arOrigin: The AR origin GPS coordinates
    func shareAROrigin(_ arOrigin: CLLocation) {
        let deviceUUID = APIService.shared.currentUserID
        sharedAROrigins[deviceUUID] = arOrigin

        let originData: [String: Any] = [
            "device_uuid": deviceUUID,
            "latitude": arOrigin.coordinate.latitude,
            "longitude": arOrigin.coordinate.longitude,
            "altitude": arOrigin.altitude,
            "timestamp": Date().timeIntervalSince1970
        ]

        // Broadcast via WebSocket (would need server-side support)
        NotificationCenter.default.post(
            name: NSNotification.Name("AROriginShared"),
            object: nil,
            userInfo: originData
        )

        print("📍 Shared AR origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
    }

    /// Gets the most recent shared AR origin from another device
    /// - Parameter deviceUUID: The device UUID to get origin for
    /// - Returns: AR origin coordinates or nil
    func getSharedAROrigin(for deviceUUID: String) -> CLLocation? {
        return sharedAROrigins[deviceUUID]
    }

    /// Synchronizes AR origins between devices to ensure coordinate consistency
    func synchronizeAROrigins() {
        // Request AR origins from all connected peers
        let deviceUUID = APIService.shared.currentUserID
        let syncRequest: [String: Any] = [
            "device_uuid": deviceUUID,
            "request_type": "ar_origin_sync"
        ]

        NotificationCenter.default.post(
            name: NSNotification.Name("AROriginSyncRequested"),
            object: nil,
            userInfo: syncRequest
        )

        print("🔄 Requested AR origin synchronization")
    }

    // MARK: - Coordinate Updates

    /// Updates object coordinates across all devices
    /// - Parameters:
    ///   - objectId: The object ID
    ///   - gpsCoordinates: GPS coordinates (primary)
    ///   - arOffset: AR offset coordinates (optional)
    ///   - arOrigin: AR origin coordinates (optional)
    func updateObjectCoordinates(objectId: String,
                                gpsCoordinates: CLLocationCoordinate2D,
                                arOffset: SIMD3<Double>? = nil,
                                arOrigin: CLLocation? = nil) {

        coordinateQueue.async { [weak self] in
            guard let self = self else { return }

            var updateData: [String: Any] = [
                "id": objectId,
                "latitude": gpsCoordinates.latitude,
                "longitude": gpsCoordinates.longitude,
                "updated_at": Date().ISO8601Format()
            ]

            // Add AR coordinates if available
            if let arOffset = arOffset {
                updateData["ar_offset_x"] = arOffset.x
                updateData["ar_offset_y"] = arOffset.y
                updateData["ar_offset_z"] = arOffset.z
            }

            if let arOrigin = arOrigin {
                updateData["ar_origin_latitude"] = arOrigin.coordinate.latitude
                updateData["ar_origin_longitude"] = arOrigin.coordinate.longitude
            }

            // Store pending update
            self.pendingCoordinateUpdates[objectId] = updateData

            // Send update via API
            Task {
                do {
                    try await self.apiService?.updateObjectLocation(
                        objectId: objectId,
                        latitude: gpsCoordinates.latitude,
                        longitude: gpsCoordinates.longitude
                    )
                    print("✅ Updated coordinates for object \(objectId)")

                    // Clear pending update on success
                    self.coordinateQueue.async {
                        self.pendingCoordinateUpdates.removeValue(forKey: objectId)
                    }

                } catch {
                    print("❌ Failed to update coordinates for object \(objectId): \(error)")
                }
            }
        }
    }

    /// Processes coordinate updates received from other devices
    /// - Parameter updateData: The coordinate update data
    func processCoordinateUpdate(_ updateData: [String: Any]) {
        guard let objectId = updateData["id"] as? String else {
            print("⚠️ Coordinate update missing object ID")
            return
        }

        coordinateQueue.async { [weak self] in
            guard let self = self else { return }

            // Update local location manager
            self.locationManager?.updateLocationCoordinates(objectId: objectId, coordinateData: updateData)

            print("🔄 Processed coordinate update for object \(objectId)")
        }
    }

    // MARK: - Notification Handlers

    @objc private func handleObjectUpdated(_ notification: Notification) {
        guard let updateData = notification.userInfo as? [String: Any] else { return }
        processCoordinateUpdate(updateData)
    }

    @objc private func handleAROriginShared(_ notification: Notification) {
        guard let originData = notification.userInfo as? [String: Any],
              let deviceUUID = originData["device_uuid"] as? String,
              let latitude = originData["latitude"] as? Double,
              let longitude = originData["longitude"] as? Double else {
            return
        }

        let coordinate = CLLocation(latitude: latitude, longitude: longitude)
        sharedAROrigins[deviceUUID] = coordinate

        print("📍 Received AR origin from device \(deviceUUID): (\(latitude), \(longitude))")
    }

    @objc private func handleWorldMapReceived(_ notification: Notification) {
        guard let worldMapData = notification.userInfo?["worldMapData"] as? Data else { return }
        _ = loadWorldMap(worldMapData)
    }

    // MARK: - Utility Methods

    /// Checks if coordinates from two devices are compatible for merging
    /// - Parameters:
    ///   - device1Coords: Coordinates from first device
    ///   - device2Coords: Coordinates from second device
    ///   - tolerance: Tolerance in meters
    /// - Returns: True if coordinates are compatible
    func areCoordinatesCompatible(_ device1Coords: CLLocationCoordinate2D,
                                 _ device2Coords: CLLocationCoordinate2D,
                                 tolerance: Double = 5.0) -> Bool {

        let location1 = CLLocation(latitude: device1Coords.latitude, longitude: device1Coords.longitude)
        let location2 = CLLocation(latitude: device2Coords.latitude, longitude: device2Coords.longitude)

        let distance = location1.distance(from: location2)
        return distance <= tolerance
    }

    /// Gets diagnostic information about coordinate sharing status
    func getDiagnostics() -> [String: Any] {
        return [
            "collaborative_session_active": isCollaborativeSessionActive,
            "connected_peers_count": connectedPeers.count,
            "shared_world_map_available": sharedWorldMapAvailable,
            "shared_ar_origins_count": sharedAROrigins.count,
            "pending_updates_count": pendingCoordinateUpdates.count
        ]
    }

    // MARK: - Cleanup

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopCollaborativeSession()
        print("🗑️ ARCoordinateSharingService deinitialized")
    }

    // MARK: - Cloud Geo Anchors Integration

    /// Starts cloud geo tracking for stable multi-user AR
    func startCloudGeoTracking() async throws {
        guard let service = cloudGeoAnchorService else {
            throw NSError(domain: "ARCoordinateSharingService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Cloud geo anchor service not available"])
        }

        try await service.startGeoTracking()

        // Sync existing anchors from server
        try await cloudGeoAnchorService?.syncGeoAnchorsFromServer()

        print("🛰️ Cloud geo tracking started and synced")
    }

    /// Stops cloud geo tracking
    func stopCloudGeoTracking() {
        cloudGeoAnchorService?.stopGeoTracking()
        print("🛑 Cloud geo tracking stopped")
    }

    /// Creates a cloud geo anchor for an object at the specified location
    func createCloudGeoAnchor(for objectId: String,
                             at coordinate: CLLocationCoordinate2D,
                             altitude: CLLocationDistance,
                             arOffset: SIMD3<Float> = .zero) async throws -> AnchorEntity {

        guard let service = cloudGeoAnchorService else {
            throw NSError(domain: "ARCoordinateSharingService",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Cloud geo anchor service not available"])
        }

        let anchorEntity = try await service.createGeoAnchorAtLocation(
            coordinate: coordinate,
            altitude: altitude,
            arOffset: arOffset,
            objectId: objectId
        )

        // Share the anchor with other users
        try await cloudAnchorSharingService?.shareGeoAnchor(
            CloudGeoAnchorData(
                objectId: objectId,
                coordinate: coordinate,
                altitude: altitude,
                createdAt: Date(),
                deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            )
        )

        print("☁️ Created and shared cloud geo anchor for object '\(objectId)'")
        return anchorEntity
    }

    /// Updates the position of a cloud geo anchor
    func updateCloudGeoAnchor(objectId: String,
                             coordinate: CLLocationCoordinate2D,
                             altitude: CLLocationDistance) async throws {

        let anchorData = CloudGeoAnchorData(
            objectId: objectId,
            coordinate: coordinate,
            altitude: altitude,
            createdAt: Date(),
            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        )

        try await cloudAnchorSharingService?.updateSharedAnchor(anchorData)
        print("🔄 Updated cloud geo anchor for object '\(objectId)'")
    }

    /// Removes a cloud geo anchor
    func removeCloudGeoAnchor(objectId: String) async throws {
        try await cloudAnchorSharingService?.removeSharedAnchor(objectId: objectId)
        cloudGeoAnchorService?.removeGeoAnchor(objectId: objectId)
        print("🗑️ Removed cloud geo anchor for object '\(objectId)'")
    }

    /// Gets the quality score of a cloud geo anchor
    func getCloudGeoAnchorQuality(objectId: String) -> Double {
        return cloudGeoAnchorService?.getAnchorQuality(objectId: objectId) ?? 0.0
    }

    /// Requests synchronization of all cloud geo anchors
    func requestCloudGeoAnchorSync() async throws {
        try await cloudAnchorSharingService?.requestAnchorSync()
        print("🔄 Requested cloud geo anchor synchronization")
    }

    /// Checks if cloud geo tracking is available and enabled
    var isCloudGeoTrackingAvailable: Bool {
        return cloudGeoAnchorService?.isGeoTrackingSupported ?? false
    }

    var isCloudGeoTrackingEnabled: Bool {
        return cloudGeoAnchorService?.isGeoTrackingEnabled ?? false
    }

    /// Gets diagnostics for cloud geo anchor services
    func getCloudGeoAnchorDiagnostics() -> [String: Any] {
        var diagnostics: [String: Any] = [:]

        if let geoDiagnostics = cloudGeoAnchorService?.getDiagnostics() {
            diagnostics["geoAnchorService"] = geoDiagnostics
        }

        if let sharingDiagnostics = cloudAnchorSharingService?.getSharingDiagnostics() {
            diagnostics["anchorSharingService"] = sharingDiagnostics
        }

        return diagnostics
    }
}

// MARK: - Extensions

extension Date {
    func ISO8601Format() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

// MARK: - LootBoxLocationManager Extension

extension LootBoxLocationManager {
    /// Updates location coordinates from coordinate sharing service
    func updateLocationCoordinates(objectId: String, coordinateData: [String: Any]) {
        // This would update the location in the location manager
        // Implementation depends on your location manager structure

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Find and update the location
            if let index = self.locations.firstIndex(where: { $0.id == objectId }) {
                let existingLocation = self.locations[index]

                // Create new location with updated coordinates
                let updatedLatitude = coordinateData["latitude"] as? Double ?? existingLocation.latitude
                let updatedLongitude = coordinateData["longitude"] as? Double ?? existingLocation.longitude
                let updatedAROffsetX = coordinateData["ar_offset_x"] as? Double ?? existingLocation.ar_offset_x
                let updatedAROffsetY = coordinateData["ar_offset_y"] as? Double ?? existingLocation.ar_offset_y
                let updatedAROffsetZ = coordinateData["ar_offset_z"] as? Double ?? existingLocation.ar_offset_z
                let updatedAROriginLat = coordinateData["ar_origin_latitude"] as? Double ?? existingLocation.ar_origin_latitude
                let updatedAROriginLng = coordinateData["ar_origin_longitude"] as? Double ?? existingLocation.ar_origin_longitude

                let updatedLocation = LootBoxLocation(
                    id: existingLocation.id,
                    name: existingLocation.name,
                    type: existingLocation.type,
                    latitude: updatedLatitude,
                    longitude: updatedLongitude,
                    radius: existingLocation.radius,
                    collected: existingLocation.collected,
                    grounding_height: existingLocation.grounding_height,
                    source: existingLocation.source,
                    created_by: existingLocation.created_by,
                    needs_sync: existingLocation.needs_sync,
                    last_modified: Date(),
                    server_version: existingLocation.server_version,
                    ar_origin_latitude: updatedAROriginLat,
                    ar_origin_longitude: updatedAROriginLng,
                    ar_offset_x: updatedAROffsetX,
                    ar_offset_y: updatedAROffsetY,
                    ar_offset_z: updatedAROffsetZ,
                    ar_placement_timestamp: existingLocation.ar_placement_timestamp,
                    ar_anchor_transform: existingLocation.ar_anchor_transform,
                    ar_world_transform: existingLocation.ar_world_transform,
                    nfc_tag_id: existingLocation.nfc_tag_id,
                    multifindable: existingLocation.multifindable
                )

                self.locations[index] = updatedLocation

                // Notify about the update
                NotificationCenter.default.post(
                    name: NSNotification.Name("LocationCoordinatesUpdated"),
                    object: nil,
                    userInfo: ["locationId": objectId, "location": updatedLocation]
                )

                print("📍 Updated coordinates for location \(objectId)")
            }
        }
    }
}