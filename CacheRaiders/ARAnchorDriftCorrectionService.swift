import Foundation
import RealityKit
import ARKit
import CoreLocation

/// Service for detecting and correcting AR anchor drift over time
/// Uses multiple strategies to maintain object stability
class ARAnchorDriftCorrectionService {
    weak var arView: ARView?
    private var anchorBaselines: [String: AnchorBaseline] = [:]
    private var driftThresholds: [String: Float] = [:]
    private var lastCorrectionTime: [String: Date] = [:]

    private struct AnchorBaseline {
        let initialPosition: SIMD3<Float>
        let initialTransform: simd_float4x4
        let baselineTimestamp: Date
        let referenceAnchors: [ARAnchor] // Nearby stable anchors for reference
    }

    init(arView: ARView?) {
        self.arView = arView
    }

    /// Establishes a baseline for an anchor to detect future drift
    func establishBaseline(objectId: String, anchorEntity: AnchorEntity, position: SIMD3<Float>) {
        // Find nearby stable anchors as reference points
        let nearbyAnchors = findNearbyStableAnchors(center: position, radius: 2.0)

        let baseline = AnchorBaseline(
            initialPosition: position,
            initialTransform: anchorEntity.transform,
            baselineTimestamp: Date(),
            referenceAnchors: nearbyAnchors
        )

        anchorBaselines[objectId] = baseline
        driftThresholds[objectId] = 0.05 // 5cm drift threshold
        lastCorrectionTime[objectId] = Date()

        print("📏 Established drift baseline for object '\(objectId)' at (\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z))) with \(nearbyAnchors.count) reference anchors")
    }

    /// Detects drift in an anchor's position
    func detectDrift(objectId: String, currentPosition: SIMD3<Float>) -> (hasDrift: Bool, driftMagnitude: Float) {
        guard let baseline = anchorBaselines[objectId] else {
            return (false, 0.0)
        }

        let driftVector = currentPosition - baseline.initialPosition
        let driftMagnitude = length(driftVector)
        let threshold = driftThresholds[objectId] ?? 0.05

        let hasDrift = driftMagnitude > threshold

        if hasDrift {
            print("⚠️ Drift detected for object '\(objectId)': \(String(format: "%.3f", driftMagnitude))m (threshold: \(String(format: "%.3f", threshold))m)")
        }

        return (hasDrift, driftMagnitude)
    }

    /// Applies drift correction to an anchor
    func applyDriftCorrection(objectId: String, anchorEntity: AnchorEntity) -> Bool {
        guard let baseline = anchorBaselines[objectId],
              let arView = arView else {
            return false
        }

        // Check if we've corrected recently (prevent over-correction)
        let now = Date()
        if let lastCorrection = lastCorrectionTime[objectId],
           now.timeIntervalSince(lastCorrection) < 1.0 { // Minimum 1 second between corrections
            return false
        }

        // Strategy 1: Use reference anchors to calculate correction
        if !baseline.referenceAnchors.isEmpty {
            let correction = calculateReferenceBasedCorrection(baseline: baseline, currentEntity: anchorEntity)
            if correction.hasCorrection {
                applyCorrection(objectId: objectId, anchorEntity: anchorEntity, correction: correction.position)
                lastCorrectionTime[objectId] = now
                return true
            }
        }

        // Strategy 2: Use GPS-based correction if geo anchors available
        if let geoCorrection = calculateGeoBasedCorrection(objectId: objectId, baseline: baseline) {
            applyCorrection(objectId: objectId, anchorEntity: anchorEntity, correction: geoCorrection)
            lastCorrectionTime[objectId] = now
            return true
        }

        // Strategy 3: Gradual drift correction toward baseline
        let currentPosition = anchorEntity.position
        let driftVector = baseline.initialPosition - currentPosition
        let correctionMagnitude = min(length(driftVector) * 0.1, 0.01) // Max 1cm correction per step

        if correctionMagnitude > 0.001 { // Only correct if drift is meaningful
            let correctionDirection = normalize(driftVector)
            let correction = currentPosition + correctionDirection * correctionMagnitude

            applyCorrection(objectId: objectId, anchorEntity: anchorEntity, correction: correction)
            lastCorrectionTime[objectId] = now
            return true
        }

        return false
    }

