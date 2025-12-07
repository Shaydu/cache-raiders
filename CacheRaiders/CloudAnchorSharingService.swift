import Foundation
import CoreLocation
import Combine
import UIKit
import ARKit

// MARK: - Cloud Anchor Sharing Service
/// Handles real-time sharing and synchronization of geo anchors between users.
/// Integrates with WebSocket service for live updates and APIService for persistence.
class CloudAnchorSharingService: ObservableObject {

    // MARK: - Properties

    @Published var connectedUsers: [String] = []
    @Published var sharedAnchors: [String: CloudGeoAnchorData] = [:]
    @Published var anchorSyncStatus: [String: AnchorSyncState] = [:]

    enum AnchorSyncState {
        case pending
        case syncing
        case synced
        case failed(Error)
    }

    private weak var apiService: APIService?
    private weak var webSocketService: WebSocketService?
    private weak var geoAnchorService: CloudGeoAnchorService?

    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.cacheraiders.cloudAnchorSharing", qos: .userInitiated)

    // MARK: - Initialization

    init(apiService: APIService? = nil,
         webSocketService: WebSocketService? = nil,
         geoAnchorService: CloudGeoAnchorService? = nil) {
        self.apiService = apiService
        self.webSocketService = webSocketService
        self.geoAnchorService = geoAnchorService

        setupWebSocketCallbacks()
        setupGeoAnchorCallbacks()

        print("🔗 CloudAnchorSharingService initialized")
    }

    func configure(with apiService: APIService,
                   webSocketService: WebSocketService,
                   geoAnchorService: CloudGeoAnchorService) {
        self.apiService = apiService
        self.webSocketService = webSocketService
        self.geoAnchorService = geoAnchorService

        setupWebSocketCallbacks()
        setupGeoAnchorCallbacks()

        print("✅ CloudAnchorSharingService configured")
    }

    // MARK: - WebSocket Integration

    private func setupWebSocketCallbacks() {
        // Handle incoming geo anchor updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGeoAnchorUpdate(_:)),
            name: NSNotification.Name("WebSocketGeoAnchorUpdate"),
            object: nil
        )

