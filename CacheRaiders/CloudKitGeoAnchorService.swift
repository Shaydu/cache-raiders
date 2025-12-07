import Foundation
import CloudKit
import CoreLocation
import Combine
import ARKit

/// Provides CloudKit-based geo anchoring for stable, shared AR experiences.
/// Uses Apple's CloudKit infrastructure for server-side persistence of ARGeoAnchors.
class CloudKitGeoAnchorService: NSObject, ObservableObject {

    // MARK: - Properties

    @Published var isCloudAvailable: Bool = false
    @Published var activeGeoAnchors: [String: ARGeoAnchor] = [:]
    @Published var anchorQuality: [String: Double] = [:] // 0.0 to 1.0
    @Published var lastCloudError: Error?
    @Published var isOfflineMode: Bool = false

    private let container: CKContainer
    private let privateDatabase: CKDatabase
    private let publicDatabase: CKDatabase

    // Zone for organizing geo anchor records
    private let geoAnchorZoneID = CKRecordZone.ID(zoneName: "GeoAnchors", ownerName: CKCurrentUserDefaultName)
    private var geoAnchorZone: CKRecordZone?

    // Subscription for real-time updates
    private var geoAnchorSubscription: CKSubscription?

    // Dependencies
    private weak var apiService: APIService?
    private weak var webSocketService: WebSocketService?

    // MARK: - Initialization

    init(containerIdentifier: String = "iCloud.com.shaydu.CacheRaiders") {
        self.container = CKContainer(identifier: containerIdentifier)
        self.privateDatabase = container.privateCloudDatabase
        self.publicDatabase = container.publicCloudDatabase

        super.init()

        setupCloudKit()
        print("☁️ CloudKitGeoAnchorService initialized with container: \(containerIdentifier)")
    }

    func configure(apiService: APIService, webSocketService: WebSocketService) {
        self.apiService = apiService
        self.webSocketService = webSocketService
        setupWebSocketCallbacks()
        startConnectivityMonitoring()
        print("✅ CloudKitGeoAnchorService configured with connectivity monitoring")
    }

    // MARK: - CloudKit Setup

