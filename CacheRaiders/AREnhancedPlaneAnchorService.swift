import Foundation
import RealityKit
import ARKit
import CoreLocation

// MARK: - Enhanced Plane Anchor Service
/// Advanced plane anchoring system that prevents drift by anchoring objects to multiple planes
/// and using geometric constraints for stability
class AREnhancedPlaneAnchorService: NSObject, ObservableObject {

    // MARK: - Properties

    @Published var activePlaneAnchors: [String: PlaneAnchorGroup] = [:]
    @Published var stabilityScore: Double = 0.0

    private weak var arView: ARView?
    private weak var arCoordinator: ARCoordinator?

    // Multi-plane anchoring
    private var planeConstraints: [String: [PlaneConstraint]] = [:]
    private var geometricStabilizers: [String: GeometricStabilizer] = [:]

    // Stability monitoring
    private var stabilityMonitorTimer: Timer?
    private var driftCorrectionThreshold: Float = 0.02 // 2cm threshold

    // MARK: - Initialization

    init(arView: ARView?, arCoordinator: ARCoordinator?) {
        super.init()
        self.arView = arView
        self.arCoordinator = arCoordinator
        setupStabilityMonitoring()
        print("🎯 AREnhancedPlaneAnchorService initialized")
    }

    deinit {
        stabilityMonitorTimer?.invalidate()
    }

    // MARK: - Multi-Plane Anchoring

    /// Creates an object anchored to multiple planes for enhanced stability
    /// - Parameters:
    ///   - objectId: Unique identifier for the object
    ///   - anchorEntity: The existing AnchorEntity to enhance with multi-plane stability
    /// - Returns: Success status of multi-plane anchoring
    func createMultiPlaneAnchor(objectId: String, anchorEntity: AnchorEntity) -> Bool {
        guard let arView = arView else {
            print("⚠️ No AR view available for multi-plane anchoring")
            return false
        }

        // Find planes within anchoring radius
        let anchorRadius: Float = 3.0 // Search within 3 meters
        let nearbyPlanes = findPlanesNearPosition(position, radius: anchorRadius)

        guard nearbyPlanes.count >= 2 else {
            print("⚠️ Insufficient planes for multi-plane anchoring (found: \(nearbyPlanes.count), needed: 2+)")
            // Fall back to single plane anchoring
            return createSinglePlaneAnchor(objectId: objectId, position: position, entity: entity)
        }

        // Create geometric constraints between planes
        let constraints = createGeometricConstraints(for: nearbyPlanes, centerPosition: position)

        // Create the anchor group
        let anchorGroup = PlaneAnchorGroup(
            objectId: objectId,
            centerPosition: position,
            planeAnchors: nearbyPlanes,
            constraints: constraints,
            stabilityScore: calculateAnchorGroupStability(planes: nearbyPlanes, constraints: constraints)
        )

        // Add geometric stabilizer to the existing anchor entity
        let stabilizer = GeometricStabilizer(
            anchorGroup: anchorGroup,
            anchorEntity: anchorEntity,
            constraints: constraints
        )

        // Store references
        activePlaneAnchors[objectId] = anchorGroup
        geometricStabilizers[objectId] = stabilizer
        planeConstraints[objectId] = constraints

        print("🎯 Created multi-plane anchor for '\(objectId)' using \(nearbyPlanes.count) planes (stability: \(String(format: "%.2f", anchorGroup.stabilityScore)))")

        return true
    }

    /// Creates a single plane anchor as fallback when multi-plane anchoring isn't possible
    private func createSinglePlaneAnchor(objectId: String, position: SIMD3<Float>, entity: Entity) -> Bool {
        guard let arView = arView else { return false }

        // Find the best single plane
        let bestPlane = findBestPlaneForPosition(position)

        // Create standard anchor entity
        let anchorEntity = AnchorEntity(world: position)
        anchorEntity.name = "single_plane_\(objectId)"
        anchorEntity.addChild(entity)

        arView.scene.addAnchor(anchorEntity)

        // Create minimal anchor group for tracking
        let anchorGroup = PlaneAnchorGroup(
            objectId: objectId,
            centerPosition: position,
            planeAnchors: bestPlane != nil ? [bestPlane!] : [],
            constraints: [],
            stabilityScore: bestPlane != nil ? 0.6 : 0.3
        )

        activePlaneAnchors[objectId] = anchorGroup

        print("📍 Created single-plane anchor for '\(objectId)' (fallback - stability: \(String(format: "%.2f", anchorGroup.stabilityScore)))")

        return true
    }

    // MARK: - Plane Detection and Analysis

    /// Finds all planes near a position within the specified radius
    private func findPlanesNearPosition(_ position: SIMD3<Float>, radius: Float) -> [ARPlaneAnchor] {
        guard let session = arView?.session else { return [] }

        let allAnchors = session.currentFrame?.anchors ?? []
        let planeAnchors = allAnchors.compactMap { $0 as? ARPlaneAnchor }

        return planeAnchors.filter { plane in
            let planeCenter = SIMD3<Float>(plane.transform.columns.3.x, plane.transform.columns.3.y, plane.transform.columns.3.z)
            let distance = simd_length(planeCenter - position)
            return distance <= radius
        }
    }

