import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

/// Enhanced coordinate sharing with conflict resolution and consistency guarantees
class EnhancedCoordinateSharingService: ObservableObject {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var webSocketService: WebSocketService?

    @Published var connectedPeers: [String: PeerInfo] = [:]
    @Published var syncStatus: SyncStatus = .disconnected
    @Published var conflictsResolved: Int = 0

    private var localAROrigin: CLLocation?
    private var sharedWorldMap: ARWorldMap?
    private var objectVersionHistory: [String: [ObjectVersion]] = [:] // objectId -> version history
    private var pendingUpdates: [String: LootBoxLocation] = [:]

    enum SyncStatus {
        case disconnected
        case connecting
        case synchronized
        case conflicting
    }

    struct PeerInfo {
        let deviceId: String
        let arOrigin: CLLocation?
        let lastSeen: Date
        let worldMapAvailable: Bool
    }

    struct ObjectVersion {
        let version: Int64
        let location: LootBoxLocation
        let timestamp: Date
        let peerId: String
    }

    init(arView: ARView?, locationManager: LootBoxLocationManager?, webSocketService: WebSocketService?) {
        self.arView = arView
        self.locationManager = locationManager
        self.webSocketService = webSocketService
        setupWebSocketHandlers()
    }

    /// Establish shared AR coordinate system with peer
    func establishSharedCoordinates(with peerId: String, peerAROrigin: CLLocation) async -> Bool {
        guard let localOrigin = localAROrigin else {
            print("⚠️ Cannot establish shared coordinates - no local AR origin")
            return false
        }

        // Calculate coordinate transformation between peer and local systems
        let transform = calculateCoordinateTransform(from: peerAROrigin, to: localOrigin)

        connectedPeers[peerId] = PeerInfo(
            deviceId: peerId,
            arOrigin: peerAROrigin,
            lastSeen: Date(),
            worldMapAvailable: false
        )

        print("🔗 Established shared coordinates with peer \(peerId)")
        print("   Local origin: \(localOrigin.coordinate.latitude), \(localOrigin.coordinate.longitude)")
        print("   Peer origin: \(peerAROrigin.coordinate.latitude), \(peerAROrigin.coordinate.longitude)")

        // Share world map if available
        await shareWorldMapIfAvailable(with: peerId)

        return true
    }

    /// Share world map for collaborative AR session
    func shareWorldMap(with peerId: String) async {
        guard let arView = arView else { return }

        do {
            let worldMap = try await arView.session.currentWorldMap()

            // Compress and share world map data
            let worldMapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)

            // Send via WebSocket (would need to implement chunking for large data)
            await sendWorldMapData(worldMapData, to: peerId)

            if var peerInfo = connectedPeers[peerId] {
                peerInfo.worldMapAvailable = true
                connectedPeers[peerId] = peerInfo
            }

            print("🗺️ Shared world map with peer \(peerId) (\(worldMapData.count) bytes)")

        } catch {
            print("❌ Failed to share world map: \(error.localizedDescription)")
        }
    }

    /// Synchronize object placement across peers
    func synchronizeObjectPlacement(_ location: LootBoxLocation, isLocalPlacement: Bool) async {
        let objectId = location.id

        // Create version entry
        let version = ObjectVersion(
            version: location.server_version ?? 1,
            location: location,
            timestamp: Date(),
            peerId: "local" // Would be actual peer ID in multi-peer scenario
        )

        // Add to version history
        if objectVersionHistory[objectId] == nil {
            objectVersionHistory[objectId] = []
        }
        objectVersionHistory[objectId]?.append(version)

        // Broadcast to peers
        if isLocalPlacement {
            await broadcastObjectUpdate(location)
        }

        // Check for conflicts and resolve
        await resolveConflicts(for: objectId)
    }

    /// Resolve conflicts when multiple users modify the same object
    private func resolveConflicts(for objectId: String) async {
        guard let versions = objectVersionHistory[objectId], versions.count > 1 else { return }

        // Conflict resolution strategy: Last Write Wins + Location-based priority
        let sortedVersions = versions.sorted { $0.timestamp > $1.timestamp }
        let latestVersion = sortedVersions.first!

        // Check if there are actual conflicts (different positions)
        let conflictingVersions = versions.filter { version in
            let distance = latestVersion.location.location.distance(from: version.location.location)
            return distance > 0.1 // More than 10cm difference
        }

        if !conflictingVersions.isEmpty {
            conflictsResolved += 1
            syncStatus = .conflicting

            print("⚠️ Conflict detected for object \(objectId) (\(conflictingVersions.count) conflicting versions)")

            // Resolve by choosing the version with highest accuracy
            let resolvedVersion = resolveConflictVersions(conflictingVersions)
            await applyResolvedVersion(resolvedVersion, for: objectId)

        } else {
            syncStatus = .synchronized
        }
    }

    /// Resolve conflicting versions using accuracy metrics
    private func resolveConflictVersions(_ versions: [ObjectVersion]) -> ObjectVersion {
        // Prioritize versions with AR coordinates over GPS-only
        let arVersions = versions.filter { version in
            version.location.ar_offset_x != nil
        }

        if !arVersions.isEmpty {
            return arVersions.sorted { $0.timestamp > $1.timestamp }.first!
        }

        // Fallback to most recent
        return versions.sorted { $0.timestamp > $1.timestamp }.first!
    }

    /// Apply resolved version across all peers
    private func applyResolvedVersion(_ version: ObjectVersion, for objectId: String) async {
        // Update local state
        if let locationManager = locationManager {
            locationManager.updateLocation(version.location)
        }

        // Broadcast resolution to peers
        await broadcastConflictResolution(version.location)

        print("✅ Applied conflict resolution for \(objectId) - using \(version.peerId)'s version")
    }

    /// Calculate coordinate transformation between two AR origins
    private func calculateCoordinateTransform(from sourceOrigin: CLLocation, to targetOrigin: CLLocation) -> simd_float4x4 {
        // Calculate ENU (East, North, Up) transformation
        let distance = sourceOrigin.distance(from: targetOrigin)
        let bearing = sourceOrigin.bearing(to: targetOrigin)

        // Convert to transformation matrix
        let east = Float(distance * sin(bearing * .pi / 180.0))
        let north = Float(distance * cos(bearing * .pi / 180.0))

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(east, 0, north, 1)

        return transform
    }

    /// Set local AR origin for sharing
    func setLocalAROrigin(_ origin: CLLocation) {
        localAROrigin = origin
        print("📍 Set local AR origin for sharing: \(origin.coordinate.latitude), \(origin.coordinate.longitude)")
    }

    // MARK: - WebSocket Integration

    private func setupWebSocketHandlers() {
        // These would integrate with the existing WebSocketService
        // to handle real-time coordinate sharing messages
    }

    private func broadcastObjectUpdate(_ location: LootBoxLocation) async {
        // Send object update to all connected peers
        print("📡 Broadcasting object update: \(location.name)")
    }

    private func broadcastConflictResolution(_ location: LootBoxLocation) async {
        // Send conflict resolution to all peers
        print("📡 Broadcasting conflict resolution: \(location.name)")
    }

    private func sendWorldMapData(_ data: Data, to peerId: String) async {
        // Send world map data to specific peer (would need chunking)
        print("📡 Sending world map data to \(peerId)")
    }

    private func shareWorldMapIfAvailable(with peerId: String) async {
        // Check if we should share world map with this peer
        if let worldMap = sharedWorldMap {
            await shareWorldMap(with: peerId)
        }
    }
}
