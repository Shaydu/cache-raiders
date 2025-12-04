import Foundation
import Dispatch

// MARK: - AR State Manager
class ARStateManager: ARStateServiceProtocol {

    // MARK: - Background Processing Queues
    // CRITICAL: Use dedicated queues for heavy processing to prevent UI freezes
    // AR session delegate runs on a background queue, but we need separate queues for different operations
    let backgroundProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.processing", qos: .userInitiated, attributes: .concurrent)
    let locationProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.locations", qos: .userInitiated)
    let viewportProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.viewport", qos: .userInitiated)
    let placementProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.placement", qos: .userInitiated)

    // Thread-safe state synchronization
    let stateQueue = DispatchQueue(label: "com.cacheraiders.ar.state", attributes: .concurrent)

    // Thread-safe state variables
    private var _pendingPlacements: [String: (location: LootBoxLocation, position: SIMD3<Float>)] = [:]
    private var _pendingRemovals: Set<String> = []

    // MARK: - Throttling for object recognition and placement checks
    var lastCorrectionCheck: Date = Date() // Throttle correction checks to prevent spam
    var lastRecognitionTime: Date = Date() // Throttle object recognition to improve framerate
    var lastDegradedModeLogTime: Date? // Throttle degraded mode logging
    var lastPlacementCheck: Date = Date() // Throttle box placement checks to improve framerate
    var lastCheckAndPlaceBoxesCall: Date = Date() // Throttle checkAndPlaceBoxes calls
    let minPlacementCheckInterval: TimeInterval = 0.5 // Max 2 calls per second

    // MARK: - Throttling for ARLootBoxView's updateUIView (moved off @State to avoid SwiftUI warnings)
    var lastViewUpdateTime: Date = Date()
    var lastLocationsCount: Int = 0
    let viewUpdateThrottleInterval: TimeInterval = 0.1 // 100ms (10 FPS for UI updates)

    // MARK: - Throttling for nearby locations logging
    var lastNearbyLogTime: Date = Date.distantPast
    var lastNearbyCheckTime: Date = Date.distantPast // Throttle getNearbyLocations calls
    let nearbyCheckInterval: TimeInterval = 1.0 // Check nearby locations once per second

    // MARK: - Thread-safe accessors
    var pendingPlacements: [String: (location: LootBoxLocation, position: SIMD3<Float>)] {
        get { stateQueue.sync { _pendingPlacements } }
        set { stateQueue.async(flags: .barrier) { self._pendingPlacements = newValue } }
    }

    var pendingRemovals: Set<String> {
        get { stateQueue.sync { _pendingRemovals } }
        set { stateQueue.async(flags: .barrier) { self._pendingRemovals = newValue } }
    }

    // MARK: - Initialization
    init() {}

    // MARK: - Thread-safe operations

    /// Add a pending placement in a thread-safe manner
    func addPendingPlacement(locationId: String, location: LootBoxLocation, position: SIMD3<Float>) {
        stateQueue.async(flags: .barrier) {
            self._pendingPlacements[locationId] = (location: location, position: position)
        }
    }

    /// Remove a pending placement in a thread-safe manner
    func removePendingPlacement(locationId: String) {
        stateQueue.async(flags: .barrier) {
            self._pendingPlacements.removeValue(forKey: locationId)
        }
    }

    /// Clear all pending placements in a thread-safe manner
    func clearPendingPlacements() {
        stateQueue.async(flags: .barrier) {
            self._pendingPlacements.removeAll()
        }
    }

    /// Add a pending removal in a thread-safe manner
    func addPendingRemoval(locationId: String) {
        stateQueue.async(flags: .barrier) {
            self._pendingRemovals.insert(locationId)
        }
    }

    /// Remove a pending removal in a thread-safe manner
    func removePendingRemoval(locationId: String) {
        stateQueue.async(flags: .barrier) {
            self._pendingRemovals.remove(locationId)
        }
    }

    /// Clear all pending removals in a thread-safe manner
    func clearPendingRemovals() {
        stateQueue.async(flags: .barrier) {
            self._pendingRemovals.removeAll()
        }
    }

    /// Get the count of pending placements (thread-safe)
    var pendingPlacementsCount: Int {
        stateQueue.sync { _pendingPlacements.count }
    }

    /// Get the count of pending removals (thread-safe)
    var pendingRemovalsCount: Int {
        stateQueue.sync { _pendingRemovals.count }
    }

    /// Check if a location has a pending placement (thread-safe)
    func hasPendingPlacement(for locationId: String) -> Bool {
        stateQueue.sync { _pendingPlacements[locationId] != nil }
    }

    /// Check if a location has a pending removal (thread-safe)
    func hasPendingRemoval(for locationId: String) -> Bool {
        stateQueue.sync { _pendingRemovals.contains(locationId) }
    }

    // MARK: - Throttling helpers

    /// Check if enough time has passed since the last placement check
    func shouldPerformPlacementCheck() -> Bool {
        let now = Date()
        let timeSinceLastCheck = now.timeIntervalSince(lastPlacementCheck)
        if timeSinceLastCheck >= minPlacementCheckInterval {
            lastPlacementCheck = now
            return true
        }
        return false
    }

