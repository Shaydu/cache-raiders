import Foundation
import RealityKit
import ARKit
import CoreLocation
import Combine

/// Enhanced world map persistence with automatic relocalization and stability improvements
class EnhancedWorldMapService: ObservableObject {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?

    @Published var isRelocalizing = false
    @Published var relocalizationProgress: Double = 0.0
    @Published var worldMapQuality: Double = 0.0
    @Published var persistedAnchors: Int = 0

    private var currentWorldMap: ARWorldMap?
    private var persistedWorldMaps: [String: ARWorldMap] = [:] // Keyed by location/area
    private var anchorQualityTracker: [String: Double] = [:] // Track anchor stability
    private var relocalizationAttempts = 0

    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        self.arView = arView
        self.locationManager = locationManager
        setupWorldMapMonitoring()
    }

    /// Capture and persist world map for current area
    func captureWorldMap(for area: String = "current") async -> Bool {
        guard let arView = arView else { return false }

        do {
            let worldMap = try await arView.session.currentWorldMap()
            let quality = assessWorldMapQuality(worldMap)

            if quality >= 0.6 { // Only persist high-quality maps
                persistedWorldMaps[area] = worldMap
                currentWorldMap = worldMap
                worldMapQuality = quality
                persistedAnchors = worldMap.anchors.count

                print("💾 Captured high-quality world map for '\(area)' (quality: \(String(format: "%.2f", quality)), \(worldMap.anchors.count) anchors)")
                return true
            } else {
                print("⚠️ World map quality too low (\(String(format: "%.2f", quality))) - not persisting")
                return false
            }
        } catch {
            print("❌ Failed to capture world map: \(error.localizedDescription)")
            return false
        }
    }

    /// Attempt automatic relocalization using persisted world maps
    func attemptRelocalization() async -> Bool {
        guard let arView = arView, !persistedWorldMaps.isEmpty else { return false }

        isRelocalizing = true
        relocalizationProgress = 0.0
        relocalizationAttempts += 1

        print("🔍 Attempting automatic relocalization (attempt \(relocalizationAttempts))")

        // Try relocalizing with each persisted world map
        for (area, worldMap) in persistedWorldMaps {
            relocalizationProgress = 0.3

            do {
                // Configure session for relocalization
                let configuration = ARWorldTrackingConfiguration()
                configuration.initialWorldMap = worldMap
                configuration.planeDetection = [.horizontal, .vertical]

                // Enable scene reconstruction if available
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    configuration.sceneReconstruction = .mesh
                }

                relocalizationProgress = 0.6

                // Run session with world map
                try await arView.session.run(configuration)

                relocalizationProgress = 0.9

                // Wait for relocalization to complete
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

                // Check if relocalization succeeded
                if let frame = arView.session.currentFrame,
                   frame.camera.trackingState == .normal {

                    relocalizationProgress = 1.0
                    isRelocalizing = false
                    worldMapQuality = assessWorldMapQuality(worldMap)

                    print("✅ Successfully relocalized using world map '\(area)'")
                    print("   Quality: \(String(format: "%.2f", worldMapQuality))")
                    print("   Anchors: \(worldMap.anchors.count)")

                    return true
                }

            } catch {
                print("⚠️ Relocalization attempt with '\(area)' failed: \(error.localizedDescription)")
            }
        }

        relocalizationProgress = 0.0
        isRelocalizing = false
        print("❌ All relocalization attempts failed")
        return false
    }

    /// Assess world map quality based on anchor count, distribution, and tracking features
    private func assessWorldMapQuality(_ worldMap: ARWorldMap) -> Double {
        guard let arView = arView else { return 0.0 }

        var quality = 0.0

        // Factor 1: Anchor count (more anchors = better)
        let anchorCount = worldMap.anchors.count
        let anchorScore = min(Double(anchorCount) / 20.0, 1.0) // Max score at 20+ anchors
        quality += anchorScore * 0.4

        // Factor 2: Anchor distribution (spread out anchors = better)
        let anchorPositions = worldMap.anchors.compactMap { anchor in
            anchor.transform.columns.3
        }
        let distributionScore = calculateAnchorDistribution(anchorPositions)
        quality += distributionScore * 0.3

        // Factor 3: Visual feature points (more features = better tracking)
        if let frame = arView.session.currentFrame {
            let featureScore = min(Double(frame.rawFeaturePoints?.points.count ?? 0) / 500.0, 1.0)
            quality += featureScore * 0.3
        }

        return quality
    }

    /// Calculate how well anchors are distributed (avoid clustering)
    private func calculateAnchorDistribution(_ positions: [SIMD4<Float>]) -> Double {
        guard positions.count >= 3 else { return 0.0 }

        // Calculate centroid
        let centroid = positions.reduce(SIMD4<Float>.zero) { $0 + $1 } / Float(positions.count)

        // Calculate average distance from centroid
        let distances = positions.map { distance($0, centroid) }
        let avgDistance = distances.reduce(0, +) / Float(distances.count)

        // Score based on distribution (higher avg distance = better spread)
        return Double(min(avgDistance / 2.0, 1.0)) // Max score when avg distance >= 2m
    }

    /// Monitor anchor stability and trigger quality improvements
    func monitorAnchorStability() {
        guard let arView = arView else { return }

        for anchor in arView.session.currentFrame?.anchors ?? [] {
            let anchorId = anchor.name ?? "unnamed_\(anchor.hash)"
            let stability = assessAnchorStability(anchor)

            anchorQualityTracker[anchorId] = stability

            // If anchor becomes unstable, attempt to improve it
            if stability < 0.5 {
                improveAnchorStability(anchor)
            }
        }
    }

    /// Assess individual anchor stability
    private func assessAnchorStability(_ anchor: ARAnchor) -> Double {
        // Factors: tracking state, transform consistency, age
        var stability = 0.0

        // Anchors in world map are considered tracked
        stability += 0.6

        // Transform stability (lower variance = more stable)
        // This would require tracking transform history
        stability += 0.4 // Placeholder

        return stability
    }

    /// Attempt to improve unstable anchor stability
    private func improveAnchorStability(_ anchor: ARAnchor) {
        // Strategies:
        // 1. Add nearby reference anchors
        // 2. Use visual features to reinforce tracking
        // 3. Merge with nearby stable anchors

        print("🔧 Attempting to improve stability for anchor: \(anchor.name ?? "unnamed")")
    }

    /// Setup continuous world map monitoring
    private func setupWorldMapMonitoring() {
        // This would be called periodically to assess and improve world map quality
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.monitorAnchorStability()

            // Periodically assess world map quality
            if let arView = self?.arView,
               arView.session.currentFrame?.camera.trackingState == .normal {
                Task {
                    let quality = await self?.assessCurrentWorldMapQuality() ?? 0.0
                    await MainActor.run {
                        self?.worldMapQuality = quality
                    }
                }
            }
        }
    }

    /// Assess current world map quality in real-time
    private func assessCurrentWorldMapQuality() async -> Double {
        guard let arView = arView else { return 0.0 }

        do {
            let worldMap = try await arView.session.currentWorldMap()
            return assessWorldMapQuality(worldMap)
        } catch {
            return 0.0
        }
    }
}
