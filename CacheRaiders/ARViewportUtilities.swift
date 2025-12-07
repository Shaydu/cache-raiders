import Foundation
import RealityKit
import ARKit

/// Utility class for AR viewport operations, visibility checks, and screen projections
class ARViewportUtilities {

    // MARK: - Viewport Visibility

    /// Checks if an object is visible in the AR viewport
    /// - Parameters:
    ///   - locationId: Object identifier (for logging)
    ///   - anchor: The anchor entity to check
    ///   - arView: The AR view containing the scene
    ///   - frame: Current AR frame
    /// - Returns: True if object is in viewport, false otherwise
    static func isObjectInViewport(locationId: String, anchor: AnchorEntity, arView: ARView, frame: ARFrame) -> Bool {
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

        // Check if object is in front of camera (not behind)
        let cameraToObject = bestPosition - cameraPos

        // Normalize vectors for dot product
        let normalizedForward = normalize(cameraForward)
        let normalizedToObject = normalize(cameraToObject)

        // Dot product: positive = in front, negative = behind, zero = perpendicular
        let dotProduct = dot(normalizedForward, normalizedToObject)

        // Only consider objects that are in front of the camera (dot product > 0)
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

        // Add a small margin to account for object size (objects slightly off-screen still count)
        let margin: CGFloat = 50.0 // 50 point margin

        let xInBounds = screenPoint.x >= -margin && screenPoint.x <= viewWidth + margin
        let yInBounds = screenPoint.y >= -margin && screenPoint.y <= viewHeight + margin

        return xInBounds && yInBounds
    }

    /// Projects a 3D world position to 2D screen coordinates
    /// - Parameters:
    ///   - worldPosition: Position in world space
    ///   - arView: The AR view
    ///   - frame: Current AR frame
    /// - Returns: Screen coordinates if visible, nil otherwise
    static func projectToScreen(worldPosition: SIMD3<Float>, arView: ARView, frame: ARFrame) -> CGPoint? {
        // Project world position to screen coordinates
        let camera = frame.camera
        let screenPoint = camera.projectPoint(worldPosition,
                                             orientation: .portrait,
                                             viewportSize: arView.bounds.size)

        // Convert to UIKit coordinates (flip Y axis)
        let uiKitPoint = CGPoint(x: screenPoint.x, y: arView.bounds.height - screenPoint.y)
        return uiKitPoint
    }

    /// Checks if a screen point is within the visible viewport bounds
    /// - Parameters:
    ///   - screenPoint: Point in screen coordinates
    ///   - arView: The AR view
    ///   - margin: Additional margin around viewport edges
    /// - Returns: True if point is in viewport, false otherwise
    static func isScreenPointInViewport(_ screenPoint: CGPoint, arView: ARView, margin: CGFloat = 50.0) -> Bool {
        let viewWidth = CGFloat(arView.bounds.width)
        let viewHeight = CGFloat(arView.bounds.height)

        let xInBounds = screenPoint.x >= -margin && screenPoint.x <= viewWidth + margin
        let yInBounds = screenPoint.y >= -margin && screenPoint.y <= viewHeight + margin

        return xInBounds && yInBounds
    }

    // MARK: - Camera and View Calculations

    /// Gets the camera position from an AR frame
    /// - Parameter frame: Current AR frame
    /// - Returns: Camera position in world space
    static func getCameraPosition(from frame: ARFrame) -> SIMD3<Float> {
        let cameraTransform = frame.camera.transform
        return SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
    }

    /// Gets the camera forward direction from an AR frame
    /// - Parameter frame: Current AR frame
    /// - Returns: Normalized forward direction vector
    static func getCameraForwardDirection(from frame: ARFrame) -> SIMD3<Float> {
        let cameraTransform = frame.camera.transform
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        return normalize(cameraForward)
    }

    /// Calculates the angle between camera forward direction and a target position
    /// - Parameters:
    ///   - targetPosition: Target position in world space
    ///   - frame: Current AR frame
    /// - Returns: Angle in degrees (0 = directly ahead, 90 = to the side, 180 = behind)
    static func calculateViewingAngle(to targetPosition: SIMD3<Float>, from frame: ARFrame) -> Float {
        let cameraPos = getCameraPosition(from: frame)
        let cameraForward = getCameraForwardDirection(from: frame)

        let toTarget = normalize(targetPosition - cameraPos)
        let dotProduct = dot(cameraForward, toTarget)

        // Clamp dot product to avoid acos domain errors
        let clampedDot = max(-1.0, min(1.0, dotProduct))
        let angleRadians = acos(clampedDot)

        return angleRadians * 180.0 / .pi
    }
}