import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine
import CloudKit

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
    @Published var isPersistentSession: Bool = false
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
    var cloudGeoAnchorService: CloudGeoAnchorService?
    var cloudAnchorSharingService: CloudAnchorSharingService?
    var cloudProvider: CloudGeoAnchorService.CloudProvider = .customServer

    // CloudKit for collaboration persistence
    private var cloudKitContainer: CKContainer?
    private let collaborationRecordType = "ARCollaborationSession"
    private var currentSessionRecord: CKRecord?

    // MARK: - Initialization

    init(arView: ARView? = nil) {
        self.arView = arView
        setupWebSocketCallbacks()
        print("🔗 ARCoordinateSharingService initialized")
    }

    func configure(with arView: ARView,
                   webSocketService: WebSocketService,
                   apiService: APIService,
                   locationManager: LootBoxLocationManager,
                   cloudProvider: CloudGeoAnchorService.CloudProvider = .customServer) {
        self.arView = arView
        self.webSocketService = webSocketService
        self.apiService = apiService
        self.locationManager = locationManager
        self.cloudProvider = cloudProvider

        // Initialize cloud geo anchor services
        setupCloudGeoAnchors()

        // Initialize CloudKit for collaboration persistence if using cloud provider
        if cloudProvider == .cloudKit {
            setupCloudKitCollaboration()
        }

        setupWebSocketCallbacks()
        print("✅ ARCoordinateSharingService configured with dependencies (provider: \(cloudProvider))")
    }

    private func setupCloudGeoAnchors() {
        // Initialize cloud geo anchor service
        cloudGeoAnchorService = CloudGeoAnchorService(arView: arView)
        cloudGeoAnchorService?.configure(with: arView ?? ARView(),
                                        apiService: apiService!,
                                        webSocketService: webSocketService!,
                                        cloudProvider: cloudProvider)

        // Initialize cloud anchor sharing service
        cloudAnchorSharingService = CloudAnchorSharingService()
        cloudAnchorSharingService?.configure(with: apiService!,
                                           webSocketService: webSocketService!,
                                           geoAnchorService: cloudGeoAnchorService!)

        print("🛰️ Cloud geo anchor services initialized with provider: \(cloudProvider)")
    }

    // MARK: - CloudKit Collaboration Setup

    private func setupCloudKitCollaboration() {
        cloudKitContainer = CKContainer(identifier: "iCloud.com.shaydu.CacheRaiders")
        print("☁️ CloudKit configured for collaboration persistence")
    }

    /// Saves the current collaboration session to CloudKit
    func saveCollaborationSession() async throws {
        guard cloudProvider == .cloudKit, let container = cloudKitContainer else {
            throw NSError(domain: "ARCoordinateSharingService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not configured"])
        }

        let record = currentSessionRecord ?? CKRecord(recordType: collaborationRecordType)
        record["sessionId"] = UUID().uuidString as CKRecordValue
        record["timestamp"] = Date() as CKRecordValue
        let deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        record["deviceId"] = deviceId as CKRecordValue
        record["connectedPeers"] = connectedPeers as CKRecordValue

        // Save world map data if available
        if let worldMapData = self.worldMapData {
            record["worldMapData"] = worldMapData as CKRecordValue
        }

        let database = container.privateCloudDatabase
        let savedRecord = try await database.save(record)
        currentSessionRecord = savedRecord

        print("☁️ Collaboration session saved to CloudKit")
    }

    /// Loads the most recent collaboration session from CloudKit
    func loadCollaborationSession() async throws -> [String: Any]? {
        guard cloudProvider == .cloudKit, let container = cloudKitContainer else {
            throw NSError(domain: "ARCoordinateSharingService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not configured"])
        }

        let database = container.privateCloudDatabase
        let query = CKQuery(recordType: collaborationRecordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        let (results, _) = try await database.records(matching: query, resultsLimit: 1)

        guard let (_, recordResult) = results.first else {
            print("ℹ️ No collaboration session found in CloudKit")
            return nil
        }

        let record: CKRecord
        do {
            record = try recordResult.get()
        } catch {
            print("❌ Failed to get record from CloudKit result: \(error)")
            return nil
        }

        currentSessionRecord = record

        var sessionData: [String: Any] = [:]

        if let sessionId = record["sessionId"] as? String {
            sessionData["sessionId"] = sessionId
        }

        if let connectedPeers = record["connectedPeers"] as? [String] {
            sessionData["connectedPeers"] = connectedPeers
        }

        if let worldMapData = record["worldMapData"] as? Data {
            sessionData["worldMapData"] = worldMapData
        }

        print("☁️ Collaboration session loaded from CloudKit")
        return sessionData
    }

    /// Deletes the current collaboration session from CloudKit
    func deleteCollaborationSession() async throws {
        guard let record = currentSessionRecord, let container = cloudKitContainer else {
            return
        }

        let database = container.privateCloudDatabase
        try await database.deleteRecord(withID: record.recordID)
        currentSessionRecord = nil

        print("🗑️ Collaboration session deleted from CloudKit")
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

    /// Starts a collaborative AR session with optional CloudKit persistence
    func startCollaborativeSession(persistent: Bool = false) {
        guard let configuration = arSession?.configuration as? ARWorldTrackingConfiguration else {
            print("⚠️ Cannot start collaborative session - no AR session")
            return
        }

        configuration.isCollaborationEnabled = true
        arSession?.run(configuration)

        isCollaborativeSessionActive = true
        isPersistentSession = persistent

        // Save session to CloudKit if requested and available
        if persistent && cloudProvider == .cloudKit {
            Task {
                do {
                    try await saveCollaborationSession()
                } catch {
                    print("⚠️ Failed to save collaborative session to CloudKit: \(error.localizedDescription)")
                }
            }
        }

        print("🤝 Started collaborative AR session\(persistent && cloudProvider == .cloudKit ? " (persistent)" : "")")
    }

    /// Stops the collaborative session and optionally cleans up CloudKit data
    func stopCollaborativeSession(cleanupCloudData: Bool = false) async {
        guard let configuration = arSession?.configuration as? ARWorldTrackingConfiguration else {
            return
        }

        configuration.isCollaborationEnabled = false
        arSession?.run(configuration)

        isCollaborativeSessionActive = false
        connectedPeers.removeAll()

        // Clean up CloudKit session data if requested
        if cleanupCloudData && cloudProvider == .cloudKit {
            do {
                try await deleteCollaborationSession()
            } catch {
                print("⚠️ Failed to delete collaborative session from CloudKit: \(error.localizedDescription)")
            }
        }

        print("🔚 Stopped collaborative AR session\(cleanupCloudData && cloudProvider == .cloudKit ? " (CloudKit cleaned up)" : "")")
    }

    /// Resumes a persistent collaborative session from CloudKit
    func resumePersistentSession() async throws {
        guard cloudProvider == .cloudKit else {
            throw NSError(domain: "ARCoordinateSharingService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not configured for collaboration"])
        }

        guard let sessionData = try await loadCollaborationSession() else {
            throw NSError(domain: "ARCoordinateSharingService",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "No persistent session found"])
        }

        // Restore session state
        if let peers = sessionData["connectedPeers"] as? [String] {
            connectedPeers = peers
        }

        // Load world map if available
        if let worldMapData = sessionData["worldMapData"] as? Data {
            _ = loadWorldMap(worldMapData)
        }

        // Start collaborative session
        startCollaborativeSession(persistent: true)

        print("🔄 Resumed persistent collaborative session from CloudKit")
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
        Task {
            await stopCollaborativeSession(cleanupCloudData: false)
        }
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
        try await cloudGeoAnchorService?.syncGeoAnchorsFromCloud()

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

    // MARK: - CloudKit Management

    /// Debug method to test CloudKit functionality
    func debugTestCloudKit() {
        Task {
            await testCloudKitFunctionality()
        }
    }

    private func testCloudKitFunctionality() async {
        print("🧪 Testing CloudKit functionality...")

        // Test basic CloudKit connectivity
        let testUtility = CloudKitTestUtility()
        let connectivityOK = await testUtility.testCloudKitConnectivity()

        if connectivityOK {
            print("✅ CloudKit is available and working")
            let diagnostics = testUtility.getDiagnostics()
            print("   Container: \(diagnostics["containerIdentifier"] ?? "unknown")")

            // Test our CloudKit geo anchor service if available
            if let cloudKitService = self.cloudGeoAnchorService?.cloudKitService {
                print("🧪 Testing CloudKitGeoAnchorService...")
                let serviceDiagnostics = cloudKitService.getDiagnostics()
                print("   Service available: \(serviceDiagnostics["cloudAvailable"] ?? false)")
                print("   Offline mode: \(serviceDiagnostics["isOfflineMode"] ?? false)")
                print("   Active anchors: \(serviceDiagnostics["activeAnchorsCount"] ?? 0)")
            }
        } else {
            print("❌ CloudKit is not available - check iCloud account and app permissions")
        }

        print("✅ CloudKit test completed")
    }

    /// Migrates data from custom server to CloudKit infrastructure
    func migrateToCloudKit(worldMapService: ARWorldMapPersistenceService?) async throws {
        print("🔄 Starting migration to CloudKit infrastructure...")

        // Switch cloud providers
        await switchCloudProvider(to: .cloudKit)
        if let worldMapService = worldMapService {
            await switchWorldMapCloudProvider(to: .cloudKit, worldMapService: worldMapService)
        }

        // Migrate geo anchors
        do {
            if let cloudKitService = cloudGeoAnchorService?.cloudKitService {
                try await cloudKitService.migrateFromCustomServer()
            }
        } catch {
            print("⚠️ Geo anchor migration failed: \(error.localizedDescription)")
        }

        // Migrate world map
        do {
            if let worldMapService = worldMapService {
                let success = await worldMapService.migrateWorldMapToCloudKit()
                if success {
                    print("✅ World map migrated to CloudKit")
                } else {
                    print("⚠️ World map migration failed or no local data to migrate")
                }
            }
        }

        // Clean up local data after successful migration
        cleanupLocalDataAfterMigration()

        print("✅ Migration to CloudKit completed")
    }

    /// Cleans up local data after successful migration to CloudKit
    private func cleanupLocalDataAfterMigration() {
        // Note: In a production app, you might want to ask user before deleting local data
        // For now, we'll keep local data as backup
        print("ℹ️ Local data preserved as backup after migration")
    }

    /// Switches the cloud infrastructure provider for geo anchors
    /// - Parameter provider: The cloud provider to use (.customServer or .cloudKit)
    func switchCloudProvider(to provider: CloudGeoAnchorService.CloudProvider) async {
        guard provider != cloudProvider else { return }

        cloudProvider = provider
        print("🔄 Switching to cloud provider: \(provider)")

        // Reconfigure coordinate sharing service with new provider
        if let arView = arView,
           let webSocketService = webSocketService,
           let apiService = apiService,
           let locationManager = locationManager {
            configure(
                with: arView,
                webSocketService: webSocketService,
                apiService: apiService,
                locationManager: locationManager,
                cloudProvider: provider
            )
        }

        // Sync existing anchors with new provider
        do {
            try await requestCloudGeoAnchorSync()
            print("✅ Successfully switched to \(provider) and synced anchors")
        } catch {
            print("⚠️ Failed to sync anchors after switching to \(provider): \(error.localizedDescription)")
        }
    }

    /// Switches the cloud infrastructure provider for world map persistence
    /// - Parameter provider: The cloud provider to use (.localStorage or .cloudKit)
    /// - Parameter worldMapService: The world map persistence service to reconfigure
    func switchWorldMapCloudProvider(to provider: ARWorldMapPersistenceService.CloudProvider, worldMapService: ARWorldMapPersistenceService) async {
        // Reconfigure with new provider
        if let arView = arView,
           let apiService = apiService,
           let webSocketService = webSocketService {
            worldMapService.configure(with: arView,
                                    apiService: apiService,
                                    webSocketService: webSocketService,
                                    cloudProvider: provider)
        }

        print("🔄 Switched world map persistence to provider: \(provider)")

        // Reload world map with new provider if available
        if worldMapService.loadPersistedWorldMap() {
            print("✅ Reloaded world map with new cloud provider")
        }
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