    /// Finds the best single plane for anchoring at a position
    private func findBestPlaneForPosition(_ position: SIMD3<Float>) -> ARPlaneAnchor? {
        let nearbyPlanes = findPlanesNearPosition(position, radius: 2.0)

        // Score planes based on size, distance, and orientation
        let scoredPlanes = nearbyPlanes.map { plane -> (plane: ARPlaneAnchor, score: Float) in
            let planeCenter = SIMD3<Float>(plane.transform.columns.3.x, plane.transform.columns.3.y, plane.transform.columns.3.z)
            let distance = simd_length(planeCenter - position)
            let distanceScore = max(0, 1.0 - distance / 2.0) // Closer is better

            let area = plane.planeExtent.width * plane.planeExtent.height
            let areaScore = min(area / 4.0, 1.0) // Larger area is better

            let orientationScore = abs(plane.transform.columns.1.y) // Prefer horizontal planes

            let totalScore = (distanceScore * 0.4) + (areaScore * 0.4) + (orientationScore * 0.2)
            return (plane, totalScore)
        }

        return scoredPlanes.sorted { $0.score > $1.score }.first?.plane
    }

    // MARK: - Geometric Constraints

    /// Creates geometric constraints between planes for stability
    private func createGeometricConstraints(for planes: [ARPlaneAnchor], centerPosition: SIMD3<Float>) -> [PlaneConstraint] {
        var constraints: [PlaneConstraint] = []

        // Create distance constraints between planes
        for i in 0..<planes.count {
            for j in (i+1)..<planes.count {
                let plane1 = planes[i]
                let plane2 = planes[j]

                let pos1 = SIMD3<Float>(plane1.transform.columns.3.x, plane1.transform.columns.3.y, plane1.transform.columns.3.z)
                let pos2 = SIMD3<Float>(plane2.transform.columns.3.x, plane2.transform.columns.3.y, plane2.transform.columns.3.z)

                let distance = simd_length(pos2 - pos1)
                let constraint = PlaneConstraint.distance(
                    between: plane1,
                    and: plane2,
                    targetDistance: distance,
                    tolerance: 0.05 // 5cm tolerance
                )

                constraints.append(constraint)
            }
        }

        // Create center-to-plane distance constraints
        for plane in planes {
            let planePos = SIMD3<Float>(plane.transform.columns.3.x, plane.transform.columns.3.y, plane.transform.columns.3.z)
            let distance = simd_length(planePos - centerPosition)

            let constraint = PlaneConstraint.centerDistance(
                plane: plane,
                centerPosition: centerPosition,
                targetDistance: distance,
                tolerance: 0.03 // 3cm tolerance
            )

            constraints.append(constraint)
        }

        return constraints
    }

    // MARK: - Stability Monitoring

    /// Sets up continuous stability monitoring
    private func setupStabilityMonitoring() {
        stabilityMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.monitorAnchorStability()
            self?.updateOverallStabilityScore()
        }
    }

    /// Monitors stability of all active anchors
    private func monitorAnchorStability() {
        for (objectId, stabilizer) in geometricStabilizers {
            let drift = stabilizer.calculateDrift()

            if drift > driftCorrectionThreshold {
                print("⚠️ Drift detected for \(objectId): \(String(format: "%.3f", drift))m")
                stabilizer.applyCorrection()
            }
        }
    }

    /// Updates the overall stability score
    private func updateOverallStabilityScore() {
        let anchorScores = activePlaneAnchors.values.map { $0.stabilityScore }
        if anchorScores.isEmpty {
            stabilityScore = 0.0
        } else {
            stabilityScore = anchorScores.reduce(0, +) / Double(anchorScores.count)
        }
    }

    // MARK: - Stability Calculations

    /// Calculates stability score for an anchor group
    private func calculateAnchorGroupStability(planes: [ARPlaneAnchor], constraints: [PlaneConstraint]) -> Double {
        // Base stability from number of planes
        let planeCountScore = min(Double(planes.count) / 4.0, 1.0) * 0.4

        // Stability from plane quality (size, confidence)
        let planeQualityScore = planes.map { plane in
            let area = Double(plane.planeExtent.width * plane.planeExtent.height)
            let confidence = Double(plane.classification.rawValue) / 3.0 // Assuming 3 confidence levels
            return min((area / 4.0) * confidence, 1.0)
        }.reduce(0, +) / Double(planes.count) * 0.4

        // Constraint satisfaction score
        let constraintScore = Double(constraints.count) / Double(max(planes.count * 2, 1)) * 0.2

        return planeCountScore + planeQualityScore + constraintScore
    }

    // MARK: - Cleanup

    /// Removes plane anchoring for an object
    func removePlaneAnchoring(objectId: String) {
        activePlaneAnchors.removeValue(forKey: objectId)
        geometricStabilizers.removeValue(forKey: objectId)
        planeConstraints.removeValue(forKey: objectId)

        // Remove anchor entity from scene
        if let arView = arView {
            let anchorName = "multi_plane_\(objectId)"
            if let anchorEntity = arView.scene.anchors.first(where: { $0.name == anchorName }) {
                arView.scene.removeAnchor(anchorEntity)
            }
        }

        print("🗑️ Removed plane anchoring for object '\(objectId)'")
    }

    /// Gets diagnostics information
    func getPlaneAnchorDiagnostics() -> [String: Any] {
        return [
            "activeAnchors": activePlaneAnchors.count,
            "stabilityScore": stabilityScore,
            "geometricStabilizers": geometricStabilizers.count,
            "totalConstraints": planeConstraints.values.flatMap { $0 }.count
        ]
    }
}

