import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - Consolidated AR Anchor Stability Service
/// Unified service providing comprehensive anchor stability, drift correction, and stabilization.
/// Combines geo anchoring, multi-anchor networks, and real-time drift monitoring.
class ARAnchorStabilityService: NSObject, ObservableObject {

    // MARK: - Properties

    @Published var activeStabilizationNetworks: [String: StabilizationNetwork] = [:]
    @Published var driftEventsDetected: Int = 0
    @Published var overallStabilityScore: Double = 0.0

    private weak var arView: ARView?
    private weak var locationManager: LootBoxLocationManager?

    // Stabilization data
    private var geoAnchors: [String: ARGeoAnchor] = [:]
    private var referenceAnchors: [String: [ARAnchor]] = [:]
    private var anchorBaselines: [String: AnchorBaseline] = [:]

    // Drift monitoring
    private var driftThreshold: Float = 0.05 // 5cm drift threshold
    private var correctionHistory: [String: [CorrectionEvent]] = [:]

    // Network monitoring
    private var networkUpdateTimer: Timer?
    private var stabilityUpdateTimer: Timer?

    // MARK: - Initialization

    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        super.init()
        self.arView = arView
        self.locationManager = locationManager
        setupStabilityMonitoring()
        startStabilityUpdates()
        print("🎯 ARAnchorStabilityService initialized")
    }

    deinit {
        networkUpdateTimer?.invalidate()
        stabilityUpdateTimer?.invalidate()
    }

    // MARK: - Geo Anchor Management

    /// Creates a geo-anchored object for GPS-synchronized stability
    func createGeoAnchoredObject(objectId: String, coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance? = nil) async throws -> AnchorEntity {
        guard let arView = arView else { throw NSError(domain: "ARAnchorStability", code: -1, userInfo: [NSLocalizedDescriptionKey: "No AR view available"]) }

        // Create geo anchor
        let geoAnchor = ARGeoAnchor(coordinate: coordinate, altitude: altitude)
        arView.session.add(anchor: geoAnchor)
        geoAnchors[objectId] = geoAnchor

        // Create AnchorEntity attached to geo anchor
        let anchorEntity = AnchorEntity(anchor: geoAnchor)
        arView.scene.addAnchor(anchorEntity)

        print("📍 Created geo-anchored object '\(objectId)' at \(coordinate.latitude), \(coordinate.longitude)")

        // Establish baseline for drift monitoring
        establishDriftBaseline(for: anchorEntity, objectId: objectId)

        return anchorEntity
    }

    /// Creates multiple reference anchors around an object for averaging stability
    func createMultiAnchorStabilization(objectId: String, centerPosition: SIMD3<Float>, radius: Float = 0.5, anchorCount: Int = 4) {
        guard let arView = arView else { return }

        var anchors: [ARAnchor] = []

        // Create anchors in a circle around the object
        for i in 0..<anchorCount {
            let angle = Float(i) * 2 * .pi / Float(anchorCount)
            let offsetX = cos(angle) * radius
            let offsetZ = sin(angle) * radius

            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(
                centerPosition.x + offsetX,
                centerPosition.y,
                centerPosition.z + offsetZ,
                1.0
            )

            let anchor = ARAnchor(name: "stabilization_\(objectId)_\(i)", transform: transform)
            arView.session.add(anchor: anchor)
            anchors.append(anchor)
        }

        referenceAnchors[objectId] = anchors

        // Create stabilization network
        createStabilizationNetwork(for: objectId, centerPosition: centerPosition, radius: radius)

        print("🔄 Created \(anchorCount) stabilization anchors for object '\(objectId)'")
    }

    // MARK: - Stabilization Network

    /// Create a stabilization network for an object anchor
    func createStabilizationNetwork(for objectId: String, centerPosition: SIMD3<Float>, radius: Float = 3.0) {
        guard let arView = arView else { return }

        // Find nearby stable anchors to create reference network
        let referenceAnchors = findReferenceAnchors(center: centerPosition, radius: radius)

        // Create primary anchor entity (temporary for network)
        let primaryAnchor = AnchorEntity(world: centerPosition)

        // Calculate initial stability score
        let stabilityScore = calculateNetworkStability(primaryAnchor: primaryAnchor, references: referenceAnchors)

        let network = StabilizationNetwork(
            networkId: objectId,
            centerPosition: centerPosition,
            referenceAnchors: referenceAnchors,
            stabilityScore: stabilityScore,
            lastUpdated: Date(),
            networkRadius: radius
        )

        activeStabilizationNetworks[objectId] = network

        print("🕸️ Created stabilization network for '\(objectId)' with \(referenceAnchors.count) reference anchors (stability: \(String(format: "%.2f", stabilityScore)))")
    }

    /// Find stable reference anchors near a position
    private func findReferenceAnchors(center: SIMD3<Float>, radius: Float) -> [StabilizationNetwork.ReferenceAnchor] {
        guard let arView = arView else { return [] }

        let allAnchors = arView.session.currentFrame?.anchors ?? []

        let unsortedAnchors: [StabilizationNetwork.ReferenceAnchor] = allAnchors.compactMap { anchor in
            let anchorPosition = SIMD3<Float>(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
            let distance = simd_length(anchorPosition - center)

            // Only include anchors within radius
            guard distance <= radius && distance > 0.1 else { return nil }

            // Calculate weight based on distance and anchor type
            let distanceWeight = 1.0 - Double(distance / radius) // Closer = higher weight
            let typeWeight = anchorTypeStabilityWeight(anchor)
            let totalWeight = distanceWeight * typeWeight

            // Calculate stability contribution
            let stabilityContribution = calculateAnchorStabilityContribution(anchor)

            return StabilizationNetwork.ReferenceAnchor(
                anchor: anchor,
                weight: totalWeight,
                distance: distance,
                stabilityContribution: stabilityContribution
            )
        }

        // Sort by stability contribution (highest first)
        return unsortedAnchors.sorted { $0.stabilityContribution > $1.stabilityContribution }
    }

    // MARK: - Drift Monitoring & Correction

    /// Establish baseline for anchor drift monitoring
    func establishDriftBaseline(for anchorEntity: AnchorEntity, objectId: String) {
        guard let arView = arView else { return }

        let baseline = AnchorBaseline(
            initialPosition: anchorEntity.position,
            initialTransform: anchorEntity.transform.matrix,
            establishmentTime: Date(),
            referenceAnchors: findReferenceAnchors(center: anchorEntity.position, radius: 3.0),
            worldMapQuality: assessWorldMapQuality()
        )

        anchorBaselines[objectId] = baseline

        print("📏 Established drift baseline for \(objectId) at (\(String(format: "%.3f", baseline.initialPosition.x)), \(String(format: "%.3f", baseline.initialPosition.y)), \(String(format: "%.3f", baseline.initialPosition.z)))")
    }

    /// Monitor all established anchors for drift
    func monitorAnchorDrift() {
        guard let arView = arView else { return }

        for (objectId, baseline) in anchorBaselines {
            // Find the current anchor entity
            guard let currentAnchor = findAnchorEntity(for: objectId, in: arView) else {
                continue
            }

            let currentPosition = currentAnchor.position
            let driftVector = currentPosition - baseline.initialPosition
            let driftMagnitude = length(driftVector)

            // Check if drift exceeds threshold
            if driftMagnitude > driftThreshold {
                driftEventsDetected += 1
                print("⚠️ Drift detected for \(objectId): \(String(format: "%.3f", driftMagnitude))m (threshold: \(String(format: "%.3f", driftThreshold))m)")

                // Apply drift correction
                applyDriftCorrection(objectId: objectId, anchorEntity: currentAnchor, baseline: baseline)
            }
        }
    }

    /// Apply drift correction to an anchor
    private func applyDriftCorrection(objectId: String, anchorEntity: AnchorEntity, baseline: AnchorBaseline) {
        let currentPosition = anchorEntity.position
        let driftVector = baseline.initialPosition - currentPosition
        let correctionMagnitude = min(length(driftVector) * 0.1, 0.01) // Max 1cm correction per step

        if correctionMagnitude > 0.001 { // Only correct if drift is meaningful
            let correctionDirection = normalize(driftVector)
            let correction = correctionDirection * correctionMagnitude

            anchorEntity.position = currentPosition + correction

            // Record correction event
            let correctionEvent = CorrectionEvent(
                timestamp: Date(),
                driftMagnitude: length(driftVector),
                correctionApplied: correction,
                success: true
            )

            if correctionHistory[objectId] == nil {
                correctionHistory[objectId] = []
            }
            correctionHistory[objectId]?.append(correctionEvent)

            print("🔧 Applied drift correction to \(objectId): moved \(String(format: "%.3f", correctionMagnitude))m")
        }
    }

    // MARK: - Stability Calculations

    /// Calculate stability score for a network
    private func calculateNetworkStability(primaryAnchor: AnchorEntity, references: [StabilizationNetwork.ReferenceAnchor]) -> Double {
        guard !references.isEmpty else { return 0.0 }

        // Base stability from primary anchor
        var totalStability = 1.0

        // Add weighted contributions from reference anchors
        for reference in references {
            totalStability += reference.stabilityContribution * reference.weight
        }

        // Normalize and cap at 1.0
        return min(totalStability / Double(references.count + 1), 1.0)
    }

    /// Calculate anchor type stability weight
    private func anchorTypeStabilityWeight(_ anchor: ARAnchor) -> Double {
        switch anchor {
        case is ARPlaneAnchor:
            return 0.8 // Planes are stable
        case is ARGeoAnchor:
            return 1.0 // Geo anchors are most stable
        case is ARImageAnchor:
            return 0.9 // Image anchors are stable
        case is ARObjectAnchor:
            return 0.7 // Object anchors are moderately stable
        default:
            return 0.5 // Other anchors are less stable
        }
    }

    /// Calculate individual anchor stability contribution
    private func calculateAnchorStabilityContribution(_ anchor: ARAnchor) -> Double {
        // Base contribution on transform validity and anchor type
        var contribution = 0.5

        // Higher contribution for valid transforms
        if anchor.transform.columns.3.w.isFinite {
            contribution += 0.3
        }

        // Additional contribution based on anchor type
        contribution += anchorTypeStabilityWeight(anchor) * 0.2

        return min(contribution, 1.0)
    }

    /// Assess current world map quality for stability context
    private func assessWorldMapQuality() -> Double {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return 0.0 }

        var quality = 0.0

        // Factor 1: Anchor count
        let anchorCount = frame.anchors.count
        quality += min(Double(anchorCount) / 20.0, 0.4)

        // Factor 2: Feature points
        let featureCount = frame.rawFeaturePoints?.points.count ?? 0
        quality += min(Double(featureCount) / 500.0, 0.4)

        // Factor 3: Tracking state
        if case .normal = frame.camera.trackingState {
            quality += 0.2
        }

        return quality
    }

    // MARK: - Helper Methods

    /// Find anchor entity by object ID
    private func findAnchorEntity(for objectId: String, in arView: ARView) -> AnchorEntity? {
        return arView.scene.anchors.first { ($0 as? AnchorEntity)?.name == objectId } as? AnchorEntity
    }

    /// Setup stability monitoring timers
    private func setupStabilityMonitoring() {
        // Monitor drift every 2 seconds
        stabilityUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.monitorAnchorDrift()
            self?.updateOverallStabilityScore()
        }

        // Update networks every 5 seconds
        networkUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStabilizationNetworks()
        }
    }

    /// Start stability update timers
    private func startStabilityUpdates() {
        stabilityUpdateTimer?.fire()
        networkUpdateTimer?.fire()
    }

    /// Update stabilization networks
    private func updateStabilizationNetworks() {
        for (objectId, network) in activeStabilizationNetworks {
            // Recalculate stability score
            guard let primaryAnchor = findAnchorEntity(for: objectId, in: arView!) else { continue }

            let updatedReferences = findReferenceAnchors(center: network.centerPosition, radius: network.networkRadius)
            let updatedScore = calculateNetworkStability(primaryAnchor: primaryAnchor, references: updatedReferences)

            // Update network
            var updatedNetwork = network
            updatedNetwork.referenceAnchors = updatedReferences
            updatedNetwork.stabilityScore = updatedScore
            updatedNetwork.lastUpdated = Date()

            activeStabilizationNetworks[objectId] = updatedNetwork
        }
    }

    /// Update overall stability score
    private func updateOverallStabilityScore() {
        let networkScores = activeStabilizationNetworks.values.map { $0.stabilityScore }
        if networkScores.isEmpty {
            overallStabilityScore = 0.0
        } else {
            overallStabilityScore = networkScores.reduce(0, +) / Double(networkScores.count)
        }
    }

    /// Remove stabilization for an object
    func removeStabilization(objectId: String) {
        activeStabilizationNetworks.removeValue(forKey: objectId)
        referenceAnchors.removeValue(forKey: objectId)
        anchorBaselines.removeValue(forKey: objectId)
        correctionHistory.removeValue(forKey: objectId)

        // Remove geo anchor if it exists
        if let geoAnchor = geoAnchors[objectId] {
            arView?.session.remove(anchor: geoAnchor)
            geoAnchors.removeValue(forKey: objectId)
        }

        print("🗑️ Removed stabilization for object '\(objectId)'")
    }

    // MARK: - Diagnostics

    func getStabilityDiagnostics() -> [String: Any] {
        return [
            "activeNetworks": activeStabilizationNetworks.count,
            "driftEventsDetected": driftEventsDetected,
            "overallStabilityScore": overallStabilityScore,
            "geoAnchors": geoAnchors.count,
            "monitoredAnchors": anchorBaselines.count,
            "totalCorrections": correctionHistory.values.flatMap { $0 }.count
        ]
    }
}

// MARK: - Supporting Structures

struct StabilizationNetwork {
    let networkId: String
    let centerPosition: SIMD3<Float>
    var referenceAnchors: [ReferenceAnchor]
    var stabilityScore: Double
    var lastUpdated: Date
    let networkRadius: Float

    struct ReferenceAnchor {
        let anchor: ARAnchor
        let weight: Double // Importance in the network (0.0-1.0)
        let distance: Float // Distance from center
        let stabilityContribution: Double // How much this anchor contributes to stability
    }
}

struct AnchorBaseline {
    let initialPosition: SIMD3<Float>
    let initialTransform: simd_float4x4
    let establishmentTime: Date
    let referenceAnchors: [StabilizationNetwork.ReferenceAnchor]
    let worldMapQuality: Double
}

struct CorrectionEvent {
    let timestamp: Date
    let driftMagnitude: Float
    let correctionApplied: SIMD3<Float>
    let success: Bool
}
