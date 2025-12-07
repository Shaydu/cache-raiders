import Foundation
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Anchor Creation Service
/// Service responsible for creating and managing different types of AR anchors
/// Handles optimal anchor selection, transform decoding, and precision placement
class ARAnchorCreationService {

    // MARK: - Properties

    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?

    // MARK: - Initialization

    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        self.arView = arView
        self.locationManager = locationManager
        print("🔧 ARAnchorCreationService initialized")
    }

    // MARK: - Anchor Creation

    /// Creates the optimal anchor for a given position and object type
    /// Attempts plane anchors for surface-attached objects, falls back to world anchors
    func createOptimalAnchor(for position: SIMD3<Float>, screenPoint: CGPoint?, objectType: LootBoxType, in arView: ARView) -> AnchorEntity {

        // Try plane anchor first if we have screen coordinates (for surface-attached objects)
        if let screenPoint = screenPoint {
            // Only try plane anchors for objects that benefit from surface attachment
            let shouldTryPlaneAnchor = (objectType == .treasureChest || objectType == .lootChest ||
                                       objectType == .chalice || objectType == .templeRelic)

            if shouldTryPlaneAnchor {
                if let raycastResult = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal).first {

                    // 🎯 PLANE ANCHOR: Attach to detected surface (much more stable!)
                    let planeAnchor = AnchorEntity(anchor: raycastResult.anchor!)
                    planeAnchor.position = SIMD3<Float>(raycastResult.worldTransform.columns.3.x, raycastResult.worldTransform.columns.3.y, raycastResult.worldTransform.columns.3.z)
                    Swift.print("✅ PLANE ANCHOR: '\(objectType.displayName)' attached to detected surface")
                    return planeAnchor
                }
                Swift.print("⚠️ PLANE ANCHOR: No surface detected for '\(objectType.displayName)', using world anchor")
            } else {
                Swift.print("🎯 WORLD ANCHOR: '\(objectType.displayName)' prefers floating placement")
            }
        } else {
            Swift.print("🎯 WORLD ANCHOR: No screen coordinates available for '\(objectType.displayName)'")
        }

        // 🎯 WORLD ANCHOR: Fallback for floating objects or when no surface detected
        let worldAnchor = AnchorEntity(world: position)
        Swift.print("✅ WORLD ANCHOR: Using world-positioned anchor for '\(objectType.displayName)'")
        return worldAnchor
    }

    // MARK: - AR Anchor Transform Support

    /// Decodes AR anchor transform from base64 string
    func decodeARAnchorTransform(_ base64String: String) -> simd_float4x4? {
        guard let data = Data(base64Encoded: base64String) else {
            Swift.print("❌ Failed to decode AR anchor transform from base64")
            return nil
        }

        do {
            let transformArray = try JSONDecoder().decode([Float].self, from: data)
            guard transformArray.count == 16 else {
                Swift.print("❌ Invalid AR anchor transform array size: \(transformArray.count), expected 16")
                return nil
            }

            // Reconstruct the 4x4 matrix from the array
            let transform = simd_float4x4(
                SIMD4<Float>(transformArray[0], transformArray[1], transformArray[2], transformArray[3]),
                SIMD4<Float>(transformArray[4], transformArray[5], transformArray[6], transformArray[7]),
                SIMD4<Float>(transformArray[8], transformArray[9], transformArray[10], transformArray[11]),
                SIMD4<Float>(transformArray[12], transformArray[13], transformArray[14], transformArray[15])
            )

            Swift.print("✅ Successfully decoded AR anchor transform")
            Swift.print("   Position: (\(String(format: "%.4f", transform.columns.3.x)), \(String(format: "%.4f", transform.columns.3.y)), \(String(format: "%.4f", transform.columns.3.z)))m")

            return transform
        } catch {
            Swift.print("❌ Failed to decode AR anchor transform: \(error)")
            return nil
        }
    }

    /// Applies AR anchor transform to place object at exact position with millimeter accuracy
    func placeObjectWithARAnchor(_ location: LootBoxLocation, arAnchorTransform: simd_float4x4, in arView: ARView, placementHandler: (_ position: SIMD3<Float>, _ location: LootBoxLocation, _ arView: ARView, _ screenPoint: CGPoint?) -> Void) {
        let position = SIMD3<Float>(
            arAnchorTransform.columns.3.x,
            arAnchorTransform.columns.3.y,
            arAnchorTransform.columns.3.z
        )

        Swift.print("🎯 [AR Anchor Precision] Placing object with cm accuracy")
        Swift.print("   Object: \(location.name)")
        Swift.print("   Position: (\(String(format: "%.4f", position.x)), \(String(format: "%.4f", position.y)), \(String(format: "%.4f", position.z)))m")
        Swift.print("   🎯 PRECISION MODE: Using exact AR anchor position (mm accuracy)")

        // Use the exact position from the AR anchor - no re-grounding
        placementHandler(position, location, arView, nil)
    }

    // MARK: - Utility Methods

    /// Determines if an object type should use plane anchoring
    func shouldUsePlaneAnchoring(for objectType: LootBoxType) -> Bool {
        return (objectType == .treasureChest || objectType == .lootChest ||
                objectType == .chalice || objectType == .templeRelic)
    }

    /// Creates a world anchor at the specified position
    func createWorldAnchor(at position: SIMD3<Float>, for objectType: LootBoxType) -> AnchorEntity {
        let worldAnchor = AnchorEntity(world: position)
        Swift.print("✅ WORLD ANCHOR: Using world-positioned anchor for '\(objectType.displayName)'")
        return worldAnchor
    }

    /// Creates a plane anchor from raycast result
    func createPlaneAnchor(from raycastResult: ARRaycastResult, for objectType: LootBoxType) -> AnchorEntity {
        let planeAnchor = AnchorEntity(anchor: raycastResult.anchor!)
        planeAnchor.position = SIMD3<Float>(raycastResult.worldTransform.columns.3.x, raycastResult.worldTransform.columns.3.y, raycastResult.worldTransform.columns.3.z)
        Swift.print("✅ PLANE ANCHOR: '\(objectType.displayName)' attached to detected surface")
        return planeAnchor
    }
}


