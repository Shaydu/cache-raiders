import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

/// Advanced anchor stability service using interconnected anchor networks for superior drift reduction
/// Creates stability clusters where anchors mutually reinforce each other's positioning accuracy
class ARAnchorStabilityNetworkService: ObservableObject {
    weak var arView: ARView?
    // Note: driftCorrectionService dependency removed - service handles corrections internally

    @Published var activeNetworks: [String: AnchorStabilityNetwork] = [:]
    @Published var networkStabilityScore: Double = 0.0

    private var networkUpdateTimer: Timer?

    struct AnchorStabilityNetwork {
        var networkId: String
        var primaryAnchor: AnchorEntity
        var referenceAnchors: [ReferenceAnchor]
        var stabilityScore: Double
        var lastUpdated: Date
        var networkRadius: Float

        struct ReferenceAnchor {
            let anchor: ARAnchor
            let weight: Double // Importance in the stability network (0.0-1.0)
            let distance: Float // Distance from primary anchor
            let stabilityContribution: Double // How much this anchor contributes to stability
        }
    }

    init(arView: ARView?) {
        self.arView = arView
        startNetworkMaintenance()
        print("🕸️ ARAnchorStabilityNetworkService initialized")
    }

    deinit {
        networkUpdateTimer?.invalidate()
    }

    /// Create a stability network for an object anchor
    func createStabilityNetwork(for objectId: String, primaryAnchor: AnchorEntity, networkRadius: Float = 3.0) {
        guard let arView = arView else { return }

        // Find nearby stable anchors to create reference network
        let primaryPosition = primaryAnchor.transform.translation
        let referenceAnchors = findReferenceAnchors(center: primaryPosition, radius: networkRadius)

        // Calculate initial stability score
        let stabilityScore = calculateNetworkStability(primaryAnchor: primaryAnchor, references: referenceAnchors)

        let network = AnchorStabilityNetwork(
            networkId: objectId,
            primaryAnchor: primaryAnchor,
            referenceAnchors: referenceAnchors,
            stabilityScore: stabilityScore,
            lastUpdated: Date(),
            networkRadius: networkRadius
        )

        activeNetworks[objectId] = network

        print("🕸️ Created stability network for '\(objectId)' with \(referenceAnchors.count) reference anchors (stability: \(String(format: "%.2f", stabilityScore)))")
    }

    /// Find stable reference anchors near a position
    private func findReferenceAnchors(center: SIMD3<Float>, radius: Float) -> [AnchorStabilityNetwork.ReferenceAnchor] {
        guard let arView = arView else { return [] }

        let allAnchors = arView.session.currentFrame?.anchors ?? []

        let unsortedAnchors: [AnchorStabilityNetwork.ReferenceAnchor] = allAnchors.compactMap { anchor in
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

            return AnchorStabilityNetwork.ReferenceAnchor(
                anchor: anchor,
                weight: totalWeight,
                distance: distance,
                stabilityContribution: stabilityContribution
            )
        }

        let sortedAnchors = unsortedAnchors.sorted { $0.weight > $1.weight } // Sort by weight (most important first)
        return Array(sortedAnchors.prefix(5)) // Limit to top 5 reference anchors
    }

    /// Calculate stability weight based on anchor type
    private func anchorTypeStabilityWeight(_ anchor: ARAnchor) -> Double {
        switch anchor {
        case is ARPlaneAnchor:
            return 0.9 // Plane anchors are very stable
        case is ARMeshAnchor:
            return 0.95 // LiDAR mesh anchors are extremely stable
        case is ARGeoAnchor:
            return 0.85 // GPS-based anchors are stable but can have GPS inaccuracy
        case is ARImageAnchor:
            return 0.8 // Image anchors are stable if image is clearly visible
        default:
            return 0.6 // Regular ARAnchor - moderate stability
        }
    }

    /// Calculate how much an anchor contributes to network stability
    private func calculateAnchorStabilityContribution(_ anchor: ARAnchor) -> Double {
        // Factors: tracking state, age, transform consistency
        var contribution = 0.5 // Base contribution

        // Age factor - older anchors are more stable
        if let session = arView?.session,
           let anchorTimestamp = getAnchorCreationTime(anchor) {
            let age = Date().timeIntervalSince(anchorTimestamp)
            contribution += min(age / 30.0, 0.3) // Max bonus after 30 seconds
        }

        // Transform stability factor
        contribution += assessTransformStability(anchor) * 0.2

        return min(contribution, 1.0)
    }

