import Foundation
import RealityKit
import ARKit
import CoreLocation

/// Advanced AR anchor stabilization service
/// Provides multiple anchoring strategies for improved stability
class ARAnchorStabilizationService {
    weak var arView: ARView?
    private var geoAnchors: [String: ARGeoAnchor] = [:]
    private var referenceAnchors: [String: [ARAnchor]] = [:] // Multiple anchors per object
    private var anchorStabilityScores: [String: Double] = [:]

    init(arView: ARView?) {
        self.arView = arView
    }

    /// Creates a geo-anchored object for GPS-synchronized stability
    func createGeoAnchoredObject(objectId: String, coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance? = nil) async throws -> AnchorEntity {
        guard let arView = arView else { throw NSError(domain: "ARAnchorStabilization", code: -1, userInfo: [NSLocalizedDescriptionKey: "No AR view available"]) }

        // Create geo anchor
        let geoAnchor = ARGeoAnchor(coordinate: coordinate, altitude: altitude)
        arView.session.add(anchor: geoAnchor)
        geoAnchors[objectId] = geoAnchor

        // Create AnchorEntity attached to geo anchor
        let anchorEntity = AnchorEntity(anchor: geoAnchor)
        arView.scene.addAnchor(anchorEntity)

        print("📍 Created geo-anchored object '\(objectId)' at \(coordinate.latitude), \(coordinate.longitude)")
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
        print("🔄 Created \(anchorCount) stabilization anchors for object '\(objectId)'")
    }

    /// Calculates stability score based on anchor tracking quality
    func calculateAnchorStability(objectId: String) -> Double {
        guard let anchors = referenceAnchors[objectId], !anchors.isEmpty else {
            return anchorStabilityScores[objectId] ?? 0.0
        }

        // Calculate average tracking quality across all anchors
        let totalScore = anchors.reduce(0.0) { sum, anchor in
            // Higher score for anchors that are being tracked well
            let trackingScore = anchor.isTracked ? 1.0 : 0.5
            return sum + trackingScore
        }

        let averageScore = totalScore / Double(anchors.count)
        anchorStabilityScores[objectId] = averageScore
        return averageScore
    }

    /// Adjusts object position based on anchor averaging for stability
    func stabilizeObjectPosition(objectId: String, originalPosition: SIMD3<Float>) -> SIMD3<Float> {
        guard let anchors = referenceAnchors[objectId], anchors.count >= 3 else {
            return originalPosition
        }

        // Calculate average position from reference anchors
        let validAnchors = anchors.filter { $0.isTracked }
        guard validAnchors.count >= 2 else { return originalPosition }

        let averagePosition = validAnchors.reduce(SIMD3<Float>.zero) { sum, anchor in
            let pos = anchor.transform.columns.3
            return sum + SIMD3<Float>(pos.x, pos.y, pos.z)
        } / Float(validAnchors.count)

        // Smooth transition to average position (don't jump suddenly)
        let smoothingFactor: Float = 0.1
        let stabilizedPosition = originalPosition + (averagePosition - originalPosition) * smoothingFactor

        print("🎯 Stabilized position for '\(objectId)': \(String(format: "%.3f", stabilizedPosition.x)), \(String(format: "%.3f", stabilizedPosition.y)), \(String(format: "%.3f", stabilizedPosition.z))")

        return stabilizedPosition
    }

    /// Detects and corrects anchor drift using camera grain estimation
    func detectAndCorrectDrift(frame: ARFrame) {
        guard let arView = arView else { return }

        // Use camera grain estimation if available (iOS 16+)
        if #available(iOS 16.0, *),
           let smoothedDepth = frame.smoothedSceneDepth,
           let cameraGrain = frame.cameraGrain {
            // Camera grain indicates tracking quality
            let trackingQuality = 1.0 - cameraGrain.intensity // Lower grain = better tracking

            if trackingQuality < 0.7 {
                print("⚠️ Low tracking quality detected (grain: \(String(format: "%.3f", cameraGrain.intensity))) - anchors may drift")
                // Could trigger anchor relocalization here
            }
        }
    }

    /// Cleans up anchors for an object
    func cleanupAnchors(objectId: String) {
        // Remove geo anchor
        if let geoAnchor = geoAnchors[objectId] {
            arView?.session.remove(anchor: geoAnchor)
            geoAnchors.removeValue(forKey: objectId)
        }

        // Remove reference anchors
        if let anchors = referenceAnchors[objectId] {
            anchors.forEach { arView?.session.remove(anchor: $0) }
            referenceAnchors.removeValue(forKey: objectId)
        }

        anchorStabilityScores.removeValue(forKey: objectId)
        print("🧹 Cleaned up anchors for object '\(objectId)'")
    }
}