    /// Finds nearby stable anchors that can serve as reference points
    private func findNearbyStableAnchors(center: SIMD3<Float>, radius: Float) -> [ARAnchor] {
        guard let arView = arView else { return [] }

        return arView.session.currentFrame?.anchors.compactMap { anchor in
            let anchorPos = SIMD3<Float>(anchor.transform.columns.3.x,
                                       anchor.transform.columns.3.y,
                                       anchor.transform.columns.3.z)
            let distance = length(anchorPos - center)

            // Only use anchors within radius and that are being tracked well
            return (distance <= radius && anchor.isTracked) ? anchor : nil
        } ?? []
    }

    /// Calculates correction based on reference anchors
    private func calculateReferenceBasedCorrection(baseline: AnchorBaseline, currentEntity: AnchorEntity) -> (hasCorrection: Bool, position: SIMD3<Float>) {
        let currentPosition = currentEntity.position
        var totalOffset = SIMD3<Float>.zero
        var validReferenceCount = 0

        // Calculate how much reference anchors have moved relative to baseline
        for referenceAnchor in baseline.referenceAnchors where referenceAnchor.isTracked {
            // This would require storing baseline positions for reference anchors
            // For now, use a simpler approach based on anchor stability
            validReferenceCount += 1
        }

        if validReferenceCount < 2 {
            return (false, currentPosition)
        }

        // Apply small correction based on reference anchor stability
        let correction = currentPosition + totalOffset / Float(validReferenceCount)
        return (true, correction)
    }

    /// Calculates GPS-based correction using geo anchors
    private func calculateGeoBasedCorrection(objectId: String, baseline: AnchorBaseline) -> SIMD3<Float>? {
        // This would integrate with ARGeoAnchorService to get GPS-based corrections
        // For now, return nil to use other correction methods
        return nil
    }

    /// Applies a position correction to an anchor
    private func applyCorrection(objectId: String, anchorEntity: AnchorEntity, correction: SIMD3<Float>) {
        let oldPosition = anchorEntity.position
        anchorEntity.position = correction

        let correctionMagnitude = length(correction - oldPosition)
        print("🔧 Applied drift correction to object '\(objectId)': moved \(String(format: "%.3f", correctionMagnitude))m")

        // Update baseline with corrected position
        if var updatedBaseline = anchorBaselines[objectId] {
            updatedBaseline.initialPosition = correction
            anchorBaselines[objectId] = updatedBaseline
        }
    }

    /// Updates drift thresholds based on environmental conditions
    func updateDriftThresholds(frame: ARFrame) {
        // Adjust thresholds based on tracking quality
        let trackingQuality = frame.camera.trackingState == .normal ? 1.0 : 0.5
        let baseThreshold: Float = 0.05 // 5cm base threshold

        // Lower threshold in good conditions, higher in poor conditions
        let adjustedThreshold = baseThreshold * Float(2.0 - trackingQuality)

        // Apply to all active anchors
        for objectId in anchorBaselines.keys {
            driftThresholds[objectId] = adjustedThreshold
        }

        if trackingQuality < 0.8 {
            print("🎯 Adjusted drift thresholds to \(String(format: "%.3f", adjustedThreshold))m due to tracking quality: \(trackingQuality)")
        }
    }

    /// Cleans up drift correction data for an object
    func cleanupDriftCorrection(objectId: String) {
        anchorBaselines.removeValue(forKey: objectId)
        driftThresholds.removeValue(forKey: objectId)
        lastCorrectionTime.removeValue(forKey: objectId)
        print("🧹 Cleaned up drift correction data for object '\(objectId)'")
    }
}
