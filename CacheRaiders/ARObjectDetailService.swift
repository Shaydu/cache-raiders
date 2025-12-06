import Foundation
import SwiftUI
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Object Detail Data Model
/// Complete details about an AR object for display in detail sheet
struct ARObjectDetail: Identifiable, Equatable {
    let id: String
    let name: String
    let itemType: String
    let placerName: String?
    let datePlaced: Date?
    let gpsCoordinates: CLLocationCoordinate2D?
    let arCoordinates: SIMD3<Float>?
    let arOrigin: CLLocationCoordinate2D?
    let arOffsets: SIMD3<Double>?
    let anchors: [String] // AR anchor information

    // Equatable conformance
    static func == (lhs: ARObjectDetail, rhs: ARObjectDetail) -> Bool {
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.itemType == rhs.itemType &&
               lhs.placerName == rhs.placerName &&
               lhs.datePlaced == rhs.datePlaced &&
               lhs.gpsCoordinates?.latitude == rhs.gpsCoordinates?.latitude &&
               lhs.gpsCoordinates?.longitude == rhs.gpsCoordinates?.longitude &&
               lhs.arCoordinates == rhs.arCoordinates &&
               lhs.arOrigin?.latitude == rhs.arOrigin?.latitude &&
               lhs.arOrigin?.longitude == rhs.arOrigin?.longitude &&
               lhs.arOffsets == rhs.arOffsets &&
               lhs.anchors == rhs.anchors
    }

    /// Display-friendly GPS coordinate string
    var gpsCoordinateString: String {
        guard let coords = gpsCoordinates else { return "N/A" }
        return String(format: "%.6f, %.6f", coords.latitude, coords.longitude)
    }

    /// Display-friendly AR coordinate string
    var arCoordinateString: String {
        guard let coords = arCoordinates else { return "N/A" }
        return String(format: "X: %.2fm, Y: %.2fm, Z: %.2fm", coords.x, coords.y, coords.z)
    }

    /// Display-friendly AR origin string
    var arOriginString: String {
        guard let origin = arOrigin else { return "N/A" }
        return String(format: "%.6f, %.6f", origin.latitude, origin.longitude)
    }

    /// Display-friendly AR offset string
    var arOffsetString: String {
        guard let offsets = arOffsets else { return "N/A" }
        return String(format: "X: %.2fm, Y: %.2fm, Z: %.2fm", offsets.x, offsets.y, offsets.z)
    }

    /// Display-friendly date placed string
    var datePlacedString: String {
        guard let date = datePlaced else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - AR Object Detail Service
/// Service for extracting detailed information about AR objects for long-press detail view
class ARObjectDetailService {

    // MARK: - Singleton
    static let shared = ARObjectDetailService()

    private init() {}

    // MARK: - Extract Object Details
    /// Extract complete details about an AR object for display
    /// - Parameters:
    ///   - location: The LootBoxLocation object
    ///   - anchor: The AR anchor entity for the object
    /// - Returns: ARObjectDetail with all available information
    func extractObjectDetails(location: LootBoxLocation, anchor: AnchorEntity?) -> ARObjectDetail {
        // Extract AR coordinates from anchor if available
        var arCoordinates: SIMD3<Float>? = nil
        var anchorInfo: [String] = []

        if let anchor = anchor {
            let transform = anchor.transformMatrix(relativeTo: nil)
            arCoordinates = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )

            // Extract anchor entity information
            let anchorId = anchor.id.description
            let anchorType = String(describing: type(of: anchor))
            anchorInfo.append("Entity ID: \(anchorId)")
            anchorInfo.append("Entity Type: \(anchorType)")

            // Add transform info from the anchor entity
            let position = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            anchorInfo.append("Position: \(String(format: "%.2f, %.2f, %.2f", position.x, position.y, position.z))")
        }

        // Extract GPS coordinates (only if valid, not 0,0)
        let hasValidGPS = location.latitude != 0.0 || location.longitude != 0.0
        let gpsCoords = hasValidGPS ? CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude
        ) : nil

        // Extract AR origin if available
        var arOrigin: CLLocationCoordinate2D? = nil
        if let originLat = location.ar_origin_latitude,
           let originLon = location.ar_origin_longitude {
            arOrigin = CLLocationCoordinate2D(latitude: originLat, longitude: originLon)
        }

        // Extract AR offsets if available
        var arOffsets: SIMD3<Double>? = nil
        if let offsetX = location.ar_offset_x,
           let offsetY = location.ar_offset_y,
           let offsetZ = location.ar_offset_z {
            arOffsets = SIMD3<Double>(offsetX, offsetY, offsetZ)
        }

        // Get placer name - convert user ID to display name
        var placerName: String? = nil
        if let createdBy = location.created_by {
            // Use same logic as ARCoordinator: "Your" for current user, "[UserID]'s" for others
            let currentUserId = APIService.shared.currentUserID
            placerName = createdBy == currentUserId ? "Your" : "\(createdBy)'s"
        } else {
            // If no creator info, show as Admin/System placed
            placerName = location.source == .api ? "Admin" : "Unknown"
        }

        return ARObjectDetail(
            id: location.id,
            name: location.name,
            itemType: location.type.displayName,
            placerName: placerName,
            datePlaced: location.ar_placement_timestamp ?? location.last_modified,
            gpsCoordinates: gpsCoords,
            arCoordinates: arCoordinates,
            arOrigin: arOrigin,
            arOffsets: arOffsets,
            anchors: anchorInfo
        )
    }