// MARK: - Supporting Structures

struct PlaneAnchorGroup {
    let objectId: String
    let centerPosition: SIMD3<Float>
    let planeAnchors: [ARPlaneAnchor]
    let constraints: [PlaneConstraint]
    var stabilityScore: Double
}

enum PlaneConstraint {
    case distance(between: ARPlaneAnchor, and: ARPlaneAnchor, targetDistance: Float, tolerance: Float)
    case centerDistance(plane: ARPlaneAnchor, centerPosition: SIMD3<Float>, targetDistance: Float, tolerance: Float)

    func checkViolation() -> Float {
        switch self {
        case .distance(let plane1, let plane2, let targetDistance, let tolerance):
            let pos1 = SIMD3<Float>(plane1.transform.columns.3.x, plane1.transform.columns.3.y, plane1.transform.columns.3.z)
            let pos2 = SIMD3<Float>(plane2.transform.columns.3.x, plane2.transform.columns.3.y, plane2.transform.columns.3.z)
            let currentDistance = simd_length(pos2 - pos1)
            let deviation = abs(currentDistance - targetDistance)
            return deviation > tolerance ? deviation : 0

        case .centerDistance(let plane, let centerPosition, let targetDistance, let tolerance):
            let planePos = SIMD3<Float>(plane.transform.columns.3.x, plane.transform.columns.3.y, plane.transform.columns.3.z)
            let currentDistance = simd_length(planePos - centerPosition)
            let deviation = abs(currentDistance - targetDistance)
            return deviation > tolerance ? deviation : 0
        }
    }
}

class GeometricStabilizer {
    let anchorGroup: PlaneAnchorGroup
    let anchorEntity: AnchorEntity
    let constraints: [PlaneConstraint]

    init(anchorGroup: PlaneAnchorGroup, anchorEntity: AnchorEntity, constraints: [PlaneConstraint]) {
        self.anchorGroup = anchorGroup
        self.anchorEntity = anchorEntity
        self.constraints = constraints
    }

    func calculateDrift() -> Float {
        let violations = constraints.map { $0.checkViolation() }
        return violations.max() ?? 0
    }

    func applyCorrection() {
        // Calculate correction based on constraint violations
        var totalCorrection = SIMD3<Float>(0, 0, 0)
        var correctionCount = 0

        for constraint in constraints {
            let violation = constraint.checkViolation()
            if violation > 0 {
                switch constraint {
                case .distance(let plane1, let plane2, let targetDistance, _):
                    let pos1 = SIMD3<Float>(plane1.transform.columns.3.x, plane1.transform.columns.3.y, plane1.transform.columns.3.z)
                    let pos2 = SIMD3<Float>(plane2.transform.columns.3.x, plane2.transform.columns.3.y, plane2.transform.columns.3.z)

                    let direction = normalize(pos2 - pos1)
                    let currentDistance = simd_length(pos2 - pos1)
                    let correction = direction * (targetDistance - currentDistance) * 0.1 // 10% correction

                    totalCorrection += correction
                    correctionCount += 1

                case .centerDistance(let plane, let centerPosition, let targetDistance, _):
                    let planePos = SIMD3<Float>(plane.transform.columns.3.x, plane.transform.columns.3.y, plane.transform.columns.3.z)
                    let direction = normalize(planePos - centerPosition)
                    let currentDistance = simd_length(planePos - centerPosition)
                    let correction = direction * (targetDistance - currentDistance) * 0.05 // 5% correction

                    totalCorrection += correction
                    correctionCount += 1
                }
            }
        }

        if correctionCount > 0 {
            let averageCorrection = totalCorrection / Float(correctionCount)
            let maxCorrection: Float = 0.01 // Max 1cm correction per step

            if length(averageCorrection) > maxCorrection {
                let correctionDirection = normalize(averageCorrection)
                anchorEntity.position += correctionDirection * maxCorrection
            } else {
                anchorEntity.position += averageCorrection
            }
        }
    }
}