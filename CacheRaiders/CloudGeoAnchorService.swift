import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - Cloud Geo Anchor Service
/// Provides cloud-backed geo anchoring for stable, shared AR experiences.
/// Uses ARGeoAnchors with server-side persistence for multi-user consistency.
/// Supports both custom server and Apple's CloudKit infrastructure.
class CloudGeoAnchorService: NSObject, ObservableObject {

    // MARK: - Properties

    @Published var isGeoTrackingEnabled: Bool = false
    @Published var activeGeoAnchors: [String: ARGeoAnchor] = [:]
    @Published var anchorQuality: [String: Double] = [:] // 0.0 to 1.0

    private weak var arView: ARView?
    private var arSession: ARSession? {
        return arView?.session
    }

    // Cloud infrastructure selection
    public enum CloudProvider {
        case customServer  // Original implementation using custom backend
        case cloudKit      // Apple's CloudKit infrastructure
    }

    private var cloudProvider: CloudProvider = .customServer
    public var cloudKitService: CloudKitGeoAnchorService?

    // Geo tracking configuration
    private var geoTrackingConfig: ARGeoTrackingConfiguration?
    var isGeoTrackingSupported: Bool {
        return ARGeoTrackingConfiguration.isSupported
    }

    // Anchor management
    private var anchorEntities: [String: AnchorEntity] = [:]
    private var pendingAnchors: [String: (coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance, objectId: String)] = [:]

    // Dependencies
    private weak var apiService: APIService?
    private weak var webSocketService: WebSocketService?

    // Session management
    private var sessionStartTime: Date?
    private let anchorPersistenceKey = "CloudGeoAnchors"

    // MARK: - Initialization

    init(arView: ARView? = nil) {
        super.init()
        self.arView = arView
        setupSessionDelegate()
        print("🛰️ CloudGeoAnchorService initialized")
    }

    func configure(with arView: ARView,
                   apiService: APIService,
                   webSocketService: WebSocketService,
                   cloudProvider: CloudProvider = .customServer) {
        self.arView = arView
        self.apiService = apiService
        self.webSocketService = webSocketService
        self.cloudProvider = cloudProvider

        setupWebSocketCallbacks()

        // Initialize CloudKit service if selected
        if cloudProvider == .cloudKit {
            cloudKitService = CloudKitGeoAnchorService()
            cloudKitService?.configure(apiService: apiService, webSocketService: webSocketService)
        }

        print("✅ CloudGeoAnchorService configured with provider: \(cloudProvider)")
    }

    // MARK: - Session Management