        // Handle user join/leave events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserJoined(_:)),
            name: NSNotification.Name("WebSocketUserJoined"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserLeft(_:)),
            name: NSNotification.Name("WebSocketUserLeft"),
            object: nil
        )

        // Handle geo anchor sharing requests
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGeoAnchorShared(_:)),
            name: NSNotification.Name("WebSocketGeoAnchorShared"),
            object: nil
        )
    }

    private func setupGeoAnchorCallbacks() {
        // Listen for local geo anchor creation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLocalGeoAnchorCreated(_:)),
            name: NSNotification.Name("CloudGeoAnchorsUpdated"),
            object: nil
        )
    }

    // MARK: - Anchor Sharing

    /// Shares a geo anchor with all connected users
    func shareGeoAnchor(_ anchorData: CloudGeoAnchorData) async throws {
        guard let webSocketService = webSocketService else {
            throw NSError(domain: "CloudAnchorSharingService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "WebSocket service not available"])
        }

        // Update sync status
        anchorSyncStatus[anchorData.objectId] = .syncing

        do {
            // Share via API (for persistence)
            try await apiService?.shareGeoAnchor(anchorData)

            // Share via WebSocket (for real-time updates)
            let message: [String: Any] = [
                "type": "geo_anchor_shared",
                "data": [
                    "object_id": anchorData.objectId,
                    "latitude": anchorData.coordinate.latitude,
                    "longitude": anchorData.coordinate.longitude,
                    "altitude": anchorData.altitude,
                    "device_id": anchorData.deviceId,
                    "created_at": ISO8601DateFormatter().string(from: anchorData.createdAt)
                ]
            ]

            webSocketService.sendMessage(message)

            // Store locally
            sharedAnchors[anchorData.objectId] = anchorData
            anchorSyncStatus[anchorData.objectId] = .synced

            print("📤 Shared geo anchor '\(anchorData.objectId)' with \(connectedUsers.count) users")

        } catch {
            anchorSyncStatus[anchorData.objectId] = .failed(error)
            throw error
        }
    }

    /// Requests synchronization of all geo anchors from server
    func requestAnchorSync() async throws {
        guard let webSocketService = webSocketService else { return }

        let message: [String: Any] = [
            "type": "request_geo_anchor_sync",
            "device_id": UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        ]

        webSocketService.sendMessage(message)
        print("🔄 Requested geo anchor synchronization")
    }

    /// Synchronizes anchors with a specific user
    func syncAnchorsWithUser(_ userId: String) async throws {
        guard let webSocketService = webSocketService else { return }

        let message: [String: Any] = [
            "type": "sync_geo_anchors",
            "target_user": userId,
            "anchors": sharedAnchors.values.map { anchor in
                [
                    "object_id": anchor.objectId,
                    "latitude": anchor.coordinate.latitude,
                    "longitude": anchor.coordinate.longitude,
                    "altitude": anchor.altitude,
                    "device_id": anchor.deviceId,
                    "created_at": ISO8601DateFormatter().string(from: anchor.createdAt)
                ]
            }
        ]

        webSocketService.sendMessage(message)
        print("🔄 Synchronizing geo anchors with user '\(userId)'")
    }

    // MARK: - Anchor Management

    /// Updates an existing shared anchor
    func updateSharedAnchor(_ anchorData: CloudGeoAnchorData) async throws {
        sharedAnchors[anchorData.objectId] = anchorData
        try await shareGeoAnchor(anchorData)

        // Notify local services
        NotificationCenter.default.post(
            name: NSNotification.Name("SharedGeoAnchorUpdated"),
            object: self,
            userInfo: ["anchorData": anchorData]
        )
    }

    /// Removes a shared anchor
    func removeSharedAnchor(objectId: String) async throws {
        guard let apiService = apiService else { return }

        // Remove from server
        try await apiService.deleteGeoAnchor(objectId: objectId)

        // Remove locally
        sharedAnchors.removeValue(forKey: objectId)
        anchorSyncStatus.removeValue(forKey: objectId)

        // Notify other users
        if let webSocketService = webSocketService {
            let message: [String: Any] = [
                "type": "geo_anchor_removed",
                "object_id": objectId
            ]
            webSocketService.sendMessage(message)
        }

        // Notify local services
        NotificationCenter.default.post(
            name: NSNotification.Name("SharedGeoAnchorRemoved"),
            object: self,
            userInfo: ["objectId": objectId]
        )

        print("🗑️ Removed shared geo anchor '\(objectId)'")
    }

    // MARK: - User Management

    func addConnectedUser(_ userId: String) {
        if !connectedUsers.contains(userId) {
            connectedUsers.append(userId)
            print("👤 User '\(userId)' joined anchor sharing")

            // Auto-sync anchors with new user
            Task {
                try? await syncAnchorsWithUser(userId)
            }
        }
    }

    func removeConnectedUser(_ userId: String) {
        connectedUsers.removeAll { $0 == userId }
        print("👋 User '\(userId)' left anchor sharing")
    }

    // MARK: - Notification Handlers

    @objc private func handleGeoAnchorUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let anchorData = userInfo["anchorData"] as? [String: Any] else { return }

        Task {
            await processIncomingAnchorData(anchorData)
        }
    }

    @objc private func handleUserJoined(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let userId = userInfo["userId"] as? String else { return }

        addConnectedUser(userId)
    }

    @objc private func handleUserLeft(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let userId = userInfo["userId"] as? String else { return }

        removeConnectedUser(userId)
    }

    @objc private func handleGeoAnchorShared(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let anchorData = userInfo["anchorData"] as? [String: Any] else { return }

        Task {
            await processIncomingAnchorData(anchorData)
        }
    }

    @objc private func handleLocalGeoAnchorCreated(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let anchors = userInfo["anchors"] as? [String: ARGeoAnchor] else { return }

        // Automatically share newly created local anchors
        for (objectId, anchor) in anchors {
            let anchorData = CloudGeoAnchorData(
                objectId: objectId,
                coordinate: anchor.coordinate,
                altitude: anchor.altitude ?? 0.0,
                createdAt: Date(),
                deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            )

            Task {
                do {
                    try await shareGeoAnchor(anchorData)
                } catch {
                    print("❌ Failed to auto-share geo anchor '\(objectId)': \(error)")
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func processIncomingAnchorData(_ anchorData: [String: Any]) async {
        guard let objectId = anchorData["object_id"] as? String,
              let latitude = anchorData["latitude"] as? Double,
              let longitude = anchorData["longitude"] as? Double,
              let altitude = anchorData["altitude"] as? Double,
              let deviceId = anchorData["device_id"] as? String,
              let createdAtString = anchorData["created_at"] as? String else {
            print("⚠️ Invalid geo anchor data received")
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()

        let anchorDataStruct = CloudGeoAnchorData(
            objectId: objectId,
            coordinate: coordinate,
            altitude: altitude,
            createdAt: createdAt,
            deviceId: deviceId
        )

        // Store shared anchor
        sharedAnchors[objectId] = anchorDataStruct
        anchorSyncStatus[objectId] = .synced

        // Notify geo anchor service to resolve the anchor
        NotificationCenter.default.post(
            name: NSNotification.Name("SharedGeoAnchorReceived"),
            object: self,
            userInfo: ["anchorData": anchorDataStruct]
        )

        print("📥 Received shared geo anchor '\(objectId)' from user '\(deviceId)'")
    }

    // MARK: - Diagnostics

    func getSharingDiagnostics() -> [String: Any] {
        return [
            "connectedUsersCount": connectedUsers.count,
            "sharedAnchorsCount": sharedAnchors.count,
            "syncStatusSummary": anchorSyncStatus.mapValues { status in
                switch status {
                case .pending: return "pending"
                case .syncing: return "syncing"
                case .synced: return "synced"
                case .failed: return "failed"
                }
            },
            "totalAnchorsSyncing": anchorSyncStatus.values.filter {
                if case .syncing = $0 { return true }
                return false
            }.count,
            "totalAnchorsFailed": anchorSyncStatus.values.filter {
                if case .failed = $0 { return true }
                return false
            }.count
        ]
    }

    /// Cleans up resources and disconnects
    func disconnect() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        connectedUsers.removeAll()
        sharedAnchors.removeAll()
        anchorSyncStatus.removeAll()

        print("🔌 CloudAnchorSharingService disconnected")
    }
}