    // MARK: - Long Press Detection
    /// Check if a long press at a screen location intersects with an AR object
    /// - Parameters:
    ///   - location: Screen location of the long press
    ///   - arView: The ARView to check
    ///   - placedBoxes: Dictionary of placed AR objects
    /// - Returns: The ID of the intersected object, if any
    func detectObjectAtLocation(
        _ location: CGPoint,
        in arView: ARView,
        placedBoxes: [String: AnchorEntity]
    ) -> String? {
        // First try direct entity hit
        if let tappedEntity = arView.entity(at: location) {
            // Walk up entity hierarchy to find object ID
            var entityToCheck: Entity? = tappedEntity
            var checkedEntities = Set<String>()

            while let currentEntity = entityToCheck {
                let entityName = currentEntity.name
                if !entityName.isEmpty {
                    let entityKey = "\(ObjectIdentifier(currentEntity))"
                    guard !checkedEntities.contains(entityKey) else { break }
                    checkedEntities.insert(entityKey)

                    // Check if this ID matches a placed box
                    if placedBoxes[entityName] != nil {
                        return entityName
                    }
                }

                // Check parent's name
                if let parent = currentEntity.parent {
                    let parentName = parent.name
                    if !parentName.isEmpty {
                        let parentKey = "\(ObjectIdentifier(parent))"
                        if !checkedEntities.contains(parentKey) {
                            checkedEntities.insert(parentKey)
                            if placedBoxes[parentName] != nil {
                                return parentName
                            }
                        }
                    }
                }

                entityToCheck = currentEntity.parent
            }
        }

        // Fallback to proximity-based detection using screen-space projection
        guard let frame = arView.session.currentFrame else { return nil }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        let normalizedCameraForward = normalize(cameraForward)

        var closestBoxId: String? = nil
        var closestScreenDistance: CGFloat = CGFloat.infinity
        let maxScreenDistance: CGFloat = 150.0 // Maximum screen distance in points

        for (boxId, anchor) in placedBoxes {
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let anchorWorldPos = SIMD3<Float>(
                anchorTransform.columns.3.x,
                anchorTransform.columns.3.y,
                anchorTransform.columns.3.z
            )

            // Check if object is in front of camera
            let cameraToObject = anchorWorldPos - cameraPos
            let normalizedToObject = normalize(cameraToObject)
            let dotProduct = dot(normalizedCameraForward, normalizedToObject)

            guard dotProduct > 0.0 else { continue } // Skip objects behind camera

            // Project to screen coordinates
            guard let screenPoint = arView.project(anchorWorldPos) else { continue }

            // Check if on screen
            let viewWidth = CGFloat(arView.bounds.width)
            let viewHeight = CGFloat(arView.bounds.height)
            guard screenPoint.x >= 0 && screenPoint.x <= viewWidth &&
                  screenPoint.y >= 0 && screenPoint.y <= viewHeight else {
                continue
            }

            // Calculate screen distance
            let dx = location.x - screenPoint.x
            let dy = location.y - screenPoint.y
            let screenDistance = sqrt(dx * dx + dy * dy)

            if screenDistance < maxScreenDistance && screenDistance < closestScreenDistance {
                closestScreenDistance = screenDistance
                closestBoxId = boxId
            }
        }

        return closestBoxId
    }
}
