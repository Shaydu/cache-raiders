import Foundation
import CoreLocation
import simd

// MARK: - AR Geospatial Service
/// Implements the practical AR+GPS architecture:
/// 1. Use ARKit VIO for device pose (runtime tracking)
/// 2. Use GNSS only to initialize world origin (not per-frame)
/// 3. Convert GPS to ENU (East-North-Up) coordinate frame
/// 4. Place AR anchors at ENU positions
/// 5. Apply smooth corrections when better GPS arrives (no teleporting)
/// 6. Use barometer/elevation for better altitude
/// 7. Fallback to visual plane detection
class ARGeospatialService {
    
    /// ENU (East-North-Up) coordinate frame origin
    /// Set once from first reliable GNSS fix, never changed
    private var enuOrigin: CLLocation?
    
    /// AR session origin (where AR session started, 0,0,0 in AR space)
    /// This is the VIO tracking origin
    private var arSessionOrigin: SIMD3<Float>?
    
    /// Ground level at AR origin (fixed reference for altitude)
    private var arOriginGroundLevel: Float?
    
    /// Current correction offset (for smooth corrections when better GPS arrives)
    private var correctionOffset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    
    /// Whether we're in degraded mode (no GPS)
    private var isDegradedMode: Bool = false
    
    /// Minimum GPS accuracy required to set origin (meters)
    private let minGPSAccuracy: Double = 7.5
    
    /// Maximum correction distance before applying (prevents large jumps)
    private let maxCorrectionDistance: Float = 2.0 // 2 meters
    
    init() {
        Swift.print("📍 ARGeospatialService initialized")
    }
    
    // MARK: - Origin Initialization
    
    /// Sets the ENU origin from first reliable GNSS fix
    /// This should be called once when AR session starts with good GPS
    /// - Parameter gpsLocation: GPS location with good accuracy (< 7.5m)
    /// - Returns: True if origin was set, false if already set or accuracy too low
    func setENUOrigin(from gpsLocation: CLLocation) -> Bool {
        // Only set if not already set (origin is fixed once)
        guard enuOrigin == nil else {
            Swift.print("⚠️ ENU origin already set - cannot change")
            return false
        }
        
        // Require good GPS accuracy
        guard gpsLocation.horizontalAccuracy >= 0 && gpsLocation.horizontalAccuracy < minGPSAccuracy else {
            Swift.print("⚠️ GPS accuracy too low for ENU origin: \(String(format: "%.2f", gpsLocation.horizontalAccuracy))m (need < \(minGPSAccuracy)m)")
            return false
        }
        
        enuOrigin = gpsLocation
        isDegradedMode = false
        
        Swift.print("✅ ENU Origin SET at: (\(String(format: "%.8f", gpsLocation.coordinate.latitude)), \(String(format: "%.8f", gpsLocation.coordinate.longitude)))")
        Swift.print("   GPS accuracy: \(String(format: "%.2f", gpsLocation.horizontalAccuracy))m")
        Swift.print("   Altitude: \(String(format: "%.2f", gpsLocation.altitude))m")
        Swift.print("   ⚠️ Origin is FIXED - will not change")
        
        return true
    }
    
