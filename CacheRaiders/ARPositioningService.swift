//
//  ARPositioningService.swift
//  CacheRaiders
//
//  Created for centralized AR positioning logic
//

import Foundation
import ARKit
import CoreLocation

// MARK: - AR Positioning Service
/// Service for managing AR positioning logic including offsets, anchor transforms, and timestamps
class ARPositioningService {

    // MARK: - Singleton
    static let shared = ARPositioningService()

    private init() {}

    // MARK: - AR Offset Management

    /// Represents AR offset coordinates in 3D space
    struct AROffsets {
        let x: Double
        let y: Double
        let z: Double

        /// Check if all offsets are valid (non-nil)
        var isValid: Bool {
            return !x.isNaN && !y.isNaN && !z.isNaN &&
                   x.isFinite && y.isFinite && z.isFinite
        }

        /// Convert to SIMD3 vector for AR calculations
        var asSIMD3: SIMD3<Double> {
            SIMD3<Double>(x, y, z)
        }

        /// Create from SIMD3 vector
        static func fromSIMD3(_ vector: SIMD3<Double>) -> AROffsets {
            AROffsets(x: vector.x, y: vector.y, z: vector.z)
        }

        /// Create from AR position (assuming meters)
        static func fromARPosition(_ position: SIMD3<Float>) -> AROffsets {
            AROffsets(x: Double(position.x), y: Double(position.y), z: Double(position.z))
        }
    }

    // MARK: - AR Origin Management

    /// Represents an AR session origin location
    struct AROrigin {
        let latitude: Double
        let longitude: Double

        /// Convert to CLLocation for distance calculations
        var location: CLLocation {
            CLLocation(latitude: latitude, longitude: longitude)
        }

        /// Check if origin is valid
        var isValid: Bool {
            return latitude >= -90 && latitude <= 90 &&
                   longitude >= -180 && longitude <= 180
        }
    }

    // MARK: - AR Anchor Transform Management

    /// Encode AR anchor transform to base64 string for storage
    /// - Parameter transform: The AR anchor transform matrix
    /// - Returns: Base64 encoded string representation
    func encodeAnchorTransform(_ transform: simd_float4x4) -> String? {
        // Convert 4x4 matrix to array of floats
        var floatArray: [Float] = []
        for column in 0..<4 {
            for row in 0..<4 {
                floatArray.append(transform[column][row])
            }
        }

        // Convert to data
        let data = floatArray.withUnsafeBytes { Data($0) }

        // Encode as base64
        return data.base64EncodedString()
    }

    /// Decode base64 string back to AR anchor transform
    /// - Parameter base64String: Base64 encoded transform string
    /// - Returns: AR anchor transform matrix, or nil if decoding fails
    func decodeAnchorTransform(_ base64String: String) -> simd_float4x4? {
        guard let data = Data(base64Encoded: base64String) else {
            print("⚠️ Failed to decode base64 anchor transform data")
            return nil
        }

        // Ensure we have exactly 64 bytes (16 floats * 4 bytes each)
        guard data.count == 64 else {
            print("⚠️ Invalid anchor transform data size: \(data.count) bytes (expected 64)")
            return nil
        }

        // Convert back to float array
        let floatArray = data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> [Float] in
            let buffer = pointer.bindMemory(to: Float.self)
            return Array(buffer)
        }

        // Reconstruct 4x4 matrix
        var transform = simd_float4x4()
        for column in 0..<4 {
            for row in 0..<4 {
                let index = column * 4 + row
                if index < floatArray.count {
                    transform[column][row] = floatArray[index]
                }
            }
        }