    private func calculateAnchorStabilityContribution(_ anchor: AnchorEntity) -> Double {
        // Simplified stability assessment for AnchorEntity
        // AnchorEntity doesn't have session tracking history, so we use simpler heuristics
        var contribution = 0.4 // Base contribution (slightly lower than ARAnchor)

        // Age factor based on entity existence (rough approximation)
        // Since we don't have creation time, assume moderate stability
        contribution += 0.2 // Moderate age bonus

        // Transform stability - AnchorEntity is generally stable once placed
        contribution += 0.2 // Assume reasonable transform stability

        return min(contribution, 1.0)
    }

    /// Assess transform stability of an anchor
    private func assessTransformStability(_ anchor: ARAnchor) -> Double {
        // Simplified stability assessment
        // In a full implementation, this would track transform history and variance

        // For now, use anchor type as a proxy for stability
        switch anchor {
        case is ARMeshAnchor:
            return 0.9 // LiDAR mesh anchors are very stable
        case is ARPlaneAnchor:
            return 0.8 // Plane anchors are stable
        default:
            return 0.6 // Other anchors are moderately stable
        }
    }

    /// Get anchor creation timestamp (simplified)
    private func getAnchorCreationTime(_ anchor: ARAnchor) -> Date? {
        // In a real implementation, you'd store timestamps when anchors are created
        // For now, return a recent timestamp based on anchor hash stability
        return Date().addingTimeInterval(-Double(anchor.hash) / Double(Int.max) * 60.0)
    }

    /// Calculate overall network stability score
    private func calculateNetworkStability(primaryAnchor: AnchorEntity, references: [AnchorStabilityNetwork.ReferenceAnchor]) -> Double {
        guard !references.isEmpty else { return 0.3 } // Low stability without references

        var totalWeightedStability = 0.0
        var totalWeight = 0.0

        // Primary anchor contributes 40% to total stability
        let primaryStability = calculateAnchorStabilityContribution(primaryAnchor)
        totalWeightedStability += primaryStability * 0.4
        totalWeight += 0.4

        // Reference anchors contribute remaining 60%
        for reference in references {
            totalWeightedStability += reference.stabilityContribution * reference.weight * 0.6
            totalWeight += reference.weight * 0.6
        }

        return totalWeight > 0 ? totalWeightedStability / totalWeight : 0.0
    }

    /// Detect drift using stability network
    func detectNetworkDrift(objectId: String) -> (hasDrift: Bool, driftMagnitude: Float, confidence: Double) {
        guard let network = activeNetworks[objectId] else {
            return (false, 0.0, 0.0)
        }

        let primaryPosition = network.primaryAnchor.transform.translation
        var totalDrift = SIMD3<Float>.zero
        var totalWeight = 0.0

        // Calculate drift relative to each reference anchor
        for reference in network.referenceAnchors {
            let referencePosition = SIMD3<Float>(reference.anchor.transform.columns.3.x, reference.anchor.transform.columns.3.y, reference.anchor.transform.columns.3.z)
            let expectedDistance = reference.distance
            let actualDistance = simd_length(referencePosition - primaryPosition)

            if abs(actualDistance - expectedDistance) > 0.05 { // 5cm threshold
                let driftDirection = simd_normalize(primaryPosition - referencePosition)
                let driftMagnitude = abs(actualDistance - expectedDistance)
                totalDrift += driftDirection * driftMagnitude * Float(reference.weight)
                totalWeight += reference.weight
            }
        }

        if totalWeight > 0 {
            let avgDrift = totalDrift / Float(totalWeight)
            let driftMagnitude = simd_length(avgDrift)

            // Confidence based on network stability and number of references
            let confidence = min(network.stabilityScore * Double(network.referenceAnchors.count) / 3.0, 1.0)

            return (driftMagnitude > 0.05, driftMagnitude, confidence)
        }

        return (false, 0.0, network.stabilityScore)
    }

