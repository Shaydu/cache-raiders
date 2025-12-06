import Foundation
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Asset Anchoring Service
/// Provides stable AR anchoring for indoor environments by using ARAnchors
/// instead of direct world positioning to prevent drift
class ARAssetAnchoringService {

    // MARK: - Properties
    private weak var arView: ARView?
    private var activeAnchors: [String: ARAnchor] = [:]
    private(set) var anchorEntities: [String: AnchorEntity] = [:]

    // Plane-based anchoring
    private var planeAnchors: [String: ARPlaneAnchor] = [:] // Track detected planes

    // Configuration for indoor anchoring
    private let minVisualFeaturesForAnchor = 5
    private let anchorStabilityRadius: Float = 1.0 // 1 meter radius for stability checks

    // Drift correction configuration
    private let driftThreshold: Float = 0.5 // 50cm threshold for drift correction
    private let maxCorrectionDistance: Float = 2.0 // 2 meter max correction to prevent jumps

    // MARK: - Initialization
    init(arView: ARView) {
        self.arView = arView
    }

    // MARK: - Stable Anchor Creation

    /// Creates a stable AR anchor at the specified position with validation
    /// - Parameters:
    ///   - position: Desired world position for the anchor
    ///   - name: Unique identifier for the anchor
    ///   - validateFeatures: Whether to check for sufficient visual features
    /// - Returns: ARAnchor if created successfully, nil if conditions not met
    func createStableAnchor(at position: SIMD3<Float>,
                           name: String,
                           validateFeatures: Bool = true) -> ARAnchor? {

        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            print("⚠️ Cannot create anchor: No AR session or frame available")
            return nil
        }

        // Validate visual features if requested
        if validateFeatures && !hasSufficientVisualFeatures(at: position, in: frame) {
            print("⚠️ Insufficient visual features for stable anchor at \(name)")
            return nil
        }