    private func setupSessionDelegate() {
        // Monitor geo anchor updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(geoAnchorsDidUpdate(_:)),
            name: NSNotification.Name("ARGeoAnchorsDidUpdate"),
            object: nil
        )
    }

    private func setupWebSocketCallbacks() {
        // Handle shared geo anchors from other users
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sharedGeoAnchorReceived(_:)),
            name: NSNotification.Name("SharedGeoAnchorReceived"),
            object: nil
        )
    }

    // MARK: - Geo Tracking Setup

    /// Starts geo tracking if supported on device
    func startGeoTracking() async throws {
        guard isGeoTrackingSupported else {
            throw NSError(domain: "CloudGeoAnchorService",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Geo tracking not supported on this device"])
        }

        guard let arView = arView else {
            throw NSError(domain: "CloudGeoAnchorService",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "No AR view available"])
        }

        // Create geo tracking configuration
        let config = ARGeoTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]

        // Note: ARGeoTrackingConfiguration does not support scene reconstruction
        // Scene reconstruction is only available with ARWorldTrackingConfiguration

        if ARGeoTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        do {
            try await arView.session.run(config)
            geoTrackingConfig = config
            isGeoTrackingEnabled = true
            sessionStartTime = Date()

            print("🛰️ Geo tracking started successfully")
        } catch {
            print("❌ Failed to start geo tracking: \(error)")
            throw error
        }
    }

    /// Stops geo tracking
    func stopGeoTracking() {
        guard let config = geoTrackingConfig else { return }

        arView?.session.run(ARWorldTrackingConfiguration())
        geoTrackingConfig = nil
        isGeoTrackingEnabled = false

        print("🛑 Geo tracking stopped")
    }

    // MARK: - Anchor Creation

    /// Creates a geo anchor at the specified GPS coordinates
    /// - Parameters:
    ///   - coordinate: GPS coordinate for anchor
    ///   - altitude: Altitude above sea level in meters
    ///   - objectId: Unique identifier for the object
    /// - Returns: AnchorEntity if successful
    func createGeoAnchor(coordinate: CLLocationCoordinate2D,
                        altitude: CLLocationDistance,
                        objectId: String) async throws -> AnchorEntity {

        guard isGeoTrackingEnabled else {
            throw NSError(domain: "CloudGeoAnchorService",
                         code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Geo tracking not enabled"])
        }

        guard let arView = arView else {
            throw NSError(domain: "CloudGeoAnchorService",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "No AR view available"])
        }

        // Create ARGeoAnchor
        let geoAnchor = ARGeoAnchor(
            coordinate: coordinate,
            altitude: altitude
        )

        // Add to session
        arView.session.add(anchor: geoAnchor)

        // Create AnchorEntity for object attachment
        let anchorEntity = AnchorEntity(anchor: geoAnchor)
        arView.scene.addAnchor(anchorEntity)

        // Store references
        activeGeoAnchors[objectId] = geoAnchor
        anchorEntities[objectId] = anchorEntity

        // Store anchor data for persistence
        await storeAnchorData(objectId: objectId,
                            coordinate: coordinate,
                            altitude: altitude,
                            geoAnchor: geoAnchor)

        print("📍 Created geo anchor for object '\(objectId)' at (\(coordinate.latitude), \(coordinate.longitude), \(altitude)m)")

        return anchorEntity
    }

    /// Creates a geo anchor at current GPS location with AR offset
    func createGeoAnchorAtLocation(coordinate: CLLocationCoordinate2D,
                                 altitude: CLLocationDistance,
                                 arOffset: SIMD3<Float> = .zero,
                                 objectId: String) async throws -> AnchorEntity {

        let anchorEntity = try await createGeoAnchor(coordinate: coordinate,
                                                   altitude: altitude,
                                                   objectId: objectId)

        // Apply AR offset if specified
        if arOffset != .zero {
            anchorEntity.position = arOffset
        }

        return anchorEntity
    }

    // MARK: - Anchor Resolution

    /// Resolves a geo anchor from stored data
    func resolveGeoAnchor(anchorData: CloudGeoAnchorData) async throws -> AnchorEntity {
        return try await createGeoAnchor(
            coordinate: anchorData.coordinate,
            altitude: anchorData.altitude,
            objectId: anchorData.objectId
        )
    }

    /// Resolves multiple geo anchors from server data
    func resolveGeoAnchors(anchorDatas: [CloudGeoAnchorData]) async throws {
        for anchorData in anchorDatas {
            do {
                _ = try await resolveGeoAnchor(anchorData: anchorData)
                print("✅ Resolved geo anchor for '\(anchorData.objectId)'")
            } catch {
                print("❌ Failed to resolve geo anchor for '\(anchorData.objectId)': \(error)")
            }
        }
    }

    // MARK: - Server Integration

    private func storeAnchorData(objectId: String,
                               coordinate: CLLocationCoordinate2D,
                               altitude: CLLocationDistance,
                               geoAnchor: ARGeoAnchor) async {

        let anchorData = CloudGeoAnchorData(
            objectId: objectId,
            coordinate: coordinate,
            altitude: altitude,
            createdAt: Date(),
            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        )

        do {
            switch cloudProvider {
            case .customServer:
                try await apiService?.storeGeoAnchor(anchorData)
                print("💾 Stored geo anchor data for '\(objectId)' on custom server")
            case .cloudKit:
                try await cloudKitService?.storeGeoAnchor(anchorData)
                print("☁️ Stored geo anchor data for '\(objectId)' in CloudKit")
            }
        } catch {
            print("❌ Failed to store geo anchor data: \(error)")
        }
    }

    /// Retrieves and resolves all geo anchors from cloud storage
    func syncGeoAnchorsFromCloud() async throws {
        let anchorDatas: [CloudGeoAnchorData]

        switch cloudProvider {
        case .customServer:
            guard let apiService = apiService else { return }
            anchorDatas = try await apiService.fetchGeoAnchors()
            print("📡 Synced geo anchors from custom server")
        case .cloudKit:
            guard let cloudKitService = cloudKitService else { return }
            anchorDatas = try await cloudKitService.fetchGeoAnchors()
            print("☁️ Synced geo anchors from CloudKit")
        }

        try await resolveGeoAnchors(anchorDatas: anchorDatas)

        print("🔄 Synced \(anchorDatas.count) geo anchors from server")
    }

    /// Shares geo anchor with other users
    func shareGeoAnchor(objectId: String) async throws {
        guard let anchorData = activeGeoAnchors[objectId] else {
            throw NSError(domain: "CloudGeoAnchorService",
                         code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Geo anchor not found"])
        }

        let coordinate = anchorData.coordinate
        let altitude = anchorData.altitude

        let anchorDataStruct = CloudGeoAnchorData(
            objectId: objectId,
            coordinate: coordinate,
            altitude: altitude ?? 0.0, // Provide default value if altitude is nil
            createdAt: Date(),
            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        )

        switch cloudProvider {
        case .customServer:
            try await apiService?.shareGeoAnchor(anchorDataStruct)
            print("📤 Shared geo anchor for '\(objectId)' with other users via custom server")
        case .cloudKit:
            try await cloudKitService?.shareGeoAnchor(anchorDataStruct)
            print("🌐 Shared geo anchor for '\(objectId)' with other users via CloudKit")
        }
    }

    // MARK: - Anchor Management

    /// Removes a geo anchor
    func removeGeoAnchor(objectId: String) {
        if let anchor = activeGeoAnchors[objectId] {
            arView?.session.remove(anchor: anchor)
            activeGeoAnchors.removeValue(forKey: objectId)
        }

        if let entity = anchorEntities[objectId] {
            arView?.scene.removeAnchor(entity)
            anchorEntities.removeValue(forKey: objectId)
        }

        anchorQuality.removeValue(forKey: objectId)
        print("🗑️ Removed geo anchor for '\(objectId)'")
    }

    /// Gets the position quality of a geo anchor
    func getAnchorQuality(objectId: String) -> Double {
        return anchorQuality[objectId] ?? 0.0
    }

    /// Updates anchor quality based on tracking state
    private func updateAnchorQuality() {
        for (objectId, anchor) in activeGeoAnchors {
            var quality = 0.0

            // Base quality on anchor transform validity
            if anchor.transform.columns.3.w.isFinite {
                quality += 0.6
            }

            // Additional quality factors
            if anchor.coordinate.latitude.isFinite && anchor.coordinate.longitude.isFinite {
                quality += 0.4
            }

            anchorQuality[objectId] = quality
        }
    }

    // MARK: - Session Delegate

    @objc private func geoAnchorsDidUpdate(_ notification: Notification) {
        updateAnchorQuality()

        // Notify about anchor updates
        NotificationCenter.default.post(
            name: NSNotification.Name("CloudGeoAnchorsUpdated"),
            object: self,
            userInfo: ["anchors": activeGeoAnchors]
        )
    }

    @objc private func sharedGeoAnchorReceived(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let anchorData = userInfo["anchorData"] as? CloudGeoAnchorData else { return }

        Task {
            do {
                _ = try await resolveGeoAnchor(anchorData: anchorData)
                print("📥 Received and resolved shared geo anchor for '\(anchorData.objectId)'")
            } catch {
                print("❌ Failed to resolve shared geo anchor: \(error)")
            }
        }
    }

    // MARK: - Diagnostics

    func getDiagnostics() -> [String: Any] {
        return [
            "geoTrackingEnabled": isGeoTrackingEnabled,
            "geoTrackingSupported": isGeoTrackingSupported,
            "activeAnchorsCount": activeGeoAnchors.count,
            "anchorQuality": anchorQuality,
            "sessionUptime": sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
        ]
    }
}

// MARK: - Cloud Geo Anchor Data Model

struct CloudGeoAnchorData: Codable {
    let objectId: String
    let coordinate: CLLocationCoordinate2D
    let altitude: CLLocationDistance
    let createdAt: Date
    let deviceId: String

    enum CodingKeys: String, CodingKey {
        case objectId
        case latitude
        case longitude
        case altitude
        case createdAt
        case deviceId
    }

    init(objectId: String, coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance, createdAt: Date, deviceId: String) {
        self.objectId = objectId
        self.coordinate = coordinate
        self.altitude = altitude
        self.createdAt = createdAt
        self.deviceId = deviceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objectId = try container.decode(String.self, forKey: .objectId)

        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)

        altitude = try container.decode(CLLocationDistance.self, forKey: .altitude)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deviceId = try container.decode(String.self, forKey: .deviceId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectId, forKey: .objectId)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
        try container.encode(altitude, forKey: .altitude)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(deviceId, forKey: .deviceId)
    }
}
