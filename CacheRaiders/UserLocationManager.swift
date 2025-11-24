import Foundation
import CoreLocation
import Combine
import AVFoundation

// MARK: - User Location Manager
class UserLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published var currentLocation: CLLocation?
    @Published var heading: Double? // Direction of travel in degrees (0 = north, 90 = east, etc.)
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isSendingLocation: Bool = false // Track when location is being sent to server
    @Published var lastLocationSentSuccessfully: Date? // Track when location was successfully received by server
    private var isSendingInProgress: Bool = false // Prevent concurrent sends
    weak var arCoordinator: ARCoordinator? // Reference to AR coordinator for enhanced location
    private var locationUpdateTimer: Timer? // Timer for automatic periodic location updates
    
    override init() {
        super.init()
        locationManager.delegate = self
        // Use best accuracy for AR precision, but optimize with distance filter
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10.0 // Update every 10 meters (optimized for battery life)
    }
    
    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            print("⚠️ Location permission not granted")
            return
        }
        locationManager.startUpdatingLocation()
        
        // Start automatic periodic location updates for admin panel (every 5 seconds)
        startAutomaticLocationUpdates()
    }
    
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
        stopAutomaticLocationUpdates()
    }
    
    // Start automatic periodic location updates (for admin panel tracking)
    private func startAutomaticLocationUpdates() {
        // Stop any existing timer
        stopAutomaticLocationUpdates()
        
        // Send location every 5 seconds automatically (matches admin panel polling interval)
        // Run on main thread to ensure UI updates work correctly
        DispatchQueue.main.async { [weak self] in
            self?.locationUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.sendCurrentLocationToServer()
            }
            // Add timer to common run loop modes so it works even when scrolling
            if let timer = self?.locationUpdateTimer {
                RunLoop.current.add(timer, forMode: .common)
            }
        }
    }
    
    // Stop automatic location updates
    private func stopAutomaticLocationUpdates() {
        locationUpdateTimer?.invalidate()
        locationUpdateTimer = nil
    }
    
    // Send current location to server (for admin map display)
    // Called automatically every 5 seconds, and also manually when user taps the GPS direction box
    func sendCurrentLocationToServer() {
        // Prevent concurrent sends
        guard !isSendingInProgress else {
            return
        }
        
        guard let location = currentLocation else {
            return
        }
        
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let acc = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        let hdg = heading
        
        // Try to get AR-enhanced location (more accurate)
        var finalLat = lat
        var finalLng = lng
        var arOffsetX: Double? = nil
        var arOffsetY: Double? = nil
        var arOffsetZ: Double? = nil
        
        let debugModeEnabled = UserDefaults.standard.bool(forKey: "showARDebugVisuals")
        
        if let arEnhanced = arCoordinator?.getAREnhancedLocation() {
            finalLat = arEnhanced.latitude
            finalLng = arEnhanced.longitude
            arOffsetX = arEnhanced.arOffsetX
            arOffsetY = arEnhanced.arOffsetY
            arOffsetZ = arEnhanced.arOffsetZ
            if debugModeEnabled {
                print("📍 [Location Push] Using AR-enhanced location: (\(String(format: "%.6f", finalLat)), \(String(format: "%.6f", finalLng))), AR offset: (\(String(format: "%.3f", arOffsetX!)), \(String(format: "%.3f", arOffsetY!)), \(String(format: "%.3f", arOffsetZ!)))m")
            }
        } else if debugModeEnabled {
            print("📍 [Location Push] Using GPS location: (\(String(format: "%.6f", lat)), \(String(format: "%.6f", lng))), accuracy: \(acc != nil ? String(format: "%.1f", acc!) : "nil")m, heading: \(hdg != nil ? String(format: "%.0f", hdg!) : "nil")°")
        }
        
        // Set sending state to true
        isSendingLocation = true
        isSendingInProgress = true
        
        // Play ping sound if debug mode is enabled
        if debugModeEnabled {
            AudioPingService.shared.playLocationPing()
        }
        
        Task {
            do {
                try await APIService.shared.updateUserLocation(
                    latitude: finalLat,
                    longitude: finalLng,
                    accuracy: acc,
                    heading: hdg,
                    arOffsetX: arOffsetX,
                    arOffsetY: arOffsetY,
                    arOffsetZ: arOffsetZ
                )
                
                if debugModeEnabled {
                    print("✅ [Location Push] Successfully pushed location to server")
                }
                
                // Mark as successfully received
                await MainActor.run {
                    lastLocationSentSuccessfully = Date()
                }
            } catch {
                if debugModeEnabled {
                    print("❌ [Location Push] Failed to push location: \(error.localizedDescription)")
                    if let apiError = error as? APIError {
                        print("   Error type: \(apiError)")
                    }
                }
            }
            
            // Reset sending state after a short delay to show the blue ring briefly
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                isSendingLocation = false
                isSendingInProgress = false
            }
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Only update local state - server updates are sent manually when user taps GPS direction box
        currentLocation = location
        
        // Extract heading from location's course (direction of travel)
        // Course is in degrees: 0 = north, 90 = east, 180 = south, 270 = west
        // Only use course if it's valid (>= 0 means valid direction)
        if location.course >= 0 {
            heading = location.course
        }
        
        // Note: Server updates are sent manually when user taps the GPS direction box
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError {
            let errorCode = clError.code.rawValue
            var errorDescription = "Unknown location error"
            var shouldLog = true // Whether to log this error
            var logLevel = "❌" // Error level indicator
            
            switch clError.code {
            case .locationUnknown:
                // This is often a transient error - GPS is still acquiring signal
                // Only log if we don't have a current location (otherwise it's just a temporary blip)
                if currentLocation == nil {
                    errorDescription = "Location unknown - GPS acquiring signal"
                    logLevel = "⚠️"
                } else {
                    // We have a location, so this is likely just a transient error - don't log it
                    shouldLog = false
                }
            case .denied:
                // Only log denied errors if we actually don't have permission
                // Sometimes CoreLocation reports denied errors transiently even when permission is granted
                if authorizationStatus != .authorizedWhenInUse && authorizationStatus != .authorizedAlways {
                    errorDescription = "Location access denied - check permissions"
                } else {
                    // We have permission, so this is likely a false positive or transient error
                    errorDescription = "Location temporarily unavailable (permission granted)"
                    logLevel = "⚠️"
                }
            case .network:
                errorDescription = "Network error - unable to get location"
                logLevel = "⚠️"
            case .headingFailure:
                // Heading failures are common and not critical - use warning level
                errorDescription = "Heading unavailable - direction of travel not available"
                logLevel = "⚠️"
            case .regionMonitoringDenied:
                errorDescription = "Region monitoring denied"
            case .regionMonitoringFailure:
                errorDescription = "Region monitoring failure"
                logLevel = "⚠️"
            case .regionMonitoringSetupDelayed:
                errorDescription = "Region monitoring setup delayed"
                logLevel = "⚠️"
            case .regionMonitoringResponseDelayed:
                errorDescription = "Region monitoring response delayed"
                logLevel = "⚠️"
            case .geocodeFoundNoResult:
                errorDescription = "Geocode found no result"
                logLevel = "⚠️"
            case .geocodeFoundPartialResult:
                errorDescription = "Geocode found partial result"
                logLevel = "⚠️"
            case .geocodeCanceled:
                // Geocode cancellation is usually intentional - don't log as error
                shouldLog = false
            @unknown default:
                errorDescription = "Unknown CoreLocation error code: \(errorCode)"
            }
            
            if shouldLog {
                print("\(logLevel) [Location Error] \(errorDescription) (kCLErrorDomain error \(errorCode))")
                if let userInfo = (error as NSError).userInfo as? [String: Any], !userInfo.isEmpty {
                    print("   Error details: \(userInfo)")
                }
            }
        } else {
            print("❌ [Location Error] \(error.localizedDescription)")
            print("   Error type: \(type(of: error))")
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdatingLocation()
        }
    }
    
    deinit {
        stopAutomaticLocationUpdates()
    }
}