        return transform
    }

    // MARK: - AR Positioning Data Validation

    /// Comprehensive validation of AR positioning data
    /// - Parameters:
    ///   - arOrigin: AR session origin coordinates
    ///   - offsets: AR offset coordinates
    ///   - anchorTransform: Optional anchor transform string
    ///   - placementTimestamp: Optional placement timestamp
    /// - Returns: True if all AR positioning data is valid
    func isValidARPositioning(
        arOrigin: AROrigin?,
        offsets: AROffsets?,
        anchorTransform: String?,
        placementTimestamp: Date?
    ) -> Bool {
        // If any AR data is present, validate it
        if let origin = arOrigin {
            guard origin.isValid else {
                print("⚠️ Invalid AR origin coordinates: (\(origin.latitude), \(origin.longitude))")
                return false
            }
        }

        if let offsets = offsets {
            guard offsets.isValid else {
                print("⚠️ Invalid AR offsets: (\(offsets.x), \(offsets.y), \(offsets.z))")
                return false
            }
        }

        // Validate anchor transform if present
        if let transformString = anchorTransform {
            guard !transformString.isEmpty else {
                print("⚠️ Empty AR anchor transform string")
                return false
            }

            // Try to decode to validate format
            guard decodeAnchorTransform(transformString) != nil else {
                print("⚠️ Invalid AR anchor transform format")
                return false
            }
        }

        // Validate timestamp if present
        if let timestamp = placementTimestamp {
            // Ensure timestamp is not in the future (with small tolerance)
            let now = Date()
            let oneHourFromNow = now.addingTimeInterval(3600)
            guard timestamp <= oneHourFromNow else {
                print("⚠️ AR placement timestamp is in the future: \(timestamp)")
                return false
            }

            // Ensure timestamp is not too far in the past (more than 1 year)
            let oneYearAgo = now.addingTimeInterval(-365 * 24 * 3600)
            guard timestamp >= oneYearAgo else {
                print("⚠️ AR placement timestamp is too old: \(timestamp)")
                return false
            }
        }

        return true
    }

    /// Check if a location has complete AR positioning data
    /// - Parameter location: The location to check
    /// - Returns: True if location has all required AR positioning data
    func hasCompleteARPositioning(_ location: LootBoxLocation) -> Bool {
        let hasOrigin = location.ar_origin_latitude != nil && location.ar_origin_longitude != nil
        let hasOffsets = location.ar_offset_x != nil && location.ar_offset_y != nil && location.ar_offset_z != nil

        // Either both origin and offsets, or neither (for non-AR objects)
        return hasOrigin == hasOffsets
    }

    // MARK: - AR Position Calculations

    /// Calculate the real-world position from AR coordinates
    /// - Parameters:
    ///   - arOrigin: AR session origin location
    ///   - offsets: AR coordinate offsets
    ///   - anchorTransform: Optional anchor transform for precise positioning
    /// - Returns: CLLocation representing the real-world position
    func calculateRealWorldPosition(
        arOrigin: AROrigin,
        offsets: AROffsets,
        anchorTransform: String? = nil
    ) -> CLLocation {
        // If we have an anchor transform, use it for millimeter precision
        if let transformString = anchorTransform,
           let transform = decodeAnchorTransform(transformString) {

            // Extract translation component from transform matrix
            let translation = SIMD3<Double>(
                Double(transform.columns.3.x),
                Double(transform.columns.3.y),
                Double(transform.columns.3.z)
            )

            // Use anchor transform for precise positioning
            let preciseOffsets = AROffsets.fromSIMD3(translation)

            return calculatePositionFromOffsets(arOrigin, preciseOffsets)
        } else {
            // Use standard offset-based positioning
            return calculatePositionFromOffsets(arOrigin, offsets)
        }
    }

    /// Calculate position using simple offset-based approach
    private func calculatePositionFromOffsets(_ arOrigin: AROrigin, _ offsets: AROffsets) -> CLLocation {
        // This is a simplified calculation - in a real implementation,
        // you'd need to account for Earth's curvature and coordinate system transformations

        // For now, assume small offsets and convert to approximate lat/lng changes
        // 1 degree latitude ≈ 111,000 meters
        // 1 degree longitude ≈ 111,000 * cos(latitude) meters

        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLng = 111000.0 * cos(arOrigin.latitude * .pi / 180.0)

        let deltaLat = offsets.z / metersPerDegreeLat  // Z axis affects latitude
        let deltaLng = offsets.x / metersPerDegreeLng  // X axis affects longitude

        let realLatitude = arOrigin.latitude + deltaLat
        let realLongitude = arOrigin.longitude + deltaLng

        return CLLocation(latitude: realLatitude, longitude: realLongitude)
    }

    /// Calculate AR offsets from a real-world position relative to AR origin
    /// - Parameters:
    ///   - realWorldLocation: The actual GPS location
    ///   - arOrigin: AR session origin location
    /// - Returns: AR offset coordinates
    func calculateAROffsets(from realWorldLocation: CLLocation, relativeTo arOrigin: AROrigin) -> AROffsets {
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLng = 111000.0 * cos(arOrigin.latitude * .pi / 180.0)

        let deltaLat = realWorldLocation.coordinate.latitude - arOrigin.latitude
        let deltaLng = realWorldLocation.coordinate.longitude - arOrigin.longitude

        let offsetX = deltaLng * metersPerDegreeLng  // East-West
        let offsetZ = deltaLat * metersPerDegreeLat  // North-South

        // Y offset (height) is typically 0 for ground-level objects
        return AROffsets(x: offsetX, y: 0.0, z: offsetZ)
    }

    // MARK: - Timestamp Management

    /// Create a placement timestamp for AR object placement
    /// - Returns: Current timestamp suitable for AR placement tracking
    func createPlacementTimestamp() -> Date {
        return Date()
    }

    /// Validate and normalize AR placement timestamp
    /// - Parameter timestamp: The timestamp to validate
    /// - Returns: Validated timestamp or current time if invalid
    func validatePlacementTimestamp(_ timestamp: Date?) -> Date {
        guard let timestamp = timestamp else {
            return createPlacementTimestamp()
        }

        // Basic validation - ensure not too far in future or past
        let now = Date()
        let oneYearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        let oneHourFromNow = now.addingTimeInterval(3600)

        if timestamp < oneYearAgo || timestamp > oneHourFromNow {
            print("⚠️ Invalid AR placement timestamp, using current time: \(timestamp)")
            return now
        }

        return timestamp
    }

    // MARK: - Data Conversion Helpers

    /// Convert LootBoxLocation AR data to service structures
    /// - Parameter location: Location with AR positioning data
    /// - Returns: Tuple of (origin, offsets) or nil if invalid
    func extractARPositioning(from location: LootBoxLocation) -> (origin: AROrigin?, offsets: AROffsets?)? {
        guard let originLat = location.ar_origin_latitude,
              let originLng = location.ar_origin_longitude,
              let offsetX = location.ar_offset_x,
              let offsetY = location.ar_offset_y,
              let offsetZ = location.ar_offset_z else {
            return nil
        }

        let origin = AROrigin(latitude: originLat, longitude: originLng)
        let offsets = AROffsets(x: offsetX, y: offsetY, z: offsetZ)

        return (origin, offsets)
    }

    /// Apply AR positioning data to a LootBoxLocation
    /// - Parameters:
    ///   - location: Location to update (will be modified)
    ///   - origin: AR session origin
    ///   - offsets: AR coordinate offsets
    ///   - anchorTransform: Optional anchor transform string
    ///   - placementTimestamp: Optional placement timestamp
    func applyARPositioning(
        to location: inout LootBoxLocation,
        origin: AROrigin,
        offsets: AROffsets,
        anchorTransform: String? = nil,
        placementTimestamp: Date? = nil
    ) {
        location.ar_origin_latitude = origin.latitude
        location.ar_origin_longitude = origin.longitude
        location.ar_offset_x = offsets.x
        location.ar_offset_y = offsets.y
        location.ar_offset_z = offsets.z
        location.ar_anchor_transform = anchorTransform
        location.ar_placement_timestamp = validatePlacementTimestamp(placementTimestamp)
    }

    /// Clear all AR positioning data from a location
    /// - Parameter location: Location to clear AR data from
    func clearARPositioning(_ location: inout LootBoxLocation) {
        location.ar_origin_latitude = nil
        location.ar_origin_longitude = nil
        location.ar_offset_x = nil
        location.ar_offset_y = nil
        location.ar_offset_z = nil
        location.ar_anchor_transform = nil
        location.ar_placement_timestamp = nil
    }

    // MARK: - Distance and Proximity Calculations

    /// Calculate distance between AR origin and a real-world location
    /// - Parameters:
    ///   - origin: AR session origin
    ///   - location: Real-world location to compare
    /// - Returns: Distance in meters
    func distance(from origin: AROrigin, to location: CLLocation) -> Double {
        return origin.location.distance(from: location)
    }

    /// Check if AR positioning data is still valid for current location
    /// - Parameters:
    ///   - location: Location with AR positioning data
    ///   - currentLocation: Current user location
    ///   - maxDistance: Maximum allowed distance before AR data becomes invalid (default 1000m)
    /// - Returns: True if AR positioning is still valid
    func isARPositioningValid(
        for location: LootBoxLocation,
        currentLocation: CLLocation,
        maxDistance: Double = 1000.0
    ) -> Bool {
        guard let arData = extractARPositioning(from: location) else {
            return false
        }

        let distance = self.distance(from: arData.origin, to: currentLocation)
        return distance <= maxDistance
    }
}