    private func setupCloudKit() {
        // Check iCloud account availability
        container.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                switch status {
                case .available:
                    self?.isCloudAvailable = true
                    self?.setupRecordZone()
                    self?.setupSubscriptions()
                    print("☁️ iCloud account available - CloudKit ready")
                case .noAccount:
                    self?.isCloudAvailable = false
                    print("⚠️ No iCloud account - CloudKit unavailable")
                case .restricted:
                    self?.isCloudAvailable = false
                    print("⚠️ iCloud access restricted - CloudKit unavailable")
                case .couldNotDetermine:
                    self?.isCloudAvailable = false
                    print("⚠️ Could not determine iCloud status - CloudKit unavailable")
                @unknown default:
                    self?.isCloudAvailable = false
                    print("⚠️ Unknown iCloud status - CloudKit unavailable")
                }
            }
        }
    }

    private func setupRecordZone() {
        let zone = CKRecordZone(zoneID: geoAnchorZoneID)

        privateDatabase.save(zone) { [weak self] savedZone, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Failed to create geo anchor zone: \(error.localizedDescription)")
                    // Try to fetch existing zone instead
                    self?.fetchRecordZone()
                } else {
                    self?.geoAnchorZone = savedZone
                    print("✅ Created geo anchor record zone")
                    // Load existing anchors
                    self?.fetchExistingGeoAnchors()
                }
            }
        }
    }

    private func fetchRecordZone() {
        privateDatabase.fetch(withRecordZoneID: geoAnchorZoneID) { [weak self] zone, error in
            DispatchQueue.main.async {
                if let zone = zone {
                    self?.geoAnchorZone = zone
                    print("✅ Found existing geo anchor record zone")
                    self?.fetchExistingGeoAnchors()
                } else {
                    print("❌ Could not find or create geo anchor zone: \(error?.localizedDescription ?? "Unknown error")")
                }
            }
        }
    }

    private func setupSubscriptions() {
        // Create subscription for real-time geo anchor updates
        let subscription = CKQuerySubscription(
            recordType: "GeoAnchor",
            predicate: NSPredicate(value: true),
            subscriptionID: "GeoAnchorUpdates",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        // Configure notification info
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        notificationInfo.category = "GEO_ANCHOR_UPDATES"
        subscription.notificationInfo = notificationInfo

        privateDatabase.save(subscription) { [weak self] savedSubscription, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("⚠️ Failed to create geo anchor subscription: \(error.localizedDescription)")
                } else {
                    self?.geoAnchorSubscription = savedSubscription
                    print("✅ Set up geo anchor subscription for real-time updates")
                }
            }
        }
    }

    private func setupWebSocketCallbacks() {
        // Handle shared geo anchors from other users (fallback to WebSocket)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sharedGeoAnchorReceived(_:)),
            name: NSNotification.Name("SharedGeoAnchorReceived"),
            object: nil
        )
    }

    // MARK: - Geo Anchor Management

    /// Stores a geo anchor in CloudKit with offline fallback
    func storeGeoAnchor(_ anchorData: CloudGeoAnchorData) async throws {
        guard isCloudAvailable else {
            // Offline fallback: cache locally and retry when online
            try await storeAnchorLocally(anchorData)
            throw NSError(domain: "CloudKitGeoAnchorService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not available - data cached locally"])
        }

        do {
            try await performCloudKitStore(anchorData)
            lastCloudError = nil
            isOfflineMode = false
        } catch let error as CKError {
            lastCloudError = error
            handleCloudKitError(error, operation: "store geo anchor")

            // Fallback to local storage for recoverable errors
            if isRecoverableError(error) {
                try await storeAnchorLocally(anchorData)
                throw NSError(domain: "CloudKitGeoAnchorService",
                             code: -2,
                             userInfo: [NSLocalizedDescriptionKey: "CloudKit temporarily unavailable - data cached locally"])
            } else {
                throw error
            }
        } catch {
            lastCloudError = error
            throw error
        }
    }

    private func performCloudKitStore(_ anchorData: CloudGeoAnchorData) async throws {

        let record = CKRecord(recordType: "GeoAnchor", zoneID: geoAnchorZoneID)
        record["objectId"] = anchorData.objectId as CKRecordValue
        record["latitude"] = anchorData.coordinate.latitude as CKRecordValue
        record["longitude"] = anchorData.coordinate.longitude as CKRecordValue
        record["altitude"] = anchorData.altitude as CKRecordValue
        record["deviceId"] = anchorData.deviceId as CKRecordValue
        record["createdAt"] = anchorData.createdAt as CKRecordValue

        try await privateDatabase.save(record)
        print("☁️ Stored geo anchor '\(anchorData.objectId)' in CloudKit")
    }

    /// Fetches all geo anchors from CloudKit with offline fallback
    func fetchGeoAnchors() async throws -> [CloudGeoAnchorData] {
        guard isCloudAvailable else {
            // Offline fallback: return locally cached anchors
            return try await fetchLocallyCachedAnchors()
        }

        do {
            let anchors = try await performCloudKitFetch()
            lastCloudError = nil
            isOfflineMode = false
            return anchors
        } catch let error as CKError {
            lastCloudError = error
            handleCloudKitError(error, operation: "fetch geo anchors")

            if isRecoverableError(error) {
                // Return cached data for recoverable errors
                return try await fetchLocallyCachedAnchors()
            } else {
                throw error
            }
        } catch {
            lastCloudError = error
            throw error
        }
    }

    private func performCloudKitFetch() async throws -> [CloudGeoAnchorData] {

        let query = CKQuery(recordType: "GeoAnchor", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let (results, _) = try await privateDatabase.records(matching: query)

        return try results.map { recordID, recordResult in
            let record = try recordResult.get()

            guard let objectId = record["objectId"] as? String,
                  let latitude = record["latitude"] as? Double,
                  let longitude = record["longitude"] as? Double,
                  let altitude = record["altitude"] as? Double,
                  let deviceId = record["deviceId"] as? String,
                  let createdAt = record["createdAt"] as? Date else {
                throw NSError(domain: "CloudKitGeoAnchorService",
                             code: -2,
                             userInfo: [NSLocalizedDescriptionKey: "Invalid record data"])
            }

            return CloudGeoAnchorData(
                objectId: objectId,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: altitude,
                createdAt: createdAt,
                deviceId: deviceId
            )
        }
    }

    /// Shares a geo anchor with other users via CloudKit public database
    func shareGeoAnchor(_ anchorData: CloudGeoAnchorData) async throws {
        guard isCloudAvailable else {
            throw NSError(domain: "CloudKitGeoAnchorService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not available"])
        }

        let record = CKRecord(recordType: "SharedGeoAnchor")
        record["objectId"] = anchorData.objectId as CKRecordValue
        record["latitude"] = anchorData.coordinate.latitude as CKRecordValue
        record["longitude"] = anchorData.coordinate.longitude as CKRecordValue
        record["altitude"] = anchorData.altitude as CKRecordValue
        record["deviceId"] = anchorData.deviceId as CKRecordValue
        record["createdAt"] = anchorData.createdAt as CKRecordValue

        try await publicDatabase.save(record)
        print("🌐 Shared geo anchor '\(anchorData.objectId)' via CloudKit public database")
    }

    /// Deletes a geo anchor from CloudKit
    func deleteGeoAnchor(objectId: String) async throws {
        guard isCloudAvailable else {
            throw NSError(domain: "CloudKitGeoAnchorService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not available"])
        }

        let query = CKQuery(recordType: "GeoAnchor", predicate: NSPredicate(format: "objectId == %@", objectId))

        let (results, _) = try await privateDatabase.records(matching: query)

        for (recordID, _) in results {
            try await privateDatabase.deleteRecord(withID: recordID)
        }

        print("🗑️ Deleted geo anchor '\(objectId)' from CloudKit")
    }

    // MARK: - Local Cache Management

    private func fetchExistingGeoAnchors() {
        Task {
            do {
                let anchors = try await fetchGeoAnchors()
                print("☁️ Loaded \(anchors.count) existing geo anchors from CloudKit")

                // Cache for offline access
                for anchor in anchors {
                    // Note: We can't create actual ARGeoAnchors without AR session context
                    // They will be created when needed during AR session
                }
            } catch {
                print("❌ Failed to fetch existing geo anchors: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Notification Handlers

    @objc private func sharedGeoAnchorReceived(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let anchorData = userInfo["anchorData"] as? CloudGeoAnchorData else { return }

        Task {
            do {
                try await shareGeoAnchor(anchorData)
            } catch {
                print("❌ Failed to share geo anchor via CloudKit: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CloudKit Subscription Handling

    func handleCloudKitNotification(_ notification: CKQueryNotification) {
        // Handle real-time updates from other devices
        switch notification.queryNotificationReason {
        case .recordCreated:
            print("☁️ New geo anchor created by another device")
            fetchExistingGeoAnchors()
        case .recordUpdated:
            print("☁️ Geo anchor updated by another device")
            fetchExistingGeoAnchors()
        case .recordDeleted:
            print("☁️ Geo anchor deleted by another device")
            fetchExistingGeoAnchors()
        default:
            break
        }
    }

    // MARK: - Migration Methods

    /// Migrates geo anchors from custom server to CloudKit
    func migrateFromCustomServer() async throws {
        guard isCloudAvailable else {
            throw NSError(domain: "CloudKitGeoAnchorService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "CloudKit not available for migration"])
        }

        guard let apiService = apiService else {
            throw NSError(domain: "CloudKitGeoAnchorService",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "API service not available for migration"])
        }

        print("🔄 Starting migration from custom server to CloudKit...")

        // Fetch all existing geo anchors from custom server
        let existingAnchors = try await apiService.fetchGeoAnchors()

        if existingAnchors.isEmpty {
            print("ℹ️ No geo anchors found on custom server to migrate")
            return
        }

        print("📊 Found \(existingAnchors.count) geo anchors to migrate")

        // Store each anchor in CloudKit
        for anchor in existingAnchors {
            do {
                try await storeGeoAnchor(anchor)
                print("✅ Migrated geo anchor '\(anchor.objectId)' to CloudKit")
            } catch {
                print("❌ Failed to migrate geo anchor '\(anchor.objectId)': \(error.localizedDescription)")
            }
        }

        print("✅ Migration completed: \(existingAnchors.count) geo anchors migrated to CloudKit")
    }

    // MARK: - Error Handling and Offline Support

    private func handleCloudKitError(_ error: CKError, operation: String) {
        switch error.code {
        case .networkUnavailable, .networkFailure:
            isOfflineMode = true
            print("🌐 CloudKit \(operation) failed due to network issues - entering offline mode")
        case .notAuthenticated:
            isCloudAvailable = false
            print("🔐 CloudKit \(operation) failed - user not authenticated")
        case .quotaExceeded:
            print("📊 CloudKit \(operation) failed - storage quota exceeded")
        case .partialFailure:
            print("⚠️ CloudKit \(operation) partially failed - some operations succeeded")
        default:
            print("❌ CloudKit \(operation) failed with error: \(error.localizedDescription)")
        }
    }

    private func isRecoverableError(_ error: CKError) -> Bool {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy:
            return true
        default:
            return false
        }
    }

    private func storeAnchorLocally(_ anchorData: CloudGeoAnchorData) async throws {
        // Store in UserDefaults as backup when CloudKit is unavailable
        let userDefaults = UserDefaults.standard
        var cachedAnchors = userDefaults.dictionary(forKey: "CachedGeoAnchors") as? [String: Data] ?? [:]

        let encoder = JSONEncoder()
        let data = try encoder.encode(anchorData)
        cachedAnchors[anchorData.objectId] = data

        userDefaults.set(cachedAnchors, forKey: "CachedGeoAnchors")
        print("💾 Cached geo anchor '\(anchorData.objectId)' locally for offline sync")
    }

    /// Attempts to sync locally cached anchors to CloudKit when connection is restored
    func syncCachedAnchorsToCloud() async {
        let userDefaults = UserDefaults.standard
        guard let cachedAnchors = userDefaults.dictionary(forKey: "CachedGeoAnchors") as? [String: Data],
              !cachedAnchors.isEmpty else {
            return
        }

        print("🔄 Attempting to sync \(cachedAnchors.count) cached anchors to CloudKit...")

        let decoder = JSONDecoder()
        var syncedCount = 0

        for (objectId, data) in cachedAnchors {
            do {
                let anchorData = try decoder.decode(CloudGeoAnchorData.self, from: data)
                try await performCloudKitStore(anchorData)

                // Remove from cache after successful sync
                var updatedCache = cachedAnchors
                updatedCache.removeValue(forKey: objectId)
                userDefaults.set(updatedCache, forKey: "CachedGeoAnchors")

                syncedCount += 1
                print("✅ Synced cached anchor '\(objectId)' to CloudKit")

            } catch {
                print("❌ Failed to sync cached anchor '\(objectId)': \(error.localizedDescription)")
            }
        }

        if syncedCount > 0 {
            print("✅ Successfully synced \(syncedCount) cached anchors to CloudKit")
        }
    }

    private func fetchLocallyCachedAnchors() async throws -> [CloudGeoAnchorData] {
        let userDefaults = UserDefaults.standard
        guard let cachedAnchors = userDefaults.dictionary(forKey: "CachedGeoAnchors") as? [String: Data] else {
            return []
        }

        let decoder = JSONDecoder()
        var anchors: [CloudGeoAnchorData] = []

        for (_, data) in cachedAnchors {
            do {
                let anchor = try decoder.decode(CloudGeoAnchorData.self, from: data)
                anchors.append(anchor)
            } catch {
                print("⚠️ Failed to decode cached anchor: \(error.localizedDescription)")
            }
        }

        print("💾 Returning \(anchors.count) locally cached geo anchors (CloudKit unavailable)")
        return anchors
    }

    /// Monitors network connectivity and attempts to sync when connection is restored
    func startConnectivityMonitoring() {
        // Monitor for iCloud account changes
        container.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                switch status {
                case .available:
                    if self?.isOfflineMode == true {
                        print("🌐 CloudKit connection restored - attempting to sync cached data")
                        Task {
                            await self?.syncCachedAnchorsToCloud()
                        }
                    }
                    self?.isCloudAvailable = true
                    self?.isOfflineMode = false
                case .noAccount, .restricted:
                    self?.isCloudAvailable = false
                    self?.isOfflineMode = true
                case .couldNotDetermine:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Utility Methods

    func getAnchorQuality(objectId: String) -> Double {
        return anchorQuality[objectId] ?? 0.0
    }

    func getDiagnostics() -> [String: Any] {
        return [
            "cloudAvailable": isCloudAvailable,
            "isOfflineMode": isOfflineMode,
            "activeAnchorsCount": activeGeoAnchors.count,
            "zoneConfigured": geoAnchorZone != nil,
            "subscriptionActive": geoAnchorSubscription != nil,
            "lastError": lastCloudError?.localizedDescription ?? "None",
            "cachedAnchorsCount": (UserDefaults.standard.dictionary(forKey: "CachedGeoAnchors")?.count ?? 0)
        ]
    }
}