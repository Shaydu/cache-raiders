import Foundation
import CoreLocation
import Combine
import AVFoundation
import UIKit

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
    weak var lootBoxLocationManager: LootBoxLocationManager? // Reference to loot box location manager for game mode checks
    weak var treasureHuntService: TreasureHuntService? // Reference to treasure hunt service for discovery logic
    private var locationUpdateTimer: Timer? // Timer for automatic periodic location updates
    private var locationUpdateInterval: TimeInterval = 5.0 // Default 5 seconds, will be fetched from server (admin panel setting)
    
    override init() {
        super.init()
        locationManager.delegate = self
        // Use best accuracy for AR precision, but optimize with distance filter
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10.0 // Update every 10 meters (optimized for battery life)
        
        // Listen for location update interval changes via WebSocket
        WebSocketService.shared.onLocationUpdateIntervalChanged = { [weak self] intervalSeconds in
            self?.updateLocationInterval(intervalSeconds)
        }
    }
    
    /// Update location update interval (called when server changes it)
    private func updateLocationInterval(_ intervalSeconds: Double) {
        locationUpdateInterval = intervalSeconds
        print("📍 Location update interval updated via WebSocket: \(intervalSeconds)s")
        
        // Restart timer with new interval if it's already running
        if locationUpdateTimer != nil {
            stopAutomaticLocationUpdates()
            startAutomaticLocationUpdates()
        }
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
        
        // Fetch location update interval from server, then start automatic updates
        Task {
            await fetchLocationUpdateInterval()
            await MainActor.run {
                startAutomaticLocationUpdates()
            }
        }
    }
    
    /// Fetch location update interval from server
    private func fetchLocationUpdateInterval() async {
        do {
            let intervalSeconds = try await APIService.shared.getLocationUpdateInterval()
            await MainActor.run {
                self.locationUpdateInterval = intervalSeconds
                print("📍 Location update interval fetched from server: \(intervalSeconds)s")
            }
        } catch {
            print("⚠️ Failed to fetch location update interval from server, using default 5.0s: \(error)")
            await MainActor.run {
                self.locationUpdateInterval = 5.0 // Default 5 seconds
            }
        }
    }
    
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
        stopAutomaticLocationUpdates()
    }
    
    // Start automatic periodic location updates (for admin panel tracking)
    private func startAutomaticLocationUpdates() {
        // Stop any existing timer
        stopAutomaticLocationUpdates()
        
        // Send location at the configured interval (fetched from server)
        // Run on main thread to ensure UI updates work correctly
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.locationUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.locationUpdateInterval, repeats: true) { [weak self] _ in
                self?.sendCurrentLocationToServer()
            }
            // Add timer to common run loop modes so it works even when scrolling
            if let timer = self.locationUpdateTimer {
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
    // Called automatically at the configured interval, and also manually when user taps the GPS direction box
    // Note: Location updates continue in story mode for admin tracking, using the frequency set in admin panel
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

        // Check for treasure discovery (Dead Men's Secrets mode)
        checkForTreasureDiscovery(at: location)

        // Note: Server updates are sent manually when user taps the GPS direction box
    }

    /// Check if player has arrived at treasure location and trigger IOU discovery
    private func checkForTreasureDiscovery(at currentLocation: CLLocation) {
        guard let treasureHuntService = treasureHuntService,
              let treasureLocation = treasureHuntService.treasureLocation,
              treasureHuntService.hasMap else {
            return // No active treasure hunt or no treasure location set
        }

        // Check if already discovered IOU (don't trigger again)
        // We'll use the server state for this check, but for now assume we can trigger it

        // Calculate distance to treasure
        let distanceToTreasure = currentLocation.distance(from: treasureLocation)
        let discoveryThreshold: Double = 10.0 // 10 meters - close enough to "arrive" at treasure X

        if distanceToTreasure <= discoveryThreshold {
            print("🎯 Player arrived at treasure location! Distance: \(String(format: "%.1f", distanceToTreasure))m")
            print("📜 Triggering IOU discovery...")

            // Trigger IOU discovery
            Task {
                do {
                    try await triggerIOUDiscovery(at: currentLocation)
                } catch {
                    print("❌ Failed to trigger IOU discovery: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Trigger the IOU discovery by calling the server API
    private func triggerIOUDiscovery(at currentLocation: CLLocation) async throws {
        guard let deviceUUID = UIDevice.current.identifierForVendor?.uuidString else {
            throw NSError(domain: "TreasureHunt", code: 1, userInfo: [NSLocalizedDescriptionKey: "No device UUID available"])
        }

        print("📡 Calling IOU discovery API...")

        // Call the API to discover IOU using the public APIService method
        try await APIService.shared.discoverIOU(
            deviceUUID: deviceUUID,
            currentLatitude: currentLocation.coordinate.latitude,
            currentLongitude: currentLocation.coordinate.longitude
        )

        print("✅ IOU discovery API response received")

        // The API response should contain the IOU note and trigger the corgi spawn
        // The corgi spawn is handled by the notification posted from the TreasureHuntService
        // when it processes the API response
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
            case .rangingUnavailable:
                errorDescription = "Ranging unavailable"
                logLevel = "⚠️"
            case .rangingFailure:
                errorDescription = "Ranging failure"
                logLevel = "⚠️"
            case .deferredFailed:
                errorDescription = "Deferred location update failed"
                logLevel = "⚠️"
            case .deferredNotUpdatingLocation:
                errorDescription = "Deferred location update not updating"
                logLevel = "⚠️"
            case .deferredAccuracyTooLow:
                errorDescription = "Deferred location update accuracy too low"
                logLevel = "⚠️"
            case .deferredDistanceFiltered:
                errorDescription = "Deferred location update distance filtered"
                logLevel = "⚠️"
            case .deferredCanceled:
                errorDescription = "Deferred location update canceled"
                logLevel = "⚠️"
            default:
                // Handle any other known or unknown cases
                errorDescription = "CoreLocation error code: \(errorCode)"
                logLevel = "⚠️"
            }
            
            if shouldLog {
                print("\(logLevel) [Location Error] \(errorDescription) (kCLErrorDomain error \(errorCode))")
                let userInfo = (error as NSError).userInfo
                if !userInfo.isEmpty {
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

