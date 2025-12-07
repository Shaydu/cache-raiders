import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

/// Service for detecting and correcting AR anchor drift in real-time
class AnchorDriftCorrectionService: ObservableObject {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?

    @Published var anchorsMonitored: Int = 0
    @Published var driftEventsDetected: Int = 0
    @Published var correctionsApplied: Int = 0

    private var anchorBaselines: [String: AnchorBaseline] = [:]
    private var driftThreshold: Float = 0.05 // 5cm drift threshold
    private var correctionHistory: [String: [CorrectionEvent]] = [:]

    struct AnchorBaseline {
        let initialPosition: SIMD3<Float>
        let initialTransform: simd_float4x4
        let establishmentTime: Date
        let referenceAnchors: [ARAnchor] // Nearby stable anchors
        let worldMapQuality: Double
    }

    struct CorrectionEvent {
        let timestamp: Date
        let driftMagnitude: Float
        let correctionApplied: SIMD3<Float>
        let success: Bool
    }

    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        self.arView = arView
        self.locationManager = locationManager
        setupDriftMonitoring()
    }

    /// Establish baseline for anchor drift monitoring
    func establishBaseline(for anchorEntity: AnchorEntity, objectId: String) {
        guard let arView = arView else { return }

        let baseline = AnchorBaseline(
            initialPosition: anchorEntity.position,
            initialTransform: anchorEntity.transform.matrix,
            establishmentTime: Date(),
            referenceAnchors: findNearbyReferenceAnchors(center: anchorEntity.position),
            worldMapQuality: assessWorldMapQuality()
        )

        anchorBaselines[objectId] = baseline
        anchorsMonitored += 1

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

                // Attempt automatic correction
                let corrected = applyDriftCorrection(to: currentAnchor, baseline: baseline, objectId: objectId)
                if corrected {
                    correctionsApplied += 1
                }
            }
        }
    }

    /// Apply drift correction to an anchor
    private func applyDriftCorrection(to anchorEntity: AnchorEntity, baseline: AnchorBaseline, objectId: String) -> Bool {
        let currentPosition = anchorEntity.position
        let driftVector = baseline.initialPosition - currentPosition

        // Strategy 1: Gradual correction (smooth movement)
        let correctionStep = min(length(driftVector) * 0.1, 0.01) // Max 1cm correction per step
        let correctionDirection = normalize(driftVector)
        let correction = currentPosition + correctionDirection * correctionStep

        // Apply correction
        let oldPosition = anchorEntity.position
        anchorEntity.position = correction

        // Record correction event
        let event = CorrectionEvent(
            timestamp: Date(),
            driftMagnitude: length(driftVector),
            correctionApplied: correction - oldPosition,
            success: true
        )

        if correctionHistory[objectId] == nil {
            correctionHistory[objectId] = []
        }
        correctionHistory[objectId]?.append(event)

        print("🔧 Applied drift correction to \(objectId): moved \(String(format: "%.3f", length(correction - oldPosition)))m")
        return true
    }

    /// Find reference anchors near a position for stability comparison
    private func findNearbyReferenceAnchors(center: SIMD3<Float>, radius: Float = 2.0) -> [ARAnchor] {
        guard let arView = arView else { return [] }

        return arView.session.currentFrame?.anchors.filter { anchor in
            let anchorPos = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            let distance = length(anchorPos - center)
            // For general ARAnchor objects, assume they're tracked if present in the session
            return distance <= radius
        } ?? []
    }

    /// Assess current world map quality for drift context
    private func assessWorldMapQuality() -> Double {
        guard let arView = arView else { return 0.0 }

        // Assess quality based on current frame data
        guard let frame = arView.session.currentFrame else { return 0.0 }

        // Quality factors
        let anchorCount = Double(frame.anchors.count)
        let planeCount = Double(frame.anchors.compactMap { $0 as? ARPlaneAnchor }.count)
        let featurePoints = Double(frame.rawFeaturePoints?.points.count ?? 0)

        // Weighted quality score
        let anchorScore = min(anchorCount / 10.0, 1.0) * 0.4  // 40% weight
        let planeScore = min(planeCount / 5.0, 1.0) * 0.3    // 30% weight
        let featureScore = min(featurePoints / 500.0, 1.0) * 0.3 // 30% weight

        return anchorScore + planeScore + featureScore
    }

    /// Find anchor entity by object ID
    private func findAnchorEntity(for objectId: String, in arView: ARView) -> AnchorEntity? {
        return arView.scene.anchors.compactMap { $0 as? AnchorEntity }.first { anchor in
            // Check if this anchor contains an entity with matching name/ID
            return anchor.children.contains { $0.name == objectId }
        }
    }

    /// Adjust drift threshold based on environmental conditions
    func adjustDriftThreshold(for trackingQuality: ARCamera.TrackingState) {
        switch trackingQuality {
        case .normal:
            driftThreshold = 0.05 // 5cm for good tracking
        case .limited:
            driftThreshold = 0.15 // 15cm for limited tracking
        case .notAvailable:
            driftThreshold = 0.50 // 50cm for poor tracking
        @unknown default:
            driftThreshold = 0.05
        }

        print("🎯 Adjusted drift threshold to \(String(format: "%.3f", driftThreshold))m based on tracking quality")
    }

    /// Get drift statistics for an object
    func getDriftStatistics(for objectId: String) -> (totalDrift: Float, corrections: Int, avgCorrection: Float)? {
        guard let history = correctionHistory[objectId], !history.isEmpty else {
            return nil
        }

        let totalDrift = history.map { $0.driftMagnitude }.reduce(0, +)
        let corrections = history.count
        let avgCorrection = history.map { length($0.correctionApplied) }.reduce(0, +) / Float(corrections)

        return (totalDrift, corrections, avgCorrection)
    }

    /// Reset drift monitoring for an object
    func resetDriftMonitoring(for objectId: String) {
        anchorBaselines.removeValue(forKey: objectId)
        correctionHistory.removeValue(forKey: objectId)
        anchorsMonitored = max(0, anchorsMonitored - 1)
        print("🔄 Reset drift monitoring for \(objectId)")
    }

    /// Setup continuous drift monitoring
    private func setupDriftMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.monitorAnchorDrift()

            // Adjust threshold based on tracking quality
            if let arView = self?.arView,
               let trackingState = arView.session.currentFrame?.camera.trackingState {
                self?.adjustDriftThreshold(for: trackingState)
            }
        }
    }
}