        // Create ARAnchor at the position
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1.0)
        let anchor = ARAnchor(name: name, transform: transform)

        // Add to session
        arView.session.add(anchor: anchor)

        // Store reference
        activeAnchors[name] = anchor

        print("✅ Created stable AR anchor: \(name) at (\(String(format: "%.2f", position.x)), \(String(format: "%.2f", position.y)), \(String(format: "%.2f", position.z)))")

        return anchor
    }

    // MARK: - Plane-Based Anchoring

    /// Places an entity on a detected horizontal plane for maximum stability
    /// - Parameters:
    ///   - position: Desired world position (will be projected onto nearest plane)
    ///   - name: Unique identifier
    ///   - entity: The entity to place
    ///   - maxDistance: Maximum distance to search for a suitable plane
    /// - Returns: True if placement successful on a plane
    func placeEntityOnPlane(at position: SIMD3<Float>,
                           name: String,
                           entity: Entity,
                           maxDistance: Float = 3.0) -> Bool {

        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            return false
        }

        // Find the nearest horizontal plane to the desired position
        let suitablePlane = findNearestHorizontalPlane(to: position, maxDistance: maxDistance, in: frame)

        if let planeAnchor = suitablePlane {
            return placeEntityOnPlaneAnchor(planeAnchor, name: name, entity: entity)
        } else {
            // Fallback to regular ARAnchor placement if no suitable plane found
            print("⚠️ No suitable horizontal plane found within \(maxDistance)m of position, using regular anchor")
            return placeEntityAtStablePosition(position, name: name, entity: entity)
        }
    }

    /// Places an entity directly on a specific plane anchor
    private func placeEntityOnPlaneAnchor(_ planeAnchor: ARPlaneAnchor,
                                        name: String,
                                        entity: Entity) -> Bool {

        guard let arView = arView else { return false }

        // Create an anchor attached to the plane
        let planeAttachmentAnchor = ARAnchor(transform: planeAnchor.transform)
        arView.session.add(anchor: planeAttachmentAnchor)

        // Create AnchorEntity and attach it
        let anchorEntity = AnchorEntity(anchor: planeAttachmentAnchor)
        anchorEntity.addChild(entity)
        arView.scene.addAnchor(anchorEntity)

        // Store references
        activeAnchors[name] = planeAttachmentAnchor
        anchorEntities[name] = anchorEntity
        planeAnchors[name] = planeAnchor

        print("✅ Placed entity '\(name)' on horizontal plane at (\(String(format: "%.2f", planeAnchor.transform.columns.3.x)), \(String(format: "%.2f", planeAnchor.transform.columns.3.y)), \(String(format: "%.2f", planeAnchor.transform.columns.3.z)))")

        return true
    }

    /// Finds the nearest horizontal plane to a given position
    private func findNearestHorizontalPlane(to position: SIMD3<Float>,
                                          maxDistance: Float,
                                          in frame: ARFrame) -> ARPlaneAnchor? {

        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal }

        var nearestPlane: ARPlaneAnchor?
        var nearestDistance: Float = maxDistance

        for planeAnchor in planeAnchors {
            let planePosition = SIMD3<Float>(planeAnchor.transform.columns.3.x, planeAnchor.transform.columns.3.y, planeAnchor.transform.columns.3.z)
            let distance = simd_distance(position, planePosition)

            if distance < nearestDistance {
                nearestDistance = distance
                nearestPlane = planeAnchor
            }
        }

        if let plane = nearestPlane {
            print("📐 Found horizontal plane \(nearestDistance)m from target position (plane size: \(String(format: "%.2f", plane.planeExtent.width))x\(String(format: "%.2f", plane.planeExtent.height))m)")
        }

        return nearestPlane
    }

    /// Creates an AnchorEntity attached to a stable ARAnchor
    /// - Parameters:
    ///   - anchor: The ARAnchor to attach to
    ///   - name: Unique identifier for the entity
    /// - Returns: AnchorEntity if created successfully
    func createAnchorEntity(for anchor: ARAnchor, name: String) -> AnchorEntity? {
        guard let arView = arView else { return nil }

        let anchorEntity = AnchorEntity(anchor: anchor)
        arView.scene.addAnchor(anchorEntity)

        // Store reference
        anchorEntities[name] = anchorEntity

        print("📍 Created AnchorEntity for anchor: \(name)")
        return anchorEntity
    }

    /// Places an entity at a stable position using ARAnchor system
    /// - Parameters:
    ///   - position: Desired world position
    ///   - name: Unique identifier
    ///   - entity: The entity to place
    /// - Returns: True if placement successful
    func placeEntityAtStablePosition(_ position: SIMD3<Float>,
                                   name: String,
                                   entity: Entity) -> Bool {

        guard let arView = arView else {
            print("⚠️ No ARView available for placement")
            return false
        }

        // Try to create AR anchor first (preferred for drift prevention)
        // Disable strict feature validation - ARKit will still track the anchor, just maybe with slightly less stability
        if let anchor = createStableAnchor(at: position, name: name, validateFeatures: false),
           let anchorEntity = createAnchorEntity(for: anchor, name: name) {
            // Add the entity to the AR anchor
            anchorEntity.addChild(entity)
            print("✅ Placed entity '\(name)' at stable position using ARAnchor (drift-resistant)")
            return true
        }

        // CRITICAL FALLBACK: If AR anchor fails, use world anchor so object still appears
        print("⚠️ AR anchor creation failed for '\(name)', falling back to world anchor")
        let worldAnchor = AnchorEntity(world: position)
        worldAnchor.name = name
        worldAnchor.addChild(entity)
        arView.scene.addAnchor(worldAnchor)
        anchorEntities[name] = worldAnchor
        print("✅ Placed entity '\(name)' using fallback world anchor (may drift at distance)")
        return true
    }

    // MARK: - Visual Feature Validation

    /// Checks if there are sufficient visual features around a position for stable anchoring
    private func hasSufficientVisualFeatures(at position: SIMD3<Float>,
                                           in frame: ARFrame) -> Bool {

        guard let featurePoints = frame.rawFeaturePoints?.points else {
            print("⚠️ No feature points available for validation")
            return false
        }

        // Convert world position to camera coordinates for feature checking
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Count features within stability radius
        let nearbyFeatures = featurePoints.filter { featurePoint in
            let worldFeaturePoint = cameraTransform * SIMD4<Float>(featurePoint.x, featurePoint.y, featurePoint.z, 1.0)
            let distance = distance(SIMD3<Float>(worldFeaturePoint.x, worldFeaturePoint.y, worldFeaturePoint.z), position)
            return distance <= anchorStabilityRadius
        }

        let sufficient = nearbyFeatures.count >= minVisualFeaturesForAnchor
        print("🔍 Visual features near position: \(nearbyFeatures.count) (need \(minVisualFeaturesForAnchor)) - \(sufficient ? "sufficient" : "insufficient")")

        return sufficient
    }

    // MARK: - Anchor Management

    /// Removes an anchor and its associated entity
    func removeAnchor(name: String) {
        if let anchor = activeAnchors[name] {
            arView?.session.remove(anchor: anchor)
            activeAnchors.removeValue(forKey: name)
        }

        if let entity = anchorEntities[name] {
            entity.removeFromParent()
            anchorEntities.removeValue(forKey: name)
        }

        print("🗑️ Removed anchor: \(name)")
    }

    /// Gets the current position of an anchor
    func getAnchorPosition(name: String) -> SIMD3<Float>? {
        guard let anchor = activeAnchors[name] else { return nil }
        return SIMD3<Float>(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
    }

    /// Updates anchor position by recreating the anchor at the new position
    func updateAnchorPosition(name: String, newPosition: SIMD3<Float>) {
        guard let oldAnchor = activeAnchors[name] else { return }

        // Remove the old anchor
        arView?.session.remove(anchor: oldAnchor)

        // Create new anchor at updated position
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(newPosition.x, newPosition.y, newPosition.z, 1.0)
        let newAnchor = ARAnchor(name: name, transform: transform)

        // Add the new anchor
        arView?.session.add(anchor: newAnchor)

        // Update references
        activeAnchors[name] = newAnchor

        // Update associated entity if it exists
        if let anchorEntity = anchorEntities[name] {
            // Remove old entity and create new one
            anchorEntity.removeFromParent()
            let newAnchorEntity = AnchorEntity(anchor: newAnchor)
            arView?.scene.addAnchor(newAnchorEntity)
            anchorEntities[name] = newAnchorEntity
        }

        print("🔄 Updated anchor '\(name)' position to (\(String(format: "%.2f", newPosition.x)), \(String(format: "%.2f", newPosition.y)), \(String(format: "%.2f", newPosition.z)))")
    }

    // MARK: - Drift Detection and Correction

    /// Detects and corrects drift for all anchors using GPS validation
    /// - Parameters:
    ///   - expectedPositions: Dictionary mapping anchor names to expected GPS positions
    ///   - geospatialService: Service to convert GPS to AR coordinates
    func detectAndCorrectDrift(expectedPositions: [String: CLLocation],
                               geospatialService: ARGeospatialService?) {

        guard let geospatialService = geospatialService else { return }

        for (anchorName, expectedGPS) in expectedPositions {
            guard let anchor = activeAnchors[anchorName],
                  let expectedPosition = geospatialService.convertGPStoAR(expectedGPS) else {
                continue
            }

            let currentPosition = SIMD3<Float>(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
            let drift = distance(currentPosition, expectedPosition)

            if drift > driftThreshold {
                if drift <= maxCorrectionDistance {
                    print("🔧 Correcting drift for '\(anchorName)': \(String(format: "%.2f", drift))m")
                    updateAnchorPosition(name: anchorName, newPosition: expectedPosition)
                } else {
                    print("⚠️ Drift too large for '\(anchorName)': \(String(format: "%.2f", drift))m (max: \(maxCorrectionDistance)m)")
                }
            }
        }
    }

    /// Updates all anchors when GPS origin changes (e.g., better GPS accuracy)
    func updateAnchorsForGPSCorrection(correctionOffset: SIMD3<Float>) {
        for (name, _) in activeAnchors {
            if let currentPosition = getAnchorPosition(name: name) {
                let correctedPosition = currentPosition + correctionOffset
                updateAnchorPosition(name: name, newPosition: correctedPosition)
            }
        }
        print("🔧 Applied GPS correction offset to all anchors: (\(String(format: "%.2f", correctionOffset.x)), \(String(format: "%.2f", correctionOffset.y)), \(String(format: "%.2f", correctionOffset.z)))")
    }

    // MARK: - Cleanup

    func removeAllAnchors() {
        for name in activeAnchors.keys {
            removeAnchor(name: name)
        }
    }

    deinit {
        removeAllAnchors()
    }
}

extension simd_float4x4 {
    var position: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}
