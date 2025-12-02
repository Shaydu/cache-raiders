import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import AVFoundation
import AudioToolbox
import Vision
import Combine
import UIKit

// Findable protocol and base class are now in FindableObject.swift

// MARK: - AR Coordinator
class ARCoordinator: NSObject, ARSessionDelegate {

    // Managers
    private var environmentManager: AREnvironmentManager?
    private var occlusionManager: AROcclusionManager?
    private var objectRecognizer: ARObjectRecognizer?
    private var distanceTracker: ARDistanceTracker?
    private var tapHandler: ARTapHandler?
    private var databaseIndicatorService: ARDatabaseIndicatorService?
    private var groundingService: ARGroundingService?
    private var precisionPositioningService: ARPrecisionPositioningService? // Legacy - kept for compatibility
    private var geospatialService: ARGeospatialService? // New ENU-based geospatial service
    private var treasureHuntService: TreasureHuntService? // Treasure hunt game mode service
    private var npcService: ARNPCService? // NPC management service
    var stateManager: ARStateManager? // State management for throttling and coordination

    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var placedBoxes: [String: AnchorEntity] = [:]
    private var findableObjects: [String: FindableObject] = [:] // Track all findable objects
    private var objectPlacementTimes: [String: Date] = [:] // Track when objects were placed (for grace period)
    // MARK: - NPC Types
    enum NPCType: String, CaseIterable {
        case skeleton = "skeleton"
        case corgi = "corgi"
        
        var modelName: String {
            switch self {
            case .skeleton: return "Curious_skeleton"
            case .corgi: return "Corgi_Traveller"
            }
        }
        
        var npcId: String {
            switch self {
            case .skeleton: return "skeleton-1"
            case .corgi: return "corgi-1"
            }
        }
        
        var defaultName: String {
            switch self {
            case .skeleton: return "Captain Bones"
            case .corgi: return "Corgi Traveller"
            }
        }
        
        var npcType: String {
            switch self {
            case .skeleton: return "skeleton"
            case .corgi: return "traveller"
            }
        }
        
        var isSkeleton: Bool {
            return self == .skeleton
        }
    }
    
    private var placedNPCs: [String: AnchorEntity] = [:] // Track all placed NPCs by ID
    private var skeletonPlaced: Bool = false // Track if skeleton has been placed
    private var corgiPlaced: Bool = false // Track if corgi has been placed
    private var skeletonAnchor: AnchorEntity? // Reference to skeleton anchor (kept for backward compatibility)
    private let SKELETON_NPC_ID = "skeleton-1" // ID for the skeleton NPC
    
    // MARK: - Skeleton Size Constants (defined in one place)
    // Target: 6-7 feet tall (1.83-2.13m) in AR space
    // Assuming base model is ~1.4m at scale 1.0, scale of 1.4 gives ~1.96m (6.4 feet)
    private static let SKELETON_SCALE: Float = 1.4 // Results in approximately 6.5 feet tall skeleton
    private static let SKELETON_COLLISION_SIZE = SIMD3<Float>(0.66, 2.0, 0.66) // Scaled proportionally for 6-7ft skeleton
    private static let SKELETON_HEIGHT_OFFSET: Float = 1.65 // Scaled proportionally
    private var hasTalkedToSkeleton: Bool = false // Track if player has talked to skeleton
    private var collectedMapPieces: Set<Int> = [] // Track which map pieces player has collected (1 = skeleton, 2 = corgi)
    private var arOriginLocation: CLLocation? // GPS location when AR session started
    private var arOriginSetTime: Date? // When AR origin was set (for degraded mode timeout)
    private var isDegradedMode: Bool = false // True if operating without GPS (AR-only mode)
    private var arOriginGroundLevel: Float? // Fixed ground level at AR origin (never changes)
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var collectionNotificationBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    var conversationNPCBinding: Binding<ConversationNPC?>?
    private var lastSpherePlacementTime: Date? // Prevent rapid duplicate sphere placements
    private var sphereModeActive: Bool = false // Track when we're in sphere randomization mode
    private var hasAutoRandomized: Bool = false // Track if we've already auto-randomized spheres
    var shouldForceReplacement: Bool = false // Force re-placement after reset when AR is ready
    var lastAppliedLensId: String? = nil // Track last applied AR lens to prevent redundant session resets

    // PERFORMANCE: Disable verbose placement logging (causes freezing when many objects)
    private let verbosePlacementLogging = false // Set to true only when debugging placement issues

    // Arrow direction tracking
    @Published var nearestObjectDirection: Double? = nil // Direction in degrees (0 = north, 90 = east, etc.)
    
    // Viewport visibility tracking for chime sounds
    private var objectsInViewport: Set<String> = [] // Track which objects are currently visible
    private var lastViewportCheck: Date = Date() // Throttle viewport checks to improve framerate
    
    // Throttling for object recognition and placement checks
    private var lastCorrectionCheck: Date = Date() // Throttle correction checks to prevent spam
    private var lastRecognitionTime: Date = Date() // Throttle object recognition to improve framerate
    private var lastDegradedModeLogTime: Date? // Throttle degraded mode logging
    private var lastPlacementCheck: Date = Date() // Throttle box placement checks to improve framerate
    private var lastCheckAndPlaceBoxesCall: Date = Date() // Throttle checkAndPlaceBoxes calls
    private let minPlacementCheckInterval: TimeInterval = 0.5 // Max 2 calls per second
    
    // Throttling for ARLootBoxView's updateUIView (moved off @State to avoid SwiftUI warnings)
    var lastViewUpdateTime: Date = Date()
    var lastLocationsCount: Int = 0
    let viewUpdateThrottleInterval: TimeInterval = 0.1 // 100ms (10 FPS for UI updates)
    
    // Throttling for nearby locations logging
    private var lastNearbyLogTime: Date = Date.distantPast
    private var lastNearbyCheckTime: Date = Date.distantPast // Throttle getNearbyLocations calls
    private let nearbyCheckInterval: TimeInterval = 1.0 // Check nearby locations once per second
    
    // Dialog state tracking - pause AR session when sheet is open
    private var isDialogOpen: Bool = false {
        didSet {
            if isDialogOpen != oldValue {
                if isDialogOpen {
                    pauseARSession()
                } else {
                    resumeARSession()
                }
            }
        }
    }
    
    // Store AR configuration for resuming
    private var savedARConfiguration: ARWorldTrackingConfiguration?
    
    // MARK: - Background Processing Queues
    // CRITICAL: Use dedicated queues for heavy processing to prevent UI freezes
    // AR session delegate runs on a background queue, but we need separate queues for different operations
    private let backgroundProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.processing", qos: .userInitiated, attributes: .concurrent)
    private let locationProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.locations", qos: .userInitiated)
    private let viewportProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.viewport", qos: .userInitiated)
    private let placementProcessingQueue = DispatchQueue(label: "com.cacheraiders.ar.placement", qos: .userInitiated)
    
    // Thread-safe state synchronization
    private let stateQueue = DispatchQueue(label: "com.cacheraiders.ar.state", attributes: .concurrent)
    private var _pendingPlacements: [String: (location: LootBoxLocation, position: SIMD3<Float>)] = [:]
    private var _pendingRemovals: Set<String> = []
    
    // Thread-safe accessors
    private var pendingPlacements: [String: (location: LootBoxLocation, position: SIMD3<Float>)] {
        get { stateQueue.sync { _pendingPlacements } }
        set { stateQueue.async(flags: .barrier) { self._pendingPlacements = newValue } }
    }
    
    private var pendingRemovals: Set<String> {
        get { stateQueue.sync { _pendingRemovals } }
        set { stateQueue.async(flags: .barrier) { self._pendingRemovals = newValue } }
    }
    
    override init() {
        super.init()
    }
    
    /// Play a chime sound when an object enters the viewport
    /// Uses a different, gentler sound than the treasure found sound
    private func playViewportChime(for locationId: String) {
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session for chime: \(error)")
        }
        
        // Get object details for logging
        let location = locationManager?.locations.first(where: { $0.id == locationId })
        let objectName = location?.name ?? "Unknown"
        let objectType = location?.type.displayName ?? "Unknown Type"
        
        // Use a gentle system notification sound for viewport entry
        // System sound 1103 is a soft, pleasant notification chime
        // This is different from the treasure found sound (level-up-01.mp3)
        AudioServicesPlaySystemSound(1103) // Soft notification sound for viewport entry
        Swift.print("🔔 SOUND: Viewport chime (system sound 1103)")

        // Single haptic "bump" when a findable object enters the viewport
        DispatchQueue.main.async {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }

