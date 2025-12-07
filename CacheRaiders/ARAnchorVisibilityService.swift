import Foundation
import RealityKit
import ARKit

// MARK: - AR Anchor Visibility Service
/// Service responsible for determining object visibility in the AR viewport
/// Handles camera frustum culling and screen space visibility calculations
class ARAnchorVisibilityService {

    // MARK: - Properties

    weak var arView: ARView?

    // Visibility thresholds
    let viewportMargin: CGFloat = 50.0 // Points outside viewport that still count as visible

    // MARK: - Initialization

    init(arView: ARView?) {
        self.arView = arView
        print("👁️ ARAnchorVisibilityService initialized")
    }

    // MARK: - Visibility Checking

    /// Determines if an object is currently visible in the AR viewport
    func isObjectInViewport(locationId: String, anchor: AnchorEntity) -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            return false
        }

        // Get camera position and forward direction
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Camera forward direction is the negative Z axis in camera space (columns.2)
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )

        // Get the object's world position
        let anchorTransform = anchor.transformMatrix(relativeTo: nil)
        let objectPosition = SIMD3<Float>(
            anchorTransform.columns.3.x,
            anchorTransform.columns.3.y,
            anchorTransform.columns.3.z
        )

        // Try to find a more specific position from child entities (like the actual box/chalice)
        var bestPosition = objectPosition
        for child in anchor.children {
            if let modelEntity = child as? ModelEntity {
                let childTransform = modelEntity.transformMatrix(relativeTo: nil)
                let childPosition = SIMD3<Float>(
                    childTransform.columns.3.x,
                    childTransform.columns.3.y,
                    childTransform.columns.3.z
                )
                // Use the first child entity's position as it's likely the visible part
                bestPosition = childPosition
                break
            }
        }

        // CRITICAL: Check if object is in front of camera (not behind)
        // Calculate vector from camera to object
        let cameraToObject = bestPosition - cameraPos

        // Normalize camera forward direction for dot product
        let normalizedForward = normalize(cameraForward)
        let normalizedToObject = normalize(cameraToObject)

        // Dot product: positive = in front, negative = behind, zero = perpendicular
        let dotProduct = dot(normalizedForward, normalizedToObject)

        // Only consider objects that are in front of the camera (dot product > 0)
        // Use a small threshold (0.0) to avoid edge cases at exactly 90 degrees
        guard dotProduct > 0.0 else {
            return false // Object is behind camera
        }

        // Project the position to screen coordinates
        guard let screenPoint = arView.project(bestPosition) else {
            return false // Object is behind camera or outside view
        }

        // Check if the projected point is within the viewport bounds
        let viewWidth = CGFloat(arView.bounds.width)
        let viewHeight = CGFloat(arView.bounds.height)

        // Break down the complex expression into sub-expressions to help compiler type-checking
        let xInBounds = screenPoint.x >= -viewportMargin && screenPoint.x <= viewWidth + viewportMargin
        let yInBounds = screenPoint.y >= -viewportMargin && screenPoint.y <= viewHeight + viewportMargin
        let isInViewport = xInBounds && yInBounds

        return isInViewport
    }

    /// Checks if multiple objects are in viewport and returns their visibility status
    func getViewportStatus(for anchors: [String: AnchorEntity]) -> [String: Bool] {
        var results = [String: Bool]()

        for (locationId, anchor) in anchors {
            results[locationId] = isObjectInViewport(locationId: locationId, anchor: anchor)
        }

        return results
    }

    /// Gets the screen coordinates of an object if it's visible
    func getScreenCoordinates(for anchor: AnchorEntity) -> CGPoint? {
        guard let arView = arView else { return nil }

        // Get object position (prefer child entity if available)
        var position = anchor.position
        for child in anchor.children {
            if let modelEntity = child as? ModelEntity {
                position = modelEntity.position(relativeTo: nil)
                break
            }
        }

        return arView.project(position)
    }

    /// Calculates the distance from camera to object
    func getDistanceToObject(anchor: AnchorEntity) -> Float? {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return nil }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        var objectPos = anchor.position
        for child in anchor.children {
            if let modelEntity = child as? ModelEntity {
                objectPos = modelEntity.position(relativeTo: nil)
                break
            }
        }

        return length(objectPos - cameraPos)
    }

    /// Determines if an object is within a reasonable viewing distance
    func isObjectWithinViewingDistance(anchor: AnchorEntity, maxDistance: Float = 50.0) -> Bool {
        guard let distance = getDistanceToObject(anchor: anchor) else { return false }
        return distance <= maxDistance
    }
}

