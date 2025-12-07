import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine
import CloudKit

// MARK: - AR World Map Persistence Service
/// Provides stable AR object persistence using ARWorldMap anchoring.
/// Objects anchored to world map features maintain position across app sessions
/// and can be synchronized between users for consistent multi-user experiences.
/// Supports both local storage and Apple's CloudKit infrastructure.
class ARWorldMapPersistenceService: ObservableObject {

    // MARK: - Properties

    @Published var isPersistenceEnabled: Bool = false
    @Published var hasPersistedWorldMap: Bool = false
    @Published var isWorldMapLoaded: Bool = false
    @Published var worldMapQuality: Double = 0.0 // 0.0 to 1.0

    private weak var arView: ARView?
    private var arSession: ARSession? {
        return arView?.session
    }

    // Cloud storage provider
    enum CloudProvider {
        case localStorage  // UserDefaults (original implementation)
        case cloudKit      // Apple's CloudKit infrastructure
    }

    private var cloudProvider: CloudProvider = .localStorage
    private var cloudKitContainer: CKContainer?
    private let worldMapRecordType = "ARWorldMap"

    // World map management
    private var currentWorldMap: ARWorldMap?
    private(set) var persistedWorldMap: ARWorldMap?
    private var worldMapData: Data?

    // Object anchoring to world map
    private var worldAnchoredObjects: [String: (anchor: ARAnchor, entity: Entity)] = [:]
    private var objectWorldTransforms: [String: simd_float4x4] = [:]

    // Persistence storage
    private let worldMapKey = "PersistedARWorldMap"
    private let objectsKey = "WorldAnchoredObjects"
    private let userDefaults = UserDefaults.standard

    // Quality thresholds
    private let minWorldMapQuality: Double = 0.3 // Minimum quality for persistence
    private let maxAnchoredObjects = 50 // Limit objects per world map

    // Dependencies
    private weak var apiService: APIService?
    private weak var webSocketService: WebSocketService?

    // MARK: - Initialization

    init(arView: ARView? = nil) {
        self.arView = arView
        setupSessionDelegate()
        print("🗺️ ARWorldMapPersistenceService initialized")
    }

    func configure(with arView: ARView,
                   apiService: APIService,
                   webSocketService: WebSocketService,
                   cloudProvider: CloudProvider = .localStorage) {
        self.arView = arView
        self.apiService = apiService
        self.webSocketService = webSocketService
        self.cloudProvider = cloudProvider

        if cloudProvider == .cloudKit {
            setupCloudKit()
        }

        setupWebSocketCallbacks()
        print("✅ ARWorldMapPersistenceService configured with provider: \(cloudProvider)")
    }

    // MARK: - CloudKit Setup

    private func setupCloudKit() {
        cloudKitContainer = CKContainer(identifier: "iCloud.com.shaydu.CacheRaiders")
        print("☁️ CloudKit configured for world map persistence")
    }

    private func saveWorldMapToCloudKit(_ worldMapData: Data, quality: Double, completion: @escaping (Bool) -> Void) {
        guard let container = cloudKitContainer else {
            print("❌ CloudKit container not configured")
            completion(false)
            return
        }

        let record = CKRecord(recordType: worldMapRecordType)
        record["worldMapData"] = worldMapData as CKRecordValue
        record["quality"] = quality as CKRecordValue
        record["timestamp"] = Date() as CKRecordValue
        let deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        record["deviceId"] = deviceId as CKRecordValue

        let database = container.privateCloudDatabase
        database.save(record) { savedRecord, error in
            if let error = error {
                print("❌ Failed to save world map to CloudKit: \(error.localizedDescription)")
                completion(false)
            } else {
                print("☁️ World map saved to CloudKit successfully")
                completion(true)
            }
        }
    }

    // MARK: - Session Management