    /// Apply network-based drift correction
    func applyNetworkDriftCorrection(objectId: String) -> Bool {
        guard let network = activeNetworks[objectId],
              let arView = arView else {
            return false
        }

        let driftResult = detectNetworkDrift(objectId: objectId)

        guard driftResult.hasDrift && driftResult.confidence > 0.6 else {
            return false // Not enough confidence for correction
        }

        // Calculate correction vector
        let primaryPosition = network.primaryAnchor.transform.translation
        var correctionVector = SIMD3<Float>.zero
        var totalWeight = 0.0

        for reference in network.referenceAnchors {
            let referencePosition = SIMD3<Float>(reference.anchor.transform.columns.3.x, reference.anchor.transform.columns.3.y, reference.anchor.transform.columns.3.z)
            let expectedDistance = reference.distance
            let actualDistance = simd_length(referencePosition - primaryPosition)

            if abs(actualDistance - expectedDistance) > 0.01 {
                let directionToReference = simd_normalize(referencePosition - primaryPosition)
                let distanceCorrection = expectedDistance - actualDistance
                correctionVector += directionToReference * distanceCorrection * Float(reference.weight)
                totalWeight += reference.weight
            }
        }

        if totalWeight > 0 && simd_length(correctionVector) > 0.01 {
            let finalCorrection = correctionVector / Float(totalWeight)
            let maxCorrection = min(simd_length(finalCorrection), 0.1) // Max 10cm correction per step
            let correctionDirection = simd_normalize(finalCorrection)

            // Apply gradual correction (only partial correction to avoid overshoot)
            let appliedCorrection = correctionDirection * maxCorrection * 0.3

            // Apply the correction to the anchor's transform
            network.primaryAnchor.transform.translation += appliedCorrection

            print("🕸️ Applied network-based drift correction to '\(objectId)': moved \(String(format: "%.3f", simd_length(appliedCorrection)))m")

            // Update network timestamp
            if var updatedNetwork = activeNetworks[objectId] {
                updatedNetwork.lastUpdated = Date()
                activeNetworks[objectId] = updatedNetwork
            }

            return true
        }

        return false
    }

    /// Update stability networks periodically
    private func startNetworkMaintenance() {
        networkUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateNetworkStability()
        }
    }

    /// Update stability scores for all networks
    func updateNetworkStability() {
        for (objectId, network) in activeNetworks {
            // Recalculate reference anchor positions and weights
            let updatedReferences = findReferenceAnchors(
                center: network.primaryAnchor.transform.translation,
                radius: network.networkRadius
            )

            let updatedStability = calculateNetworkStability(
                primaryAnchor: network.primaryAnchor,
                references: updatedReferences
            )

            // Update network
            var updatedNetwork = network
            updatedNetwork.referenceAnchors = updatedReferences
            updatedNetwork.stabilityScore = updatedStability
            updatedNetwork.lastUpdated = Date()

            activeNetworks[objectId] = updatedNetwork
        }

        // Calculate overall network stability
        let avgStability = activeNetworks.values.map { $0.stabilityScore }.reduce(0, +) / Double(max(activeNetworks.count, 1))
        networkStabilityScore = activeNetworks.isEmpty ? 0.0 : avgStability
    }

    /// Remove stability network for an object
    func removeStabilityNetwork(objectId: String) {
        activeNetworks.removeValue(forKey: objectId)
        print("🕸️ Removed stability network for '\(objectId)'")
    }

    /// Get stability diagnostics for debugging
    func getStabilityDiagnostics(objectId: String) -> [String: Any]? {
        guard let network = activeNetworks[objectId] else { return nil }

        return [
            "networkId": network.networkId,
            "stabilityScore": network.stabilityScore,
            "referenceAnchorCount": network.referenceAnchors.count,
            "networkRadius": network.networkRadius,
            "lastUpdated": network.lastUpdated,
            "referenceAnchors": network.referenceAnchors.map { anchor in
                [
                    "distance": anchor.distance,
                    "weight": anchor.weight,
                    "stabilityContribution": anchor.stabilityContribution
                ]
            }
        ]
    }

    /// Optimize network by removing weak reference anchors
    func optimizeNetwork(objectId: String) {
        guard var network = activeNetworks[objectId] else { return }

        // Keep only reference anchors with good stability contribution
        network.referenceAnchors = network.referenceAnchors.filter { $0.stabilityContribution > 0.5 }

        // Recalculate stability score
        network.stabilityScore = calculateNetworkStability(
            primaryAnchor: network.primaryAnchor,
            references: network.referenceAnchors
        )

        activeNetworks[objectId] = network
        print("🕸️ Optimized network for '\(objectId)': kept \(network.referenceAnchors.count) reference anchors")
    }
}