    /// Sets the AR session origin (VIO tracking origin)
    /// This is where ARKit's coordinate system starts (0,0,0)
    /// - Parameter arPosition: Position in AR session coordinate frame
    /// - Parameter groundLevel: Ground level at AR origin (for altitude reference)
    func setARSessionOrigin(arPosition: SIMD3<Float>, groundLevel: Float) {
        arSessionOrigin = arPosition
        arOriginGroundLevel = groundLevel
        
        Swift.print("📍 AR Session Origin set at: (\(String(format: "%.2f", arPosition.x)), \(String(format: "%.2f", arPosition.y)), \(String(format: "%.2f", arPosition.z)))")
        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED)")
    }
    
    /// Enters degraded mode (AR-only, no GPS)
    /// Sets ground level from visual plane detection
    func enterDegradedMode(groundLevel: Float) {
        isDegradedMode = true
        arOriginGroundLevel = groundLevel
        
        Swift.print("⚠️ ENTERED DEGRADED MODE (AR-only, no GPS)")
        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED)")
    }
    
    // MARK: - GPS to ENU Conversion
    
    /// Converts GPS coordinates to ENU (East-North-Up) coordinates
    /// ENU: +E = East, +N = North, +U = Up (altitude)
    /// - Parameter gpsLocation: GPS location to convert
    /// - Returns: ENU coordinates (E, N, U) in meters, or nil if origin not set
    func convertGPSToENU(_ gpsLocation: CLLocation) -> SIMD3<Double>? {
        guard let origin = enuOrigin else {
            Swift.print("⚠️ ENU origin not set - cannot convert GPS to ENU")
            return nil
        }
        
        // Calculate distance and bearing from origin
        let distance = origin.distance(from: gpsLocation)
        let bearing = origin.bearing(to: gpsLocation)
        
        // Convert bearing (0° = North, clockwise) to ENU
        // ENU: +E = East, +N = North
        let bearingRad = bearing * .pi / 180.0
        
        // East component (X in ENU)
        let east = distance * sin(bearingRad)
        
        // North component (Y in ENU, but we'll use Z for North in AR)
        let north = distance * cos(bearingRad)
        
        // Up component (altitude difference)
        let up = gpsLocation.altitude - origin.altitude
        
        let enu = SIMD3<Double>(east, north, up)
        
        Swift.print("📍 GPS to ENU: (\(String(format: "%.4f", east)), \(String(format: "%.4f", north)), \(String(format: "%.4f", up)))m")
        
        return enu
    }
    
    // MARK: - ENU to AR Coordinate Conversion
    
    /// Converts ENU coordinates to AR session coordinates
    /// ARKit uses: +X = East, +Y = Up, +Z = -North (right-handed)
    /// ENU uses: +E = East, +N = North, +U = Up
    /// - Parameter enu: ENU coordinates (E, N, U)
    /// - Returns: AR coordinates (X, Y, Z) in meters
    func convertENUToAR(_ enu: SIMD3<Double>) -> SIMD3<Float> {
        // ARKit coordinate system:
        // +X = East (same as ENU East)
        // +Y = Up (same as ENU Up)
        // +Z = -North (opposite of ENU North)
        
        let arX = Float(enu.x)  // East
        let arY = Float(enu.z)   // Up (altitude) - but we'll use ground level for Y
        let arZ = -Float(enu.y)  // -North (ARKit convention)
        
        // Use fixed ground level for Y coordinate (not GPS altitude)
        // GPS altitude is unreliable, so we use detected ground level
        let finalY: Float
        if let groundLevel = arOriginGroundLevel {
            // For horizontal placement, use ground level
            // For objects that need altitude, we could add the ENU up component
            finalY = groundLevel
        } else {
            // Fallback to ENU up component if no ground level
            finalY = arY
        }
        
        return SIMD3<Float>(arX, finalY, arZ)
    }
    
    /// Converts GPS directly to AR coordinates (convenience method)
    /// - Parameter gpsLocation: GPS location to convert
    /// - Returns: AR coordinates (X, Y, Z) in meters, or nil if origin not set
    func convertGPSToAR(_ gpsLocation: CLLocation) -> SIMD3<Float>? {
        guard let enu = convertGPSToENU(gpsLocation) else {
            return nil
        }
        
        return convertENUToAR(enu)
    }
    
    // MARK: - Smooth Corrections
    
    /// Applies a smooth correction when better GPS arrives
    /// Computes the difference and applies it gradually (no teleporting)
    /// - Parameter betterGPS: New GPS location with better accuracy
    /// - Returns: Correction offset to apply, or nil if correction not needed
    func computeSmoothCorrection(from betterGPS: CLLocation) -> SIMD3<Float>? {
        guard let origin = enuOrigin else {
            return nil
        }
        
        // Only apply correction if new GPS is significantly better
        guard betterGPS.horizontalAccuracy < origin.horizontalAccuracy else {
            return nil
        }
        
        // Calculate what the origin should be with better GPS
        // We don't change the origin, but we compute an offset
        let distance = origin.distance(from: betterGPS)
        let bearing = origin.bearing(to: betterGPS)
        
        // If correction is too large, don't apply it (prevents jumps)
        if Float(distance) > maxCorrectionDistance {
            Swift.print("⚠️ Correction too large (\(String(format: "%.2f", distance))m) - skipping to prevent jump")
            return nil
        }
        
        // Convert to ENU offset
        let bearingRad = bearing * .pi / 180.0
        let eastOffset = Float(distance * sin(bearingRad))
        let northOffset = Float(distance * cos(bearingRad))
        let upOffset = Float(betterGPS.altitude - origin.altitude)
        
        let enuOffset = SIMD3<Double>(Double(eastOffset), Double(northOffset), Double(upOffset))
        let arOffset = convertENUToAR(enuOffset)
        
        Swift.print("🔧 Smooth correction computed: (\(String(format: "%.4f", arOffset.x)), \(String(format: "%.4f", arOffset.y)), \(String(format: "%.4f", arOffset.z)))m")
        Swift.print("   Old GPS accuracy: \(String(format: "%.2f", origin.horizontalAccuracy))m")
        Swift.print("   New GPS accuracy: \(String(format: "%.2f", betterGPS.horizontalAccuracy))m")
        
        return arOffset
    }
    
    // MARK: - Getters
    
    var hasENUOrigin: Bool {
        return enuOrigin != nil
    }
    
    var hasARSessionOrigin: Bool {
        return arSessionOrigin != nil
    }
    
    var currentGroundLevel: Float? {
        return arOriginGroundLevel
    }
    
    var isInDegradedMode: Bool {
        return isDegradedMode
    }
}

// MARK: - Note: CLLocation bearing(to:) extension already exists in LootBoxLocation.swift
// Using the existing implementation to avoid redeclaration