    private func setupSessionDelegate() {
        // Monitor world map updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(worldMapDidUpdate(_:)),
            name: NSNotification.Name("ARWorldMapDidUpdate"),
            object: nil
        )
    }

    private func setupWebSocketCallbacks() {
        // Handle shared world maps from other users
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sharedWorldMapReceived(_:)),
            name: NSNotification.Name("SharedWorldMapReceived"),
            object: nil
        )
    }

    // MARK: - World Map Quality Assessment

    /// Assesses the quality of the current AR world map
    /// - Returns: Quality score from 0.0 (poor) to 1.0 (excellent)
    func assessWorldMapQuality() -> Double {
        guard let session = arSession,
              let frame = session.currentFrame else {
            return 0.0
        }

        let worldMap = frame.anchors.compactMap { $0 as? ARAnchor }
        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }

        // Quality factors
        let anchorCount = Double(worldMap.count)
        let planeCount = Double(planeAnchors.count)
        let featurePoints = Double(frame.rawFeaturePoints?.points.count ?? 0)

        // Weighted quality score
        let anchorScore = min(anchorCount / 10.0, 1.0) * 0.4  // 40% weight
        let planeScore = min(planeCount / 5.0, 1.0) * 0.3    // 30% weight
        let featureScore = min(featurePoints / 500.0, 1.0) * 0.3 // 30% weight

        let quality = anchorScore + planeScore + featureScore

        print("🗺️ World map quality: \(String(format: "%.2f", quality)) (anchors: \(Int(anchorCount)), planes: \(Int(planeCount)), features: \(Int(featurePoints)))")

        return quality
    }

    // MARK: - World Map Persistence

    /// Captures and persists the current AR world map if quality is sufficient
    func captureAndPersistWorldMap() async -> Bool {
        let quality = assessWorldMapQuality()
        worldMapQuality = quality

        guard quality >= minWorldMapQuality else {
            print("⚠️ World map quality too low (\(String(format: "%.2f", quality))) - minimum required: \(minWorldMapQuality)")
            return false
        }

        guard let session = arSession else {
            print("⚠️ No AR session available for world map capture")
            return false
        }

        return await withCheckedContinuation { continuation in
            session.getCurrentWorldMap { worldMap, error in
                if let error = error {
                    print("❌ Failed to capture world map: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                    return
                }

                guard let worldMap = worldMap else {
                    print("⚠️ No world map data available")
                    continuation.resume(returning: false)
                    return
                }

                // Serialize world map
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                    self.worldMapData = data
                    self.currentWorldMap = worldMap

                    // Persist based on cloud provider
                    switch self.cloudProvider {
                    case .localStorage:
                        self.userDefaults.set(data, forKey: self.worldMapKey)
                        self.hasPersistedWorldMap = true
                        print("💾 World map captured and persisted to local storage (\(data.count) bytes, quality: \(String(format: "%.2f", quality)))")
                        continuation.resume(returning: true)

                    case .cloudKit:
                        self.saveWorldMapToCloudKit(data, quality: quality) { success in
                            self.hasPersistedWorldMap = success
                            if success {
                                print("☁️ World map captured and persisted to CloudKit (\(data.count) bytes, quality: \(String(format: "%.2f", quality)))")
                            } else {
                                print("❌ Failed to persist world map to CloudKit")
                            }
                            continuation.resume(returning: success)
                        }
                    }

                } catch {
                    print("❌ Failed to serialize world map: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Loads a persisted world map from storage
    func loadPersistedWorldMap() -> Bool {
        switch cloudProvider {
        case .localStorage:
            return loadWorldMapFromLocalStorage()
        case .cloudKit:
            loadWorldMapFromCloudKit()
            return false // Async operation, will complete later
        }
    }

    private func loadWorldMapFromLocalStorage() -> Bool {
        guard let data = userDefaults.data(forKey: worldMapKey) else {
            print("ℹ️ No persisted world map found in local storage")
            return false
        }

        do {
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                print("❌ Failed to unarchive world map from local storage")
                return false
            }

            self.persistedWorldMap = worldMap
            self.worldMapData = data
            self.hasPersistedWorldMap = true
            self.isWorldMapLoaded = false // Will be set to true when loaded into session

            print("💾 Persisted world map loaded from local storage (\(data.count) bytes)")
            return true

        } catch {
            print("❌ Failed to load persisted world map from local storage: \(error.localizedDescription)")
            return false
        }
    }

    private func loadWorldMapFromCloudKit() {
        guard let container = cloudKitContainer else {
            print("❌ CloudKit container not configured")
            return
        }

        let database = container.privateCloudDatabase
        let query = CKQuery(recordType: worldMapRecordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        database.perform(query, inZoneWith: nil) { records, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Failed to fetch world map from CloudKit: \(error.localizedDescription)")
                    return
                }

                guard let records = records, let latestRecord = records.first else {
                    print("ℹ️ No world map found in CloudKit")
                    return
                }

                guard let worldMapData = latestRecord["worldMapData"] as? Data else {
                    print("❌ Invalid world map data in CloudKit record")
                    return
                }

                do {
                    guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: worldMapData) else {
                        print("❌ Failed to unarchive world map from CloudKit")
                        return
                    }

                    self.persistedWorldMap = worldMap
                    self.worldMapData = worldMapData
                    self.isWorldMapLoaded = true
                    self.hasPersistedWorldMap = true

                    print("☁️ Loaded persisted world map from CloudKit (\(worldMapData.count) bytes)")

                } catch {
                    print("❌ Failed to load world map from CloudKit: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Applies persisted world map to current AR session
    func applyWorldMapToSession() -> Bool {
        guard let worldMap = persistedWorldMap else {
            print("⚠️ No persisted world map available")
            return false
        }

        guard let session = arSession else {
            print("⚠️ No AR session available")
            return false
        }

        // Create configuration with persisted world map
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = worldMap

        // Apply configuration
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        isWorldMapLoaded = true
        print("✅ Applied persisted world map to AR session")
        return true
    }

    // MARK: - Object Anchoring to World Map

    /// Anchors an object to world map features for persistent positioning
    /// - Parameters:
    ///   - entity: The RealityKit entity to anchor
    ///   - objectId: Unique identifier for the object
    ///   - position: World position where to anchor the object
    /// - Returns: True if anchoring successful
    func anchorObjectToWorldMap(entity: Entity, objectId: String, position: SIMD3<Float>) -> Bool {
        guard let session = arSession else {
            print("⚠️ No AR session available for object anchoring")
            return false
        }

        guard worldAnchoredObjects.count < maxAnchoredObjects else {
            print("⚠️ Maximum anchored objects limit reached (\(maxAnchoredObjects))")
            return false
        }

        // Create AR anchor at the specified position
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1.0)

        let anchor = ARAnchor(name: "world_anchored_\(objectId)", transform: transform)
        session.add(anchor: anchor)

        // Store the world transform for persistence
        objectWorldTransforms[objectId] = transform

        // Create AnchorEntity and attach the object
        let anchorEntity = AnchorEntity(anchor: anchor)
        anchorEntity.addChild(entity)
        arView?.scene.addAnchor(anchorEntity)

        // Store reference
        worldAnchoredObjects[objectId] = (anchor: anchor, entity: entity)

        print("📍 Anchored object '\(objectId)' to world map at (\(String(format: "%.2f", position.x)), \(String(format: "%.2f", position.y)), \(String(format: "%.2f", position.z)))")
        return true
    }

    /// Removes world map anchoring for an object
    func removeWorldAnchoring(objectId: String) {
        if let (anchor, _) = worldAnchoredObjects[objectId] {
            arSession?.remove(anchor: anchor)
            worldAnchoredObjects.removeValue(forKey: objectId)
            objectWorldTransforms.removeValue(forKey: objectId)
            print("🗑️ Removed world anchoring for object '\(objectId)'")
        }
    }

    // MARK: - Persistence of Anchored Objects

    /// Persists all world-anchored objects to storage
    func persistAnchoredObjects() {
        let objectData = objectWorldTransforms.map { objectId, transform -> [String: Any] in
            return [
                "id": objectId,
                "transform": [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3],
                "timestamp": Date().timeIntervalSince1970
            ]
        }

        userDefaults.set(objectData, forKey: objectsKey)
        print("💾 Persisted \(objectData.count) world-anchored objects")
    }

    /// Restores previously persisted world-anchored objects
    func restoreAnchoredObjects() {
        guard let objectData = userDefaults.array(forKey: objectsKey) as? [[String: Any]] else {
            print("ℹ️ No persisted anchored objects found")
            return
        }

        var restoredCount = 0
        for objectDict in objectData {
            guard let objectId = objectDict["id"] as? String,
                  let transformColumns = objectDict["transform"] as? [SIMD4<Float>] else {
                continue
            }

            // Reconstruct transform matrix
            var transform = matrix_identity_float4x4
            if transformColumns.count >= 4 {
                transform.columns.0 = transformColumns[0]
                transform.columns.1 = transformColumns[1]
                transform.columns.2 = transformColumns[2]
                transform.columns.3 = transformColumns[3]
            }

            // Restore the anchor
            let anchor = ARAnchor(name: "world_anchored_\(objectId)", transform: transform)
            arSession?.add(anchor: anchor)

            // Store transform for reference
            objectWorldTransforms[objectId] = transform
            restoredCount += 1

            print("🔄 Restored world anchoring for object '\(objectId)'")
        }

        print("✅ Restored \(restoredCount) world-anchored objects from persistence")
    }

    // MARK: - Multi-User Synchronization

    /// Shares current world map and anchored objects with other users
    func shareWorldMapAndObjects() async {
        guard let worldMapData = worldMapData,
              let apiService = apiService else {
            print("⚠️ Cannot share world map - no data or API service available")
            return
        }

        let sharedData: [String: Any] = [
            "worldMapData": worldMapData.base64EncodedString(),
            "anchoredObjects": objectWorldTransforms.map { objectId, transform in
                [
                    "id": objectId,
                    "transform": [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
                ]
            },
            "timestamp": Date().timeIntervalSince1970,
            "deviceUUID": UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        ]

        // Note: shareARWorldMap method not yet implemented in APIService
        // Commenting out for now to allow build to succeed
        /*
        do {
            try await apiService.shareARWorldMap(sharedData)
            print("📤 Shared world map and \(objectWorldTransforms.count) anchored objects")
        } catch {
            print("❌ Failed to share world map: \(error.localizedDescription)")
        }
        */
        print("⚠️ World map sharing not yet implemented - shareARWorldMap API method needed")
    }

    /// Loads shared world map and objects from another user
    func loadSharedWorldMap(_ sharedData: [String: Any]) -> Bool {
        guard let worldMapString = sharedData["worldMapData"] as? String,
              let worldMapData = Data(base64Encoded: worldMapString) else {
            print("❌ Invalid shared world map data")
            return false
        }

        // Load the shared world map
        do {
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: worldMapData) else {
                print("❌ Failed to unarchive shared world map")
                return false
            }

            // Apply to session
            let configuration = ARWorldTrackingConfiguration()
            configuration.initialWorldMap = worldMap
            arSession?.run(configuration, options: [.resetTracking, .removeExistingAnchors])

            self.persistedWorldMap = worldMap
            self.worldMapData = worldMapData
            self.isWorldMapLoaded = true

            // Load shared objects if available
            if let anchoredObjects = sharedData["anchoredObjects"] as? [[String: Any]] {
                loadSharedAnchoredObjects(anchoredObjects)
            }

            print("✅ Loaded shared world map from another user")
            return true

        } catch {
            print("❌ Failed to load shared world map: \(error.localizedDescription)")
            return false
        }
    }

    private func loadSharedAnchoredObjects(_ objectsData: [[String: Any]]) {
        var loadedCount = 0

        for objectDict in objectsData {
            guard let objectId = objectDict["id"] as? String,
                  let transformColumns = objectDict["transform"] as? [SIMD4<Float>] else {
                continue
            }

            // Reconstruct transform
            var transform = matrix_identity_float4x4
            if transformColumns.count >= 4 {
                transform.columns.0 = transformColumns[0]
                transform.columns.1 = transformColumns[1]
                transform.columns.2 = transformColumns[2]
                transform.columns.3 = transformColumns[3]
            }

            // Create anchor
            let anchor = ARAnchor(name: "shared_world_anchored_\(objectId)", transform: transform)
            arSession?.add(anchor: anchor)

            objectWorldTransforms[objectId] = transform
            loadedCount += 1

            print("🔄 Loaded shared anchored object '\(objectId)'")
        }

        print("✅ Loaded \(loadedCount) shared anchored objects")
    }

    // MARK: - Notification Handlers

    @objc private func worldMapDidUpdate(_ notification: Notification) {
        // Update quality assessment
        worldMapQuality = assessWorldMapQuality()

        // Auto-persist if quality is good and we don't have a persisted map
        if !hasPersistedWorldMap && worldMapQuality >= minWorldMapQuality {
            Task {
                await captureAndPersistWorldMap()
            }
        }
    }

    @objc private func sharedWorldMapReceived(_ notification: Notification) {
        guard let sharedData = notification.userInfo?["sharedData"] as? [String: Any] else {
            return
        }

        DispatchQueue.main.async {
            _ = self.loadSharedWorldMap(sharedData)
        }
    }

    // MARK: - Migration Methods

    /// Migrates world map data from local storage to CloudKit
    func migrateWorldMapToCloudKit() async -> Bool {
        guard cloudProvider == .cloudKit, let container = cloudKitContainer else {
            print("❌ CloudKit not configured for world map migration")
            return false
        }

        // Load existing world map from local storage
        guard let data = userDefaults.data(forKey: worldMapKey) else {
            print("ℹ️ No local world map found to migrate")
            return false
        }

        do {
            // Unarchive to verify it's valid
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                print("❌ Invalid world map data in local storage")
                return false
            }

            // Save to CloudKit
            let record = CKRecord(recordType: worldMapRecordType)
            record["worldMapData"] = data as CKRecordValue
            record["quality"] = assessWorldMapQuality() as CKRecordValue
            record["timestamp"] = Date() as CKRecordValue
            let deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            record["deviceId"] = deviceId as CKRecordValue
            record["migrationSource"] = "localStorage" as CKRecordValue

            let database = container.privateCloudDatabase
            _ = try await database.save(record)

            print("✅ Migrated world map from local storage to CloudKit")
            return true

        } catch {
            print("❌ Failed to migrate world map to CloudKit: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Utility Methods

    /// Gets the current position of a world-anchored object
    func getWorldAnchoredPosition(objectId: String) -> SIMD3<Float>? {
        guard let transform = objectWorldTransforms[objectId] else {
            return nil
        }
        return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// Checks if an object is world-anchored
    func isWorldAnchored(objectId: String) -> Bool {
        return worldAnchoredObjects[objectId] != nil
    }

    /// Gets the number of world-anchored objects
    var worldAnchoredObjectsCount: Int {
        return worldAnchoredObjects.count
    }

    /// Gets diagnostic information
    func getDiagnostics() -> [String: Any] {
        return [
            "persistenceEnabled": isPersistenceEnabled,
            "hasPersistedWorldMap": hasPersistedWorldMap,
            "isWorldMapLoaded": isWorldMapLoaded,
            "worldMapQuality": worldMapQuality,
            "anchoredObjectsCount": worldAnchoredObjects.count,
            "worldMapDataSize": worldMapData?.count ?? 0
        ]
    }

    // MARK: - World Transform Storage

    /// Store the world transform for an object (for persistence)
    /// - Parameters:
    ///   - objectId: Unique identifier for the object
    ///   - transform: The world transform matrix to store
    func storeObjectWorldTransform(_ objectId: String, transform: simd_float4x4) {
        objectWorldTransforms[objectId] = transform
        print("🗺️ Stored world transform for object: \(objectId)")
    }

    /// Retrieve stored world transform for an object
    /// - Parameter objectId: Unique identifier for the object
    /// - Returns: The stored world transform, or nil if not found
    func getStoredWorldTransform(_ objectId: String) -> simd_float4x4? {
        return objectWorldTransforms[objectId]
    }

    // MARK: - Cleanup

    func clearAllPersistence() {
        // Remove all anchors
        for (objectId, _) in worldAnchoredObjects {
            removeWorldAnchoring(objectId: objectId)
        }

        // Clear storage
        userDefaults.removeObject(forKey: worldMapKey)
        userDefaults.removeObject(forKey: objectsKey)

        // Reset state
        currentWorldMap = nil
        persistedWorldMap = nil
        worldMapData = nil
        hasPersistedWorldMap = false
        isWorldMapLoaded = false

        print("🧹 Cleared all world map persistence data")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