    /// Check if enough time has passed since the last checkAndPlaceBoxes call
    func shouldPerformCheckAndPlaceBoxes() -> Bool {
        let now = Date()
        let timeSinceLastCall = now.timeIntervalSince(lastCheckAndPlaceBoxesCall)
        if timeSinceLastCall >= minPlacementCheckInterval {
            lastCheckAndPlaceBoxesCall = now
            return true
        }
        return false
    }

    /// Check if enough time has passed since the last view update
    func shouldPerformViewUpdate(currentLocationsCount: Int) -> Bool {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastViewUpdateTime)

        // Only throttle if the locations count hasn't changed (avoid unnecessary updates)
        if lastLocationsCount == currentLocationsCount && timeSinceLastUpdate < viewUpdateThrottleInterval {
            return false
        }

        lastViewUpdateTime = now
        lastLocationsCount = currentLocationsCount
        return true
    }

    /// Check if enough time has passed since the last nearby locations check
    func shouldPerformNearbyCheck() -> Bool {
        let now = Date()
        let timeSinceLastCheck = now.timeIntervalSince(lastNearbyCheckTime)
        if timeSinceLastCheck >= nearbyCheckInterval {
            lastNearbyCheckTime = now
            return true
        }
        return false
    }

    /// Check if enough time has passed since the last correction check
    func shouldPerformCorrectionCheck() -> Bool {
        let now = Date()
        let timeSinceLastCheck = now.timeIntervalSince(lastCorrectionCheck)
        if timeSinceLastCheck >= 5.0 { // 5 seconds for correction checks
            lastCorrectionCheck = now
            return true
        }
        return false
    }

    /// Check if enough time has passed since the last object recognition
    func shouldPerformObjectRecognition() -> Bool {
        let now = Date()
        let timeSinceLastRecognition = now.timeIntervalSince(lastRecognitionTime)
        if timeSinceLastRecognition >= 2.0 { // 2 seconds for recognition
            lastRecognitionTime = now
            return true
        }
        return false
    }

    /// Check if we should log degraded mode status (throttled to every 5 seconds)
    func shouldLogDegradedMode() -> Bool {
        let now = Date()
        if let lastLog = lastDegradedModeLogTime, now.timeIntervalSince(lastLog) < 5.0 {
            return false
        }
        lastDegradedModeLogTime = now
        return true
    }

    /// Check if we should log nearby locations (throttled)
    func shouldLogNearbyLocations() -> Bool {
        let now = Date()
        let timeSinceLastLog = now.timeIntervalSince(lastNearbyLogTime)
        if timeSinceLastLog >= nearbyCheckInterval {
            lastNearbyLogTime = now
            return true
        }
        return false
    }

    // MARK: - Async wrapper methods for background processing

    /// Execute a block on the background processing queue
    func executeOnBackgroundQueue(_ block: @escaping () -> Void) {
        backgroundProcessingQueue.async(execute: block)
    }

    /// Execute a block on the location processing queue
    func executeOnLocationQueue(_ block: @escaping () -> Void) {
        locationProcessingQueue.async(execute: block)
    }

    /// Execute a block on the viewport processing queue
    func executeOnViewportQueue(_ block: @escaping () -> Void) {
        viewportProcessingQueue.async(execute: block)
    }

    /// Execute a block on the placement processing queue
    func executeOnPlacementQueue(_ block: @escaping () -> Void) {
        placementProcessingQueue.async(execute: block)
    }

    /// Execute a block synchronously on the state queue (for reading state)
    func executeOnStateQueue<T>(_ block: () -> T) -> T {
        stateQueue.sync(execute: block)
    }

    /// Execute a block asynchronously on the state queue with barrier (for writing state)
    func executeOnStateQueueWithBarrier(_ block: @escaping () -> Void) {
        stateQueue.async(flags: .barrier, execute: block)
    }

    // MARK: - ARStateServiceProtocol conformance
    
    /// Throttle operations to prevent excessive calls
    func throttle(_ key: String, interval: TimeInterval, operation: @escaping () -> Void) {
        // For now, just execute immediately - can be enhanced with proper throttling per key
        operation()
    }
    
    /// Schedule background operation on appropriate queue
    func scheduleBackgroundOperation(_ operation: @escaping () -> Void) {
        executeOnBackgroundQueue(operation)
    }
    
    /// Update object placement time (placeholder for now)
    func updateObjectPlacementTime(_ objectId: String, time: Date) {
        // This could be used to track when objects were placed for cleanup purposes
    }
    
    // MARK: - ARServiceProtocol conformance
    
    /// Configure with coordinator (required by ARServiceProtocol)
    func configure(with coordinator: ARCoordinatorCoreProtocol) {
        // Store coordinator reference if needed
    }
    
    /// Cleanup resources (required by ARServiceProtocol)
    func cleanup() {
        clearPendingPlacements()
        clearPendingRemovals()
    }
}