        Swift.print("   Trigger: Object entered viewport")
        Swift.print("   Object: \(objectName) (\(objectType))")
        Swift.print("   Location ID: \(locationId)")
    }
    
    /// Check if an object is currently visible in the viewport
    private func isObjectInViewport(locationId: String, anchor: AnchorEntity) -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return false }
        
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
        let _ = length(cameraToObject) // Distance check (unused but calculated for future use)
        
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
        
        // Add a small margin to account for object size (objects slightly off-screen still count)
        let margin: CGFloat = 50.0 // 50 point margin
        
        // Break down the complex expression into sub-expressions to help compiler type-checking
        let xInBounds = screenPoint.x >= -margin && screenPoint.x <= viewWidth + margin
        let yInBounds = screenPoint.y >= -margin && screenPoint.y <= viewHeight + margin
        let isInViewport = xInBounds && yInBounds
        
        return isInViewport
    }
    
    /// Check viewport visibility for all placed objects and play chime when objects enter
    /// PERFORMANCE: Optimized to limit checks and avoid expensive operations
    private func checkViewportVisibility() {
        guard let arView = arView else { return }
        
        // PERFORMANCE: Limit viewport checks to prevent freeze with many objects
        // Only check up to 20 objects per frame (prioritize nearby objects)
        let maxChecksPerFrame = 20
        var checkedCount = 0
        
        var currentlyVisible: Set<String> = []
        
        // Check visibility for each placed object (limited to prevent freeze)
        for (locationId, anchor) in placedBoxes {
            // PERFORMANCE: Limit checks per frame
            if checkedCount >= maxChecksPerFrame {
                break
            }
            checkedCount += 1
            
            // Skip if already found/collected
            if distanceTracker?.foundLootBoxes.contains(locationId) ?? false {
                continue
            }
            
            // Check if object is in viewport
            if isObjectInViewport(locationId: locationId, anchor: anchor) {
                currentlyVisible.insert(locationId)
                
                // If object just entered viewport (wasn't visible before), play chime and log details
                if !objectsInViewport.contains(locationId) {
                    playViewportChime(for: locationId)
                    
                    // Get object details for logging (cached lookup to avoid expensive search)
                    let location = locationManager?.locations.first(where: { $0.id == locationId })
                    let objectName = location?.name ?? "Unknown"
                    let objectType = location?.type.displayName ?? "Unknown Type"
                    
                    // Calculate distance if user location is available
                    var distanceInfo = ""
                    if let userLocation = userLocationManager?.currentLocation,
                       let location = location {
                        let distance = userLocation.distance(from: location.location)
                        distanceInfo = String(format: " (%.1fm away)", distance)
                    }
                    
                    // Get screen position for additional context
                    let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                    let objectPosition = SIMD3<Float>(
                        anchorTransform.columns.3.x,
                        anchorTransform.columns.3.y,
                        anchorTransform.columns.3.z
                    )
                    if let screenPoint = arView.project(objectPosition) {
                        Swift.print("👁️ Object entered viewport: '\(objectName)' (\(objectType))\(distanceInfo) [ID: \(locationId)]")
                        Swift.print("   Screen position: (x: \(String(format: "%.1f", screenPoint.x)), y: \(String(format: "%.1f", screenPoint.y)))")
                    } else {
                        Swift.print("👁️ Object entered viewport: '\(objectName)' (\(objectType))\(distanceInfo) [ID: \(locationId)]")
                    }
                }
            }
        }
        
        // Update tracked visible objects
        objectsInViewport = currentlyVisible
    }
    
    // Conversation manager reference
    private weak var conversationManager: ARConversationManager?

    func setupARView(_ arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearbyLocations: Binding<[LootBoxLocation]>, distanceToNearest: Binding<Double?>, temperatureStatus: Binding<String?>, collectionNotification: Binding<String?>, nearestObjectDirection: Binding<Double?>, conversationNPC: Binding<ConversationNPC?>, conversationManager: ARConversationManager, treasureHuntService: TreasureHuntService? = nil) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.nearbyLocationsBinding = nearbyLocations
        self.distanceToNearestBinding = distanceToNearest
        self.temperatureStatusBinding = temperatureStatus
        self.collectionNotificationBinding = collectionNotification
        self.nearestObjectDirectionBinding = nearestObjectDirection
        self.conversationNPCBinding = conversationNPC
        self.conversationManager = conversationManager

        // Use provided treasure hunt service or create new one
        // Note: In ContentView, we create a shared instance so state persists
        if self.treasureHuntService == nil {
            self.treasureHuntService = TreasureHuntService()
            self.treasureHuntService?.setConversationManager(conversationManager)
        }

        // Size changes not supported - objects are randomized on placement
        // locationManager.onSizeChanged callback removed
        
        // Set up callback to remove objects from AR when collected by other users
        locationManager.onObjectCollectedByOtherUser = { [weak self] objectId in
            self?.handleObjectCollectedByOtherUser(objectId: objectId)
        }
        
        // Set up callback to re-place objects when they are uncollected
        locationManager.onObjectUncollected = { [weak self] objectId in
            self?.handleObjectUncollected(objectId: objectId)
        }
        
        // Set up NPC sync handlers for two-way sync with admin
        setupNPCSyncHandlers()
        
        // Store the GPS location when AR starts (this becomes our AR world origin)
        arOriginLocation = userLocationManager.currentLocation
        
        // Set AR coordinator reference in user location manager for enhanced location tracking
        userLocationManager.arCoordinator = self
        
        // Listen for notifications from ARPlacementView when objects are saved
        // This triggers immediate placement so objects appear right after placement view dismisses
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleARPlacementObjectSaved),
            name: NSNotification.Name("ARPlacementObjectSaved"),
            object: nil
        )
        
        // Listen for sheet presentation notifications to pause/resume AR session
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogOpened),
            name: NSNotification.Name("SheetPresented"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogClosed),
            name: NSNotification.Name("SheetDismissed"),
            object: nil
        )
        
        // Initialize managers
        environmentManager = AREnvironmentManager(arView: arView, locationManager: locationManager)
        // Only initialize object recognizer if enabled (saves battery/processing)
        if locationManager.enableObjectRecognition {
            objectRecognizer = ARObjectRecognizer()
            Swift.print("🔍 Object recognition enabled")
        } else {
            Swift.print("🔍 Object recognition disabled (saves battery/processing)")
        }
        distanceTracker = ARDistanceTracker(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager, treasureHuntService: treasureHuntService)
        occlusionManager = AROcclusionManager(arView: arView, locationManager: locationManager, distanceTracker: distanceTracker)
        tapHandler = ARTapHandler(arView: arView, locationManager: locationManager)
        databaseIndicatorService = ARDatabaseIndicatorService()
        groundingService = ARGroundingService(arView: arView)
        precisionPositioningService = ARPrecisionPositioningService(arView: arView) // Legacy
        geospatialService = ARGeospatialService() // New ENU-based service
        stateManager = ARStateManager() // State management for throttling and coordination

        // Configure environment lighting for proper shading and colors
        // Increase intensity to ensure objects are well-lit and colors are visible
        arView.environment.lighting.intensityExponent = 1.5

        // Start periodic grounding checks to ensure objects stay on surfaces
        // This continuously monitors for better surface data and re-grounds objects when found
        startPeriodicGrounding()

        // Configure managers with shared state
        occlusionManager?.placedBoxes = placedBoxes
        distanceTracker?.placedBoxes = placedBoxes
        distanceTracker?.distanceToNearestBinding = distanceToNearest
        distanceTracker?.temperatureStatusBinding = temperatureStatus
        distanceTracker?.nearestObjectDirectionBinding = nearestObjectDirection
        tapHandler?.placedBoxes = placedBoxes
        tapHandler?.findableObjects = findableObjects
        tapHandler?.collectionNotificationBinding = collectionNotification
        tapHandler?.placedNPCs = placedNPCs // Pass NPCs to tap handler
        
        // Set up tap handler callbacks
        tapHandler?.onFindLootBox = { [weak self] locationId, anchor, cameraPos, sphereEntity in
            self?.findLootBox(locationId: locationId, anchor: anchor, cameraPosition: cameraPos, sphereEntity: sphereEntity)
        }
        tapHandler?.onPlaceLootBoxAtTap = { [weak self] location, result in
            self?.placeLootBoxAtTapLocation(location, tapResult: result, in: arView)
        }
        tapHandler?.onNPCTap = { [weak self] npcId in
            // Convert NPC ID string to NPCType
            if let npcType = NPCType.allCases.first(where: { $0.npcId == npcId }) {
                self?.handleNPCTap(type: npcType)
            } else {
                Swift.print("⚠️ Unknown NPC ID: \(npcId)")
            }
        }
        
        // Monitor AR session
        arView.session.delegate = self
        
        // Start distance logging
        distanceTracker?.startDistanceLogging()
        
        // Clean up any existing occlusion planes once at startup
        occlusionManager?.removeAllOcclusionPlanes()
        
        // Start occlusion checking
        occlusionManager?.startOcclusionChecking()
        
        // Apply ambient light setting
        environmentManager?.updateAmbientLight()
    }
    
    /// Handle when an object is collected by another user - remove it from AR scene
    private func handleObjectCollectedByOtherUser(objectId: String) {
        guard arView != nil else { return }
        
        // Check if this object is currently placed in AR
        guard let anchor = placedBoxes[objectId] else {
            Swift.print("ℹ️ Object \(objectId) collected by another user but not currently in AR scene")
            return
        }
        
        // Get object name for logging
        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"
        
        Swift.print("🗑️ Removing object '\(objectName)' (ID: \(objectId)) from AR - collected by another user")
        
        // Remove from AR scene
        anchor.removeFromParent()
        
        // Remove from tracking dictionaries
        placedBoxes.removeValue(forKey: objectId)
        findableObjects.removeValue(forKey: objectId)
        objectsInViewport.remove(objectId)
        
        // Also remove from distance tracker if applicable
        distanceTracker?.foundLootBoxes.insert(objectId)
        if let textEntity = distanceTracker?.distanceTextEntities[objectId] {
            textEntity.removeFromParent()
            distanceTracker?.distanceTextEntities.removeValue(forKey: objectId)
        }
        
        Swift.print("✅ Object '\(objectName)' removed from AR scene")
    }
    
    /// Handle when an object is uncollected (marked as unfound) - clear found sets and re-place it
    private func handleObjectUncollected(objectId: String) {
        guard arView != nil else { return }
        
        // Get object name for logging
        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"
        
        Swift.print("🔄 Object uncollected: '\(objectName)' (ID: \(objectId)) - clearing found sets and re-placing")
        
        // CRITICAL: Clear from found sets so object can be placed again
        distanceTracker?.foundLootBoxes.remove(objectId)
        tapHandler?.foundLootBoxes.remove(objectId)
        
        // Remove from AR scene if it's currently placed (so it can be re-placed)
        if let anchor = placedBoxes[objectId] {
            anchor.removeFromParent()
            placedBoxes.removeValue(forKey: objectId)
            findableObjects.removeValue(forKey: objectId)
            objectsInViewport.remove(objectId)
            objectPlacementTimes.removeValue(forKey: objectId)
            Swift.print("   ✅ Removed object from AR scene - will be re-placed on next checkAndPlaceBoxes")
        }
        
        // Trigger immediate re-placement if we have user location
        if let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            // Check if this object is in nearby locations
            if nearby.contains(where: { $0.id == objectId }) {
                Swift.print("   🔄 Object is nearby - triggering immediate re-placement")
                checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
            } else {
                Swift.print("   ℹ️ Object is not nearby (outside search radius) - will appear when you get closer")
            }
        }
    }
    
    // Clear found loot boxes set - makes objects tappable again after reset
    func clearFoundLootBoxes() {
        distanceTracker?.clearFoundLootBoxes()
        tapHandler?.foundLootBoxes.removeAll()
    }
    
    // Remove all placed objects from AR scene and clear tracking dictionaries
    // This allows objects to be re-placed at their proper GPS locations after reset
    func removeAllPlacedObjects() {
        guard arView != nil else { return }
        
        Swift.print("🔄 Removing all \(placedBoxes.count) placed objects from AR scene...")
        
        // Remove all anchors from the scene
        for (_, anchor) in placedBoxes {
            anchor.removeFromParent()
        }
        
        // Clear tracking dictionaries
        placedBoxes.removeAll()
        findableObjects.removeAll()
        
        // Clear viewport visibility tracking
        objectsInViewport.removeAll()
        
        // Also clear found loot boxes tracking
        clearFoundLootBoxes()
        
        // Set flag to force re-placement when AR tracking is ready
        shouldForceReplacement = true
        
        Swift.print("✅ All placed objects removed - ready for re-placement at proper locations")
    }
    
    // Update scene ambient lighting based on settings
    func updateAmbientLight() {
        environmentManager?.updateAmbientLight()
    }
    
    // MARK: - Distance Tracking (delegated to ARDistanceTracker)
    // MARK: - Object Recognition (delegated to ARObjectRecognizer)
    
    deinit {
        distanceTracker?.stopDistanceLogging()
        occlusionManager?.stopOcclusionChecking()
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ARPlacementObjectSaved"), object: nil)
        stopPeriodicGrounding()
    }

    /// Timer for periodic grounding checks
    private var groundingTimer: Timer?

    /// Track when we last checked grounding for each object (to avoid excessive raycasting)
    private var lastGroundingCheck: [String: Date] = [:]

    /// Starts periodic grounding checks to ensure objects stay on surfaces
    /// DISABLED: Periodic grounding causes objects to move when camera moves
    /// Objects are now placed once and never moved to ensure stability
    private func startPeriodicGrounding() {
        // DISABLED: Periodic grounding causes drift
        // Objects are placed at final positions and never modified
        // This ensures maximum stability and prevents objects from moving when camera moves
        Swift.print("⏸️ Periodic grounding DISABLED - objects stay fixed at placement position for maximum stability")
    }

    /// Stops periodic grounding checks
    private func stopPeriodicGrounding() {
        groundingTimer?.invalidate()
        groundingTimer = nil
        Swift.print("⏹️ Stopped periodic grounding checks")
    }

    /// Performs a grounding check on all placed objects
    /// DISABLED: This function is disabled to prevent objects from moving after placement
    /// Objects are placed once at their final position and never modified
    private func performGroundingCheck() {
        // DISABLED: Moving objects after placement causes drift
        // Objects maintain their exact placement position for maximum stability
    }

    /// Re-grounds all placed objects immediately (called when new planes detected)
    /// DISABLED: This function is disabled to prevent objects from moving after placement
    /// Objects are placed once at their final position and never modified
    private func regroundAllObjects() {
        // DISABLED: Moving objects after placement causes drift
        // Objects maintain their exact placement position for maximum stability
        Swift.print("⏸️ Re-grounding disabled - objects stay fixed at placement position")
    }
    
    /// Enters degraded AR-only mode when GPS is unavailable
    /// In this mode, objects are placed relative to AR origin (0,0,0) without GPS coordinates
    private func enterDegradedMode(cameraPos: SIMD3<Float>, frame: ARFrame) {
        guard arOriginLocation == nil else { return } // Already set
        
        isDegradedMode = true

        // CRITICAL FIX: Use best available GPS location even in degraded mode
        // This allows GPS-based objects to be placed with reduced accuracy instead of not at all
        if let userLocation = userLocationManager?.currentLocation {
            // Use current GPS location even if accuracy is poor
            arOriginLocation = userLocation

            // Set up geospatial service with this GPS location
            if geospatialService?.setENUOrigin(from: userLocation) == true {
                Swift.print("📍 Degraded mode: Using GPS with reduced accuracy")
                Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                Swift.print("   Location: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
            }
        } else {
            // No GPS available - cannot place GPS-based objects
            arOriginLocation = nil
            Swift.print("📍 Degraded mode: No GPS available - AR-only objects only")
        }
        arOriginSetTime = Date()

        // Set fixed ground level using surface detection or camera estimate
        let groundLevel: Float
        if let surfaceY = groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
            groundLevel = surfaceY
            Swift.print("📍 Degraded mode: Ground level from surface detection: \(String(format: "%.2f", groundLevel))m")
        } else {
            groundLevel = cameraPos.y - 1.5
            Swift.print("📍 Degraded mode: Ground level estimated: \(String(format: "%.2f", groundLevel))m")
        }

        arOriginGroundLevel = groundLevel
        geospatialService?.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
        precisionPositioningService?.setAROriginGroundLevel(groundLevel) // Legacy compatibility

        Swift.print("⚠️ ENTERED DEGRADED MODE (reduced GPS accuracy)")
        Swift.print("   Objects will be placed relative to AR origin")
        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED - never changes)")
        Swift.print("   GPS-based objects will be placed with reduced accuracy")
        Swift.print("   AR-only objects (tap-to-place, randomize) will work normally")
    }
    
    /// Legacy function - kept for compatibility but disabled
    private func regroundAllObjectsLegacy() {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        for (_, anchor) in placedBoxes {
            // Get anchor's current position
            let anchorTransform = anchor.transformMatrix(relativeTo: nil)
            let currentX = anchorTransform.columns.3.x
            let currentZ = anchorTransform.columns.3.z
            let _ = anchorTransform.columns.3.y

            // Try to find a surface at this X/Z position
            if let _ = groundingService?.findHighestBlockingSurface(x: currentX, z: currentZ, cameraPos: cameraPos) {
                // DISABLED: Never re-ground objects - they should stay exactly where they were placed
                // Objects should NEVER move after being placed, especially for the user who placed them
                // Kept surface lookup for potential future diagnostics, but no mutation occurs here.
            }
        }
    }
    
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        // STORY MODE: Remove all findables and prevent new placements
        let gameMode = locationManager?.gameMode ?? .open
        let isStoryMode = gameMode == .deadMensSecrets
        
        if isStoryMode {
            // In story modes, only NPCs are shown - remove all findable objects (loot boxes, turkeys, etc.)
            // NPCs are handled separately in session(_:didUpdate:) method
            guard arView != nil else {
                return
            }
            
            // Remove all loot boxes/findables from AR scene in story modes
            let findablesToRemove = placedBoxes.keys.filter { locationId in
                // Keep NPCs (they're tracked in placedNPCs, not placedBoxes)
                // But remove all findable objects (turkey, chests, etc.)
                return !(placedNPCs.keys.contains(locationId))
            }
            
            for locationId in findablesToRemove {
                if let anchor = placedBoxes[locationId] {
                    let locationName = locationManager?.locations.first(where: { $0.id == locationId })?.name ?? locationId
                    Swift.print("🗑️ Removing findable '\(locationName)' (ID: \(locationId)) from story mode - only NPCs allowed")
                    anchor.removeFromParent()
                    placedBoxes.removeValue(forKey: locationId)
                    findableObjects.removeValue(forKey: locationId)
                    objectsInViewport.remove(locationId)
                    objectPlacementTimes.removeValue(forKey: locationId)
                }
            }
            
            // Early return - no new loot boxes should be placed in story modes
            return
        }
        
        // PERFORMANCE: Throttle calls to prevent excessive placement checks
        let now = Date()
        let timeSinceLastCall = now.timeIntervalSince(lastCheckAndPlaceBoxesCall)
        guard timeSinceLastCall >= minPlacementCheckInterval else {
            // Too soon since last call - skip this check to prevent freeze
            return
        }
        lastCheckAndPlaceBoxesCall = now

        let startTime = CFAbsoluteTimeGetCurrent()
        guard let arView = arView else {
            Swift.print("⚠️ checkAndPlaceBoxes: No ARView available")
            return
        }

        Swift.print("🔍 checkAndPlaceBoxes called: \(nearbyLocations.count) nearby, \(placedBoxes.count) already placed")
        Swift.print("   AR origin set: \(arOriginLocation != nil), Degraded mode: \(isDegradedMode)")
        Swift.print("   Total locations in manager: \(locationManager?.locations.count ?? 0)")
        Swift.print("   Max search distance: \(locationManager?.maxSearchDistance ?? 0)m")
        Swift.print("   Max object limit: \(locationManager?.maxObjectLimit ?? 0)")
        if let userLoc = userLocationManager?.currentLocation {
            Swift.print("   User GPS: (\(String(format: "%.6f", userLoc.coordinate.latitude)), \(String(format: "%.6f", userLoc.coordinate.longitude))), accuracy: \(String(format: "%.1f", userLoc.horizontalAccuracy))m")
        } else {
            Swift.print("   ⚠️ User GPS location not available!")
        }

        // Log details about each nearby location
        for (index, loc) in nearbyLocations.enumerated() {
            let alreadyPlaced = placedBoxes[loc.id] != nil
            Swift.print("   📍 Nearby[\(index)]: '\(loc.name)' (type: \(loc.type.displayName), source: \(loc.source), collected: \(loc.collected), alreadyPlaced: \(alreadyPlaced))")
            if loc.latitude != 0 || loc.longitude != 0 {
                Swift.print("      GPS: (\(String(format: "%.6f", loc.latitude)), \(String(format: "%.6f", loc.longitude)))")
            } else {
                Swift.print("      GPS: (0, 0) - AR-only placement")
            }
            if let arX = loc.ar_offset_x, let arY = loc.ar_offset_y, let arZ = loc.ar_offset_z {
                Swift.print("      AR offsets: (\(String(format: "%.4f", arX)), \(String(format: "%.4f", arY)), \(String(format: "%.4f", arZ)))")
            }
        }

        // PERFORMANCE: Logging disabled - print statements are EXTREMELY expensive (blocks main thread)
        // 677 print statements in codebase causing major freezing
        // Only log critical errors and performance metrics
        // let debugLogging = false // Disable verbose logging - removed dead code to fix warnings

        // CRITICAL: Only remove objects that are no longer in the nearbyLocations list AND are not manually placed
        // Manually placed objects (with AR coordinates) should NEVER be removed or moved
        let nearbyLocationIds = Set(nearbyLocations.map { $0.id })
        var objectsToRemove: [String] = []
        var manuallyPlacedObjects: Set<String> = []

        // PERFORMANCE: Build location lookup map once to avoid O(n) searches in loop
        let locationMap = Dictionary(uniqueKeysWithValues: (locationManager?.locations ?? []).map { ($0.id, $0) })
        
        for (locationId, _) in placedBoxes {
            // CRITICAL: First check if object is collected - remove it immediately regardless of other checks
            // This ensures collected objects are always removed, even if they're not in locationMap yet
            // Check multiple sources: locationMap, locationManager, and foundLootBoxes sets
            var shouldRemove = false
            var reason = ""
            
            // Check 1: Is in foundLootBoxes set? (most reliable - set when collected)
            if distanceTracker?.foundLootBoxes.contains(locationId) ?? false {
                shouldRemove = true
                reason = "found in distanceTracker.foundLootBoxes"
            }
            // Check 2: Is in tapHandler's foundLootBoxes?
            else if tapHandler?.foundLootBoxes.contains(locationId) ?? false {
                shouldRemove = true
                reason = "found in tapHandler.foundLootBoxes"
            }
            // Check 3: Is collected in locationMap?
            else if let existingLocation = locationMap[locationId], existingLocation.collected {
                shouldRemove = true
                reason = "collected in locationMap"
            }
            // Check 4: Is collected in locationManager? (fallback if not in locationMap)
            else if let locationManager = locationManager,
                    let existingLocation = locationManager.locations.first(where: { $0.id == locationId }),
                    existingLocation.collected {
                shouldRemove = true
                reason = "collected in locationManager"
            }
            
            if shouldRemove {
                let locationName = locationMap[locationId]?.name ?? locationManager?.locations.first(where: { $0.id == locationId })?.name ?? locationId
                Swift.print("🗑️ Removing collected object '\(locationName)' (ID: \(locationId)) from AR scene - \(reason)")
                objectsToRemove.append(locationId)
                continue
            }
            
            // Check if this object was manually placed (has AR coordinates OR AR source)
            // Manually placed objects should NEVER be removed OR re-placed (unless collected, which we handled above)
            // PERFORMANCE: Use dictionary lookup instead of first(where:) - O(1) vs O(n)
            var isManuallyPlaced = false

            if let existingLocation = locationMap[locationId] {
                
                let hasARCoordinates = existingLocation.ar_offset_x != nil &&
                                      existingLocation.ar_offset_y != nil &&
                                      existingLocation.ar_offset_z != nil

                let isARPlaced = existingLocation.source == .arManual ||
                                existingLocation.source == .arRandomized

                if hasARCoordinates || isARPlaced {
                    isManuallyPlaced = true
                    manuallyPlacedObjects.insert(locationId)
                }
            } else {
                // Object is in placedBoxes but not in locationMap yet
                // This can happen for newly placed objects that haven't been synced to locationManager yet
                // Check if it has AR coordinates stored in UserDefaults (from ARPlacementView)
                let arPositionKey = "ARPlacementPosition_\(locationId)"
                if UserDefaults.standard.dictionary(forKey: arPositionKey) != nil {
                    // This object was manually placed and has AR coordinates - protect it
                    isManuallyPlaced = true
                    manuallyPlacedObjects.insert(locationId)
                    Swift.print("🛡️ Protecting newly placed object (ID: \(locationId)) - has AR coordinates but not in locationMap yet")
                }
            }

            // If this placed object is not in the current nearby locations list, check if it should be removed
            if !nearbyLocationIds.contains(locationId) {
                // Never remove manually placed objects (unless they're collected, which we already handled above)
                if isManuallyPlaced {
                    continue
                }
                
                // CRITICAL: Give newly placed objects a grace period (5 seconds) before removing them
                // This prevents objects from disappearing immediately after placement while they're being synced to locationManager
                if let placementTime = objectPlacementTimes[locationId] {
                    let timeSincePlacement = Date().timeIntervalSince(placementTime)
                    if timeSincePlacement < 5.0 {
                        Swift.print("🛡️ Protecting newly placed object (ID: \(locationId)) - placed \(String(format: "%.1f", timeSincePlacement))s ago, grace period: 5s")
                        continue
                    }
                }

                // Only remove objects that weren't manually placed and are past the grace period
                objectsToRemove.append(locationId)
            }
        }

        // Remove the unselected objects from the scene (but never manually placed ones)
        for locationId in objectsToRemove {
            if let anchor = placedBoxes[locationId] {
                anchor.removeFromParent()
                placedBoxes.removeValue(forKey: locationId)
                findableObjects.removeValue(forKey: locationId)
                objectsInViewport.remove(locationId)
                objectPlacementTimes.removeValue(forKey: locationId) // Clean up placement time
            }
        }

        // Allow GPS-based loot boxes even when spheres are active
        // Limit to maximum objects (configurable in settings, default 6)
        let maxObjects = locationManager?.maxObjectLimit ?? 6
        
        // Count unfound objects that should be placed
        let unfoundLocations = nearbyLocations.filter { loc in
            !loc.collected &&
            !(distanceTracker?.foundLootBoxes.contains(loc.id) ?? false) &&
            !(tapHandler?.foundLootBoxes.contains(loc.id) ?? false) &&
            placedBoxes[loc.id] == nil &&
            !(loc.latitude == 0 && loc.longitude == 0) &&
            !((loc.source == .arManual || loc.source == .arRandomized) && 
              (loc.ar_offset_x == nil || loc.ar_offset_y == nil || loc.ar_offset_z == nil))
        }
        
        Swift.print("📊 Placement analysis:")
        Swift.print("   Total nearby: \(nearbyLocations.count)")
        Swift.print("   Unfound & placeable: \(unfoundLocations.count)")
        Swift.print("   Already placed: \(placedBoxes.count)")
        Swift.print("   Max limit: \(maxObjects)")
        Swift.print("   Can place: \(maxObjects - placedBoxes.count) more")
        
        if placedBoxes.count >= maxObjects {
            Swift.print("⏭️ Max object limit reached: \(placedBoxes.count)/\(maxObjects) objects already placed")
            Swift.print("   💡 Increase max object limit in settings or remove some objects to place more")
            if unfoundLocations.count > 0 {
                Swift.print("   ⚠️ \(unfoundLocations.count) unfound object(s) waiting to be placed: \(unfoundLocations.map { $0.name }.joined(separator: ", "))")
            }
            return
        }

        // Note: Story mode check happens at the top of this function - we return early if in story mode
        // So all code below only executes in open mode
        
        for location in nearbyLocations {
            // Stop if we've reached the limit
            guard placedBoxes.count < maxObjects else {
                break
            }

            // Skip locations that are already placed (double-check to prevent duplicates)
            // CRITICAL: Never re-place objects that are already placed - they should stay fixed
            // This is especially important for manually placed objects with AR coordinates
            if placedBoxes[location.id] != nil {
                continue
            }

            // Skip tap-created locations (lat: 0, lon: 0) - they're placed manually via tap
            // These should not be placed again by checkAndPlaceBoxes
            if location.latitude == 0 && location.longitude == 0 {
                Swift.print("⏭️ Skipping tap-created object '\(location.name)' (lat/lon 0,0) - placed manually")
                continue
            }

            // CRITICAL: Skip AR-placed objects that don't have valid ar_offset coordinates yet
            // These objects are still being set up and will be placed by ARPlacementView
            if (location.source == .arManual || location.source == .arRandomized) {
                let hasValidAROffsets = location.ar_offset_x != nil &&
                                       location.ar_offset_y != nil &&
                                       location.ar_offset_z != nil
                if !hasValidAROffsets {
                    Swift.print("⏭️ Skipping AR-placed object '\(location.name)' - waiting for ar_offset coordinates")
                    continue
                }
            }

            // Skip if already collected (critical check to prevent re-placement after finding)
            // Check multiple sources to ensure we don't place collected objects
            let isInFoundSets = distanceTracker?.foundLootBoxes.contains(location.id) ?? false || tapHandler?.foundLootBoxes.contains(location.id) ?? false
            if location.collected || isInFoundSets {
                if location.collected {
                    Swift.print("⏭️ Skipping collected object '\(location.name)' (ID: \(location.id)) - location.collected = true")
                } else if isInFoundSets {
                    Swift.print("⏭️ Skipping object '\(location.name)' (ID: \(location.id)) - still in foundLootBoxes sets (should be cleared when uncollected)")
                    Swift.print("   💡 Try marking as unfound again or restart the app to clear found sets")
                }
                continue
            }
            
            // Log that we're attempting to place this object
            Swift.print("✅ Attempting to place unfound object '\(location.name)' (ID: \(location.id), type: \(location.type.displayName))")
            
            // CRITICAL: Check for GPS collision - if another object with same/similar GPS coordinates is already placed OR in the current batch
            // Instead of skipping, offset the location by 5m in a random direction
            var locationToPlace = location
            if location.latitude != 0 && location.longitude != 0 {
                let newLoc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                var offsetApplied = false
                
                // First check against already-placed objects
                for (existingId, _) in placedBoxes {
                    // Find the location for this existing object
                    if let existingLocation = nearbyLocations.first(where: { $0.id == existingId }) {
                        // Check if GPS coordinates are very close (within 1 meter)
                        let existingLoc = CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude)
                        let gpsDistance = existingLoc.distance(from: newLoc)

                        if gpsDistance < 1.0 {
                            // Offset by 5 meters in a random direction
                            let randomBearing = Double.random(in: 0..<360) // Random direction 0-360 degrees
                            let offsetCoordinate = newLoc.coordinate.coordinate(atDistance: 5.0, atBearing: randomBearing)
                            
                            // Create a new location with offset coordinates
                            locationToPlace = LootBoxLocation(
                                id: location.id,
                                name: location.name,
                                type: location.type,
                                latitude: offsetCoordinate.latitude,
                                longitude: offsetCoordinate.longitude,
                                radius: location.radius,
                                collected: location.collected,
                                source: location.source
                            )
                            // Copy AR-related properties if they exist
                            locationToPlace.grounding_height = location.grounding_height
                            locationToPlace.ar_origin_latitude = location.ar_origin_latitude
                            locationToPlace.ar_origin_longitude = location.ar_origin_longitude
                            locationToPlace.ar_offset_x = location.ar_offset_x
                            locationToPlace.ar_offset_y = location.ar_offset_y
                            locationToPlace.ar_offset_z = location.ar_offset_z
                            locationToPlace.ar_placement_timestamp = location.ar_placement_timestamp

                            offsetApplied = true
                            break
                        }
                    }
                }

                // Also check against other locations in the current batch (to prevent placing duplicates in same loop)
                if !offsetApplied {
                    for otherLocation in nearbyLocations {
                        // Skip self and already-placed objects (we checked those above)
                        if otherLocation.id == location.id || placedBoxes[otherLocation.id] != nil {
                            continue
                        }

                        // Check if GPS coordinates are very close (within 1 meter)
                        let otherLoc = CLLocation(latitude: otherLocation.latitude, longitude: otherLocation.longitude)
                        let gpsDistance = newLoc.distance(from: otherLoc)

                        if gpsDistance < 1.0 {
                            // Offset by 5 meters in a random direction
                            let randomBearing = Double.random(in: 0..<360) // Random direction 0-360 degrees
                            let offsetCoordinate = newLoc.coordinate.coordinate(atDistance: 5.0, atBearing: randomBearing)
                            
                            // Create a new location with offset coordinates
                            locationToPlace = LootBoxLocation(
                                id: location.id,
                                name: location.name,
                                type: location.type,
                                latitude: offsetCoordinate.latitude,
                                longitude: offsetCoordinate.longitude,
                                radius: location.radius,
                                collected: location.collected,
                                source: location.source
                            )
                            // Copy AR-related properties if they exist
                            locationToPlace.grounding_height = location.grounding_height
                            locationToPlace.ar_origin_latitude = location.ar_origin_latitude
                            locationToPlace.ar_origin_longitude = location.ar_origin_longitude
                            locationToPlace.ar_offset_x = location.ar_offset_x
                            locationToPlace.ar_offset_y = location.ar_offset_y
                            locationToPlace.ar_offset_z = location.ar_offset_z
                            locationToPlace.ar_placement_timestamp = location.ar_placement_timestamp

                            offsetApplied = true
                            break
                        }
                    }
                }
            }

            // Skip AR-only items that are already placed (they're placed directly in randomizeLootBoxes)
            // BUT: Don't skip spheres with valid GPS coordinates - they should be placed via GPS
            // Spheres from the API/map have GPS coordinates and should appear in AR
            if location.isAROnly && location.type != .sphere {
                continue
            }

            // Determine placement method based on type
            // Use locationToPlace (which may have been offset to avoid GPS collisions)
            if locationToPlace.type == .sphere {
                // Spheres with GPS coordinates should be placed via GPS positioning
                if locationToPlace.latitude != 0 || locationToPlace.longitude != 0 {
                    Swift.print("   📍 Placing sphere: \(locationToPlace.name) at GPS (\(locationToPlace.latitude), \(locationToPlace.longitude))")
                    placeARSphereAtLocation(locationToPlace, in: arView)
                } else {
                    // Sphere with no GPS - skip it (should be placed via randomizeLootBoxes)
                    Swift.print("   ⏭️ Skipping sphere with no GPS: \(locationToPlace.name)")
                    continue
                }
            } else {
                Swift.print("   📍 Placing \(locationToPlace.type.displayName): \(locationToPlace.name) at GPS (\(locationToPlace.latitude), \(locationToPlace.longitude))")
                placeLootBoxAtLocation(locationToPlace, in: arView)
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Swift.print("⏱️ [PERF] checkAndPlaceBoxes took \(String(format: "%.1f", elapsed))ms for \(nearbyLocations.count) nearby locations")
        Swift.print("📊 Final status: \(placedBoxes.count) objects placed in AR scene")
        Swift.print("   Objects in AR: \(placedBoxes.keys.sorted())")
    }


    // Regenerate loot boxes at random locations in the AR room
    func randomizeLootBoxes() {
        print("🎲 RANDOMIZE TRIGGERED - Starting sphere placement...")

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            Swift.print("⚠️ Cannot randomize: AR not ready")
            return
        }

        // Enter sphere mode - prevent GPS boxes
        sphereModeActive = true
        hasAutoRandomized = true // Mark as having randomized (whether auto or manual)

        print("🗑️ Removing \(placedBoxes.count) existing spheres...")
        // Remove all existing placed boxes
        for (_, anchor) in placedBoxes {
            anchor.removeFromParent()
        }
        placedBoxes.removeAll()
        findableObjects.removeAll() // Also clear findable objects

        // Also remove old randomly-generated AR item locations from locationManager to reset the counter
        // Keep GPS-based locations and manually-added map markers
        let oldCount = locationManager.locations.count
        locationManager.locations.removeAll { location in
            // Remove temporary AR-only items (randomized), but keep map-added items
            location.isTemporary && location.isAROnly
        }
        let removedCount = oldCount - locationManager.locations.count
        print("🗑️ Removed \(removedCount) old random AR item locations from locationManager")

        // Generate exactly 3 new loot boxes at random positions (since we only allow 3 total)
        let numberOfBoxes = 3
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Add time-based offset to ensure different results each randomization
        let timeOffset = Float(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100.0))
        Swift.print("🎲 Time-based randomization offset: \(String(format: "%.2f", timeOffset))")

        // Create a virtual "random center" that's offset from the actual camera position
        // This ensures different placement patterns even when starting from the same location
        let centerOffsetDistance = Float.random(in: 0...2.0) // Up to 2m offset
        let centerOffsetAngle = Float.random(in: 0...(2 * Float.pi))
        let randomCenterX = cameraPos.x + centerOffsetDistance * cos(centerOffsetAngle)
        let randomCenterZ = cameraPos.z + centerOffsetDistance * sin(centerOffsetAngle)
        let randomCenter = SIMD3<Float>(randomCenterX, cameraPos.y, randomCenterZ)

        Swift.print("🎲 Using random center at (\(String(format: "%.2f", randomCenterX)), \(String(format: "%.2f", randomCenterZ))) instead of camera position")

        // TEMPORARILY DISABLE indoor detection to ensure spheres spawn
        // TODO: Re-enable with better logic once spheres are working reliably
        let isIndoors = false // Always use outdoor placement for now
        Swift.print("🏠 Environment detection: DISABLED (using outdoor placement)")
        Swift.print("   Starting placement...")

        // Adjust placement strategy based on environment
        let (minDistance, maxDistance, placementStrategy) = getPlacementStrategy(isIndoors: isIndoors, searchDistance: Float(locationManager.maxSearchDistance))

        Swift.print("🎲 Randomizing \(numberOfBoxes) loot boxes (\(placementStrategy))...")

        var placedCount = 0
        var attempts = 0
        let maxAttempts = numberOfBoxes * 15 // Allow more attempts for complex indoor placement
        
        while placedCount < numberOfBoxes && attempts < maxAttempts {
            attempts += 1

            var randomX: Float
            var randomZ: Float

            // Simplified placement for reliable sphere spawning
            let randomDistance = Float.random(in: minDistance...maxDistance)
            let randomAngle = Float.random(in: 0...(2 * Float.pi))

            // Add time-based variation to ensure different results each session
            let angleOffset = timeOffset * 0.1 // Small angle variation based on time
            let adjustedAngle = randomAngle + angleOffset

            // Use random center instead of camera position for more varied placement
            randomX = randomCenter.x + randomDistance * cos(adjustedAngle)
            randomZ = randomCenter.z + randomDistance * sin(adjustedAngle)

            // Find the highest blocking surface (floor or table above floor)
            // If no surface detected, use default height and rely on periodic grounding to fix later
            let surfaceY: Float
            var usedDefaultHeight = false
            if let detectedY = groundingService?.findHighestBlockingSurface(x: randomX, z: randomZ, cameraPos: cameraPos) {
                surfaceY = detectedY
                Swift.print("✅ Found surface at attempt \(attempts) - Y: \(String(format: "%.2f", surfaceY))")
            } else {
                // Use default ground height - object will be adjusted later by periodic grounding
                let objectTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest, .sphere, .cube]
                let selectedType = objectTypes.randomElement() ?? .sphere
                surfaceY = groundingService?.getDefaultGroundHeight(for: selectedType, cameraPos: cameraPos) ?? (cameraPos.y - 1.5)
                usedDefaultHeight = true
                Swift.print("⚠️ No surface at attempt \(attempts) - using default height Y=\(String(format: "%.2f", surfaceY)) (will auto-adjust later)")
            }

            let cameraY = cameraPos.y

            // Reject surfaces too far away (more than 2m above or below camera)
            // BUT allow default heights since they're calculated relative to camera
            let heightDiff = abs(surfaceY - cameraY)
            if !usedDefaultHeight && heightDiff > 2.0 {
                Swift.print("⚠️ Surface too far rejected at attempt \(attempts) - surfaceY: \(String(format: "%.2f", surfaceY)), cameraY: \(String(format: "%.2f", cameraY)), diff: \(String(format: "%.2f", heightDiff))")
                continue
            }
            
            let boxPosition = SIMD3<Float>(randomX, surfaceY, randomZ)
            let distanceFromCamera = length(boxPosition - cameraPos)

            // CRITICAL: Enforce MINIMUM 1m distance from camera to prevent objects spawning on camera
            if distanceFromCamera < 1.0 {
                Swift.print("⚠️ Too close to camera rejected at attempt \(attempts) - distance: \(String(format: "%.2f", distanceFromCamera))m")
                continue
            }

            if distanceFromCamera < minDistance || distanceFromCamera > maxDistance {
                Swift.print("⚠️ Distance out of range rejected at attempt \(attempts) - distance: \(String(format: "%.2f", distanceFromCamera))m, min: \(String(format: "%.2f", minDistance))m, max: \(String(format: "%.2f", maxDistance))m")
                continue
            }
            
            // Check if too close to other boxes
            var tooClose = false
            for (_, existingAnchor) in placedBoxes {
                let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
                let existingPos = SIMD3<Float>(
                    existingTransform.columns.3.x,
                    existingTransform.columns.3.y,
                    existingTransform.columns.3.z
                )
                let distanceToExisting = length(boxPosition - existingPos)
                if distanceToExisting < 3.0 {
                    Swift.print("⚠️ Too close to existing box rejected at attempt \(attempts) - distance: \(String(format: "%.2f", distanceToExisting))m")
                    tooClose = true
                    break
                }
            }

            if tooClose {
                continue
            }
            
            // Create a new temporary location for this object
            // Use completely unique IDs to avoid any confusion with map locations
            // Randomly select object type for variety
            let objectTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest, .lootChest, .turkey, .sphere, .cube]
            let selectedType = objectTypes.randomElement() ?? .chalice
            
            // Use the factory's itemDescription() to get the proper name for this type
            // This ensures each type gets its unique description (e.g., "Golden Chalice" not just "Chalice")
            let factory = selectedType.factory
            let baseName = factory.itemDescription()

            // Add unique suffix to prevent duplicate names
            // Use the placement count to ensure uniqueness
            let itemName = "\(baseName) #\(placedCount + 1)"
            
            let newLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: itemName, // Use the factory's description to ensure proper naming
                type: selectedType,
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0, // Large radius since we're not using GPS
                source: .arRandomized // Randomized AR item
            )
            
            // Add the location to locationManager so it shows up in the counter
            locationManager.addLocation(newLocation)

            // Place the object (will create appropriate type based on location.type)
            Swift.print("✅ Found valid position at attempt \(attempts) - placing \(itemName) (\(selectedType.displayName)) at distance: \(String(format: "%.2f", distanceFromCamera))m")
            placeBoxAtPosition(boxPosition, location: newLocation, in: arView)
            placedCount += 1
        }
        
        Swift.print("✅ Randomized and placed \(placedCount) objects!")
        if placedCount == 0 {
            Swift.print("⚠️ WARNING: No objects were placed!")
            Swift.print("   💡 Try: 1) Move camera around to scan surfaces, 2) Tap on surfaces to place manually")
        } else {
            Swift.print("   🎯 Objects placed on floors/tables - look around to find them!")
        }
    }


    // Generate position for indoor placement (simplified approach)
    private func generateIndoorPosition(cameraPos: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> (x: Float, z: Float) {
        // Simplified indoor placement: just place closer to camera in a smaller area
        // Avoid complex wall boundary calculations that might be failing
        Swift.print("🏠 Using simplified indoor placement")

        let randomDistance = Float.random(in: minDistance...min(maxDistance, 4.0)) // Limit to 4m indoors
        let randomAngle = Float.random(in: 0...(2 * Float.pi)) // Any direction

        let x = cameraPos.x + randomDistance * cos(randomAngle)
        let z = cameraPos.z + randomDistance * sin(randomAngle)

        Swift.print("🏠 Indoor position: distance \(String(format: "%.1f", randomDistance))m, angle \(String(format: "%.1f", randomAngle * 180 / .pi))°")
        return (x, z)
    }

    // Check if a position is within room boundaries defined by walls
    private func isPositionWithinRoomBounds(x: Float, z: Float, cameraPos: SIMD3<Float>, walls: [ARPlaneAnchor]) -> Bool {
        let testPos = SIMD3<Float>(x, cameraPos.y, z)

        // For each wall, check if the position is on the correct side
        for wall in walls {
            let wallTransform = wall.transform
            let wallPosition = SIMD3<Float>(
                wallTransform.columns.3.x,
                wallTransform.columns.3.y,
                wallTransform.columns.3.z
            )

            // Get wall normal (direction the wall is facing)
            let wallNormal = SIMD3<Float>(
                wallTransform.columns.2.x,
                wallTransform.columns.2.y,
                wallTransform.columns.2.z
            )

            // Vector from wall to test position
            let toTestPos = testPos - wallPosition

            // If the dot product is positive, the position is on the "outside" of the wall
            // We want positions on the "inside" (negative dot product)
            let dotProduct = dot(wallNormal, toTestPos)

            // Allow some tolerance - if clearly outside, reject
            if dotProduct > 1.0 { // More than 1m outside the wall
                return false
            }
        }

        return true // Position is within bounds or no clear boundary violation
    }

    // Get placement strategy - simplified for reliable sphere spawning
    private func getPlacementStrategy(isIndoors: Bool, searchDistance: Float) -> (minDistance: Float, maxDistance: Float, strategy: String) {
        // Use indoor-like distances for reliable sphere spawning
        return (
            minDistance: 1.0, // Minimum 1 meter
            maxDistance: 8.0,  // Maximum 8 meters (reasonable for indoor spaces)
            strategy: "INDOOR-FRIENDLY MODE - close placement for spheres"
        )
    }

    // MARK: - AR-Enhanced Location
    
    /// Get AR-enhanced GPS location (more accurate than raw GPS)
    /// Converts current AR camera position to GPS coordinates using AR origin
    /// Returns nil if AR origin not set or AR not available
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let arOrigin = arOriginLocation else {
            return nil
        }
        
        // Get current camera position in AR world space
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Convert AR position to GPS coordinates
        // AR origin is at (0,0,0) in AR space, so camera position is the offset
        let distance = sqrt(cameraPos.x * cameraPos.x + cameraPos.z * cameraPos.z) // Horizontal distance
        let bearing = atan2(Double(cameraPos.x), -Double(cameraPos.z)) * 180.0 / .pi // Bearing in degrees (0 = north)
        let normalizedBearing = (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
        
        // Calculate GPS coordinate from AR origin
        let enhancedGPS = arOrigin.coordinate.coordinate(atDistance: Double(distance), atBearing: normalizedBearing)
        
        return (
            latitude: enhancedGPS.latitude,
            longitude: enhancedGPS.longitude,
            arOffsetX: Double(cameraPos.x),
            arOffsetY: Double(cameraPos.y),
            arOffsetZ: Double(cameraPos.z)
        )
    }
    
    // MARK: - Object Recognition (delegated to ARObjectRecognizer)
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // CRITICAL: Set AR origin on first frame if not set - NEVER change it after
        // Changing the AR origin causes all objects to drift/shift position
        // Supports two modes:
        // 1. Accurate mode: Wait for GPS with good accuracy (< 7.5m) for precise AR-to-GPS conversion
        // 2. Degraded mode: Use AR-only positioning if GPS unavailable after timeout
        
        if arOriginLocation == nil {
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            
            // Try to get GPS location
            if let userLocation = userLocationManager?.currentLocation {
                // Check GPS accuracy - for < 7.5m resolution, we need < 7.5m GPS accuracy
                if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 7.5 {
                    // ACCURATE MODE: GPS available with good accuracy
                    // Step 1: Set ENU origin from GPS (geospatial coordinate frame)
                    if geospatialService?.setENUOrigin(from: userLocation) == true {
                        arOriginLocation = userLocation
                        arOriginSetTime = Date()
                        isDegradedMode = false
                        
                        // Step 2: Set AR session origin (VIO tracking origin at 0,0,0)
                        // Set fixed ground level at AR origin (using surface detection if available)
                        let groundLevel: Float
                        if let surfaceY = groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
                            // Use detected surface for accurate ground level
                            groundLevel = surfaceY
                            Swift.print("📍 AR Origin ground level from surface detection: \(String(format: "%.2f", groundLevel))m")
                        } else {
                            // Fallback: estimate from camera position
                            groundLevel = cameraPos.y - 1.5
                            Swift.print("📍 AR Origin ground level estimated: \(String(format: "%.2f", groundLevel))m (camera Y: \(String(format: "%.2f", cameraPos.y))m)")
                        }
                        
                        arOriginGroundLevel = groundLevel
                        geospatialService?.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
                        precisionPositioningService?.setAROriginGroundLevel(groundLevel) // Legacy compatibility
                        
                        Swift.print("✅ AR Origin SET (ACCURATE MODE) at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
                        Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                        Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED - never changes)")
                        Swift.print("   ⚠️ AR origin will NOT change - all objects positioned relative to this fixed point")
                        Swift.print("   📐 Using ENU coordinate system for geospatial positioning")
                    }
                } else {
                    // GPS available but accuracy too low
                    // Wait up to 10 seconds for better GPS, then enter degraded mode
                    let waitTime: TimeInterval = 10.0
                    if let setTime = arOriginSetTime {
                        if Date().timeIntervalSince(setTime) > waitTime {
                            // Timeout reached - enter degraded mode
                            enterDegradedMode(cameraPos: cameraPos, frame: frame)
                        } else {
                            Swift.print("⏳ Waiting for better GPS accuracy (current: \(String(format: "%.2f", userLocation.horizontalAccuracy))m, need: < 7.5m)")
                        }
                    } else {
                        // First time seeing low accuracy - start timer
                        arOriginSetTime = Date()
                        Swift.print("⚠️ GPS accuracy too low: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                        Swift.print("   Will wait \(Int(waitTime))s for better GPS, then enter degraded AR-only mode")
                    }
                }
            } else {
                // No GPS location available
                // Wait up to 5 seconds for GPS, then enter degraded mode
                let waitTime: TimeInterval = 5.0
                if let setTime = arOriginSetTime {
                    if Date().timeIntervalSince(setTime) > waitTime {
                        // Timeout reached - enter degraded mode
                        enterDegradedMode(cameraPos: cameraPos, frame: frame)
                    } else {
                        Swift.print("⏳ Waiting for GPS location...")
                    }
                } else {
                    // First time - start timer
                    arOriginSetTime = Date()
                    Swift.print("⚠️ No GPS location available")
                    Swift.print("   Will wait \(Int(waitTime))s for GPS, then enter degraded AR-only mode")
                }
            }
        }
        
        // Step 5.5: Check if we should exit degraded mode (GPS accuracy improved)
        // Note: This check happens even when arOriginLocation == nil because degraded mode sets it to nil
        // The existing code above will also try to set origin, but this provides explicit degraded mode exit
        if isDegradedMode, let userLocation = userLocationManager?.currentLocation {
            // Use hysteresis: require better accuracy (< 6.5m) to exit degraded mode than to enter (< 7.5m)
            // This prevents rapid mode switching when GPS accuracy fluctuates around the threshold
            if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 6.5 {
                // GPS accuracy improved significantly - exit degraded mode and set AR origin
                let cameraTransform = frame.camera.transform
                let cameraPos = SIMD3<Float>(
                    cameraTransform.columns.3.x,
                    cameraTransform.columns.3.y,
                    cameraTransform.columns.3.z
                )
                
                // Set ENU origin from GPS (geospatial coordinate frame)
                if geospatialService?.setENUOrigin(from: userLocation) == true {
                    arOriginLocation = userLocation
                    arOriginSetTime = Date()
                    isDegradedMode = false
                    
                    // Set fixed ground level
                    let groundLevel: Float
                    if let surfaceY = groundingService?.findHighestBlockingSurface(x: 0, z: 0, cameraPos: cameraPos) {
                        groundLevel = surfaceY
                        Swift.print("📍 Exiting degraded mode: Ground level from surface detection: \(String(format: "%.2f", groundLevel))m")
                    } else {
                        groundLevel = cameraPos.y - 1.5
                        Swift.print("📍 Exiting degraded mode: Ground level estimated: \(String(format: "%.2f", groundLevel))m")
                    }
                    
                    arOriginGroundLevel = groundLevel
                    geospatialService?.setARSessionOrigin(arPosition: SIMD3<Float>(0, 0, 0), groundLevel: groundLevel)
                    precisionPositioningService?.setAROriginGroundLevel(groundLevel)
                    
                    Swift.print("✅ EXITED DEGRADED MODE - GPS accuracy improved!")
                    Swift.print("   AR Origin SET at: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
                    Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                    Swift.print("   Ground level: \(String(format: "%.2f", groundLevel))m (FIXED)")
                    Swift.print("   GPS-based objects can now be placed")
                }
            } else if userLocation.horizontalAccuracy >= 0 {
                // Still in degraded mode, but log current accuracy for debugging
                // Only log occasionally to avoid spam (every 5 seconds)
                if let lastLog = lastDegradedModeLogTime, Date().timeIntervalSince(lastLog) < 5.0 {
                    // Skip logging
                } else {
                    lastDegradedModeLogTime = Date()
                    Swift.print("⏳ Still in degraded mode - GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m (need: < 6.5m to exit)")
                }
            }
        }
        
        // Step 6: DISABLED - Smooth corrections cause objects to drift/move
        // Objects should stay exactly where they're first placed for consistent AR experience
        // Once an object is placed in AR, it's locked to that world position
        // This prevents objects from appearing to "float" or "drift" as GPS updates

        // ORIGINAL CODE (now disabled):
        // Step 6: Apply smooth corrections when better GPS arrives (no teleporting)
        // Check if we have a better GPS fix than when origin was set
        // Throttle to every 5 seconds to prevent excessive checks and spam
        // let now = Date()
        // if now.timeIntervalSince(lastCorrectionCheck) > 5.0 {
        //     lastCorrectionCheck = now
        //
        //     if let geospatial = geospatialService,
        //        geospatial.hasENUOrigin,
        //        let userLocation = userLocationManager?.currentLocation,
        //        let origin = arOriginLocation,
        //        userLocation.horizontalAccuracy < origin.horizontalAccuracy {
        //         // Better GPS available - compute smooth correction
        //         if let correction = geospatial.computeSmoothCorrection(from: userLocation) {
        //             Swift.print("🔧 Applying smooth correction for better GPS accuracy")
        //             Swift.print("   Correction offset: (\(String(format: "%.4f", correction.x)), \(String(format: "%.4f", correction.y)), \(String(format: "%.4f", correction.z)))m")
        //
        //             // Apply correction to all placed objects (smooth, not teleport)
        //             // Note: In practice, you might want to animate this over time
        //             for (_, anchor) in placedBoxes {
        //                 let currentTransform = anchor.transformMatrix(relativeTo: nil)
        //                 let currentPos = SIMD3<Float>(
        //                     currentTransform.columns.3.x,
        //                     currentTransform.columns.3.y,
        //                     currentTransform.columns.3.z
        //                 )
        //                 let correctedPos = currentPos + correction
        //                 anchor.transform.translation = correctedPos
        //             }
        //
        //             Swift.print("✅ Applied smooth correction to \(placedBoxes.count) object(s)")
        //         }
        //     }
        // }

        // Objects are locked to initial placement - no GPS drift corrections applied
        // (Debug print removed to reduce log spam - this runs every frame)
        
        // PERFORMANCE: Skip heavy processing when dialog is open to prevent freezes
        if isDialogOpen {
            // Only do minimal processing when dialog is open
            // Skip object recognition, placement checks, viewport checks, etc.
            return
        }
        
        // Perform object recognition on camera frame (throttled to improve framerate)
        // Only run recognition every 2 seconds to reduce CPU usage
        let recognitionNow = Date()
        if recognitionNow.timeIntervalSince(lastRecognitionTime) > 2.0 {
            lastRecognitionTime = recognitionNow
            objectRecognizer?.performObjectRecognition(on: frame.capturedImage)
        }

        // Check for nearby locations when AR is tracking (throttled to reduce CPU usage)
        // CRITICAL: Move heavy processing to background threads to prevent UI freezes
        let now = Date()
        if frame.camera.trackingState == .normal,
           now.timeIntervalSince(lastNearbyCheckTime) > nearbyCheckInterval,
           let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            lastNearbyCheckTime = now
            
            // Move getNearbyLocations to background thread (can be expensive with many locations)
            locationProcessingQueue.async { [weak self] in
                guard let self = self else { return }
                
                // CRITICAL: Skip all processing if dialog is open to prevent UI freezes
                guard !self.isDialogOpen else { return }
                
                let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
                
                // DEBUG: Log what we found (on background thread to avoid blocking)
                if Date().timeIntervalSince(self.lastNearbyLogTime) > 3.0 {
                    self.lastNearbyLogTime = Date()
                    let placedCount = self.stateQueue.sync { self.placedBoxes.count }
                    let hasOrigin = self.arOriginLocation != nil
                    Swift.print("📱 AR Update: Found \(nearby.count) nearby locations, \(placedCount) placed, AR origin: \(hasOrigin)")
                    if !nearby.isEmpty && placedCount == 0 {
                        Swift.print("   ⚠️ Objects nearby but NONE placed yet!")
                        Swift.print("   First 3 nearby: \(nearby.prefix(3).map { $0.name })")
                    }
                }
                
                // CRITICAL: Double-check dialog state before dispatching to main thread
                guard !self.isDialogOpen else { return }
                
                // Game Mode: Place NPCs based on mode (must be on main thread for AR scene updates)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let arView = self.arView else { return }
                    
                    // CRITICAL: Final check on main thread - dialog may have opened
                    guard !self.isDialogOpen else { return }
                    
                    // Check for NPCs in nearby locations that should be placed in AR
                    // This handles NPCs loaded from the API/map that might not be placed yet
                    let npcLocations = nearby.filter { $0.id.hasPrefix("npc_") }
                    for npcLocation in npcLocations {
                        // Extract NPC type from ID (format: "npc_skeleton-1" or "npc_corgi-1")
                        let npcIdWithoutPrefix = String(npcLocation.id.dropFirst(4)) // Remove "npc_" prefix
                        
                        // Check if this is a skeleton NPC
                        if npcIdWithoutPrefix == NPCType.skeleton.npcId || npcLocation.name.contains("Captain Bones") || npcLocation.name.contains("skeleton") {
                            if !self.skeletonPlaced && self.placedNPCs[NPCType.skeleton.npcId] == nil {
                                Swift.print("💀 Found Captain Bones on map - placing in AR")
                                self.placeNPC(type: .skeleton, in: arView)
                            }
                        }
                        // Check if this is a corgi NPC
                        else if npcIdWithoutPrefix == NPCType.corgi.npcId || npcLocation.name.contains("Corgi") {
                            if !self.corgiPlaced && self.placedNPCs[NPCType.corgi.npcId] == nil {
                                Swift.print("🐕 Found Corgi Traveller on map - placing in AR")
                                self.placeNPC(type: .corgi, in: arView)
                            }
                        }
                    }
                    
                    switch locationManager.gameMode {
                    case .open:
                        // In open mode, only place NPCs if they're on the map (handled above)
                        // Remove NPCs that shouldn't be in open mode (only if not on map)
                        let hasSkeletonOnMap = nearby.contains { $0.id.hasPrefix("npc_") && ($0.name.contains("Captain Bones") || $0.name.contains("skeleton")) }
                        if self.skeletonPlaced && !hasSkeletonOnMap {
                            if let skeletonAnchor = self.skeletonAnchor {
                                skeletonAnchor.removeFromParent()
                                self.placedNPCs.removeValue(forKey: NPCType.skeleton.npcId)
                            }
                            self.skeletonPlaced = false
                            self.skeletonAnchor = nil
                        }
                        let hasCorgiOnMap = nearby.contains { $0.id.hasPrefix("npc_") && $0.name.contains("Corgi") }
                        if self.corgiPlaced && !hasCorgiOnMap {
                            if let corgiAnchor = self.placedNPCs[NPCType.corgi.npcId] {
                                corgiAnchor.removeFromParent()
                                self.placedNPCs.removeValue(forKey: NPCType.corgi.npcId)
                            }
                            self.corgiPlaced = false
                        }
                        break
                        
                    case .deadMensSecrets:
                        // Dead Men's Secrets: Only skeleton appears as guide
                        if !self.skeletonPlaced && self.placedNPCs[NPCType.skeleton.npcId] == nil {
                            Swift.print("💀 Dead Men's Secrets mode - placing Captain Bones")
                            self.placeNPC(type: .skeleton, in: arView)
                        }
                        // Remove corgi if it exists (shouldn't be in this mode)
                        if self.corgiPlaced {
                            if let corgiAnchor = self.placedNPCs[NPCType.corgi.npcId] {
                                corgiAnchor.removeFromParent()
                                self.placedNPCs.removeValue(forKey: NPCType.corgi.npcId)
                            }
                            self.corgiPlaced = false
                        }
                        
                    }
                }
                
                // Throttle box placement checks to improve framerate
                // Only check every 2 seconds instead of every frame (60fps)
                // Objects don't need frequent re-placement checks
                let placementNow = Date()
                let shouldCheck = self.shouldForceReplacement || placementNow.timeIntervalSince(self.lastPlacementCheck) > 2.0
                
                if shouldCheck {
                    self.lastPlacementCheck = placementNow
                    
                    // CRITICAL: Skip if dialog is open
                    guard !self.isDialogOpen else { return }
                    
                    // Move checkAndPlaceBoxes to background thread (very expensive operation)
                    self.placementProcessingQueue.async { [weak self] in
                        guard let self = self else { return }
                        
                        // CRITICAL: Skip if dialog is open
                        guard !self.isDialogOpen else { return }
                        
                        // Force re-placement after reset if flag is set
                        if self.shouldForceReplacement {
                            Swift.print("🔄 Force re-placement triggered - re-placing all nearby objects")
                            Swift.print("   📍 Found \(nearby.count) nearby locations within \(locationManager.maxSearchDistance)m")
                            self.shouldForceReplacement = false
                        }
                        
                        // Perform heavy computation on background thread
                        self.checkAndPlaceBoxesAsync(userLocation: userLocation, nearbyLocations: nearby)
                    }
                }
                
                // Check viewport visibility and play chime when objects enter
                // Throttle to every 1.0 seconds to improve framerate (was 0.5s)
                // Viewport checking is expensive (screen projections) and doesn't need high frequency
                let viewportNow = Date()
                if viewportNow.timeIntervalSince(self.lastViewportCheck) > 1.0 {
                    self.lastViewportCheck = viewportNow
                    
                    // CRITICAL: Skip if dialog is open
                    guard !self.isDialogOpen else { return }
                    
                    // Move viewport checking to background thread
                    self.viewportProcessingQueue.async { [weak self] in
                        guard let self = self else { return }
                        // CRITICAL: Skip if dialog is open
                        guard !self.isDialogOpen else { return }
                        self.checkViewportVisibilityAsync()
                    }
                }
                
                // CRITICAL: Periodically check for collected objects that should be removed from AR
                // This ensures objects are removed even if checkAndPlaceBoxes hasn't run yet
                // Check every 0.5 seconds to catch collected objects quickly
                let removalNow = Date()
                if removalNow.timeIntervalSince(self.lastPlacementCheck) > 0.5 {
                    self.lastPlacementCheck = removalNow
                    
                    // CRITICAL: Skip if dialog is open
                    guard !self.isDialogOpen else { return }
                    
                    // Move removal check to background thread
                    self.placementProcessingQueue.async { [weak self] in
                        guard let self = self else { return }
                        // CRITICAL: Skip if dialog is open
                        guard !self.isDialogOpen else { return }
                        self.removeCollectedObjectsFromARAsync()
                        // Also ensure all placed objects have their FindableObjects synced to tap handler
                        self.syncFindableObjectsToTapHandlerAsync()
                    }
                }
            }
        }
    }
    
    /// Ensures all placed objects have their FindableObjects synced to the tap handler
    /// This fixes cases where objects might not be tappable due to sync issues
    private func syncFindableObjectsToTapHandler() {
        guard let tapHandler = tapHandler else { return }
        
        var syncedCount = 0
        var missingCount = 0
        
        // Check all placed objects and ensure they're in tap handler's findableObjects
        for (locationId, _) in placedBoxes {
            if let findableObject = findableObjects[locationId] {
                // Sync to tap handler if not already present
                if tapHandler.findableObjects[locationId] == nil {
                    tapHandler.findableObjects[locationId] = findableObject
                    syncedCount += 1
                } else {
                    // Update to ensure it's the latest version
                    tapHandler.findableObjects[locationId] = findableObject
                }
            } else {
                // Object is placed but has no FindableObject - this shouldn't happen
                missingCount += 1
                Swift.print("⚠️ [Sync] Object \(locationId) is placed but has no FindableObject")
            }
        }
        
        // Clean up tap handler's findableObjects - remove any that are no longer placed
        let placedIds = Set(placedBoxes.keys)
        let tapHandlerIds = Set(tapHandler.findableObjects.keys)
        let orphanedIds = tapHandlerIds.subtracting(placedIds)
        
        for orphanedId in orphanedIds {
            tapHandler.findableObjects.removeValue(forKey: orphanedId)
            Swift.print("🧹 [Sync] Removed orphaned FindableObject from tap handler: \(orphanedId)")
        }
        
        if syncedCount > 0 || missingCount > 0 || !orphanedIds.isEmpty {
            Swift.print("🔄 [Sync] Synced \(syncedCount) FindableObjects, found \(missingCount) missing, removed \(orphanedIds.count) orphaned")
        }
    }
    
    /// Removes all collected objects from AR scene immediately
    /// This is called periodically to ensure collected objects don't remain visible
    private func removeCollectedObjectsFromAR() {
        guard let locationManager = locationManager else { return }
        
        var objectsToRemove: [String] = []
        
        // Check all placed objects to see if they're collected
        for (locationId, _) in placedBoxes {
            var shouldRemove = false
            var reason = ""
            
            // Check 1: Is this object in the foundLootBoxes set? (most reliable - set when collected)
            if distanceTracker?.foundLootBoxes.contains(locationId) ?? false {
                shouldRemove = true
                reason = "found in distanceTracker.foundLootBoxes"
            }
            // Check 2: Is this object collected in locationManager?
            else if let location = locationManager.locations.first(where: { $0.id == locationId }),
                    location.collected {
                shouldRemove = true
                reason = "collected in locationManager"
            }
            // Check 3: Is this object in tapHandler's foundLootBoxes?
            else if tapHandler?.foundLootBoxes.contains(locationId) ?? false {
                shouldRemove = true
                reason = "found in tapHandler.foundLootBoxes"
            }
            
            if shouldRemove {
                let locationName = locationManager.locations.first(where: { $0.id == locationId })?.name ?? locationId
                Swift.print("🗑️ [Periodic Check] Removing collected object '\(locationName)' (ID: \(locationId)) from AR scene - \(reason)")
                objectsToRemove.append(locationId)
            }
        }
        
        // Remove collected objects from AR scene
        for locationId in objectsToRemove {
            if let anchor = placedBoxes[locationId] {
                anchor.removeFromParent()
                placedBoxes.removeValue(forKey: locationId)
                findableObjects.removeValue(forKey: locationId)
                objectsInViewport.remove(locationId)
                objectPlacementTimes.removeValue(forKey: locationId)
                
                // Also remove from distance tracker if applicable
                if let textEntity = distanceTracker?.distanceTextEntities[locationId] {
                    textEntity.removeFromParent()
                    distanceTracker?.distanceTextEntities.removeValue(forKey: locationId)
                }
                
                // Also remove from distance tracker's foundLootBoxes if it's there
                distanceTracker?.foundLootBoxes.remove(locationId)
                
                Swift.print("   ✅ Object removed from AR scene")
            }
        }
    }
    
    // MARK: - Async Wrapper Methods (for background thread processing)
    
    /// Async wrapper for checkAndPlaceBoxes - dispatches to main thread for AR scene updates
    private func checkAndPlaceBoxesAsync(userLocation: CLLocation, nearbyLocations: [LootBoxLocation]) {
        // CRITICAL: Skip if dialog is open to prevent UI freezes
        guard !isDialogOpen else { return }
        
        // AR scene updates must be on main thread
        DispatchQueue.main.async { [weak self] in
            // Double-check dialog state on main thread (may have changed)
            guard let self = self, !self.isDialogOpen else { return }
            self.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
        }
    }
    
    /// Async wrapper for checkViewportVisibility - dispatches to main thread for AR scene access
    private func checkViewportVisibilityAsync() {
        // CRITICAL: Skip if dialog is open to prevent UI freezes
        guard !isDialogOpen else { return }
        
        // AR scene access must be on main thread
        DispatchQueue.main.async { [weak self] in
            // Double-check dialog state on main thread (may have changed)
            guard let self = self, !self.isDialogOpen else { return }
            self.checkViewportVisibility()
        }
    }
    
    /// Async wrapper for removeCollectedObjectsFromAR - dispatches to main thread for AR scene updates
    private func removeCollectedObjectsFromARAsync() {
        // CRITICAL: Skip if dialog is open to prevent UI freezes
        guard !isDialogOpen else { return }
        
        // AR scene updates must be on main thread
        DispatchQueue.main.async { [weak self] in
            // Double-check dialog state on main thread (may have changed)
            guard let self = self, !self.isDialogOpen else { return }
            self.removeCollectedObjectsFromAR()
        }
    }
    
    /// Async wrapper for syncFindableObjectsToTapHandler - thread-safe dictionary access
    private func syncFindableObjectsToTapHandlerAsync() {
        // CRITICAL: Skip if dialog is open to prevent UI freezes
        guard !isDialogOpen else { return }
        
        // Dictionary access is already thread-safe, but dispatch to main for consistency
        DispatchQueue.main.async { [weak self] in
            // Double-check dialog state on main thread (may have changed)
            guard let self = self, !self.isDialogOpen else { return }
            self.syncFindableObjectsToTapHandler()
        }
    }
    
    // Handle AR anchor updates - remove any unwanted plane anchors (especially ceilings)
    // Also re-ground objects when new horizontal planes are detected
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let arView = arView, let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Check if any new anchors are horizontal planes
        var hasNewHorizontalPlane = false
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor,
               planeAnchor.alignment == .horizontal {
                hasNewHorizontalPlane = true
                Swift.print("🆕 New horizontal plane detected - will re-ground floating objects")
                break
            }
        }

        // If new horizontal plane detected, re-ground all placed objects
        if hasNewHorizontalPlane {
            regroundAllObjects()
        }
        
        for anchor in anchors {
            // Handle horizontal plane anchors (floors/tables) - we need these for raycasting!
            if let planeAnchor = anchor as? ARPlaneAnchor {
                if planeAnchor.alignment == .horizontal {
                    // Check if this plane is above the camera (likely a ceiling) or suspiciously large
                    let planeY = planeAnchor.transform.columns.3.y
                    let planeHeight = planeAnchor.planeExtent.height
                    let planeWidth = planeAnchor.planeExtent.width

                    // Allow reasonable-sized horizontal planes (floors/tables) but remove problematic ones
                    let isCeiling = planeY > cameraPos.y + 0.5 // Clearly above camera
                    let isTooLarge = planeHeight > 8.0 || planeWidth > 8.0 // Suspiciously large
                    let isTooSmall = planeHeight < 0.3 || planeWidth < 0.3 // Too small to be useful

                    if isCeiling || isTooLarge || isTooSmall {
                        Swift.print("🗑️ Removing horizontal plane anchor: ceiling=\(isCeiling), too_large=\(isTooLarge), too_small=\(isTooSmall), Y=\(String(format: "%.2f", planeY)), size=\(String(format: "%.2f", planeWidth))x\(String(format: "%.2f", planeHeight))")
                        // Remove the anchor by not adding it to the scene
                        // ARKit will handle cleanup
                    } else {
                        Swift.print("✅ Keeping horizontal plane anchor (floor/table): Y=\(String(format: "%.2f", planeY)), size=\(String(format: "%.2f", planeWidth))x\(String(format: "%.2f", planeHeight))")

                        // Auto-randomize spheres when we have a good surface available
                        if !hasAutoRandomized && placedBoxes.isEmpty {
                            Swift.print("🎯 Auto-randomizing spheres on detected surface!")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                                // Small delay to let AR settle
                                self?.hasAutoRandomized = true
                                self?.randomizeLootBoxes()
                            }
                        }
                    }
                }
                // Disabled: Don't create occlusion planes for vertical planes (was causing dark boxes everywhere)
                // if planeAnchor.alignment == .vertical {
                //     createOcclusionPlane(for: planeAnchor, in: arView)
                // }
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Disabled: No longer updating occlusion planes (was causing dark boxes)
        // guard let arView = arView else { return }
        //
        // for anchor in anchors {
        //     if let planeAnchor = anchor as? ARPlaneAnchor,
        //        planeAnchor.alignment == .vertical,
        //        let occlusionAnchor = occlusionPlanes[planeAnchor.identifier] {
        //         // Update the occlusion plane geometry when ARKit refines the plane
        //         updateOcclusionPlane(occlusionAnchor, with: planeAnchor)
        //     }
        // }
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Occlusion plane cleanup is now handled by AROcclusionManager
        // No action needed here
    }
    
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        if let arError = error as? ARError {
            let errorCode = arError.code
            var errorDescription = "Unknown AR error"
            
            switch arError.code {
            case .unsupportedConfiguration:
                errorDescription = "AR configuration not supported on this device"
            case .sensorUnavailable:
                errorDescription = "AR sensor unavailable - camera or motion sensors not available"
            case .sensorFailed:
                errorDescription = "AR sensor failed - camera or motion sensors failed"
            case .cameraUnauthorized:
                errorDescription = "Camera access denied - check camera permissions"
            case .worldTrackingFailed:
                errorDescription = "World tracking failed - unable to track position"
            case .invalidReferenceImage:
                errorDescription = "Invalid reference image"
            case .invalidReferenceObject:
                errorDescription = "Invalid reference object"
            case .invalidWorldMap:
                errorDescription = "Invalid world map"
            case .invalidConfiguration:
                errorDescription = "Invalid AR configuration"
            case .insufficientFeatures:
                errorDescription = "Insufficient features - not enough visual features to track"
            case .objectMergeFailed:
                errorDescription = "Object merge failed"
            case .fileIOFailed:
                errorDescription = "File I/O failed"
            case .requestFailed:
                errorDescription = "AR request failed"
            case .invalidCollaborationData:
                errorDescription = "Invalid collaboration data"
            case .geoTrackingNotAvailableAtLocation:
                errorDescription = "GeoTracking not available at this location"
            case .geoTrackingFailed:
                errorDescription = "GeoTracking failed"
            default:
                errorDescription = "Unknown AR error code: \(errorCode.rawValue)"
            }
            
            Swift.print("❌ [AR Session Error] \(errorDescription) (ARError code: \(errorCode.rawValue))")
            let nsError = arError as NSError
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                Swift.print("   Underlying error: \(underlyingError.localizedDescription)")
            }
            if let failureReason = nsError.localizedFailureReason {
                Swift.print("   Failure reason: \(failureReason)")
            }
            if let recoverySuggestion = nsError.localizedRecoverySuggestion {
                Swift.print("   Recovery suggestion: \(recoverySuggestion)")
            }
        } else {
            Swift.print("❌ [AR Session Error] \(error.localizedDescription)")
            Swift.print("   Error type: \(type(of: error))")
            
            // Check for FigCaptureSourceRemote errors (camera capture errors)
            let errorString = String(describing: error)
            if errorString.contains("FigCaptureSourceRemote") || errorString.contains("err=-12784") {
                Swift.print("   ⚠️ Camera capture error detected - this may be a temporary camera issue")
                Swift.print("   This error (err=-12784) is often related to camera resource conflicts")
                Swift.print("   This is typically harmless and can occur during AR session transitions")
                // Don't restart session immediately for camera errors - let ARKit handle it
                // Restarting too aggressively can cause more conflicts
                return
            }
        }
        
        // Try to restart the session
        Swift.print("🔄 [AR Session] Attempting to restart AR session...")
        if let arView = arView {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for wall detection (occlusion)
            config.environmentTexturing = .automatic
            
            // Apply selected lens if available
            if let locationManager = locationManager,
               let selectedLensId = locationManager.selectedARLens,
               let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
                config.videoFormat = videoFormat
            }
            
            arView.session.run(config, options: [.resetTracking])

            // Configure environment lighting for proper shading and colors
            arView.environment.lighting.intensityExponent = 1.5

            // Clear raycast cache when session resets (surfaces may have changed)
            groundingService?.clearCache()
            Swift.print("✅ [AR Session] AR session restart initiated")
        } else {
            Swift.print("⚠️ [AR Session] Cannot restart - ARView is nil")
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        Swift.print("⚠️ [AR Session] AR Session was interrupted")
        Swift.print("   This usually happens when the app goes to background or another app uses the camera")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        Swift.print("✅ [AR Session] AR Session interruption ended")
        Swift.print("   Placed objects: \(placedBoxes.count) anchors in placedBoxes dictionary")

        // CRITICAL: AR session interruption (e.g., from ARPlacementView dismissing) removes all anchors
        // Even though we don't call session.run(), the anchors are gone from the scene
        // We need to force re-placement of all objects that were in the scene

        // Wait a moment for the session to fully resume, then check and re-place objects
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self,
                  let locationManager = self.locationManager,
                  let userLocation = self.userLocationManager?.currentLocation else {
                Swift.print("⚠️ Cannot re-place objects - missing locationManager or userLocation")
                return
            }

            // Check which anchors are still in scene
            var anchorsStillInScene = 0
            var anchorsRemoved: [String] = []
            for (locationId, anchor) in self.placedBoxes {
                if anchor.parent != nil {
                    anchorsStillInScene += 1
                } else {
                    anchorsRemoved.append(locationId)
                }
            }

            Swift.print("📊 Anchors check: \(anchorsStillInScene) still in scene, \(anchorsRemoved.count) removed")

            // If anchors were removed, clear placedBoxes and force re-placement
            if !anchorsRemoved.isEmpty {
                Swift.print("🔄 Re-placing \(anchorsRemoved.count) objects that were removed by session interruption")

                // Clear placedBoxes to allow re-placement
                self.placedBoxes.removeAll()
                self.findableObjects.removeAll()

                // Get nearby locations and re-place them
                let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
                Swift.print("   Found \(nearby.count) nearby locations to re-place")
                self.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
            } else {
                Swift.print("✅ All anchors still in scene - no re-placement needed")
            }
        }
    }
    
    // MARK: - Loot Box Placement
    private func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        Swift.print("🎯 placeLootBoxAtLocation called for: \(location.name) (type: \(location.type.displayName))")

        // CRITICAL: Check if already placed to prevent infinite loops
        if placedBoxes[location.id] != nil {
            Swift.print("   ⏭️ Already placed, skipping")
            return // Already placed, skip silently
        }

        // Check AR frame availability
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': AR frame not available")
            Swift.print("   AR session configuration: \(arView.session.configuration != nil ? "configured" : "not configured")")
            Swift.print("   This usually means AR is still initializing or was interrupted")
            return
        }
        
        // Check user location availability
        guard let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ [Placement] Cannot place '\(location.name)': User location not available")
            Swift.print("   GPS status: \(userLocationManager?.authorizationStatus == .authorizedWhenInUse || userLocationManager?.authorizationStatus == .authorizedAlways ? "authorized" : "not authorized")")
            Swift.print("   This usually means GPS is still acquiring location or permissions were denied")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // CRITICAL: Use AR coordinates first for mm-precision (primary)
        // Only fall back to GPS if AR coordinates aren't available
        if let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude,
           let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z {
            // AR coordinates available - use them for mm-precision placement
            let arOriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)
            
            // INDOOR vs OUTDOOR placement strategy:
            // - < 12m from AR origin: INDOOR - Use AR coordinates for mm/cm precision
            // - >= 12m from AR origin: OUTDOOR - Use GPS coordinates (acceptable GPS accuracy)
            let useARCoordinates: Bool
            let arPosition = SIMD3<Float>(Float(arOffsetX), Float(arOffsetY), Float(arOffsetZ))
            let distanceFromOrigin = length(arPosition)
            
            if let currentAROrigin = arOriginLocation {
                // Compare AR origins - if they match, we can use AR coordinates directly
                let originDistance = currentAROrigin.distance(from: arOriginGPS)
                
                // CRITICAL FIX: Only use AR coordinates if AR origins match (same session)
                // If AR origins don't match (e.g., object was placed in ARPlacementView with different origin),
                // we must use GPS coordinates instead, otherwise object will appear at wrong position (0,0,0)
                // AR coordinates are only valid within the same AR session
                useARCoordinates = originDistance < 1.0 && distanceFromOrigin < 12.0
                
        if useARCoordinates {
                    Swift.print("✅ INDOOR placement (< 12m): Using AR coordinates for mm/cm-precision")
                    Swift.print("   AR origin match: distance=\(String(format: "%.3f", originDistance))m (same session)")
                    Swift.print("   Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m")
                    Swift.print("   AR offset: (\(String(format: "%.4f", arOffsetX)), \(String(format: "%.4f", arOffsetY)), \(String(format: "%.4f", arOffsetZ)))m")
                } else {
                    if originDistance >= 1.0 {
                        Swift.print("⚠️ AR origins don't match (distance=\(String(format: "%.3f", originDistance))m) - object was placed in different AR session")
                        Swift.print("   Falling back to GPS coordinates (AR coordinates only valid in same session)")
                    } else {
                        Swift.print("🌍 OUTDOOR placement (>= 12m): Using GPS coordinates")
                        Swift.print("   Distance from AR origin: \(String(format: "%.2f", distanceFromOrigin))m")
                        Swift.print("   GPS accuracy acceptable for outdoor distances")
                    }
                }
            } else {
                // No current AR origin - cannot use AR coordinates (no origin to reference)
                // Must use GPS coordinates instead
                useARCoordinates = false
                Swift.print("⚠️ No current AR origin set - cannot use stored AR coordinates")
                Swift.print("   Falling back to GPS coordinates (AR origin required for AR coordinate placement)")
            }
            
            if useARCoordinates {
                // Use stored AR coordinates directly (mm-precision) - NEVER re-ground
                // This preserves the exact placement position where the user placed it
                // Objects should NEVER move after being placed, especially for the user who placed them
                let arPosition = SIMD3<Float>(
                    Float(arOffsetX),
                    Float(arOffsetY),
                    Float(arOffsetZ)
                )
                
                // Use exact stored position - don't re-ground to preserve user's placement
                Swift.print("✅ [Placement] Using exact stored AR coordinates for \(location.name) (mm-precision, no re-grounding)")
                Swift.print("   Object ID: \(location.id)")
                Swift.print("   Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                Swift.print("   Object will stay fixed at this position (never moves)")
                
                placeBoxAtPosition(arPosition, location: location, in: arView)
                
                // Log location again after 1 second to verify it's still there
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    await MainActor.run {
                        if let anchor = placedBoxes[location.id] {
                            let currentPos = anchor.position
                            let isStillInScene = anchor.parent != nil
                            Swift.print("📍 [Placement] Object '\(location.name)' location after 1 second:")
                            Swift.print("   AR Position: X=\(String(format: "%.4f", currentPos.x))m, Y=\(String(format: "%.4f", currentPos.y))m, Z=\(String(format: "%.4f", currentPos.z))m")
                            Swift.print("   Still in scene: \(isStillInScene ? "YES" : "NO")")
                            Swift.print("   Anchor parent: \(anchor.parent != nil ? "exists" : "nil")")
                            if !isStillInScene {
                                Swift.print("   ⚠️ WARNING: Object was removed from scene!")
                            } else if abs(currentPos.x - arPosition.x) > 0.001 || abs(currentPos.y - arPosition.y) > 0.001 || abs(currentPos.z - arPosition.z) > 0.001 {
                                Swift.print("   ⚠️ WARNING: Object moved! Original: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z))), Current: (\(String(format: "%.4f", currentPos.x)), \(String(format: "%.4f", currentPos.y)), \(String(format: "%.4f", currentPos.z)))")
                            } else {
                                Swift.print("   ✅ Object still at original position")
                            }
                        } else {
                            // Check if object was collected (normal case - not an error)
                            let wasCollected = locationManager?.locations.first(where: { $0.id == location.id })?.collected ?? false
                            if wasCollected {
                                Swift.print("   ℹ️ Object '\(location.name)' was collected (removed from placedBoxes - this is normal)")
                            } else if findableObjects[location.id] == nil {
                                Swift.print("   ⚠️ WARNING: Object '\(location.name)' not found in placedBoxes and not in findableObjects - may have been removed unexpectedly")
                            } else {
                                Swift.print("   ℹ️ Object '\(location.name)' not in placedBoxes but still in findableObjects (may be in transition)")
                            }
                        }
                    }
                }
                return
            }
        }
        
        // Fallback to GPS-based placement if AR coordinates not available
        if location.latitude != 0 || location.longitude != 0 {
            // CRITICAL: Check if object was manually placed (has intended AR position stored)
            // Manually placed objects bypass degraded mode check
            let arPositionKey = "ARPlacementPosition_\(location.id)"
            let hasIntendedPosition = UserDefaults.standard.dictionary(forKey: arPositionKey) != nil

            // CRITICAL: Require AR origin to be set before placing GPS-based objects
            // In degraded mode, GPS-based objects cannot be placed UNLESS manually placed
            if isDegradedMode && !hasIntendedPosition {
                Swift.print("⚠️ Cannot place GPS-based object '\(location.name)': Operating in degraded AR-only mode")
                Swift.print("   GPS-based objects require accurate GPS fix (< 7.5m accuracy)")
                Swift.print("   Use AR-only placement (tap-to-place or randomize) instead")
                return
            } else if isDegradedMode && hasIntendedPosition {
                Swift.print("✅ Allowing manually placed object '\(location.name)' in degraded mode (has intended AR position)")
            }

            // CRITICAL: If we have intended AR position, use it directly (skip GPS conversion)
            // This ensures object appears exactly where user placed it
            if hasIntendedPosition,
               let arPositionDict = UserDefaults.standard.dictionary(forKey: arPositionKey) as? [String: Float],
               let intendedX = arPositionDict["x"],
               let intendedY = arPositionDict["y"],
               let intendedZ = arPositionDict["z"] {

                let intendedPosition = SIMD3<Float>(intendedX, intendedY, intendedZ)
                Swift.print("✅ Using intended AR position for '\(location.name)' (bypassing GPS conversion)")
                Swift.print("   Intended position: (\(String(format: "%.4f", intendedPosition.x)), \(String(format: "%.4f", intendedPosition.y)), \(String(format: "%.4f", intendedPosition.z)))m")

                // Place at intended position
                placeBoxAtPosition(intendedPosition, location: location, in: arView)

                // Clean up - position has been used
                UserDefaults.standard.removeObject(forKey: arPositionKey)
                return
            }

            guard let arOrigin = arOriginLocation else {
                Swift.print("⚠️ Cannot place \(location.name): AR origin not set yet")
                Swift.print("   Waiting for AR origin to be established (requires GPS accuracy < 7.5m)")
                Swift.print("   Will enter degraded mode if GPS unavailable")
                return
            }
            
            // Use ENU-based geospatial service for GPS to AR conversion
            let targetLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let distance = userLocation.distance(from: targetLocation)
            
            if verbosePlacementLogging {
                Swift.print("📍 Placing \(location.name) at GPS distance \(String(format: "%.2f", distance))m")
                Swift.print("   Using fixed AR origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
            }
            
            // Step 1: Convert GPS to ENU, then ENU to AR (new architecture)
            var precisePosition: SIMD3<Float>?
            if let geospatial = geospatialService, geospatial.hasENUOrigin {
                // Use new ENU-based conversion
                if let arPos = geospatial.convertGPSToAR(targetLocation) {
                    precisePosition = arPos
                    if verbosePlacementLogging {
                        Swift.print("✅ Using ENU coordinate system for GPS conversion")
                    }
                }
            }
            
            // Fallback to legacy precision positioning service if ENU not available
            if precisePosition == nil {
                if let legacyPosition = precisionPositioningService?.convertGPSToARPosition(
                    targetGPS: targetLocation,
                    userGPS: userLocation,
                    cameraTransform: cameraTransform,
                    arOriginGPS: arOrigin
                ) {
                    precisePosition = legacyPosition
                    Swift.print("⚠️ Using legacy precision positioning service (ENU not available)")
                }
            }
            
            if let precisePosition = precisePosition {
                // CRITICAL: If object already has AR coordinates stored, use them instead of re-converting GPS
                // BUT: Only if AR origins match! Otherwise the coordinates are relative to a different origin
                let finalPosition: SIMD3<Float>

                if let storedArX = location.ar_offset_x,
                   let storedArY = location.ar_offset_y,
                   let storedArZ = location.ar_offset_z,
                   let storedOriginLat = location.ar_origin_latitude,
                   let storedOriginLon = location.ar_origin_longitude {
                    // Check if AR origins match (must be same session)
                    let storedOrigin = CLLocation(latitude: storedOriginLat, longitude: storedOriginLon)
                    let originDistance = arOrigin.distance(from: storedOrigin)

                    if originDistance < 1.0 {
                        // Origins match - use stored AR coordinates to prevent movement
                        finalPosition = SIMD3<Float>(Float(storedArX), Float(storedArY), Float(storedArZ))
                        Swift.print("✅ Using stored AR coordinates for \(location.type.displayName) (prevents movement from GPS conversion)")
                        Swift.print("   Stored position: (\(String(format: "%.4f", finalPosition.x)), \(String(format: "%.4f", finalPosition.y)), \(String(format: "%.4f", finalPosition.z)))m")
                    } else {
                        // Origins don't match - must use GPS-based position
                        Swift.print("⚠️ AR origins don't match (distance=\(String(format: "%.3f", originDistance))m) - using GPS-based position")
                        Swift.print("   Stored origin: (\(String(format: "%.6f", storedOriginLat)), \(String(format: "%.6f", storedOriginLon)))")
                        Swift.print("   Current origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")

                        // Use GPS-converted position with surface detection
                        if distance < 5.0 {
                            let surfaceY = groundingService?.findSurfaceOrDefault(
                                x: precisePosition.x,
                                z: precisePosition.z,
                                cameraPos: cameraPos,
                                objectType: location.type
                            ) ?? precisePosition.y
                            finalPosition = SIMD3<Float>(precisePosition.x, surfaceY, precisePosition.z)
                        } else {
                            if let fixedGroundLevel = arOriginGroundLevel {
                                finalPosition = SIMD3<Float>(precisePosition.x, fixedGroundLevel, precisePosition.z)
                            } else {
                                finalPosition = precisePosition
                            }
                        }
                        Swift.print("   Using GPS-based position: (\(String(format: "%.4f", finalPosition.x)), \(String(format: "%.4f", finalPosition.y)), \(String(format: "%.4f", finalPosition.z)))m")
                    }
                } else {
                    // No stored AR coordinates - this is first placement, detect surface and store result
                    if distance < 5.0 {
                        // Close proximity: detect surface for first placement
                        let surfaceY = groundingService?.findSurfaceOrDefault(
                            x: precisePosition.x,
                            z: precisePosition.z,
                            cameraPos: cameraPos,
                            objectType: location.type
                        ) ?? precisePosition.y
                        finalPosition = SIMD3<Float>(precisePosition.x, surfaceY, precisePosition.z)
                        // PERFORMANCE: Logging disabled - runs in placement loop
                    } else {
                        // Far distance: use fixed ground level for stability
                        if let fixedGroundLevel = arOriginGroundLevel {
                            finalPosition = SIMD3<Float>(precisePosition.x, fixedGroundLevel, precisePosition.z)
                            Swift.print("✅ First placement: Using fixed AR origin ground level")
                        } else if let surfaceY = precisionPositioningService?.getPreciseSurfaceHeight(
                            x: precisePosition.x,
                            z: precisePosition.z,
                            cameraPos: cameraPos
                        ) {
                            finalPosition = SIMD3<Float>(precisePosition.x, surfaceY, precisePosition.z)
                            Swift.print("✅ First placement: Using detected surface")
                        } else {
                            Swift.print("❌ Cannot place \(location.type.displayName): No surface or ground level available")
                            return
                        }
                    }

                    // CRITICAL GPS CORRECTION: Check if this object was just placed in ARPlacementView
                    // If so, we have the INTENDED AR position stored, and can measure GPS error
                    // by comparing where GPS-based placement put it vs where the user actually placed it
                    let arPositionKey = "ARPlacementPosition_\(location.id)"
                    if let arPositionDict = UserDefaults.standard.dictionary(forKey: arPositionKey) as? [String: Float],
                       let intendedX = arPositionDict["x"],
                       let intendedY = arPositionDict["y"],
                       let intendedZ = arPositionDict["z"] {

                        let intendedPosition = SIMD3<Float>(intendedX, intendedY, intendedZ)
                        let actualPosition = finalPosition
                        let arDelta = actualPosition - intendedPosition
                        let arDistance = length(arDelta)

                        Swift.print("🎯 [GPS Correction] Detected object placed in ARPlacementView")
                        Swift.print("   Intended AR position: (\(String(format: "%.4f", intendedPosition.x)), \(String(format: "%.4f", intendedPosition.y)), \(String(format: "%.4f", intendedPosition.z)))m")
                        Swift.print("   GPS-based AR position: (\(String(format: "%.4f", actualPosition.x)), \(String(format: "%.4f", actualPosition.y)), \(String(format: "%.4f", actualPosition.z)))m")
                        Swift.print("   AR distance error: \(String(format: "%.4f", arDistance))m")
                        Swift.print("   AR delta: (\(String(format: "%.4f", arDelta.x)), \(String(format: "%.4f", arDelta.y)), \(String(format: "%.4f", arDelta.z)))m")

                        // Only correct if error is significant (> 10cm) and reasonable (< 50m)
                        // Prevents correcting random noise or corrupted data
                        if arDistance > 0.1 && arDistance < 50.0 {
                            Swift.print("   📍 Correcting GPS coordinates to compensate for \(String(format: "%.2f", arDistance))m GPS error...")

                            // Calculate corrected GPS coordinates
                            // We need to move the GPS coords in the opposite direction of the AR error
                            // to compensate for GPS inaccuracy
                            correctGPSCoordinates(
                                location: location,
                                intendedARPosition: intendedPosition,
                                arOrigin: arOrigin,
                                cameraTransform: cameraTransform
                            )

                            // Clean up UserDefaults - we've applied the correction
                            UserDefaults.standard.removeObject(forKey: arPositionKey)
                        } else if arDistance > 50.0 {
                            Swift.print("   ⚠️ AR error too large (\(String(format: "%.2f", arDistance))m) - GPS correction skipped (possible corruption)")
                            UserDefaults.standard.removeObject(forKey: arPositionKey)
                        } else {
                            Swift.print("   ✅ AR error small (\(String(format: "%.2f", arDistance))m < 10cm) - GPS already accurate")
                            UserDefaults.standard.removeObject(forKey: arPositionKey)
                        }
                    }

                    // Store AR coordinates after first placement so object never moves
                    // PERFORMANCE: Logging disabled
                }
                
                // Check distance from camera BEFORE placing (early rejection)
                let distanceFromCamera = length(finalPosition - cameraPos)
                if distanceFromCamera < 3.0 {
                    // PERFORMANCE: Logging disabled - this runs in retry loop
                    return
                }
                
                // PERFORMANCE: Logging disabled
                placeBoxAtPosition(finalPosition, location: location, in: arView)
                return
            } else {
                // Precision positioning service failed - cannot place object accurately
                Swift.print("❌ Cannot place \(location.name): Precision positioning service failed")
                Swift.print("   Object placement requires proper AR origin and ground level initialization")
                return
            }
        }
        
        // Fallback: If no GPS coordinates, use random placement (for AR-only items)
        Swift.print("⚠️ No GPS coordinates for \(location.name), using random placement")
        placeLootBoxInFrontOfCamera(location: location, in: arView)
    }
    
    // Place a loot box at tap location (allows closer placement for manual taps)
    private func placeLootBoxAtTapLocation(_ location: LootBoxLocation, tapResult: ARRaycastResult, in arView: ARView) {
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ No AR frame available for tap placement")
            return
        }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let hitY = tapResult.worldTransform.columns.3.y
        let hitX = tapResult.worldTransform.columns.3.x
        let hitZ = tapResult.worldTransform.columns.3.z
        
        var boxPosition = SIMD3<Float>(hitX, hitY, hitZ)
        
        // For manual tap placement, allow closer placement (minimum 1m instead of 3-5m)
        let distanceFromCamera = length(boxPosition - cameraPos)
        let minDistance: Float = 1.0 // Allow closer placement for manual taps
        
        if distanceFromCamera < minDistance {
            // Adjust position to be at minimum distance
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * minDistance
            // Recalculate Y from highest blocking surface at new position
            if let surfaceY = groundingService?.findHighestBlockingSurface(x: boxPosition.x, z: boxPosition.z, cameraPos: cameraPos) {
                boxPosition.y = surfaceY
            }
        }
        
        // Check if position is too close to other boxes (prevent overlapping)
        var tooCloseToOtherBox = false
        let minDistanceBetweenObjects: Float = 2.0 // Minimum 2 meters between objects
        for (existingId, existingAnchor) in placedBoxes {
            let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
            let existingPos = SIMD3<Float>(
                existingTransform.columns.3.x,
                existingTransform.columns.3.y,
                existingTransform.columns.3.z
            )
            let distanceToExisting = length(boxPosition - existingPos)
            if distanceToExisting < minDistanceBetweenObjects {
                Swift.print("⚠️ Cannot place - too close to existing object \(existingId) (distance: \(String(format: "%.2f", distanceToExisting))m, minimum: \(minDistanceBetweenObjects)m)")
                tooCloseToOtherBox = true
                break
            }
        }
        
        if tooCloseToOtherBox {
            Swift.print("⚠️ Tap location too close to existing object")
            return
        }
        
        Swift.print("🎯 Placing object at tap location (distance: \(String(format: "%.2f", length(boxPosition - cameraPos)))m)")
        placeBoxAtPosition(boxPosition, location: location, in: arView)
    }
    
    // Place an AR sphere at a GPS location (for map-added spheres)
    private func placeARSphereAtLocation(_ location: LootBoxLocation, in arView: ARView) {
        // CRITICAL: Check if already placed to prevent infinite loops
        if placedBoxes[location.id] != nil {
            return // Already placed, skip silently
        }

        // Check AR frame availability
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ [Placement] Cannot place sphere '\(location.name)': AR frame not available")
            Swift.print("   AR session configuration: \(arView.session.configuration != nil ? "configured" : "not configured")")
            Swift.print("   This usually means AR is still initializing or was interrupted")
            return
        }
        
        // Check user location availability
        guard let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ [Placement] Cannot place sphere '\(location.name)': User location not available")
            Swift.print("   GPS status: \(userLocationManager?.authorizationStatus == .authorizedWhenInUse || userLocationManager?.authorizationStatus == .authorizedAlways ? "authorized" : "not authorized")")
            Swift.print("   This usually means GPS is still acquiring location or permissions were denied")
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        // CRITICAL: Use AR coordinates first for mm-precision (primary)
        // Only fall back to GPS if AR coordinates aren't available
        if let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude,
           let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z {
            // AR coordinates available - use them for mm-precision placement
            let arOriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)
            
            // Check if AR origin matches current AR session origin
            let useARCoordinates: Bool
            if let currentAROrigin = arOriginLocation {
                let originDistance = currentAROrigin.distance(from: arOriginGPS)
                useARCoordinates = originDistance < 1.0 // Within 1m = same AR session origin
                
                if useARCoordinates {
                    Swift.print("✅ Using AR coordinates for mm-precision sphere placement: \(location.name)")
                    Swift.print("   AR offset: (\(String(format: "%.4f", arOffsetX)), \(String(format: "%.4f", arOffsetY)), \(String(format: "%.4f", arOffsetZ)))m")
                }
            } else {
                useARCoordinates = true
            }
            
            if useARCoordinates {
                // Use stored AR coordinates directly (mm-precision) - NO re-grounding
                // This preserves the exact placement position where the user placed it
                let arPosition = SIMD3<Float>(
                    Float(arOffsetX),
                    Float(arOffsetY),
                    Float(arOffsetZ)
                )
                
                // Use exact stored Y position - don't re-ground to preserve user's placement
                Swift.print("✅ Using exact stored AR coordinates for sphere (mm-precision, no re-grounding)")
                Swift.print("   Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                
                // Create sphere at exact AR position
                let sphereRadius: Float = 0.15
                let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
                var sphereMaterial = SimpleMaterial()
                sphereMaterial.color = .init(tint: .orange)
                sphereMaterial.roughness = 0.2
                sphereMaterial.metallic = 0.3
                
                let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
                sphere.name = location.id
                
                // Place anchor at exact AR position - sphere base will be at arPosition.y
                let anchor = AnchorEntity(world: arPosition)
                // Position sphere so its base (bottom) is at the anchor position (center of shadow X)
                sphere.position = SIMD3<Float>(0, sphereRadius, 0)
                
                let light = PointLightComponent(color: .orange, intensity: 200)
                sphere.components.set(light)
                
                anchor.addChild(sphere)
                arView.scene.addAnchor(anchor)
                placedBoxes[location.id] = anchor
                objectPlacementTimes[location.id] = Date() // Record placement time for grace period
                
                environmentManager?.applyUniformLuminanceToNewEntity(anchor)
                
                // If enabled, attach a hidden real object that will be revealed from the generic icon
                let useGenericIcons = locationManager?.useGenericDoubloonIcons ?? false
                let isContainerType = location.type != .sphere && location.type != .cube
                let containerForReveal: LootBoxContainer?
                if useGenericIcons && isContainerType {
                    let factory = location.type.factory
                    if let container = factory.createContainer(location: location, sizeMultiplier: 1.0) {
                        container.container.isEnabled = false
                        anchor.addChild(container.container)
                        containerForReveal = container
                    } else {
                        containerForReveal = nil
                    }
                } else {
                    containerForReveal = nil
                }
                
                findableObjects[location.id] = FindableObject(
                    locationId: location.id,
                    anchor: anchor,
                    sphereEntity: sphere,
                    container: containerForReveal,
                    location: location
                )

                findableObjects[location.id]?.onFoundCallback = { [weak self] id in
                    DispatchQueue.main.async {
                        if let locationManager = self?.locationManager {
                            locationManager.markCollected(id)
                        }
                    }
                }

                // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
                if let findable = findableObjects[location.id] {
                    tapHandler?.findableObjects[location.id] = findable
                }
                
                Swift.print("✅ Placed AR sphere '\(location.name)' using stored AR coordinates at (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f",    arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                return
            }
        }
        
        // Fallback to GPS-based placement if AR coordinates not available
        // Check if we're in degraded mode
        if isDegradedMode {
            Swift.print("⚠️ Cannot place GPS-based sphere '\(location.name)': Operating in degraded AR-only mode")
            return
        }
        
        let locationCLLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        
        // Use precision positioning service for inch-level accuracy
        guard let precisePosition = precisionPositioningService?.convertGPSToARPosition(
            targetGPS: locationCLLocation,
            userGPS: userLocation,
            cameraTransform: cameraTransform,
            arOriginGPS: arOriginLocation
        ) else {
            Swift.print("⚠️ Precision positioning failed for sphere, using fallback")
            // Fallback to simple GPS conversion
            guard let arOrigin = arOriginLocation else {
                Swift.print("⚠️ No AR origin set for sphere placement")
                return
            }
            let distance = arOrigin.distance(from: locationCLLocation)
            let bearing = arOrigin.bearing(to: locationCLLocation)
            let x = Float(distance * sin(bearing * .pi / 180.0))
            let z = Float(distance * cos(bearing * .pi / 180.0))
            
            // Use fixed ground level if available, otherwise detect surface
            let groundY: Float
            if let fixedGroundLevel = arOriginGroundLevel {
                groundY = fixedGroundLevel
                Swift.print("✅ Using fixed AR origin ground level for sphere: Y=\(String(format: "%.2f", groundY))")
            } else if let surfaceY = groundingService?.findHighestBlockingSurface(x: x, z: z, cameraPos: cameraPos) {
                groundY = surfaceY
            } else {
                groundY = cameraPos.y - 1.5
            }
            
            let sphereRadius: Float = 0.15
            let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
            var sphereMaterial = SimpleMaterial()
            sphereMaterial.color = .init(tint: .orange)
            sphereMaterial.roughness = 0.2
            sphereMaterial.metallic = 0.3
            let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
            sphere.name = location.id
            let anchor = AnchorEntity(world: SIMD3<Float>(x, groundY, z))
            sphere.position = SIMD3<Float>(0, sphereRadius, 0)
            let light = PointLightComponent(color: .orange, intensity: 200)
            sphere.components.set(light)
            anchor.addChild(sphere)
            arView.scene.addAnchor(anchor)
            placedBoxes[location.id] = anchor
            environmentManager?.applyUniformLuminanceToNewEntity(anchor)
            
            // If enabled, attach a hidden real object that will be revealed from the generic icon
            let useGenericIcons = locationManager?.useGenericDoubloonIcons ?? false
            let isContainerType = location.type != .sphere && location.type != .cube
            let containerForReveal: LootBoxContainer?
            if useGenericIcons && isContainerType {
                let factory = location.type.factory
                if let container = factory.createContainer(location: location, sizeMultiplier: 1.0) {
                    container.container.isEnabled = false
                    anchor.addChild(container.container)
                    containerForReveal = container
                } else {
                    containerForReveal = nil
                }
            } else {
                containerForReveal = nil
            }

            findableObjects[location.id] = FindableObject(
                locationId: location.id,
                anchor: anchor,
                sphereEntity: sphere,
                container: containerForReveal,
                location: location
            )
            findableObjects[location.id]?.onFoundCallback = { [weak self] id in
                DispatchQueue.main.async {
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(id)
                    }
                }
            }

            // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
            if let findable = findableObjects[location.id] {
                tapHandler?.findableObjects[location.id] = findable
            }
            return
        }
        
        let distance = userLocation.distance(from: locationCLLocation)
        Swift.print("🎯 Placing AR sphere '\(location.name)' using precision positioning")
        Swift.print("   GPS distance: \(String(format: "%.2f", distance))m")
        Swift.print("   Precise AR position: (\(String(format: "%.4f", precisePosition.x)), \(String(format: "%.4f", precisePosition.y)), \(String(format: "%.4f", precisePosition.z)))")

        // Create sphere at calculated position
        let sphereRadius: Float = 0.15 // Smaller sphere for GPS-located items
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: .orange)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = location.id

        // Use precise position with fixed ground level for stability
        // Prefer fixed ground level to prevent objects from moving when camera moves
        let groundY: Float
        if distance < 5.0 {
            // Close proximity: precision service already handled surface detection
            // But prefer fixed ground level if available for stability
            if let fixedGroundLevel = arOriginGroundLevel {
                groundY = fixedGroundLevel
                Swift.print("✅ Using fixed AR origin ground level for close sphere (ensures stability)")
            } else {
                groundY = precisePosition.y
            }
        } else {
            // Far distance: prefer fixed ground level, fallback to surface detection
            if let fixedGroundLevel = arOriginGroundLevel {
                groundY = fixedGroundLevel
                Swift.print("✅ Using fixed AR origin ground level for far sphere (ensures stability)")
            } else if let surfaceY = precisionPositioningService?.getPreciseSurfaceHeight(
                x: precisePosition.x,
                z: precisePosition.z,
                cameraPos: cameraPos
            ) {
                groundY = surfaceY
            } else if let surfaceY = groundingService?.findHighestBlockingSurface(x: precisePosition.x, z: precisePosition.z, cameraPos: cameraPos) {
                groundY = surfaceY
            } else {
                groundY = cameraPos.y - 1.5
                Swift.print("⚠️ No surface found for sphere - using fallback height")
            }
        }

        // Create anchor at grounded position
        let anchor = AnchorEntity(world: SIMD3<Float>(precisePosition.x, groundY, precisePosition.z))

        // Position sphere relative to anchor so bottom sits flat on surface
        sphere.position = SIMD3<Float>(0, sphereRadius, 0) // Bottom of sphere touches surface

        // Add point light to make it visible
        let light = PointLightComponent(color: .orange, intensity: 200)
        sphere.components.set(light)

        anchor.addChild(sphere)

        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor

        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // If enabled, attach a hidden real object that will be revealed from the generic icon
        let useGenericIcons = locationManager?.useGenericDoubloonIcons ?? false
        let isContainerType = location.type != .sphere && location.type != .cube
        let containerForReveal: LootBoxContainer?
        if useGenericIcons && isContainerType {
            let factory = location.type.factory
            if let container = factory.createContainer(location: location, sizeMultiplier: 1.0) {
                container.container.isEnabled = false
                anchor.addChild(container.container)
                containerForReveal = container
            } else {
                containerForReveal = nil
            }
        } else {
            containerForReveal = nil
        }

        // Set callback to increment found count
        findableObjects[location.id] = FindableObject(
            locationId: location.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: containerForReveal,
            location: location
        )

        // Set callback to mark as collected when found
        findableObjects[location.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
        if let findable = findableObjects[location.id] {
            tapHandler?.findableObjects[location.id] = findable
        }

        Swift.print("✅ Placed AR sphere '\(location.name)' at AR position (\(String(format: "%.2f", precisePosition.x)), \(String(format: "%.2f", precisePosition.z)))")
    }
    
    // Helper method to place a randomly selected object at a specific position
    private func placeBoxAtPosition(_ boxPosition: SIMD3<Float>, location: LootBoxLocation, in arView: ARView) {
        // Prevent duplicate placements
        if placedBoxes[location.id] != nil {
            Swift.print("⚠️ Object with ID \(location.id) already placed - skipping duplicate placement")
            return
        }
        
        // CRITICAL: Check for collision with already placed objects (minimum 3m horizontal separation, 1m vertical)
        // Increased from 2m to 3m to prevent objects from appearing on top of each other
        let minHorizontalSeparation: Float = 3.0 // Minimum 3 meters horizontal distance between objects
        let minVerticalSeparation: Float = 1.0 // Minimum 1 meter vertical distance (prevents stacking)
        for (existingId, existingAnchor) in placedBoxes {
            let existingTransform = existingAnchor.transformMatrix(relativeTo: nil)
            let existingPos = SIMD3<Float>(
                existingTransform.columns.3.x,
                existingTransform.columns.3.y,
                existingTransform.columns.3.z
            )
            
            // Calculate horizontal distance (X-Z plane)
            let horizontalDistance = sqrt(
                pow(boxPosition.x - existingPos.x, 2) +
                pow(boxPosition.z - existingPos.z, 2)
            )
            
            // Calculate vertical distance (Y-axis)
            let verticalDistance = abs(boxPosition.y - existingPos.y)
            
            // Check both horizontal and vertical separation
            if horizontalDistance < minHorizontalSeparation {
                Swift.print("⚠️ Rejected placement of \(location.name) - too close horizontally to existing object '\(existingId)'")
                Swift.print("   Horizontal distance: \(String(format: "%.2f", horizontalDistance))m (minimum: \(minHorizontalSeparation)m)")
                Swift.print("   Vertical distance: \(String(format: "%.2f", verticalDistance))m")
                return
            }
            
            // Also check if objects are stacking vertically (same X-Z position but different Y)
            if horizontalDistance < 0.5 && verticalDistance < minVerticalSeparation {
                Swift.print("⚠️ Rejected placement of \(location.name) - stacking detected with existing object '\(existingId)'")
                Swift.print("   Horizontal distance: \(String(format: "%.2f", horizontalDistance))m")
                Swift.print("   Vertical distance: \(String(format: "%.2f", verticalDistance))m (minimum: \(minVerticalSeparation)m)")
                return
            }
        }
        
        // CRITICAL: Final safety check - ensure minimum 3m distance from camera
        // BUT: Skip this check for manually placed objects (objects with AR coordinates)
        // Manually placed objects were intentionally placed by the user, so allow any distance
        let isManuallyPlaced = location.ar_offset_x != nil &&
                               location.ar_offset_y != nil &&
                               location.ar_offset_z != nil

        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place box: no AR frame available")
            return
        }
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let distanceFromCamera = length(boxPosition - cameraPos)

        if !isManuallyPlaced && distanceFromCamera < 3.0 {
            Swift.print("⚠️ Rejected placement of \(location.name) - too close to camera (\(String(format: "%.2f", distanceFromCamera))m)")
            return
        } else if isManuallyPlaced && distanceFromCamera < 3.0 {
            Swift.print("✅ Allowing manually placed object '\(location.name)' at close range (\(String(format: "%.2f", distanceFromCamera))m)")
        }

        // CRITICAL: Always ensure object is grounded on a horizontal surface
        // This ensures artifacts sit on the ground or whatever horizontal surface is beneath them
        var groundedPosition = boxPosition
        
        // Always try to find and use the actual detected surface first
        if let surfaceY = groundingService?.findSurfaceOrDefault(
            x: boxPosition.x,
            z: boxPosition.z,
            cameraPos: cameraPos,
            objectType: location.type
        ) {
            // Use detected surface Y coordinate - object will sit on this surface
            groundedPosition = SIMD3<Float>(boxPosition.x, surfaceY, boxPosition.z)
            Swift.print("✅ Grounded object on detected horizontal surface at Y: \(String(format: "%.2f", surfaceY))")
        } else {
            // Fallback: should not reach here as findSurfaceOrDefault always returns a value
            // But keep this for safety
            let defaultY = groundingService?.getDefaultGroundHeight(for: location.type, cameraPos: cameraPos) ?? (cameraPos.y - 1.5)
            groundedPosition = SIMD3<Float>(boxPosition.x, defaultY, boxPosition.z)
            Swift.print("⚠️ Grounding fallback - using default height: Y=\(String(format: "%.2f", defaultY))")
        }
        
        // Verify object is not floating (should be at or very close to detected surface)
        let heightDifference = abs(groundedPosition.y - boxPosition.y)
        if heightDifference > 0.1 {
            Swift.print("📏 Grounding adjustment: Y changed by \(String(format: "%.3f", heightDifference))m to sit on surface")
        }
        
        // DEBUG: Log position details
        Swift.print("📍 Placing at position: (\(String(format: "%.2f", groundedPosition.x)), \(String(format: "%.2f", groundedPosition.y)), \(String(format: "%.2f", groundedPosition.z)))")
        Swift.print("📍 Camera position: (\(String(format: "%.2f", cameraPos.x)), \(String(format: "%.2f", cameraPos.y)), \(String(format: "%.2f", cameraPos.z)))")
        Swift.print("📍 Distance from camera: \(String(format: "%.2f", distanceFromCamera))m")
        Swift.print("📍 Height difference (camera - box): \(String(format: "%.2f", cameraPos.y - groundedPosition.y))m")
        
        // Use same simple world anchor approach as spheres for consistency
        // This ensures boxes stay fixed in world space and don't follow the camera
        let anchor = AnchorEntity(world: groundedPosition)
        // CRITICAL: Set anchor name to location.id so tap detection works even if entity hit test fails
        anchor.name = location.id
        
        // Determine object type based on location type from dropdown selection
        let selectedObjectType: PlacedObjectType
        switch location.type {
        case .chalice:
            selectedObjectType = .chalice
        case .sphere:
            selectedObjectType = .sphere
        case .cube:
            selectedObjectType = .cube
        case .templeRelic, .treasureChest, .lootChest, .lootCart, .turkey:
            selectedObjectType = .treasureBox
        }

        Swift.print("🎲 Placing \(selectedObjectType) (\(location.type.displayName)) for \(location.name)")
        Swift.print("   Location ID: \(location.id)")
        Swift.print("   Location type: \(location.type)")
        Swift.print("   Selected object type: \(selectedObjectType)")

        // Use factory to create entity - each factory encapsulates its own creation logic
        Swift.print("🎯 Creating \(location.type.displayName) using factory for \(location.name)")
        Swift.print("   Location type: \(location.type), Factory type: \(type(of: location.type.factory))")
        // Calculate size multiplier to ensure final size doesn't exceed 2 feet (0.61m)
        // Max multiplier = 0.61 / baseSize, capped at 1.0
        let baseSize = location.type.size
        let maxMultiplier = min(1.0, 0.61 / baseSize) // Ensure final size <= 0.61m
        let minMultiplier = max(0.5, maxMultiplier * 0.7) // Keep some variety but stay under limit
        let sizeMultiplier = Float.random(in: minMultiplier...maxMultiplier) // Vary size for variety, capped at 2 feet
        let factory = location.type.factory
        
        // CRITICAL: Verify each type uses its correct factory to ensure proper separation
        // Check factory type name to ensure correct factory is being used
        // Note: This verification could be removed if we trust the registry, but it's useful for debugging
        let factoryTypeName = String(describing: type(of: factory))
        Swift.print("✅ Using factory \(factoryTypeName) for \(location.type.displayName)")
        
        let (entity, findable) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: sizeMultiplier)
        
        let placedEntity = entity
        let findableObject = findable
        
        // Add the placed entity to the anchor
        anchor.addChild(placedEntity)
        
        // FINAL GROUND SNAP: ensure the visual mesh sits exactly on the detected ground plane
        // Even if the model's pivot isn't at its base, this will align the lowest point of the
        // rendered geometry with the groundedPosition.y height so objects never appear to float.
        // Calculate bounds relative to the anchor (not world space) to get accurate entity bounds
        let bounds = placedEntity.visualBounds(relativeTo: anchor)
        let currentMinY = bounds.min.y  // This is relative to anchor, so entity's lowest point relative to anchor
        let desiredMinY: Float = 0  // We want the bottom of the object at anchor Y (0 relative to anchor)
        let deltaY = desiredMinY - currentMinY
        
        // Adjust entity position (not anchor position) so base aligns with anchor Y
        // The anchor is already at groundedPosition, so we just need to adjust the entity
        placedEntity.position.y += deltaY
        
        let formattedDeltaY = String(format: "%.3f", deltaY)
        Swift.print("✅ [GroundSnap] Adjusted '\(location.name)' to sit on ground: ΔY=\(formattedDeltaY)m")
        
        // Store the anchor and findable object
        arView.scene.addAnchor(anchor)
        placedBoxes[location.id] = anchor
        objectPlacementTimes[location.id] = Date() // Record placement time for grace period

        Swift.print("✅✅✅ ANCHOR ADDED TO SCENE! ✅✅✅")
        Swift.print("   Anchor ID: \(location.id)")
        Swift.print("   Anchor has \(anchor.children.count) children")
        Swift.print("   Entity isEnabled: \(placedEntity.isEnabled)")
        Swift.print("   Entity isActive: \(placedEntity.isActive)")
        Swift.print("   Total anchors in scene: \(arView.scene.anchors.count)")
        Swift.print("   Total placed boxes tracked: \(placedBoxes.count)")

        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // DEBUG: Log final world positions
        let finalAnchorTransform = anchor.transformMatrix(relativeTo: nil)
        let finalAnchorPos = SIMD3<Float>(
            finalAnchorTransform.columns.3.x,
            finalAnchorTransform.columns.3.y,
            finalAnchorTransform.columns.3.z
        )

        Swift.print("✅ Placed \(selectedObjectType) at AR position: \(finalAnchorPos)")
        
        // DEBUG: Log container info
        Swift.print("   FindableObject created:")
        Swift.print("     - Has container: \(findableObject.container != nil)")
        Swift.print("     - Has location: \(findableObject.location != nil)")
        Swift.print("     - Location name: \(findableObject.location?.name ?? "nil")")
        if let container = findableObject.container {
            Swift.print("     - Container has box: \(container.box.name)")
            Swift.print("     - Container has lid: \(container.lid.name)")
            Swift.print("     - Container has prize: \(container.prize.name)")
            Swift.print("     - Built-in animation: \(container.builtInAnimation != nil ? "YES" : "NO")")
        }

        // Set callback to increment found count
        findableObject.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        findableObjects[location.id] = findableObject
        Swift.print("   ✅ Stored FindableObject in findableObjects dictionary")

        // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
        // The tap handler needs direct access to findableObjects for tap detection to work
        tapHandler?.findableObjects[location.id] = findableObject
        Swift.print("   ✅ Updated tap handler's findableObjects - object is now tappable")
        
        // Start continuous loop animation if the factory supports it
        // This is especially important for animated models like the turkey
        factory.animateLoop(entity: placedEntity)

        // CRITICAL: Save AR coordinates for manually placed objects (prevents removal by checkAndPlaceBoxes)
        // For objects placed at lat/lon 0,0 (manual placement via tap), save AR coordinates
        if location.latitude == 0 && location.longitude == 0 {
            // This is a manually placed object - save AR coordinates to prevent removal
            if let locationManager = locationManager,
               let arOrigin = arOriginLocation,
               let index = locationManager.locations.firstIndex(where: { $0.id == location.id }) {
                var updatedLocation = locationManager.locations[index]
                updatedLocation.ar_origin_latitude = arOrigin.coordinate.latitude
                updatedLocation.ar_origin_longitude = arOrigin.coordinate.longitude
                updatedLocation.ar_offset_x = Double(groundedPosition.x)
                updatedLocation.ar_offset_y = Double(groundedPosition.y)
                updatedLocation.ar_offset_z = Double(groundedPosition.z)
                locationManager.locations[index] = updatedLocation
                locationManager.saveLocations()
                Swift.print("✅ Saved AR coordinates for manually placed object '\(location.name)'")
                Swift.print("   AR offset: (\(String(format: "%.4f", groundedPosition.x)), \(String(format: "%.4f", groundedPosition.y)), \(String(format: "%.4f", groundedPosition.z)))m")
                Swift.print("   This object will NOT be removed by checkAndPlaceBoxes")
            }
        }

        // Database indicators removed - no longer adding visual indicators to objects
    }
    
    // MARK: - DMTNT NPC Placement
    
    /// Place an NPC in AR for story mode
    /// - Parameters:
    ///   - type: The type of NPC to place (skeleton, corgi, etc.)
    ///   - arView: The AR view to place the NPC in
    private func placeNPC(type: NPCType, in arView: ARView) {
        // Check if already placed - verify the anchor is actually in the scene
        if let existingAnchor = placedNPCs[type.npcId] {
            // Verify the anchor is still in the scene (might have been removed)
            if arView.scene.anchors.contains(where: { ($0 as? AnchorEntity) === existingAnchor }) {
                Swift.print("💬 \(type.defaultName) already placed and in scene, skipping")
                return
            } else {
                // Anchor was removed but not cleaned up - remove from tracking
                Swift.print("⚠️ \(type.defaultName) anchor was removed but not cleaned up - fixing")
                placedNPCs.removeValue(forKey: type.npcId)
                if type == .skeleton {
                    skeletonPlaced = false
                    skeletonAnchor = nil
                } else if type == .corgi {
                    corgiPlaced = false
                }
            }
        }
        
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place \(type.defaultName): AR frame not available")
            return
        }
        
        Swift.print("💬 Placing \(type.defaultName) NPC for story mode...")
        Swift.print("   Game mode: \(locationManager?.gameMode.displayName ?? "unknown")")
        Swift.print("   Model: \(type.modelName).usdz")
        
        // Load the NPC model
        guard let modelURL = Bundle.main.url(forResource: type.modelName, withExtension: "usdz") else {
            Swift.print("❌ Could not find \(type.modelName).usdz in bundle")
            Swift.print("   Make sure \(type.modelName).usdz is added to the Xcode project")
            Swift.print("   Bundle path: \(Bundle.main.bundlePath)")
            return
        }
        
        Swift.print("✅ Found model at: \(modelURL.path)")
        
        do {
            // Load the NPC model
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)
            
            // Wrap in ModelEntity for proper scaling
            let npcEntity = ModelEntity()
            npcEntity.addChild(loadedEntity)
            
            // Scale NPC to reasonable size
            // Skeleton size is defined in SKELETON_SCALE constant above
            let npcScale: Float = type == .skeleton ? Self.SKELETON_SCALE : 0.5
            npcEntity.scale = SIMD3<Float>(repeating: npcScale)
            
            // Position NPC in front of camera
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
            
            // Place NPCs at different distances to avoid overlap
            // Skeleton: 5.5m (more distant), Corgi: 4.5m (to the side)
            let baseDistance: Float = type == .skeleton ? 5.5 : 4.5
            let sideOffset: Float = type == .corgi ? 1.5 : 0.0 // Place corgi to the side
            let right = SIMD3<Float>(-cameraTransform.columns.0.x, -cameraTransform.columns.0.y, -cameraTransform.columns.0.z)
            let targetPosition = cameraPos + forward * baseDistance + right * sideOffset
            
            // Use grounding service to properly ground the NPC on surfaces
            // This ensures the skeleton is placed on the floor or highest blocking surface
            // CRITICAL: The skeleton model's pivot point determines where the feet are.
            // If pivot is at center, we need to offset by half height downward.
            // If pivot is at bottom/feet, no offset needed. We'll assume pivot is at bottom for now.
            let npcPosition: SIMD3<Float>
            if let groundingService = groundingService {
                // Use grounding service to find proper surface height
                let groundedPosition = groundingService.groundPosition(targetPosition, cameraPos: cameraPos)
                
                // The grounding service returns the surface Y where the object should rest.
                // For skeleton, if the model pivot is at the center (not at feet), we'd need to offset.
                // Based on SKELETON_HEIGHT_OFFSET (1.65m), if pivot is at center, feet would be 0.825m below.
                // However, most 3D models have pivot at bottom/feet, so we'll use 0 offset initially.
                // If skeleton appears floating, adjust this offset.
                let skeletonFootOffset: Float = 0.0 // Adjust if skeleton model pivot is at center instead of feet
                npcPosition = SIMD3<Float>(
                    groundedPosition.x,
                    groundedPosition.y + skeletonFootOffset,
                    groundedPosition.z
                )
                Swift.print("✅ \(type.defaultName) grounded using ARGroundingService")
                Swift.print("   Surface Y: \(String(format: "%.2f", groundedPosition.y))")
                Swift.print("   Final anchor Y: \(String(format: "%.2f", npcPosition.y))")
                Swift.print("   Foot offset: \(String(format: "%.2f", skeletonFootOffset))m")
            } else {
                // Fallback: use simple raycast if grounding service not available
                let raycastQuery = ARRaycastQuery(
                    origin: SIMD3<Float>(targetPosition.x, cameraPos.y, targetPosition.z),
                    direction: SIMD3<Float>(0, -1, 0),
                    allowing: .estimatedPlane,
                    alignment: .horizontal
                )
                
                let raycastResults = arView.session.raycast(raycastQuery)
                
                if let firstResult = raycastResults.first {
                    let surfaceY = firstResult.worldTransform.columns.3.y
                    // Same foot offset logic as grounding service path
                    let skeletonFootOffset: Float = 0.0
                    npcPosition = SIMD3<Float>(
                        firstResult.worldTransform.columns.3.x,
                        surfaceY + skeletonFootOffset,
                        firstResult.worldTransform.columns.3.z
                    )
                    Swift.print("✅ \(type.defaultName) grounded using raycast at Y: \(String(format: "%.2f", npcPosition.y))")
                } else {
                    // Final fallback: use camera Y position (assume ground level)
                    // Skeleton height offset is defined in SKELETON_HEIGHT_OFFSET constant above
                    npcPosition = SIMD3<Float>(
                        targetPosition.x,
                        cameraPos.y - (type == .skeleton ? Self.SKELETON_HEIGHT_OFFSET : 1.2), // Skeleton taller, corgi shorter
                        targetPosition.z
                    )
                    Swift.print("⚠️ \(type.defaultName) using fallback ground height: Y=\(String(format: "%.2f", npcPosition.y))")
                }
            }
            
            // Create anchor for NPC
            let anchor = AnchorEntity(world: npcPosition)
            anchor.name = type.npcId
            npcEntity.name = type.npcId // Make it tappable

            // Add collision component for tap detection
            // Use a bounding box collision shape that covers the NPC model
            // Skeleton collision size is defined in SKELETON_COLLISION_SIZE constant above
            let collisionSize: SIMD3<Float> = type == .skeleton
                ? Self.SKELETON_COLLISION_SIZE
                : SIMD3<Float>(0.8, 0.6, 0.8) // Corgi: short and wide
            let collisionShape = ShapeResource.generateBox(size: collisionSize)
            npcEntity.collision = CollisionComponent(shapes: [collisionShape])
            
            // Enable input handling so the entity can be tapped
            npcEntity.components.set(InputTargetComponent())

            // Make NPC face the camera while keeping it upright
            let cameraDirection = normalize(cameraPos - npcPosition)
            
            // Project camera direction onto horizontal plane (XZ plane) to keep NPC upright
            let horizontalDirection = normalize(SIMD3<Float>(cameraDirection.x, 0, cameraDirection.z))
            
            // Calculate rotation to face camera (only horizontal rotation, Y-axis stays up)
            // Default forward direction is -Z, so we rotate to face horizontalDirection
            let modelForward = SIMD3<Float>(0, 0, -1) // Model's default forward direction
            var angle = atan2(horizontalDirection.x, horizontalDirection.z) - atan2(modelForward.x, modelForward.z)
            
            // Fix skeleton rotation: add 180° (π radians) to face the correct direction
            if type == .skeleton {
                angle += Float.pi
            }
            
            // Create rotation quaternion around Y-axis only (keeps model upright)
            let yAxis = SIMD3<Float>(0, 1, 0)
            let rotation = simd_quatf(angle: angle, axis: yAxis)
            
            npcEntity.orientation = rotation
            
            anchor.addChild(npcEntity)
            arView.scene.addAnchor(anchor)
            
            // Track NPC
            placedNPCs[type.npcId] = anchor
            // Also update tap handler's placedNPCs so it can detect taps
            tapHandler?.placedNPCs = placedNPCs
            
            if type == .skeleton {
                skeletonAnchor = anchor
                skeletonPlaced = true
            } else if type == .corgi {
                corgiPlaced = true
            }
            
            Swift.print("✅ \(type.defaultName) NPC placed at position: \(npcPosition)")
            Swift.print("   \(type.defaultName) is tappable and ready for interaction")
            
            // Add NPC to map in Dead Men's Secrets mode
            if let locationManager = locationManager,
               locationManager.gameMode == .deadMensSecrets,
               let arOrigin = arOriginLocation {
                // Convert AR position to GPS coordinates
                let distance = sqrt(npcPosition.x * npcPosition.x + npcPosition.z * npcPosition.z)
                let bearing = atan2(Double(npcPosition.x), -Double(npcPosition.z)) * 180.0 / .pi
                let normalizedBearing = (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
                let npcGPS = arOrigin.coordinate.coordinate(atDistance: Double(distance), atBearing: normalizedBearing)
                
                // Create a special location for the NPC (only in Dead Men's Secrets mode)
                // Note: This is just for local display - NPCs are synced via NPC API, not object API
                let npcLocation = LootBoxLocation(
                    id: "npc_\(type.npcId)",
                    name: type.defaultName,
                    type: type == .skeleton ? .treasureChest : .chalice, // Use existing type for icon
                    latitude: npcGPS.latitude,
                    longitude: npcGPS.longitude,
                    radius: 10.0,
                    collected: false,
                    source: .arManual // Mark as AR manual to prevent auto-sync as object
                )
                
                // Remove existing NPC location if any, then add new one
                locationManager.locations.removeAll { $0.id == npcLocation.id }
                locationManager.addLocation(npcLocation)
                
                Swift.print("🗺️ Added \(type.defaultName) to map at GPS: (\(String(format: "%.8f", npcGPS.latitude)), \(String(format: "%.8f", npcGPS.longitude)))")
                
                // Send NPC location to server so it appears on admin map
                // Use the NPC API endpoint instead of object API
                Task {
                    do {
                        // Convert AR position to GPS if we have AR origin
                        if let arOrigin = arOriginLocation {
                            let distance = sqrt(npcPosition.x * npcPosition.x + npcPosition.z * npcPosition.z)
                            let bearing = atan2(Double(npcPosition.x), -Double(npcPosition.z)) * 180.0 / .pi
                            let normalizedBearing = (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
                            let npcGPS = arOrigin.coordinate.coordinate(atDistance: Double(distance), atBearing: normalizedBearing)
                            
                            // Create NPC on server with AR coordinates
                            _ = try await APIService.shared.createNPC(
                                id: type.npcId,
                                name: type.defaultName,
                                npcType: type.npcType,
                                latitude: npcGPS.latitude,
                                longitude: npcGPS.longitude,
                                arOriginLatitude: arOrigin.coordinate.latitude,
                                arOriginLongitude: arOrigin.coordinate.longitude,
                                arOffsetX: Double(npcPosition.x),
                                arOffsetY: Double(npcPosition.y),
                                arOffsetZ: Double(npcPosition.z)
                            )
                            Swift.print("✅ Sent \(type.defaultName) to server via NPC API")
                        } else {
                            // No AR origin - use default GPS location
                            _ = try await APIService.shared.createNPC(
                                id: type.npcId,
                                name: type.defaultName,
                                npcType: type.npcType,
                                latitude: npcLocation.latitude,
                                longitude: npcLocation.longitude
                            )
                            Swift.print("✅ Sent \(type.defaultName) to server via NPC API (no AR origin)")
                        }
                    } catch {
                        Swift.print("⚠️ Failed to send \(type.defaultName) to server: \(error.localizedDescription)")
                    }
                }
            }
            
        } catch {
            Swift.print("❌ Error loading \(type.defaultName) model: \(error)")
        }
    }
    
    // MARK: - NPC Sync Handlers
    
    /// Set up WebSocket handlers for NPC sync (two-way sync with admin)
    private func setupNPCSyncHandlers() {
        // Handle NPC created event from admin
        WebSocketService.shared.onNPCCreated = { [weak self] npcData in
            guard let self = self, let arView = self.arView else { return }
            self.handleNPCCreated(npcData: npcData, in: arView)
        }
        
        // Handle NPC updated event from admin
        WebSocketService.shared.onNPCUpdated = { [weak self] npcData in
            guard let self = self, let arView = self.arView else { return }
            self.handleNPCUpdated(npcData: npcData, in: arView)
        }
        
        // Handle NPC deleted event from admin
        WebSocketService.shared.onNPCDeleted = { [weak self] npcId in
            guard let self = self else { return }
            self.handleNPCDeleted(npcId: npcId)
        }
    }
    
    /// Handle NPC created event - place NPC in AR
    private func handleNPCCreated(npcData: [String: Any], in arView: ARView) {
        guard let npcId = npcData["id"] as? String,
              let npcTypeString = npcData["npc_type"] as? String else {
            Swift.print("⚠️ NPC created event missing required fields")
            return
        }
        
        // Convert npc_type string to NPCType enum
        guard let npcType = NPCType.allCases.first(where: { $0.npcType == npcTypeString || $0.rawValue == npcTypeString }) else {
            Swift.print("⚠️ Unknown NPC type: \(npcTypeString)")
            return
        }
        
        // Check if already placed
        if placedNPCs[npcId] != nil {
            Swift.print("💬 NPC \(npcId) already placed, skipping")
            return
        }
        
        Swift.print("💬 Syncing NPC created: \(npcId) (\(npcTypeString))")
        
        // If NPC has AR coordinates, use them; otherwise place in front of camera
        if let arOffsetX = npcData["ar_offset_x"] as? Double,
           let arOffsetY = npcData["ar_offset_y"] as? Double,
           let arOffsetZ = npcData["ar_offset_z"] as? Double,
           let _ = npcData["ar_origin_latitude"] as? Double,
           let _ = npcData["ar_origin_longitude"] as? Double,
           let _ = userLocationManager?.currentLocation {
            // Use stored AR coordinates
            let arPosition = SIMD3<Float>(
                Float(arOffsetX),
                Float(arOffsetY),
                Float(arOffsetZ)
            )
            
            // Place NPC at stored AR position
            placeNPCAtPosition(arPosition, type: npcType, npcId: npcId, in: arView)
        } else {
            // No AR coordinates - place in front of camera (default behavior)
            placeNPC(type: npcType, in: arView)
        }
    }
    
    /// Handle NPC updated event - update NPC position or properties
    private func handleNPCUpdated(npcData: [String: Any], in arView: ARView) {
        guard let npcId = npcData["id"] as? String else {
            Swift.print("⚠️ NPC updated event missing id")
            return
        }
        
        Swift.print("💬 Syncing NPC updated: \(npcId)")
        
        // Remove existing NPC if placed
        if let existingAnchor = placedNPCs[npcId] {
            existingAnchor.removeFromParent()
            placedNPCs.removeValue(forKey: npcId)
            tapHandler?.placedNPCs = placedNPCs
        }
        
        // Re-place NPC with updated data
        handleNPCCreated(npcData: npcData, in: arView)
    }
    
    /// Handle NPC deleted event - remove NPC from AR
    private func handleNPCDeleted(npcId: String) {
        Swift.print("💬 Syncing NPC deleted: \(npcId)")
        
        if let anchor = placedNPCs[npcId] {
            anchor.removeFromParent()
            placedNPCs.removeValue(forKey: npcId)
            tapHandler?.placedNPCs = placedNPCs
            
            // Update tracking flags
            if npcId == NPCType.skeleton.npcId {
                skeletonPlaced = false
                skeletonAnchor = nil
            } else if npcId == NPCType.corgi.npcId {
                corgiPlaced = false
            }
            
            Swift.print("✅ Removed NPC \(npcId) from AR scene")
        }
    }
    
    /// Place NPC at a specific AR position (used for synced NPCs)
    private func placeNPCAtPosition(_ position: SIMD3<Float>, type: NPCType, npcId: String, in arView: ARView) {
        // Load and place NPC model at the specified position
        guard let modelURL = Bundle.main.url(forResource: type.modelName, withExtension: "usdz") else {
            Swift.print("❌ Could not find \(type.modelName).usdz in bundle")
            return
        }
        
        do {
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)
            let npcEntity = ModelEntity()
            npcEntity.addChild(loadedEntity)
            
            let npcScale: Float = type == .skeleton ? Self.SKELETON_SCALE : 0.5
            npcEntity.scale = SIMD3<Float>(repeating: npcScale)
            
            let anchor = AnchorEntity(world: position)
            anchor.name = npcId
            npcEntity.name = npcId
            
            let collisionSize: SIMD3<Float> = type == .skeleton
                ? Self.SKELETON_COLLISION_SIZE
                : SIMD3<Float>(0.8, 0.6, 0.8)
            let collisionShape = ShapeResource.generateBox(size: collisionSize)
            npcEntity.collision = CollisionComponent(shapes: [collisionShape])
            npcEntity.components.set(InputTargetComponent())
            
            anchor.addChild(npcEntity)
            arView.scene.addAnchor(anchor)
            
            placedNPCs[npcId] = anchor
            tapHandler?.placedNPCs = placedNPCs
            
            if type == .skeleton {
                skeletonPlaced = true
                skeletonAnchor = anchor
            } else if type == .corgi {
                corgiPlaced = true
            }
            
            Swift.print("✅ Placed synced NPC \(npcId) at position: \(position)")
        } catch {
            Swift.print("❌ Error loading NPC model: \(error)")
        }
    }
    
    // MARK: - NPC Interaction
    
    /// Handle tap on any NPC - opens conversation
    /// - Parameter type: The type of NPC that was tapped
    private func handleNPCTap(type: NPCType) {
        Swift.print("💬 ========== handleNPCTap CALLED ==========")
        Swift.print("   NPC Type: \(type.rawValue)")
        Swift.print("   NPC Name: \(type.defaultName)")
        Swift.print("   NPC ID: \(type.npcId)")

        // Show conversation alert
        // Note: In a full implementation, this would open a proper conversation view
        DispatchQueue.main.async { [weak self] in
            Swift.print("   📞 Calling showNPCConversation on main thread")
            self?.showNPCConversation(type: type)
        }
    }
    
    /// Show NPC conversation UI
    /// - Parameter type: The type of NPC to show conversation for
    private func showNPCConversation(type: NPCType) {
        Swift.print("   ========== showNPCConversation CALLED ==========")
        Swift.print("   NPC: \(type.defaultName)")

        guard let locationManager = locationManager else {
            Swift.print("   ❌ ERROR: locationManager is nil!")
            return
        }

        Swift.print("   Current game mode: \(locationManager.gameMode.rawValue)")

        // For skeleton, always open the conversation view
        if type == .skeleton {
            Swift.print("   📱 Opening SkeletonConversationView (full-screen dialog)")
            // CRITICAL: Clear binding first to ensure onChange fires even if it was previously set
            // This allows re-tapping after the dialog is dismissed
            self.conversationNPCBinding?.wrappedValue = nil
            // Small delay to ensure the nil value is processed before setting the new value
            DispatchQueue.main.async { [weak self] in
                self?.conversationNPCBinding?.wrappedValue = ConversationNPC(
                    id: type.npcId,
                    name: type.defaultName
                )
                Swift.print("   ✅ ConversationNPC binding set: id=\(type.npcId), name=\(type.defaultName)")
            }
        }

        // Handle different game modes
        Swift.print("   🎮 Checking game mode...")
        switch locationManager.gameMode {
        case .open:
            Swift.print("   ℹ️ Open mode - no special game mode handling")
            break

        case .deadMensSecrets:
            Swift.print("   🎯 Dead Men's Secrets mode - full conversation view is already shown above")
            // NOTE: We no longer show the UIAlertController text input here because
            // the full-screen SkeletonConversationView (opened above) provides a better UX.
            // The conversation view handles all interactions.
            
        }
    }
    
    /// Combine map pieces to reveal treasure location
    private func combineMapPieces() {
        Swift.print("🗺️ Combining map pieces - revealing treasure location!")
        
        // Show notification that map is combined
        collectionNotificationBinding?.wrappedValue = "🗺️ Map Combined! The treasure location has been revealed on the map!"
        
        // Hide notification after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.collectionNotificationBinding?.wrappedValue = nil
        }
        
        // TODO: In a full implementation, this would:
        // 1. Reveal a special treasure location on the map
        // 2. Place a treasure chest at a specific GPS location
        // 3. Show visual indicators in AR
        Swift.print("💡 Map pieces combined - treasure location should be revealed")
    }
    
    /// Show text input prompt for skeleton conversation (Dead Men's Secrets mode)
    private func showSkeletonTextInput(for skeletonEntity: AnchorEntity, in arView: ARView, npcId: String, npcName: String) {
        Swift.print("   ========== showSkeletonTextInput CALLED ==========")
        Swift.print("   NPC ID: \(npcId)")
        Swift.print("   NPC Name: \(npcName)")
        Swift.print("   Skeleton Entity: \(skeletonEntity.name)")

        // Show alert with text input
        DispatchQueue.main.async {
            Swift.print("   📝 Creating UIAlertController for text input...")
            let alert = UIAlertController(title: "💀 Talk to \(npcName)", message: "Ask the skeleton about the treasure...", preferredStyle: .alert)
            
            alert.addTextField { textField in
                textField.placeholder = "Ask about the treasure..."
                textField.autocapitalizationType = .sentences
            }
            
            alert.addAction(UIAlertAction(title: "Ask", style: .default) { [weak self] _ in
                guard let self = self,
                      let textField = alert.textFields?.first,
                      let message = textField.text,
                      !message.isEmpty else {
                    return
                }

                // Show user message in 2D overlay (bottom third of screen)
                self.conversationManager?.showMessage(
                    npcName: npcName,
                    message: message,
                    isUserMessage: true,
                    duration: 2.0
                )

                // Check if this is a map/direction request
                let isMapRequest = self.treasureHuntService?.isMapRequest(message) ?? false

                // Get response from API
                Task {
                    do {
                        if isMapRequest, let userLocation = self.userLocationManager?.currentLocation {
                            // User is asking for the map - fetch and show treasure map via service
                            Swift.print("🗺️ Map request detected in message: '\(message)'")
                            try await self.treasureHuntService?.handleMapRequest(
                                npcId: npcId,
                                npcName: npcName,
                                userLocation: userLocation
                            )
                        } else {
                            // Regular conversation
                            let response = try await APIService.shared.interactWithNPC(
                                npcId: npcId,
                                message: message,
                                npcName: npcName,
                                npcType: "skeleton",
                                isSkeleton: true
                            )

                            await MainActor.run {
                                // Show skeleton response in 2D overlay after a brief delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                                    self?.conversationManager?.showMessage(
                                        npcName: npcName,
                                        message: response.response,
                                        isUserMessage: false,
                                        duration: 10.0
                                    )
                                }
                            }
                        }
                    } catch {
                        await MainActor.run { [weak self] in
                            // Provide user-friendly error messages
                            let errorMessage: String
                            if let apiError = error as? APIError {
                                switch apiError {
                                case .serverError(let message):
                                    if message.contains("LLM service not available") || message.contains("not available") {
                                        errorMessage = "Arr, the treasure map service be down! The server needs the LLM service running. Check the server logs, matey!"
                                    } else {
                                        errorMessage = message
                                    }
                                case .serverUnreachable:
                                    errorMessage = "Arr, I can't reach the server! Make sure it's running and we're on the same network, matey!"
                                case .httpError(let code):
                                    if code == 503 {
                                        errorMessage = "The treasure map service be unavailable! Check if the LLM service is running on the server."
                                    } else {
                                        errorMessage = "Server error \(code). Check the server, matey!"
                                    }
                                default:
                                    errorMessage = apiError.localizedDescription
                                }
                            } else {
                                // For other errors, provide a generic but friendly message
                                let errorDesc = error.localizedDescription
                                if errorDesc.contains("not available") || errorDesc.contains("unreachable") {
                                    errorMessage = "Arr, I can't reach the server! Make sure it's running, matey!"
                                } else {
                                    errorMessage = errorDesc
                                }
                            }

                            // Show error message in 2D overlay (bottom third)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                self?.conversationManager?.showMessage(
                                    npcName: npcName,
                                    message: errorMessage,
                                    isUserMessage: false,
                                    duration: 8.0
                                )
                            }
                        }
                    }
                }
            })
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
            // Present alert from root view controller
            Swift.print("   🎭 Attempting to present UIAlertController...")
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                Swift.print("   ✅ Found root view controller")

                // Check if there's already a presented view controller (like another alert)
                if let presentedVC = rootViewController.presentedViewController {
                    Swift.print("   ⚠️ Found existing presented view controller: \(type(of: presentedVC))")
                    Swift.print("   Dismissing it first...")
                    presentedVC.dismiss(animated: false) {
                        // Present our alert after dismissing the existing one
                        Swift.print("   ✅ Existing alert dismissed, presenting new alert")
                        rootViewController.present(alert, animated: true)
                        Swift.print("   ✅ Alert presented successfully")
                    }
                } else {
                    // No existing alert, present directly
                    Swift.print("   ✅ No existing alerts, presenting directly")
                    rootViewController.present(alert, animated: true)
                    Swift.print("   ✅ Alert presented successfully")
                }
            } else {
                Swift.print("   ❌ ERROR: Could not find root view controller!")
            }
        }
    }
    
    // MARK: - Distance Text Overlay (delegated to ARDistanceTracker)
    
    // Fallback: place in front of camera
    private func placeLootBoxInFrontOfCamera(location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        
        // Try to raycast to find ground plane at least 6m away (further than normal placement)
        // CRITICAL: Use at least 3m minimum distance (preferably more for fallback)
        let fallbackMinDistance: Float = 6.0 // Prefer 6m for fallback placement
        let targetPosition = cameraPos + forward * fallbackMinDistance
        let raycastOrigin = SIMD3<Float>(targetPosition.x, cameraPos.y, targetPosition.z)
        
        // Create raycast query to find horizontal plane
        let raycastQuery = ARRaycastQuery(
            origin: raycastOrigin,
            direction: SIMD3<Float>(0, -1, 0), // Point downward
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        let raycastResults = arView.session.raycast(raycastQuery)
        
        var boxPosition: SIMD3<Float>
        if let result = raycastResults.first {
            let hitPoint = SIMD3<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z
            )
            // Reject ceiling-like hits
            if hitPoint.y > cameraPos.y - 0.2 {
                boxPosition = cameraPos + forward * max(fallbackMinDistance, 1.0)
                boxPosition.y = cameraPos.y - 1.5
                Swift.print("⚠️ Raycast landed on ceiling-like plane. Falling back to estimated ground placement.")
            } else {
                let distanceFromCamera = length(hitPoint - cameraPos)
                // CRITICAL: Enforce minimum 3m distance (preferably 5m for fallback)
                if distanceFromCamera < 3.0 {
                    let direction = normalize(hitPoint - cameraPos)
                    boxPosition = cameraPos + direction * max(fallbackMinDistance, 3.0)
                    boxPosition.y = hitPoint.y
                } else if distanceFromCamera < 5.0 {
                    let direction = normalize(hitPoint - cameraPos)
                    boxPosition = cameraPos + direction * 5.0
                    boxPosition.y = hitPoint.y
                } else {
                    boxPosition = hitPoint
                }
            }
        } else {
            // No plane detected, place at fallback distance in front at estimated ground level
            // CRITICAL: Must be at least 3m away (preferably more)
            boxPosition = cameraPos + forward * max(fallbackMinDistance, 3.0)
            boxPosition.y = cameraPos.y - 1.5

            // DEBUG: Log placement details
            Swift.print("📍 Fallback placement: camera at (\(String(format: "%.1f", cameraPos.x)), \(String(format: "%.1f", cameraPos.y)), \(String(format: "%.1f", cameraPos.z)))")
            Swift.print("📍 Forward direction: (\(String(format: "%.2f", forward.x)), \(String(format: "%.2f", forward.y)), \(String(format: "%.2f", forward.z)))")
            Swift.print("📍 Placing at: (\(String(format: "%.1f", boxPosition.x)), \(String(format: "%.1f", boxPosition.y)), \(String(format: "%.1f", boxPosition.z)))")
        }

        // CRITICAL: Final safety check - enforce ABSOLUTE minimum 3m distance from camera
        let finalDistance = length(boxPosition - cameraPos)
        if finalDistance < 3.0 {
            // If somehow too close, move it to exactly 3m away (absolute minimum)
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * 3.0
            Swift.print("⚠️ CRITICAL: Adjusted \(location.name) placement to 3m MINIMUM distance from camera")
        } else if finalDistance < 5.0 {
            // Prefer 5m for fallback placement
            let direction = normalize(boxPosition - cameraPos)
            boxPosition = cameraPos + direction * 5.0
            Swift.print("⚠️ Adjusted \(location.name) placement to 5m minimum distance from camera")
        }

        // ADDITIONAL SAFETY: Ensure box is below camera level and not too high
        if boxPosition.y > cameraPos.y - 0.5 {
            boxPosition.y = cameraPos.y - 1.5 // Ensure it's at least 1.5m below camera
            Swift.print("⚠️ Adjusted \(location.name) to be below camera level")
        }
        
        // Use the standard placement function instead of duplicating logic
        placeBoxAtPosition(boxPosition, location: location, in: arView)
        Swift.print("✅ Placed \(location.name) in front of camera (fallback) at: \(boxPosition)")
        Swift.print("   Distance from camera: \(String(format: "%.2f", finalDistance))m")
    }
    
    
    
    // MARK: - Find Loot Box Helper
    /// Finds any findable object using the FindableObject base class behavior
    private func findLootBox(locationId: String, anchor: AnchorEntity, cameraPosition: SIMD3<Float>, sphereEntity: ModelEntity?) {
        guard !(distanceTracker?.foundLootBoxes.contains(locationId) ?? false) else {
            return // Already found
        }
        
        // Mark as found to prevent duplicate finds
        distanceTracker?.foundLootBoxes.insert(locationId)
        tapHandler?.foundLootBoxes.insert(locationId)
        
        // Remove distance text when found
        if let textEntity = distanceTracker?.distanceTextEntities[locationId] {
            textEntity.removeFromParent()
            distanceTracker?.distanceTextEntities.removeValue(forKey: locationId)
        }
        
        // Get or create FindableObject for this location
        var findableObject: FindableObject
        if let existing = findableObjects[locationId] {
            // Use existing FindableObject (already has container/sphere info)
            findableObject = existing
            Swift.print("✅ Using existing FindableObject for \(locationId)")
            Swift.print("   Has container: \(findableObject.container != nil)")
            Swift.print("   Has location: \(findableObject.location != nil)")
            // Update sphereEntity if provided (in case it wasn't set initially)
            if let sphereEntity = sphereEntity {
                findableObject.sphereEntity = sphereEntity
            }
        } else {
            Swift.print("⚠️ Creating new FindableObject for \(locationId) (should not happen if placed correctly)")
            // Create new FindableObject (fallback case - should rarely happen)
            let location = locationManager?.locations.first(where: { $0.id == locationId })
            var container: LootBoxContainer? = nil
            
            // Try to get container from component
            if let info = anchor.components[LootBoxInfoComponent.self] {
                container = info.container
            }
            
            // If no container from component, try to find it in anchor's children
            // (containers are typically the main child entity)
            if container == nil {
                for child in anchor.children {
                    if child is ModelEntity,
                       child.name == locationId || child.name.contains("container") {
                        // This might be a container - check if it has prize/lid children
                        // For now, we'll create a minimal container structure if needed
                        // But ideally containers should be stored in FindableObject when placed
                    }
                }
            }
            
            findableObject = FindableObject(
                locationId: locationId,
                anchor: anchor,
                sphereEntity: sphereEntity,
                container: container,
                location: location
            )
            
            // Set callback to increment found count
            findableObject.onFoundCallback = { [weak self] id in
                DispatchQueue.main.async {
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(id)
                    }
                }
            }
            
            findableObjects[locationId] = findableObject

            // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
            tapHandler?.findableObjects[locationId] = findableObject
        }

        // CRITICAL: Mark as collected IMMEDIATELY to prevent re-placement by checkAndPlaceBoxes
        // This must happen before the animation starts to prevent race conditions
        // BUT: Don't remove the object yet - we need it for confetti and animation
        if let foundLocation = findableObject.location {
            DispatchQueue.main.async { [weak self] in
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(foundLocation.id)
                    Swift.print("✅ Marked \(foundLocation.name) as collected immediately to prevent re-placement")
                }
            }
        }
        
        // Use FindableObject's find() method - this encapsulates all the basic findable behavior
        // This will trigger: confetti, sound, animation
        // The object will be removed in the completion callback
        let objectName = findableObject.itemDescription()
        findableObject.find { [weak self] in
            // Show discovery notification AFTER animation completes
            DispatchQueue.main.async { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = "🎉 Discovered: \(objectName)!"
            }
            
            // Hide notification after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = nil
            }
            
            // CRITICAL: Remove anchor from AR scene to make object disappear
            // This happens AFTER confetti and animation complete
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if anchor.parent != nil {
                    Swift.print("🗑️ Removing \(objectName) (ID: \(locationId)) from AR scene (animation completed)...")
                    anchor.removeFromParent()
                    Swift.print("   ✅ Anchor removed from scene - object should now be invisible")
                } else {
                    Swift.print("ℹ️ Object \(objectName) (ID: \(locationId)) already removed from scene")
                }

                // Cleanup after find completes
                if self.placedBoxes[locationId] != nil {
                    self.placedBoxes.removeValue(forKey: locationId)
                    self.findableObjects.removeValue(forKey: locationId)
                    self.objectsInViewport.remove(locationId) // Also remove from viewport tracking
                    Swift.print("   ✅ Removed from placedBoxes (\(self.placedBoxes.count) remaining)")
                } else {
                    Swift.print("   ℹ️ Already removed from placedBoxes")
                }
                
                // Also remove from distance tracker if applicable
                if let textEntity = self.distanceTracker?.distanceTextEntities[locationId] {
                    textEntity.removeFromParent()
                    self.distanceTracker?.distanceTextEntities.removeValue(forKey: locationId)
                }
            }

            // Remove randomized AR items from locationManager when found (they're AR-only, not GPS-based)
            // This keeps the counter accurate - only shows items that are actually placed on screen
            if locationId.hasPrefix("AR_ITEM_") || locationId.hasPrefix("AR_SPHERE_") {
                DispatchQueue.main.async { [weak self] in
                    if let locationManager = self?.locationManager {
                        // Remove the location from locationManager since it's no longer on screen
                        locationManager.locations.removeAll { $0.id == locationId }
                        Swift.print("🗑️ Removed AR item \(locationId) from locationManager (no longer on screen)")
                    }
                }
            }
            
            Swift.print("🎉 Collected: \(objectName)")

            // Check if all randomized AR items are found and disable sphere mode
            if let self = self, self.sphereModeActive {
                // Check for remaining temporary AR items
                let remainingItems = self.placedBoxes.keys.filter { locationId in
                    if let location = self.locationManager?.locations.first(where: { $0.id == locationId }) {
                        return location.isTemporary && location.isAROnly
                    }
                    return false
                }
                if remainingItems.isEmpty {
                    Swift.print("🎯 All randomized AR items collected - exiting sphere mode")
                    self.sphereModeActive = false
                }
            }
        }
    }
    
    // MARK: - Tap Handling (delegated to ARTapHandler)
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        tapHandler?.handleTap(sender)
        guard let arView = arView,
              let locationManager = locationManager,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Tap handler: Missing AR view, location manager, or frame")
            return
        }
        
        let tapLocation = sender.location(in: arView)
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        Swift.print("👆 Tap detected at screen: (\(tapLocation.x), \(tapLocation.y))")
        Swift.print("   Placed boxes count: \(placedBoxes.count), keys: \(placedBoxes.keys.sorted())")
        
        // Get tap world position using raycast
        var tapWorldPosition: SIMD3<Float>? = nil
        if let raycastResult = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first {
            tapWorldPosition = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
        }
        
        // Check if tapped on existing loot box
        // First try direct entity hit
        let tappedEntity: Entity? = arView.entity(at: tapLocation)
        var locationId: String? = nil

        Swift.print("🎯 Tap entity hit test result: \(tappedEntity != nil ? "hit entity" : "no entity hit")")

        // Walk up the entity hierarchy to find the location ID
        var entityToCheck = tappedEntity
        while let currentEntity = entityToCheck {
            let entityName = currentEntity.name
            Swift.print("🎯 Checking entity: '\(entityName)'")
            // Entity.name is a String, not String?, so check if it's not empty
            if !entityName.isEmpty {
                let idString = entityName
                
                // Check if this is an NPC (skeleton, corgi, etc.)
                // CRITICAL: NPCs should NEVER be treated as loot boxes, even if they're accidentally in placedBoxes
                if let npcType = NPCType.allCases.first(where: { $0.npcId == idString }) {
                    Swift.print("💬 \(npcType.defaultName) NPC tapped - opening conversation")
                    handleNPCTap(type: npcType)
                    return // Don't process as regular object - NPCs are not loot boxes
                }
                
                // Check if this ID matches a placed box (but NOT an NPC)
                // Double-check it's not an NPC to prevent accidental matching
                if placedBoxes[idString] != nil && placedNPCs[idString] == nil {
                    locationId = idString
                    Swift.print("🎯 Found matching placed box ID: \(idString)")
                    break
                }
            }
            entityToCheck = currentEntity.parent
        }
        
        // If entity hit didn't work, try proximity-based detection for NPCs first
        // Check all placed NPCs to see if tap is near any of them on screen
        if tappedEntity == nil && !placedNPCs.isEmpty {
            var closestNPCId: String? = nil
            var closestNPCScreenDistance: CGFloat = CGFloat.infinity
            let maxNPCScreenDistance: CGFloat = 250.0 // Maximum screen distance in points to consider a tap "on" the NPC (increased for easier tapping)
            
            for (npcId, anchor) in placedNPCs {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Project the NPC's world position to screen coordinates
                guard let screenPoint = arView.project(anchorWorldPos) else {
                    continue // NPC is not visible (behind camera or outside view)
                }
                
                // Check if the projection is valid (NPC is visible on screen)
                let viewWidth = CGFloat(arView.bounds.width)
                let viewHeight = CGFloat(arView.bounds.height)
                let isOnScreen = screenPoint.x >= 0 && screenPoint.x <= viewWidth &&
                                screenPoint.y >= 0 && screenPoint.y <= viewHeight
                
                if isOnScreen {
                    // Calculate screen-space distance from tap to NPC
                    let tapX = CGFloat(tapLocation.x)
                    let tapY = CGFloat(tapLocation.y)
                    let dx = tapX - screenPoint.x
                    let dy = tapY - screenPoint.y
                    let screenDistance = sqrt(dx * dx + dy * dy)
                    
                    // If screen distance is within threshold, consider it a hit
                    if screenDistance < maxNPCScreenDistance && screenDistance < closestNPCScreenDistance {
                        closestNPCScreenDistance = screenDistance
                        closestNPCId = npcId
                        Swift.print("💬 Found candidate NPC \(npcId): screen dist=\(String(format: "%.1f", screenDistance))px")
                    }
                }
            }
            
            if let npcId = closestNPCId, let npcType = NPCType.allCases.first(where: { $0.npcId == npcId }) {
                Swift.print("💬 \(npcType.defaultName) NPC tapped via proximity detection - opening conversation")
                handleNPCTap(type: npcType)
                return // Don't process as regular object
            }
        }
        
        // If entity hit didn't work, try proximity-based detection using screen-space projection
        // Check all placed boxes to see if tap is near any of them on screen
        if locationId == nil && !placedBoxes.isEmpty {
            var closestBoxId: String? = nil
            var closestScreenDistance: CGFloat = CGFloat.infinity
            let maxScreenDistance: CGFloat = 150.0 // Maximum screen distance in points to consider a tap "on" the box
            
            // Use ARView's project method to convert world positions to screen coordinates
            for (boxId, anchor) in placedBoxes {
                // CRITICAL: Skip NPCs - they should never be treated as loot boxes
                // NPCs are in placedNPCs, but double-check to prevent accidental matching
                if placedNPCs[boxId] != nil {
                    Swift.print("⏭️ Skipping \(boxId) in loot box proximity check - it's an NPC")
                    continue
                }
                
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Project the box's world position to screen coordinates
                guard let optionalScreenPoint = arView.project(anchorWorldPos) else {
                    // Box is not visible (behind camera or outside view)
                    continue
                }
                let screenPoint = optionalScreenPoint
                
                // Check if the projection is valid (box is visible on screen)
                let viewWidth = CGFloat(arView.bounds.width)
                let viewHeight = CGFloat(arView.bounds.height)
                let pointX = screenPoint.x
                let pointY = screenPoint.y
                let isOnScreen = pointX >= 0 && pointX <= viewWidth &&
                                 pointY >= 0 && pointY <= viewHeight
                
                if isOnScreen {
                    // Calculate screen-space distance from tap to box
                    let tapX = CGFloat(tapLocation.x)
                    let tapY = CGFloat(tapLocation.y)
                    let dx = tapX - screenPoint.x
                    let dy = tapY - screenPoint.y
                    let screenDistance = sqrt(dx * dx + dy * dy)
                    
                    // Also check world-space distance if we have tap world position (for validation)
                    var worldDistance: Float = Float.infinity
                    if let tapPos = tapWorldPosition {
                        worldDistance = length(anchorWorldPos - tapPos)
                    }
                    
                    // If screen distance is within threshold, consider it a hit
                    if screenDistance < maxScreenDistance {
                        // If we have world position, prefer boxes that are also close in world space
                        let isCloseInWorld = worldDistance < 10.0
                        let shouldSelect = worldDistance == Float.infinity || isCloseInWorld
                        
                        if shouldSelect && screenDistance < closestScreenDistance {
                            closestScreenDistance = screenDistance
                            closestBoxId = boxId
                            if worldDistance != Float.infinity {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px, world dist=\(String(format: "%.2f", worldDistance))m")
                            } else {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px")
                            }
                        }
                    }
                } else {
                    // Box is not visible on screen (behind camera or outside view)
                    Swift.print("   Box \(boxId) is off-screen (projected to: (\(String(format: "%.1f", screenPoint.x)), \(String(format: "%.1f", screenPoint.y))))")
                }
            }
            
            if let closestId = closestBoxId {
                locationId = closestId
                Swift.print("🎯 Detected tap on box via screen projection: \(closestId), screen distance: \(String(format: "%.1f", closestScreenDistance))px")
            } else {
                Swift.print("⚠️ Tap did not hit any box. Tap world pos: \(tapWorldPosition != nil ? "yes" : "no"), boxes checked: \(placedBoxes.count)")
                // Debug: show where boxes are projected
                for (boxId, anchor) in placedBoxes {
                    let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                    let anchorWorldPos = SIMD3<Float>(
                        anchorTransform.columns.3.x,
                        anchorTransform.columns.3.y,
                        anchorTransform.columns.3.z
                    )
                    if let screenPoint = arView.project(anchorWorldPos) {
                        let distanceFromCamera = length(anchorWorldPos - cameraPos)
                        Swift.print("   Box \(boxId): screen=(\(String(format: "%.1f", screenPoint.x)), \(String(format: "%.1f", screenPoint.y))), camera dist=\(String(format: "%.2f", distanceFromCamera))m")
                    } else {
                        Swift.print("   Box \(boxId): not projectable (behind camera)")
                    }
                }
            }
        }
        
        // UNIFIED FINDABLE BEHAVIOR: All objects in placedBoxes are findable and clickable
        // If we found a location ID (tapped on any findable object), trigger find behavior
        Swift.print("🎯 Tap result: locationId = \(locationId ?? "nil")")
        if let idString = locationId {
            Swift.print("🎯 Processing tap on: \(idString)")
            
            // Check if already found - but also check if location was reset
            // If location is not collected, allow tapping again (reset functionality)
            let isLocationCollected = locationManager.locations.first(where: { $0.id == idString })?.collected ?? false
            
            let isFound = (distanceTracker?.foundLootBoxes.contains(idString) ?? false) || (tapHandler?.foundLootBoxes.contains(idString) ?? false)
            if isFound && isLocationCollected {
                Swift.print("⚠️ Object \(idString) has already been found and is still marked as collected")
                return
            } else if isFound && !isLocationCollected {
                // Location was reset - clear from found set to allow tapping again
                distanceTracker?.foundLootBoxes.remove(idString)
                tapHandler?.foundLootBoxes.remove(idString)
                Swift.print("🔄 Object \(idString) was reset - clearing from found set, allowing tap again")
            }
            
            // Check if in location manager and already collected
            if let location = locationManager.locations.first(where: { $0.id == idString }),
               location.collected {
                Swift.print("⚠️ \(location.name) has already been collected")
                return
            }
            
            // Get the anchor for this object
            guard let anchor = placedBoxes[idString] else {
                Swift.print("⚠️ Anchor not found for \(idString)")
                return
            }
            
            // Get camera position
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            
            // Find the sphere entity if it exists (for objects with spheres)
            var sphereEntity: ModelEntity? = nil
            for child in anchor.children {
                if let modelEntity = child as? ModelEntity,
                   modelEntity.components[PointLightComponent.self] != nil {
                    sphereEntity = modelEntity
                    break
                }
            }
            
            // Use unified findLootBox for ALL objects (spheres, chalices, treasure boxes, etc.)
            // This handles: sound, confetti, animation, increment count, and removal
            Swift.print("🎯 Finding object: \(idString) (type: sphere=\(sphereEntity != nil), has findableObject=\(findableObjects[idString] != nil))")
            findLootBox(locationId: idString, anchor: anchor, cameraPosition: cameraPos, sphereEntity: sphereEntity)
            return
        }
        
        // If no location-based system or not at a location, allow manual placement
        // Place a test loot box where user taps (for testing without locations)
        if placedBoxes.count >= 3 {
            return
        }

        // Prevent rapid duplicate tap placements (debounce)
        let now = Date()
        if let lastTap = tapHandler?.lastTapPlacementTime,
           now.timeIntervalSince(lastTap) < 1.0 {
            Swift.print("⚠️ Tap placement blocked - too soon since last placement (\(String(format: "%.1f", now.timeIntervalSince(lastTap)))s ago)")
            return
        }
        tapHandler?.lastTapPlacementTime = now

        if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first,
           let frame = arView.session.currentFrame {
            let cameraY = frame.camera.transform.columns.3.y
            let hitY = result.worldTransform.columns.3.y
            if hitY <= cameraY - 0.2 {
                let testLocation = LootBoxLocation(
                    id: UUID().uuidString,
                    name: "Test Artifact",
                    type: .templeRelic,
                    latitude: 0,
                    longitude: 0,
                    radius: 100
                )
                // For manual tap placement, allow closer placement (1-2m instead of 3-5m)
                // Add to locationManager FIRST so it's tracked, then place it
                // This ensures the location exists before placement and prevents duplicates
                locationManager.addLocation(testLocation)
                placeLootBoxAtTapLocation(testLocation, tapResult: result, in: arView)
            } else {
                Swift.print("⚠️ Tap raycast hit likely ceiling. Ignoring manual placement.")
            }
        }
    }

    // Place a single sphere in the current AR room
    func placeSingleSphere(locationId: String? = nil) {
        Swift.print("🎯 placeSingleSphere() called - checking if already placed recently...")

        // Prevent multiple placements from rapid view updates
        let now = Date()
        if let lastPlacement = lastSpherePlacementTime,
           now.timeIntervalSince(lastPlacement) < 2.0 {
            Swift.print("⚠️ Sphere placement blocked - too soon since last placement (\(String(format: "%.1f", now.timeIntervalSince(lastPlacement)))s ago)")
            return
        }
        lastSpherePlacementTime = now

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let locationManager = locationManager else {
            Swift.print("⚠️ Cannot place single sphere: AR not ready")
            return
        }

        // Limit to maximum objects (configurable in settings, default 6)
        let maxObjects = locationManager.maxObjectLimit
        guard placedBoxes.count < maxObjects else {
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Try to find ground plane for proper placement
        let raycastQuery = ARRaycastQuery(
            origin: cameraPos,
            direction: SIMD3<Float>(0, -1, 0), // Downward ray
            allowing: .estimatedPlane,
            alignment: .horizontal
        )

        var spherePosition: SIMD3<Float>

        if let raycastResult = arView.session.raycast(raycastQuery).first {
            // Place on detected ground plane, 2m in front of camera
            let groundY = raycastResult.worldTransform.columns.3.y
            let forwardDirection = SIMD3<Float>(
                -cameraTransform.columns.2.x, // Forward vector (negative Z in camera space)
                0,
                -cameraTransform.columns.2.z
            )
            let forwardPos = cameraPos + normalize(forwardDirection) * 2.0
            spherePosition = SIMD3<Float>(forwardPos.x, groundY, forwardPos.z)
            Swift.print("✅ Placed sphere on detected ground plane at Y: \(groundY)")
        } else {
            // Fallback: place 2m in front at current camera height
            spherePosition = cameraPos + SIMD3<Float>(0, 0, -2)
            Swift.print("⚠️ No ground plane detected, placing at camera height")
        }

        // Use provided location ID (from map marker) or create a new one
        let newLocation: LootBoxLocation
        if let existingLocationId = locationId,
           let existingLocation = locationManager.locations.first(where: { $0.id == existingLocationId }) {
            // Use the existing map marker location
            newLocation = existingLocation
            Swift.print("✅ Using existing map marker location: \(existingLocationId)")
        } else {
            // Create a new location (fallback for manual sphere placement)
            newLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: "Mysterious Sphere",
                type: .sphere,
                latitude: 0, // Not GPS-based
                longitude: 0, // Not GPS-based
                radius: 100.0, // Large radius since we're not using GPS
                source: .arManual // Manually placed AR sphere
            )
            // Add to locationManager so it counts toward the total
            // Note: Temporary AR items won't sync to API (by design)
            locationManager.addLocation(newLocation)
            Swift.print("✅ Created new location for sphere: \(newLocation.id)")
            Swift.print("   📍 Note: Temporary AR sphere will NOT sync to API")
        }

        // Create sphere directly
        let sphereRadius: Float = 0.15
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: .red)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = newLocation.id // This is crucial for tap detection

        // Position sphere so bottom sits flat on ground
        sphere.position = SIMD3<Float>(0, sphereRadius, 0) // Bottom of sphere touches ground

        // Add point light to make it visible
        let light = PointLightComponent(color: .red, intensity: 200)
        sphere.components.set(light)

        // Create anchor and add sphere
        let anchor = AnchorEntity(world: spherePosition)
        anchor.addChild(sphere)

        arView.scene.addAnchor(anchor)
        placedBoxes[newLocation.id] = anchor
        objectPlacementTimes[newLocation.id] = Date() // Record placement time for grace period
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to mark as collected when found
        findableObjects[newLocation.id] = FindableObject(
            locationId: newLocation.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: nil,
            location: newLocation
        )

        findableObjects[newLocation.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
        if let findable = findableObjects[newLocation.id] {
            tapHandler?.findableObjects[newLocation.id] = findable
        }

        Swift.print("✅ Placed single sphere at position (\(spherePosition.x), \(spherePosition.y), \(spherePosition.z))")
    }

    // Place any AR item in the current AR room (same size as spheres)
    func placeARItem(_ item: LootBoxLocation) {
        Swift.print("🎯 placeARItem() called for: \(item.name) (ID: \(item.id)) at GPS (\(item.latitude), \(item.longitude))")
        
        // Check if this item should sync to API
        let isTemporaryARItem = item.id.hasPrefix("AR_ITEM_") || 
                               (item.id.hasPrefix("AR_SPHERE_") && !item.id.hasPrefix("AR_SPHERE_MAP_"))
        if isTemporaryARItem {
            Swift.print("   ⏭️ This is a temporary AR item - will NOT sync to API")
        } else {
            Swift.print("   🔄 This is a permanent item - should sync to API if API sync is enabled")
            // Check if item is already in locationManager (which means it should be synced)
            if locationManager?.locations.first(where: { $0.id == item.id }) != nil {
                Swift.print("   ✅ Item already exists in locationManager - API sync status depends on useAPISync setting")
            } else {
                Swift.print("   ⚠️ Item not found in locationManager - may need to be added/synced")
            }
        }

        // CRITICAL: Check if this item is already placed to prevent duplicates
        if placedBoxes[item.id] != nil {
            Swift.print("⚠️ Item \(item.name) (ID: \(item.id)) already placed - skipping duplicate placement")
            return
        }

        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ Cannot place AR item: AR not ready or no user location")
            return
        }
        let _ = locationManager // Location manager checked but unused in this scope

        // Limit to maximum objects (configurable in settings, default 6)
        let maxObjects = locationManager?.maxObjectLimit ?? 6
        guard placedBoxes.count < maxObjects else {
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Calculate GPS-based position
        let targetLocation = CLLocation(latitude: item.latitude, longitude: item.longitude)
        var distance = userLocation.distance(from: targetLocation) // Distance in meters
        let bearing = userLocation.bearing(to: targetLocation) // Bearing in degrees (0-360, 0 = North)
        
        // Ensure minimum distance of 1m for AR placement (items too close are hard to interact with)
        let minDistance: Double = 1.0
        if distance < minDistance {
            Swift.print("⚠️ GPS distance \(String(format: "%.2f", distance))m is too close, using minimum \(minDistance)m")
            distance = minDistance
        }
        
        Swift.print("📍 GPS offset: \(String(format: "%.2f", distance))m at bearing \(String(format: "%.1f", bearing))°")

        // Convert bearing to radians and calculate offset in AR space
        // ARKit uses a right-handed coordinate system where:
        // - X is right (east)
        // - Z is forward (north when camera faces north)
        // - Y is up
        // We need to account for the camera's current orientation
        
        // Get camera's forward direction in AR space
        let cameraForward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            0,
            -cameraTransform.columns.2.z
        )
        let cameraRight = SIMD3<Float>(
            cameraTransform.columns.0.x,
            0,
            cameraTransform.columns.0.z
        )
        
        // Normalize directions
        let forwardDir = normalize(cameraForward)
        let rightDir = normalize(cameraRight)
        
        // Calculate bearing relative to camera's forward direction
        // We need to know which way the camera is facing in GPS terms
        // For now, assume camera forward is roughly north and calculate relative bearing
        // Convert bearing to radians (0 = North, 90 = East, 180 = South, 270 = West)
        let bearingRad = Float(bearing * .pi / 180.0)
        
        // Calculate offset in AR space: use distance and bearing
        // X = distance * sin(bearing) (east/west)
        // Z = distance * cos(bearing) (north/south)
        // But we need to align with camera's orientation
        // For simplicity, place relative to camera's current position
        let offsetX = Float(distance) * sin(bearingRad)
        let offsetZ = Float(distance) * cos(bearingRad)
        
        // Apply offset relative to camera's orientation
        // Rotate the offset to match camera's current orientation
        // This is a simplified approach - for more accuracy, we'd need compass heading
        let targetPos = cameraPos + rightDir * offsetX + forwardDir * offsetZ
        
        // Clamp distance to reasonable AR space (max 10m)
        if distance > 10.0 {
            Swift.print("⚠️ GPS distance \(String(format: "%.2f", distance))m exceeds 10m, clamping to 10m for AR placement")
            let scale = Float(10.0 / distance)
            let adjustedTargetPos = cameraPos + (targetPos - cameraPos) * scale
            // Find the highest blocking surface at adjusted position
            var itemPosition: SIMD3<Float>
            if let surfaceY = groundingService?.findHighestBlockingSurface(x: adjustedTargetPos.x, z: adjustedTargetPos.z, cameraPos: cameraPos) {
                itemPosition = SIMD3<Float>(adjustedTargetPos.x, surfaceY, adjustedTargetPos.z)
                Swift.print("✅ Placed \(item.type.displayName) on surface at AR position (\(String(format: "%.2f", adjustedTargetPos.x)), \(String(format: "%.2f", surfaceY)), \(String(format: "%.2f", adjustedTargetPos.z)))")
            } else {
                itemPosition = adjustedTargetPos
                Swift.print("⚠️ No surface detected, placing at camera height")
            }
            
            // Location is already added to locationManager in addFindableItem, no need to add again
            // Use unified placeBoxAtPosition which handles all object types correctly
            placeBoxAtPosition(itemPosition, location: item, in: arView)
            return
        }

        // Find the highest blocking surface at target position
        var itemPosition: SIMD3<Float>
        if let surfaceY = groundingService?.findHighestBlockingSurface(x: targetPos.x, z: targetPos.z, cameraPos: cameraPos) {
            itemPosition = SIMD3<Float>(targetPos.x, surfaceY, targetPos.z)
            Swift.print("✅ Placed \(item.type.displayName) on surface at AR position (\(String(format: "%.2f", targetPos.x)), \(String(format: "%.2f", surfaceY)), \(String(format: "%.2f", targetPos.z))) based on GPS offset")
        } else {
            // Fallback: place at target position at current camera height
            itemPosition = targetPos
            Swift.print("⚠️ No surface detected, placing \(item.type.displayName) at camera height")
        }

        // Location is already added to locationManager in addFindableItem, no need to add again
        // Use unified placeBoxAtPosition which handles all object types correctly
        placeBoxAtPosition(itemPosition, location: item, in: arView)
    }

    private func createSphereEntity(at position: SIMD3<Float>, item: LootBoxLocation, in arView: ARView) {
        // Create sphere directly (same as placeSingleSphere)
        let sphereRadius: Float = 0.15
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        var sphereMaterial = SimpleMaterial()
        sphereMaterial.color = .init(tint: item.type.color)
        sphereMaterial.roughness = 0.2
        sphereMaterial.metallic = 0.3

        let sphere = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphere.name = item.id

        // Position sphere so bottom sits flat on ground
        sphere.position = SIMD3<Float>(0, sphereRadius, 0)

        // Add point light to make it visible
        let light = PointLightComponent(color: item.type.glowColor, intensity: 200)
        sphere.components.set(light)

        // Create anchor and add sphere
        let anchor = AnchorEntity(world: position)
        anchor.addChild(sphere)

        arView.scene.addAnchor(anchor)
        placedBoxes[item.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to mark as collected when found
        findableObjects[item.id] = FindableObject(
            locationId: item.id,
            anchor: anchor,
            sphereEntity: sphere,
            container: nil,
            location: item
        )

        findableObjects[item.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
        if let findable = findableObjects[item.id] {
            tapHandler?.findableObjects[item.id] = findable
        }

        Swift.print("✅ Placed sphere \(item.name) at position (\(position.x), \(position.y), \(position.z))")
    }

    private func placeItemAsBox(at position: SIMD3<Float>, item: LootBoxLocation, in arView: ARView) {
        // Create a box entity scaled to sphere size (0.15 radius = 0.3 diameter)
        let boxSize: Float = 0.3 // Same size as sphere diameter

        // Create a simple box for the item
        let boxMesh = MeshResource.generateBox(width: boxSize, height: boxSize, depth: boxSize, cornerRadius: 0.05)
        var boxMaterial = SimpleMaterial()
        boxMaterial.color = .init(tint: item.type.color)
        boxMaterial.roughness = 0.3
        boxMaterial.metallic = 0.5

        let boxEntity = ModelEntity(mesh: boxMesh, materials: [boxMaterial])
        boxEntity.name = item.id

        // Position box so bottom sits on ground
        boxEntity.position = SIMD3<Float>(0, boxSize/2, 0)

        // Add point light for visibility
        let light = PointLightComponent(color: item.type.glowColor, intensity: 150)
        boxEntity.components.set(light)

        // Create anchor and add box
        let anchor = AnchorEntity(world: position)
        anchor.addChild(boxEntity)

        arView.scene.addAnchor(anchor)
        placedBoxes[item.id] = anchor
        
        // Apply uniform luminance if ambient light is disabled
        environmentManager?.applyUniformLuminanceToNewEntity(anchor)

        // Set callback to mark as collected when found
        findableObjects[item.id] = FindableObject(
            locationId: item.id,
            anchor: anchor,
            sphereEntity: nil, // Not a sphere
            container: nil, // Simple box, no container
            location: item
        )

        findableObjects[item.id]?.onFoundCallback = { [weak self] id in
            DispatchQueue.main.async {
                if let locationManager = self?.locationManager {
                    locationManager.markCollected(id)
                }
            }
        }

        // CRITICAL: Update tap handler's findableObjects dictionary so the object is tappable
        if let findable = findableObjects[item.id] {
            tapHandler?.findableObjects[item.id] = findable
        }

        Swift.print("✅ Placed \(item.type.displayName) \(item.name) as box at position (\(position.x), \(position.y), \(position.z))")
    }

    // MARK: - GPS Correction
    /// Corrects GPS coordinates by calculating the offset needed to place object at intended AR position
    /// This compensates for GPS inaccuracy by measuring the difference between where GPS placement
    /// put the object vs where the user actually placed it in ARPlacementView
    private func correctGPSCoordinates(
        location: LootBoxLocation,
        intendedARPosition: SIMD3<Float>,
        arOrigin: CLLocation,
        cameraTransform: simd_float4x4
    ) {
        // Convert intended AR position back to GPS coordinates
        // This gives us the "corrected" GPS coordinates that would place the object
        // at the intended AR position when converted back through GPS->AR conversion

        // Calculate offset from AR origin (0,0,0) to intended position
        let offset = intendedARPosition

        // Convert offset to distance and bearing
        let distanceX = Double(offset.x)
        let distanceZ = Double(offset.z)
        let distance = sqrt(distanceX * distanceX + distanceZ * distanceZ)

        // Calculate bearing from AR origin
        // In AR space: +X = East, +Z = North
        let bearingRad = atan2(distanceX, distanceZ)
        let bearingDeg = bearingRad * 180.0 / .pi
        let compassBearing = (bearingDeg + 360).truncatingRemainder(dividingBy: 360)

        // Calculate corrected GPS coordinate from AR origin
        let correctedCoordinate = arOrigin.coordinate.coordinate(atDistance: distance, atBearing: compassBearing)

        Swift.print("   📍 Calculated corrected GPS coordinates:")
        Swift.print("      Original GPS: (\(String(format: "%.6f", location.latitude)), \(String(format: "%.6f", location.longitude)))")
        Swift.print("      Corrected GPS: (\(String(format: "%.6f", correctedCoordinate.latitude)), \(String(format: "%.6f", correctedCoordinate.longitude)))")
        Swift.print("      Distance from AR origin: \(String(format: "%.4f", distance))m")
        Swift.print("      Bearing: \(String(format: "%.1f", compassBearing))°")

        // Update GPS coordinates in the API
        Task {
            do {
                try await APIService.shared.updateObjectLocation(
                    objectId: location.id,
                    latitude: correctedCoordinate.latitude,
                    longitude: correctedCoordinate.longitude
                )
                Swift.print("   ✅ GPS coordinates corrected and saved to API")

                // Reload locations to pick up the corrected coordinates
                await locationManager?.loadLocationsFromAPI(userLocation: userLocationManager?.currentLocation)
                Swift.print("   🔄 Locations reloaded with corrected GPS coordinates")
            } catch {
                Swift.print("   ❌ Failed to update corrected GPS coordinates: \(error)")
            }
        }
    }
    
    /// Handles notification from ARPlacementView when an object is saved
    /// This triggers immediate placement so the object appears right after placement view dismisses
    @objc private func handleARPlacementObjectSaved(_ notification: Notification) {
        guard arView != nil,
              let userLocation = userLocationManager?.currentLocation,
              let nearbyLocations = nearbyLocationsBinding?.wrappedValue else {
            Swift.print("⚠️ [Placement Notification] Cannot place object: Missing AR view, location, or nearbyLocations")
            return
        }
        
        Swift.print("🔔 [Placement Notification] Received object saved notification - triggering immediate placement")
        Swift.print("   Nearby locations: \(nearbyLocations.count)")
        
        // Force immediate placement check (bypass throttling)
        // This ensures the newly placed object appears immediately
        checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
    }
    
    /// Handle dialog opened notification - pause AR session
    @objc private func handleDialogOpened(_ notification: Notification) {
        isDialogOpen = true
    }
    
    /// Handle dialog closed notification - resume AR session
    @objc private func handleDialogClosed(_ notification: Notification) {
        isDialogOpen = false
        // Clear conversationNPC binding to allow re-tapping
        DispatchQueue.main.async { [weak self] in
            self?.conversationNPCBinding?.wrappedValue = nil
        }
    }
    
    /// Pause AR session when sheet is shown (saves battery and prevents UI freezes)
    private func pauseARSession() {
        guard let arView = arView else {
            Swift.print("⚠️ Cannot pause AR session: AR view not available")
            return
        }
        
        // Only pause if session is currently running
        guard arView.session.configuration != nil else {
            Swift.print("ℹ️ AR session not running, skipping pause")
            return
        }
        
        // Save current configuration for resuming
        if let config = arView.session.configuration as? ARWorldTrackingConfiguration {
            savedARConfiguration = config
            Swift.print("⏸️ Pausing AR session (sheet shown)")
            arView.session.pause()
        } else {
            Swift.print("⚠️ Could not save AR configuration for resuming")
        }
    }
    
    /// Resume AR session when sheet is dismissed
    private func resumeARSession() {
        guard let arView = arView else {
            Swift.print("⚠️ Cannot resume AR session: AR view not available")
            return
        }
        
        guard let config = savedARConfiguration else {
            Swift.print("⚠️ Cannot resume AR session: No saved configuration")
            // Try to create a default configuration
            let defaultConfig = ARWorldTrackingConfiguration()
            defaultConfig.planeDetection = [.horizontal, .vertical]
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                defaultConfig.sceneReconstruction = .mesh
            }
            defaultConfig.environmentTexturing = .automatic
            arView.session.run(defaultConfig, options: [])
            return
        }
        
        Swift.print("▶️ Resuming AR session (sheet dismissed)")
        // Resume with saved configuration
        arView.session.run(config, options: [])
        savedARConfiguration = nil // Clear saved config after resuming
    }
    
    /// Clear all placed objects from AR scene (loot boxes and NPCs)
    /// Called when game mode changes to ensure clean state
    func clearAllARObjects() {
        guard let arView = arView else { return }
        
        Swift.print("🗑️ Clearing all AR objects due to game mode change...")
        
        // Remove all placed loot boxes
        let lootBoxCount = placedBoxes.count
        for (_, anchor) in placedBoxes {
            anchor.removeFromParent()
        }
        placedBoxes.removeAll()
        findableObjects.removeAll()
        objectPlacementTimes.removeAll()
        
        // Remove all placed NPCs
        let npcCount = placedNPCs.count
        for (_, anchor) in placedNPCs {
            anchor.removeFromParent()
        }
        placedNPCs.removeAll()
        skeletonPlaced = false
        corgiPlaced = false
        skeletonAnchor = nil
        
        // Clear found loot boxes sets
        distanceTracker?.foundLootBoxes.removeAll()
        tapHandler?.foundLootBoxes.removeAll()
        
        // Update tap handler's NPC reference
        tapHandler?.placedNPCs = placedNPCs
        
        Swift.print("✅ Cleared \(lootBoxCount) loot boxes and \(npcCount) NPCs from AR scene")
    }

    // MARK: - Debug Methods

    /// Debug method to print current AR scene state information
    func debugARSceneState() {
        Swift.print("🔍 AR Scene State Debug:")
        Swift.print("   📦 Placed loot boxes: \(placedBoxes.count)")
        Swift.print("   👥 Placed NPCs: \(placedNPCs.count)")
        Swift.print("   👁️ Objects in viewport: \(objectsInViewport.count)")

        if let arView = arView {
            let trackingState = arView.session.currentFrame?.camera.trackingState ?? .notAvailable
            Swift.print("   📱 AR View session state: \(String(describing: trackingState))")
            Swift.print("   🎯 Camera tracking state: \(String(describing: trackingState))")
        }

        if let userLocation = userLocationManager?.currentLocation {
            Swift.print("   📍 User location: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
        }

        if let gameMode = locationManager?.gameMode {
            Swift.print("   🎮 Game mode: \(gameMode.displayName)")
        }

        Swift.print("   🔄 Force replacement: \(shouldForceReplacement)")
        Swift.print("   💀 Skeleton placed: \(skeletonPlaced)")
        Swift.print("   🐕 Corgi placed: \(corgiPlaced)")
    }

}
