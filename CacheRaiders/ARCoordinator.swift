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
// Import for NFC positioning service
import Foundation

// Utility classes are available within the same module

// MARK: - AR Coordinator
class ARCoordinator: NSObject, ARSessionDelegate, AROriginProvider {

    // Managers
    private var environmentManager: AREnvironmentManager?
    private var occlusionManager: AROcclusionManager?
    private var objectRecognizer: ARObjectRecognizer?
    private var distanceTracker: ARDistanceTracker?
    var tapHandler: ARTapHandler?
    private var databaseIndicatorService: ARDatabaseIndicatorService?
    private var groundingService: ARGroundingService?
    private var precisionPositioningService: ARPrecisionPositioningService? // Legacy - kept for compatibility
    private var geospatialService: ARGeospatialService? // New ENU-based geospatial service
    private var treasureHuntService: TreasureHuntService? // Treasure hunt game mode service
    private var npcService: ARNPCService? // NPC management service
    internal var coordinateSharingService: ARCoordinateSharingService? // Coordinate sharing for multi-user AR
    internal var worldMapPersistenceService: ARWorldMapPersistenceService? // World map persistence for stable AR anchoring
    internal var enhancedPlaneAnchorService: AREnhancedPlaneAnchorService? // Enhanced multi-plane anchoring
    internal var vioSlamService: ARVIO_SLAM_Service? // VIO/SLAM enhancements
    var stateManager: ARStateManager? // State management for throttling and coordination

    // Cloud infrastructure preference
    private var cloudProvider: CloudGeoAnchorService.CloudProvider = .customServer

    weak var arView: ARView?
    var locationManager: LootBoxLocationManager? // Changed from private to allow extension access
    var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?

    // MEMORY OPTIMIZATION: Consolidated tracking - findableObjects contains the anchor, so no need for separate placedBoxes dictionary
    var findableObjects: [String: FindableObject] = [:] // Track all findable objects (contains anchor reference)
    var objectPlacementTimes: [String: Date] = [:] // Track when objects were placed (for grace period)

    // BACKWARD COMPATIBILITY: Computed property for services that still reference placedBoxes
    var placedBoxes: [String: AnchorEntity] {
        return findableObjects.mapValues { $0.anchor }
    }

    // Track placed box IDs for quick lookup
    private var placedBoxesSet: Set<String> = []

    // Track camera freeze issues
    private var consecutiveNoFrames: Int = 0

    // Track active AR anchors by object ID
    private var activeAnchors: [String: ARAnchor] = [:]

    let objectPlaced = PassthroughSubject<String, Never>() // Publisher for object placement events
    var shouldForceReplacement: Bool = false // Force re-placement after reset when AR is ready
    // MARK: - Helper Methods
    private func updateManagerReferences() {
        // Update all managers that reference placedBoxes (backward compatibility)
        occlusionManager?.placedBoxes = placedBoxes
        distanceTracker?.placedBoxes = placedBoxes
        tapHandler?.placedBoxes = placedBoxes
    }

    /// Debug method to test CloudKit functionality
    func debugTestCloudKit() {
        coordinateSharingService?.debugTestCloudKit()
    }

    /// Switches the cloud infrastructure provider for world map persistence
    /// - Parameter provider: The cloud provider to use (.localStorage or .cloudKit)
    func switchWorldMapCloudProvider(to provider: ARWorldMapPersistenceService.CloudProvider) async {
        guard let worldMapService = worldMapPersistenceService else { return }
        await coordinateSharingService?.switchWorldMapCloudProvider(to: provider, worldMapService: worldMapService)
    }

    /// Migrates data from custom server to CloudKit infrastructure
    func migrateToCloudKit() async throws {
        try await coordinateSharingService?.migrateToCloudKit(worldMapService: worldMapPersistenceService)
    }

    /// Switches the cloud infrastructure provider for geo anchors
    /// - Parameter provider: The cloud provider to use (.customServer or .cloudKit)
    func switchCloudProvider(to provider: CloudGeoAnchorService.CloudProvider) async {
        guard provider != cloudProvider else { return }

        cloudProvider = provider
        print("🔄 Switching to cloud provider: \(provider)")

        // Switch provider in coordinate sharing service
        await coordinateSharingService?.switchCloudProvider(to: provider)

        print("✅ Successfully switched to \(provider) and synced anchors")
    }

    /// Choose the best anchor type based on available data and object type
    private func createOptimalAnchor(for position: SIMD3<Float>, screenPoint: CGPoint?, objectType: LootBoxType, in arView: ARView) -> AnchorEntity {

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
    private var _arOriginLocation: CLLocation? // GPS location when AR session started
    private var arOriginSetTime: Date? // When AR origin was set (for degraded mode timeout)
    private var isDegradedMode: Bool = false // True if operating without GPS (AR-only mode)

    /// Public access to AR origin location for components that need it
    var arOriginLocation: CLLocation? {
        return _arOriginLocation
    }
    private var arOriginGroundLevel: Float? // Fixed ground level at AR origin (never changes)
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var collectionNotificationBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    var currentTargetObjectNameBinding: Binding<String?>?
    var currentTargetObjectBinding: Binding<LootBoxLocation?>?
    var conversationNPCBinding: Binding<ConversationNPC?>?
    private var lastSpherePlacementTime: Date? // Prevent rapid duplicate sphere placements
    private var sphereModeActive: Bool = false // Track when we're in sphere randomization mode
    var lastAppliedLensId: String? = nil // Track last applied AR lens to prevent redundant session resets

    // Debug frame counter for session delegate logging
    private var sessionFrameCount: Int = 0

    // PERFORMANCE: Disable verbose placement logging (causes freezing when many objects)
    private let verbosePlacementLogging = false // Set to true only when debugging placement issues

    // Arrow direction tracking
    @Published var nearestObjectDirection: Double? = nil // Direction in degrees (0 = north, 90 = east, etc.)
    
    // Viewport visibility tracking for chime sounds
    private var objectsInViewport: Set<String> = [] // Track which objects are currently visible
    private var manuallyPlacedObjectIds: Set<String> = [] // Track manually placed objects to prevent auto-removal
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

    // PERFORMANCE: Batched object placement queue to prevent UI freezing during initial load
    private var placementQueue: [LootBoxLocation] = []
    private var placementBatchSize: Int = 2 // Place 2 objects per batch
    private var placementBatchDelay: TimeInterval = 0.1 // 100ms delay between batches
    private var isPlacementInProgress: Bool = false
    private var currentProgress: Int = 0 // Track how many objects have been placed so far
    private var totalOriginallyQueued: Int = 0 // Track total number of objects originally queued
    
    // Throttling for nearby locations logging
    private var lastNearbyLogTime: Date = Date.distantPast
    private var lastNearbyCheckTime: Date = Date.distantPast // Throttle getNearbyLocations calls
    private let nearbyCheckInterval: TimeInterval = 1.0 // Check nearby locations once per second
    
    // Dialog state tracking - pause AR session when sheet is open
    private var isDialogOpen: Bool = false {
        didSet {
            if isDialogOpen != oldValue {
                if isDialogOpen {
                    pauseARSessionInternal()
                } else {
                    resumeARSessionInternal()
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

        return ARViewportUtilities.isObjectInViewport(locationId: locationId, anchor: anchor, arView: arView, frame: frame)
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
                // DEBUG: Log when object becomes visible
                if !objectsInViewport.contains(locationId) {
                    Swift.print("👁️ Object \(locationId) entered viewport")
                }
                
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

        // DEBUG: Log viewport statistics periodically
        if sessionFrameCount % 300 == 0 { // Every 5 seconds at 60fps
            Swift.print("🎯 Viewport stats: \(currentlyVisible.count)/\(placedBoxes.count) objects visible, checked \(checkedCount) objects this frame")
        }

        // Update tracked visible objects
        objectsInViewport = currentlyVisible
    }
    
    // Conversation manager reference
    private weak var conversationManager: ARConversationManager?

    func setupARView(_ arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearbyLocations: Binding<[LootBoxLocation]>, distanceToNearest: Binding<Double?>, temperatureStatus: Binding<String?>, collectionNotification: Binding<String?>, nearestObjectDirection: Binding<Double?>, currentTargetObjectName: Binding<String?>, currentTargetObject: Binding<LootBoxLocation?>, conversationNPC: Binding<ConversationNPC?>, conversationManager: ARConversationManager, treasureHuntService: TreasureHuntService? = nil) {
        Swift.print("🎯 [SETUP] setupARView called")
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        // Set this ARCoordinator as the reference in locationManager for pause/resume functionality
        locationManager.arCoordinator = self
        self.nearbyLocationsBinding = nearbyLocations
        self.distanceToNearestBinding = distanceToNearest
        self.temperatureStatusBinding = temperatureStatus
        self.collectionNotificationBinding = collectionNotification
        self.nearestObjectDirectionBinding = nearestObjectDirection
        self.currentTargetObjectNameBinding = currentTargetObjectName
        self.currentTargetObjectBinding = currentTargetObject
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
        // CRITICAL: Only set AR origin if we have a valid GPS location (not 0,0)
        // If GPS is not ready yet, session(_:didUpdate:) will set it when GPS becomes available
        if let currentLocation = userLocationManager.currentLocation,
           currentLocation.coordinate.latitude != 0.0 || currentLocation.coordinate.longitude != 0.0 {
            _arOriginLocation = currentLocation
            Swift.print("🎯 [SETUP] Setting initial AR origin from userLocationManager")
            Swift.print("   Location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
            Swift.print("   Accuracy: \(currentLocation.horizontalAccuracy)m")
        } else {
            Swift.print("🎯 [SETUP] GPS not ready yet (0,0 or nil), will set AR origin in session(_:didUpdate:)")
            _arOriginLocation = nil
        }

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
            selector: #selector(handleDialogOpened(_:)),
            name: NSNotification.Name("SheetPresented"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogClosed(_:)),
            name: NSNotification.Name("SheetDismissed"),
            object: nil
        )
        
        // Listen for NFC object creation notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNFCObjectCreated),
            name: NSNotification.Name("NFCObjectCreated"),
            object: nil
        )

        // Listen for NFC object placement notifications (when PreciseARPositioningService places objects)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNFCObjectPlaced),
            name: NSNotification.Name("NFCObjectPlaced"),
            object: nil
        )

        // Listen for real-time object creation via WebSocket
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRealtimeObjectCreated),
            name: NSNotification.Name("ObjectCreatedRealtime"),
            object: nil
        )

        // Listen for real-time object deletion via WebSocket
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRealtimeObjectDeleted),
            name: NSNotification.Name("ObjectDeletedRealtime"),
            object: nil
        )

        // Listen for real-time object updates via WebSocket
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRealtimeObjectUpdated),
            name: NSNotification.Name("ObjectUpdatedRealtime"),
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
        tapHandler = ARTapHandler(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager, arCoordinator: self, arOriginProvider: self)
        databaseIndicatorService = ARDatabaseIndicatorService()
        groundingService = ARGroundingService(arView: arView)
        precisionPositioningService = ARPrecisionPositioningService(arView: arView) // Legacy
        geospatialService = ARGeospatialService() // New ENU-based service
        coordinateSharingService = ARCoordinateSharingService(arView: arView) // Coordinate sharing for multi-user AR
        worldMapPersistenceService = ARWorldMapPersistenceService(arView: arView) // World map persistence for stable AR anchoring
        worldMapPersistenceService?.configure(with: arView,
                                             apiService: APIService.shared,
                                             webSocketService: WebSocketService.shared,
                                             cloudProvider: .localStorage) // Default to local storage, can be changed later
        enhancedPlaneAnchorService = AREnhancedPlaneAnchorService(arView: arView, arCoordinator: self) // Multi-plane anchoring for drift prevention
        vioSlamService = ARVIO_SLAM_Service(arView: arView, arCoordinator: self) // VIO/SLAM enhancements
        stateManager = ARStateManager() // State management for throttling and coordination

        // Configure environment lighting for proper shading and colors
        // Increase intensity to ensure objects are well-lit and colors are visible
        arView.environment.lighting.intensityExponent = 1.5

        // Start periodic grounding checks to ensure objects stay on surfaces
        // This continuously monitors for better surface data and re-grounds objects when found
        startPeriodicGrounding()

        // Configure enhanced AR anchoring services
        configureEnhancedAnchoring()

        // Configure coordinate sharing service
        if let coordinateSharingService = coordinateSharingService,
           let locationManagerProperty = self.locationManager {
            coordinateSharingService.configure(
                with: arView,
                webSocketService: WebSocketService.shared,
                apiService: APIService.shared,
                locationManager: locationManagerProperty,
                cloudProvider: cloudProvider
            )
        }

        // Setup world map persistence
        setupWorldMapPersistence()

        // AR WORLD MAP INTEGRATION: Configure AR session with world map if available
        if let worldMapService = worldMapPersistenceService,
           worldMapService.isWorldMapLoaded {
            Swift.print("🗺️ AR session will use loaded world map for stable object positioning")
        } else {
            Swift.print("🗺️ Starting fresh AR session (no persisted world map)")
        }

        // Configure managers with shared state
        occlusionManager?.placedBoxes = placedBoxes
        distanceTracker?.placedBoxes = placedBoxes
        distanceTracker?.distanceToNearestBinding = distanceToNearest
        distanceTracker?.temperatureStatusBinding = temperatureStatus
        distanceTracker?.nearestObjectDirectionBinding = nearestObjectDirection
        distanceTracker?.currentTargetObjectNameBinding = currentTargetObjectName
        distanceTracker?.currentTargetObjectBinding = currentTargetObject
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
        tapHandler?.onShowObjectInfo = { [weak self] location in
            self?.showObjectInfoPanel(location: location)
        }
        tapHandler?.onLongPressObject = { [weak self] locationId in
            self?.handleLongPressObject(locationId: locationId)
        }

        // Monitor AR session
        Swift.print("🎯 [SETUP] Setting arView.session.delegate = self")
        Swift.print("🎯 [SETUP] Self is: \(type(of: self))")
        arView.session.delegate = self
        Swift.print("🎯 [SETUP] Delegate set. Delegate is: \(arView.session.delegate != nil ? "NOT NIL" : "NIL")")
        if let delegate = arView.session.delegate {
            Swift.print("🎯 [SETUP] Delegate type is: \(type(of: delegate))")
        }
        
        // Start distance logging
        distanceTracker?.startDistanceLogging()
        
        // Clean up any existing occlusion planes once at startup
        occlusionManager?.removeAllOcclusionPlanes()
        
        // Start occlusion checking
        occlusionManager?.startOcclusionChecking()
        
        // Apply ambient light setting
        environmentManager?.updateAmbientLight()
    }

    // MARK: - Enhanced AR Anchoring Configuration

    private func configureEnhancedAnchoring() {
        // Configure world map persistence service
        if let worldMapPersistenceService = worldMapPersistenceService {
            worldMapPersistenceService.isPersistenceEnabled = true
        }

        // Initialize enhanced plane anchor service
        initializeEnhancedPlaneAnchoring()

        // Configure VIO/SLAM improvements
        configureVIOAndSLAMEnhancements()
    }

    private func initializeEnhancedPlaneAnchoring() {
        // Enhanced plane detection will be implemented in plane anchor service
        Swift.print("🎯 Enhanced plane anchoring initialized")
    }

    private func configureVIOAndSLAMEnhancements() {
        // VIO/SLAM enhancements will be implemented in dedicated service
        Swift.print("🎯 VIO/SLAM enhancements configured")
    }

    // MARK: - Object Info Panel

    func showObjectInfoPanel(location: LootBoxLocation) {
        Swift.print("ℹ️ Showing info panel for object: \(location.name) (ID: \(location.id))")

        // Create a notification or binding to show the info panel in the UI
        // For now, we'll use a notification that the main view can listen for
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowObjectInfoPanel"),
            object: location
        )
    }

    // MARK: - Long Press Object Detail Handler

    func handleLongPressObject(locationId: String) {
        Swift.print("📋 ========== LONG PRESS OBJECT DETAIL ==========")
        Swift.print("   Object ID: \(locationId)")

        // Handle orphaned entities specially
        if locationId.hasPrefix("orphan:") {
            let orphanId = String(locationId.dropFirst(7)) // Remove "orphan:" prefix
            Swift.print("   👻 Handling orphaned entity: \(orphanId)")

            // Get the anchor for this orphaned object (it might be in the scene but not tracked)
            var orphanAnchor: AnchorEntity? = nil
            if let arView = arView {
                // Search the scene for an anchor with this name
                for anchor in arView.scene.anchors {
                    if let anchorEntity = anchor as? AnchorEntity,
                       anchorEntity.name == orphanId {
                        orphanAnchor = anchorEntity
                        break
                    }
                }
            }

            // Create a minimal detail object for the orphaned entity
            let objectDetail = ARObjectDetail(
                id: orphanId,
                name: "Orphaned Object",
                itemType: "Unknown (Orphaned)",
                placerName: "Unknown",
                datePlaced: nil,
                gpsCoordinates: nil,
                arCoordinates: orphanAnchor != nil ? {
                    let transform = orphanAnchor!.transformMatrix(relativeTo: nil)
                    return SIMD3<Float>(
                        transform.columns.3.x,
                        transform.columns.3.y,
                        transform.columns.3.z
                    )
                }() : nil,
                arOrigin: nil,
                arOffsets: nil,
                anchors: orphanAnchor != nil ? [orphanAnchor!.name] : []
            )

            Swift.print("   👻 Orphaned object details:")
            Swift.print("      AR Coordinates: \(objectDetail.arCoordinateString)")
            Swift.print("      Anchor found: \(orphanAnchor != nil)")

            // Post notification to show the detail sheet
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowObjectDetailSheet"),
                object: objectDetail
            )

            Swift.print("✅ Posted notification to show orphaned object detail sheet")
            return
        }

        // Find the location object
        guard let location = locationManager?.locations.first(where: { $0.id == locationId }) else {
            Swift.print("⚠️ Location not found for ID: \(locationId)")
            return
        }

        Swift.print("   Object Name: \(location.name)")
        Swift.print("   Object Type: \(location.type.displayName)")

        // Get the anchor for this object
        let anchor = placedBoxes[locationId]

        // Extract detailed information about the object
        let objectDetail = ARObjectDetailService.shared.extractObjectDetails(
            location: location,
            anchor: anchor
        )

        Swift.print("   GPS Coordinates: \(objectDetail.gpsCoordinateString)")
        Swift.print("   AR Coordinates: \(objectDetail.arCoordinateString)")
        Swift.print("   Placed By: \(objectDetail.placerName ?? "Unknown")")

        // Post notification to show the detail sheet
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowObjectDetailSheet"),
            object: objectDetail
        )

        Swift.print("✅ Posted notification to show object detail sheet")
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
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ObjectUpdatedRealtime"), object: nil)
        stopPeriodicGrounding()

        // WORLD MAP PERSISTENCE: Clean up on deinit
        onARSessionEnded()

        // AR WORLD MAP INTEGRATION: Stop world map capture timer
        stopWorldMapCaptureTimer()
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
        guard _arOriginLocation == nil else { return } // Already set
        
        isDegradedMode = true

        // CRITICAL FIX: Use best available GPS location even in degraded mode
        // This allows GPS-based objects to be placed with reduced accuracy instead of not at all
        if let userLocation = userLocationManager?.currentLocation {
            // Use current GPS location even if accuracy is poor
            _arOriginLocation = userLocation

            // Share AR origin with placement view for coordinate consistency
            locationManager?.sharedAROrigin = userLocation

            // Set up geospatial service with this GPS location
            if geospatialService?.setENUOrigin(from: userLocation) == true {
                Swift.print("📍 Degraded mode: Using GPS with reduced accuracy")
                Swift.print("   GPS accuracy: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                Swift.print("   Location: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
            }
        } else {
            // No GPS available - cannot place GPS-based objects
            _arOriginLocation = nil
            locationManager?.sharedAROrigin = nil
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
        print("🟢 [checkAndPlaceBoxes] Called with \(nearbyLocations.count) nearby locations")
        print("   Currently placed objects: \(placedBoxes.count)")
        print("   User location: (\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude))")

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
        Swift.print("   AR origin set: \(_arOriginLocation != nil), Degraded mode: \(isDegradedMode)")
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

                let isARPlaced = false // No longer using AR-specific sources

                if hasARCoordinates {
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
            true // All valid locations can be placed
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

        // PERFORMANCE: Use batched placement instead of synchronous placement to prevent UI freezing
        // Collect all valid locations that need to be placed
        var locationsToQueue: [LootBoxLocation] = []

        for location in nearbyLocations {
            // Stop if we've reached the limit
            guard placedBoxes.count + locationsToQueue.count < maxObjects else {
                Swift.print("⏭️ Would exceed max object limit (\(maxObjects)), stopping collection")
                break
            }

            // Skip locations that are already placed (double-check to prevent duplicates)
            // CRITICAL: Never re-place objects that are already placed - they should stay fixed
            // This is especially important for manually placed objects with AR coordinates
            if placedBoxes[location.id] != nil {
                // Check if this is a GPS collision case where we might create a modified location
                // If so, we should skip entirely rather than create a duplicate with same ID
                if location.latitude != 0 && location.longitude != 0 {
                    let newLoc = CLLocation(latitude: location.latitude, longitude: location.longitude)

                    // Check if this would trigger GPS collision offset
                    var wouldOffset = false
                    for (existingId, _) in placedBoxes {
                        if let existingLocation = nearbyLocations.first(where: { $0.id == existingId }) {
                            let existingLoc = CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude)
                            let gpsDistance = existingLoc.distance(from: newLoc)
                            if gpsDistance < 1.0 {
                                wouldOffset = true
                                break
                            }
                        }
                    }

                    if wouldOffset {
                        Swift.print("⏭️ Skipping GPS collision case for already-placed object '\\(location.name)' - would create duplicate with same ID")
                        continue
                    }
                }
                continue
            }

            // Skip tap-created locations (lat: 0, lon: 0) - they're placed manually via tap
            // These should not be placed again by checkAndPlaceBoxes
            if location.latitude == 0 && location.longitude == 0 {
                Swift.print("⏭️ Skipping tap-created object '\\(location.name)' (lat/lon 0,0) - placed manually")
                continue
            }

            // Skip if already collected (critical check to prevent re-placement after finding)
            // Check multiple sources to ensure we don't place collected objects
            let isInFoundSets = distanceTracker?.foundLootBoxes.contains(location.id) ?? false || tapHandler?.foundLootBoxes.contains(location.id) ?? false
            if location.collected || isInFoundSets {
                if location.collected {
                    Swift.print("⏭️ Skipping collected object '\\(location.name)' (ID: \\(location.id)) - location.collected = true")
                } else if isInFoundSets {
                    Swift.print("⏭️ Skipping object '\\(location.name)' (ID: \\(location.id)) - still in foundLootBoxes sets (should be cleared when uncollected)")
                    Swift.print("   💡 Try marking as unfound again or restart the app to clear found sets")
                }
                continue
            }

            // Skip AR-only locations (no GPS coordinates)
            if location.isAROnly {
                continue
            }

            // Handle GPS collision by offsetting location
            var locationToQueue = location
            if location.latitude != 0 && location.longitude != 0 {
                let newLoc = CLLocation(latitude: location.latitude, longitude: location.longitude)
                var offsetApplied = false

                // First check against already-placed objects
                for (existingId, _) in placedBoxes {
                    if let existingLocation = nearbyLocations.first(where: { $0.id == existingId }) {
                        let existingLoc = CLLocation(latitude: existingLocation.latitude, longitude: existingLocation.longitude)
                        let gpsDistance = existingLoc.distance(from: newLoc)

                        if gpsDistance < 1.0 {
                            // Offset by 5 meters in a random direction
                            let randomBearing = Double.random(in: 0..<360)
                            let offsetCoordinate = newLoc.coordinate.coordinateAt(distance: 5.0, bearing: randomBearing)

                            locationToQueue = LootBoxLocation(
                                id: location.id,
                                name: location.name,
                                type: location.type,
                                latitude: offsetCoordinate.latitude,
                                longitude: offsetCoordinate.longitude,
                                radius: location.radius,
                                collected: location.collected,
                                source: location.source
                            )
                            // Copy AR-related properties
                            locationToQueue.grounding_height = location.grounding_height
                            locationToQueue.ar_origin_latitude = location.ar_origin_latitude
                            locationToQueue.ar_origin_longitude = location.ar_origin_longitude
                            locationToQueue.ar_offset_x = location.ar_offset_x
                            locationToQueue.ar_offset_y = location.ar_offset_y
                            locationToQueue.ar_offset_z = location.ar_offset_z
                            locationToQueue.ar_placement_timestamp = location.ar_placement_timestamp

                            offsetApplied = true
                            Swift.print("🔄 Applied GPS collision offset for '\(location.name)'")
                            break
                        }
                    }
                }

                // Also check against other locations in the current batch
                if !offsetApplied {
                    for otherLocation in nearbyLocations {
                        if otherLocation.id == location.id || placedBoxes[otherLocation.id] != nil {
                            continue
                        }

                        let otherLoc = CLLocation(latitude: otherLocation.latitude, longitude: otherLocation.longitude)
                        let gpsDistance = newLoc.distance(from: otherLoc)

                        if gpsDistance < 1.0 {
                            let randomBearing = Double.random(in: 0..<360)
                            let offsetCoordinate = newLoc.coordinate.coordinateAt(distance: 5.0, bearing: randomBearing)

                            locationToQueue = LootBoxLocation(
                                id: location.id,
                                name: location.name,
                                type: location.type,
                                latitude: offsetCoordinate.latitude,
                                longitude: offsetCoordinate.longitude,
                                radius: location.radius,
                                collected: location.collected,
                                source: location.source
                            )
                            // Copy AR-related properties
                            locationToQueue.grounding_height = location.grounding_height
                            locationToQueue.ar_origin_latitude = location.ar_origin_latitude
                            locationToQueue.ar_origin_longitude = location.ar_origin_longitude
                            locationToQueue.ar_offset_x = location.ar_offset_x
                            locationToQueue.ar_offset_y = location.ar_offset_y
                            locationToQueue.ar_offset_z = location.ar_offset_z
                            locationToQueue.ar_placement_timestamp = location.ar_placement_timestamp

                            offsetApplied = true
                            Swift.print("🔄 Applied GPS collision offset for '\(location.name)' (batch collision)")
                            break
                        }
                    }
                }
            }

            // Add to queue for batched placement
            locationsToQueue.append(locationToQueue)
        }

        // Queue all collected locations for batched placement
        if !locationsToQueue.isEmpty {
            Swift.print("📋 Queuing \(locationsToQueue.count) objects for batched placement to prevent UI freezing")
            queueObjectsForPlacement(locationsToQueue)
        } else {
            Swift.print("📭 No objects to place")
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Swift.print("⏱️ [PERF] checkAndPlaceBoxes took \(String(format: "%.1f", elapsed))ms for \(nearbyLocations.count) nearby locations")
        Swift.print("📊 Final status: \(placedBoxes.count) objects placed in AR scene")
        Swift.print("   Objects in AR: \(placedBoxes.keys.sorted())")
    }


    // Regenerate loot boxes at random locations in the AR room


    /// Place an AR item from game data
    func placeARItem(_ item: LootBoxLocation) {
        guard let arView = arView,
              let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ Cannot place AR item: AR view or user location not available")
            return
        }

        Swift.print("📦 Placing AR item: \(item.name)")

        // Create anchor at current camera position with forward offset
        guard let frame = arView.session.currentFrame else { return }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)

        // Position 2m in front of camera
        let position = cameraPos + normalize(forward) * 2.0

        // Create the entity using the factory
        let factory = item.type.factory
        let (entity, findable) = factory.createEntity(location: item, anchor: AnchorEntity(), sizeMultiplier: 1.0)

        // Create the anchor entity first
        let anchor = AnchorEntity(world: position)
        anchor.name = item.id
        anchor.addChild(entity)

        // Try enhanced multi-plane anchoring for better stability
        var usedEnhancedAnchoring = false
        if let enhancedAnchorService = enhancedPlaneAnchorService {
            usedEnhancedAnchoring = enhancedAnchorService.createMultiPlaneAnchor(objectId: item.id, anchorEntity: anchor)
            if usedEnhancedAnchoring {
                Swift.print("🎯 Used enhanced multi-plane anchoring for \(item.id)")
            } else {
                Swift.print("📍 Used traditional anchoring for \(item.id) (insufficient planes for enhancement)")
            }
        } else {
            Swift.print("📍 Used traditional anchoring for \(item.id) (enhanced service unavailable)")
        }

        // Add anchor to scene
        arView.scene.addAnchor(anchor)

        print("📍 Placed AR item '\(item.name)' at position (\(String(format: "%.2f", position.x)), \(String(format: "%.2f", position.y)), \(String(format: "%.2f", position.z)))")
        findableObjects[item.id] = findable
        objectPlacementTimes[item.id] = Date() // CRITICAL: Track placement time for grace period

        // CRITICAL: Update tap handler's dictionaries so the object is tappable
        // The tap handler checks both placedBoxes and findableObjects for tap detection
        tapHandler?.placedBoxes[item.id] = anchor
        tapHandler?.findableObjects[item.id] = findable

        // Update all manager references
        updateManagerReferences()

        Swift.print("✅ Placed AR item '\(item.name)' at camera-relative position")
    }

    /// Create a random sphere location for testing


    // Generate position for indoor placement (simplified approach)
    private func generateIndoorPosition(cameraPos: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> (x: Float, z: Float) {
        return ARPlacementUtilities.generateIndoorPosition(cameraPos: cameraPos, minDistance: minDistance, maxDistance: maxDistance)
    }

    // Check if a position is within room boundaries defined by walls
    private func isPositionWithinRoomBounds(x: Float, z: Float, cameraPos: SIMD3<Float>, walls: [ARPlaneAnchor]) -> Bool {
        return ARPlacementUtilities.isPositionWithinRoomBounds(x: x, z: z, cameraPos: cameraPos, walls: walls)
    }

    // Get placement strategy - simplified for reliable sphere spawning
    private func getPlacementStrategy(isIndoors: Bool, searchDistance: Float) -> (minDistance: Float, maxDistance: Float, strategy: String) {
        return ARPlacementUtilities.getPlacementStrategy(isIndoors: isIndoors, searchDistance: searchDistance)
    }

    // MARK: - AR-Enhanced Location
    
    /// Get AR-enhanced GPS location (more accurate than raw GPS)
    /// Converts current AR camera position to GPS coordinates using AR origin
    /// Returns nil if AR origin not set or AR not available
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)? {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let arOrigin = locationManager?.sharedAROrigin else { return nil }

        return ARGPSUtilities.getAREnhancedLocation(arView: arView, frame: frame, arOrigin: arOrigin)
    }
    // MARK: - Object Recognition (delegated to ARObjectRecognizer)
    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Set performance mode to reduced when AR is active to prevent camera freezing
        if LootBoxEntity.globalPerformanceMode != .reduced {
            LootBoxEntity.globalPerformanceMode = .reduced
        }

        // CRITICAL FIX: Move expensive operations to background queue to prevent ARFrame retention
        // The ARSession delegate must return quickly to avoid the "retaining X ARFrames" warning
        // This warning causes camera frames to stop being delivered, leading to frozen/black camera

        // Process VIO/SLAM in background - reduced frequency to prevent frame backup
        let shouldProcessVIO_SLAM = sessionFrameCount % 5 == 0 // Process every 5th frame (12fps instead of 20fps)
        if shouldProcessVIO_SLAM {
            // Create a weak reference to avoid retaining the frame
            let frameTimestamp = frame.timestamp
            backgroundProcessingQueue.async { [weak self] in
                // Only process if we still exist and this is still the most recent frame
                guard let self = self,
                      let currentFrame = self.arView?.session.currentFrame,
                      currentFrame.timestamp == frameTimestamp else { return }

                self.vioSlamService?.processFrameForEnhancement(currentFrame)
            }
        }

        // Apply stabilization less frequently - every 10th frame instead of 6th (6fps)
        let shouldApplyStabilization = sessionFrameCount % 10 == 0
        if shouldApplyStabilization {
            backgroundProcessingQueue.async { [weak self] in
                self?.applyEnhancedStabilization()
            }
        }

        // Track consecutive frames with no camera data (for detecting frozen camera)
        if frame.camera.trackingState == .notAvailable {
            consecutiveNoFrames += 1
        } else {
            if consecutiveNoFrames > 60 { // Only log if it was a significant freeze
                Swift.print("📷 Camera feed restored after \(consecutiveNoFrames/60) seconds")
            }
            consecutiveNoFrames = 0
        }

        // Log every 60 frames (roughly once per second at 60fps) to avoid spam
        sessionFrameCount += 1
        if sessionFrameCount % 60 == 0 {
            Swift.print("🎯 [SESSION] didUpdate called (frame \(sessionFrameCount)), arOrigin: \(_arOriginLocation != nil)")
            Swift.print("   Camera tracking state: \(frame.camera.trackingState)")
            if case .notAvailable = frame.camera.trackingState {
                Swift.print("⚠️ CAMERA TRACKING NOT AVAILABLE - THIS CAUSES BLACK CAMERA!")
                Swift.print("   Possible causes:")
                Swift.print("   - Insufficient lighting")
                Swift.print("   - Device moving too fast")
                Swift.print("   - Camera obstructed")
                Swift.print("   - AR session interrupted and not properly resumed")
                Swift.print("   - Camera permissions revoked")
                Swift.print("💡 Try: Move to better lighting, reduce motion, check camera permissions")

                // CRITICAL FIX: Attempt to recover tracking by resetting the session
                // This can help when tracking gets stuck in .notAvailable state
                recoverARSessionTracking()

                // AUTO-RESTART: If camera has been unavailable for too long, force restart
                if consecutiveNoFrames > 300 { // 5+ seconds of no frames (60fps * 5)
                    Swift.print("🚨 AUTO-RESTARTING AR SESSION - Camera feed frozen for \(consecutiveNoFrames/60) seconds")
                    forceRestartARSession()
                    consecutiveNoFrames = 0
                }
            } else if case .limited(let reason) = frame.camera.trackingState {
                Swift.print("⚠️ Camera tracking LIMITED: \(reason)")
                switch reason {
                case .initializing:
                    Swift.print("   Camera is initializing - wait a few seconds")
                case .relocalizing:
                    Swift.print("   Camera is relocalizing - keep device still")
                case .excessiveMotion:
                    Swift.print("   Too much motion - slow down device movement")
                case .insufficientFeatures:
                    Swift.print("   Not enough visual features - move to area with more detail/textures")
                @unknown default:
                    Swift.print("   Unknown limiting reason")
                }
            }
        }

        // CRITICAL: Set AR origin on first frame if not set - NEVER change it after
        // Changing the AR origin causes all objects to drift/shift position
        // Supports two modes:
        // 1. Accurate mode: Wait for GPS with good accuracy (< 20.0m) for AR-to-GPS conversion
        // 2. Degraded mode: Use AR-only positioning if GPS unavailable after timeout

        // PERFORMANCE: Only do AR origin setup on first frame to avoid blocking delegate
        if _arOriginLocation == nil {
            Swift.print("🎯 [SESSION] AR origin is nil, attempting to set it")
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            
            // Try to get GPS location
            if let userLocation = userLocationManager?.currentLocation {
                Swift.print("🎯 [SESSION] User location available: (\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)), accuracy: \(userLocation.horizontalAccuracy)m")
                // Check GPS accuracy - accept up to 20m for better UX (consistent with placement view)
                if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 20.0 {
                    Swift.print("🎯 [SESSION] GPS accuracy good (< 20.0m), setting AR origin")
                    // ACCURATE MODE: GPS available with good accuracy
                    // Step 1: Set ENU origin from GPS (geospatial coordinate frame)
                    if geospatialService?.setENUOrigin(from: userLocation) == true {
                        _arOriginLocation = userLocation
                        locationManager?.sharedAROrigin = userLocation // Share AR origin with placement view
                        arOriginSetTime = Date()
                        isDegradedMode = false
                        Swift.print("✅ [SESSION] AR origin successfully set!")
                        
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

        // WORLD MAP PERSISTENCE: Initialize when AR session starts
        onARSessionStarted()

        // AR WORLD MAP INTEGRATION: Capture world map periodically for persistence
        // This ensures objects can be restored if the app is killed or AR session resets
        startWorldMapCaptureTimer()
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
                            Swift.print("⏳ Waiting for better GPS accuracy (current: \(String(format: "%.2f", userLocation.horizontalAccuracy))m, need: < 20.0m)")
                        }
                    } else {
                        // First time seeing low accuracy - start timer
                        arOriginSetTime = Date()
                        Swift.print("⚠️ GPS accuracy too low: \(String(format: "%.2f", userLocation.horizontalAccuracy))m")
                        Swift.print("   Will wait \(Int(waitTime))s for GPS accuracy < 20.0m, then enter degraded AR-only mode")
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
        // Note: This check happens even when _arOriginLocation == nil because degraded mode sets it to nil
        // The existing code above will also try to set origin, but this provides explicit degraded mode exit
        if isDegradedMode, let userLocation = userLocationManager?.currentLocation {
            // Use hysteresis: require better accuracy (< 6.5m) to exit degraded mode than to enter (< 20.0m)
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
                    _arOriginLocation = userLocation
                    locationManager?.sharedAROrigin = userLocation // Share AR origin with placement view
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
        //        let origin = _arOriginLocation,
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
        
        // Perform object recognition on camera frame (throttled and moved to background)
        // Only run recognition every 2 seconds to reduce CPU usage
        let recognitionNow = Date()
        if recognitionNow.timeIntervalSince(lastRecognitionTime) > 2.0 {
            lastRecognitionTime = recognitionNow
            // Move object recognition to background to prevent frame retention
            backgroundProcessingQueue.async { [weak self] in
                guard let self = self else { return }
                // Create a copy of the pixel buffer to avoid retaining the frame
                let pixelBuffer = frame.capturedImage
                self.objectRecognizer?.performObjectRecognition(on: pixelBuffer)
            }
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
                    let hasOrigin = self._arOriginLocation != nil
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
                        // Also check for and re-place any unfound objects that need to be visible
                        self.replaceUnfoundObjectsAsync()
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
    
    /// Async wrapper for replaceUnfoundObjects - dispatches to main thread for AR scene updates
    private func replaceUnfoundObjectsAsync() {
        // CRITICAL: Skip if dialog is open to prevent UI freezes
        guard !isDialogOpen else { return }

        // AR scene updates must be on main thread
        DispatchQueue.main.async { [weak self] in
            // Double-check dialog state on main thread (may have changed)
            guard let self = self, !self.isDialogOpen else { return }
            self.replaceUnfoundObjects()
        }
    }

    // MARK: - Batched Placement System

    /// Queue objects for batched placement to prevent UI freezing during initial load
    private func queueObjectsForPlacement(_ locations: [LootBoxLocation]) {
        guard !isPlacementInProgress else {
            Swift.print("⚠️ Placement already in progress, ignoring new queue request")
            return
        }

        // Filter out objects that are already placed or collected
        let validLocations = locations.filter { location in
            // Skip if already placed
            if placedBoxes[location.id] != nil {
                return false
            }

            // Skip if collected
            let isInFoundSets = distanceTracker?.foundLootBoxes.contains(location.id) ?? false ||
                               tapHandler?.foundLootBoxes.contains(location.id) ?? false
            if location.collected || isInFoundSets {
                return false
            }

            // Skip tap-created locations
            if location.latitude == 0 && location.longitude == 0 {
                return false
            }

            return true
        }

        if validLocations.isEmpty {
            Swift.print("📭 No valid objects to place in queue")
            return
        }

        placementQueue = validLocations
        currentProgress = 0
        totalOriginallyQueued = validLocations.count
        // Post notification to update UI
        NotificationCenter.default.post(name: NSNotification.Name("PlacementProgressUpdate"),
                                      object: nil,
                                      userInfo: ["current": 0, "total": validLocations.count])
        Swift.print("📋 Queued \(validLocations.count) objects for batched placement")
        startBatchedPlacement()
    }

    /// Start the batched placement process
    private func startBatchedPlacement() {
        guard !placementQueue.isEmpty && !isPlacementInProgress else { return }

        isPlacementInProgress = true
        Swift.print("🚀 Starting batched placement of \(placementQueue.count) objects")

        // Process first batch immediately
        processNextPlacementBatch()
    }

    /// Process the next batch of objects to place
    private func processNextPlacementBatch() {
        // CRITICAL: Cancel placement if dialog is open to prevent UI freezing
        guard !isDialogOpen, !placementQueue.isEmpty, let arView = arView else {
            if placementQueue.isEmpty {
                finishBatchedPlacement()
            } else if isDialogOpen {
                Swift.print("🛑 Cancelling placement batch - dialog is open")
                cancelBatchedPlacement()
            }
            return
        }

        // Take next batch from queue
        let batchSize = min(placementBatchSize, placementQueue.count)
        let batch = Array(placementQueue.prefix(batchSize))
        placementQueue.removeFirst(batchSize)

        // Calculate progress (batch.count items are being processed now)
        let remainingInQueue = placementQueue.count
        let currentBatch = batch.count
        let totalProgress = remainingInQueue + currentBatch

        Swift.print("📦 Processing batch of \(currentBatch) objects (\(remainingInQueue) remaining in queue)")

        // Place each object in the batch
        for location in batch {
            if location.type == .sphere {
                placeARSphereAtLocation(location, in: arView)
            } else {
                placeLootBoxAtLocation(location, in: arView)
            }
        }

        // Update progress
        currentProgress += batch.count

        // Update progress via notification
        NotificationCenter.default.post(name: NSNotification.Name("PlacementProgressUpdate"),
                                      object: nil,
                                      userInfo: ["current": currentProgress, "total": totalOriginallyQueued])

        // Schedule next batch if queue isn't empty
        if !placementQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + placementBatchDelay) { [weak self] in
                self?.processNextPlacementBatch()
            }
        } else {
            finishBatchedPlacement()
        }
    }

    /// Finish the batched placement process
    private func finishBatchedPlacement() {
        isPlacementInProgress = false
        placementQueue.removeAll()
        currentProgress = 0
        totalOriginallyQueued = 0
        // Post notification to reset progress
        NotificationCenter.default.post(name: NSNotification.Name("PlacementProgressUpdate"),
                                      object: nil,
                                      userInfo: ["current": 0, "total": 0])
        Swift.print("✅ Batched placement completed")
    }

    /// Cancel any ongoing batched placement
    private func cancelBatchedPlacement() {
        placementQueue.removeAll()
        isPlacementInProgress = false
        currentProgress = 0
        totalOriginallyQueued = 0
        // Post notification to update UI
        NotificationCenter.default.post(name: NSNotification.Name("PlacementProgressUpdate"),
                                      object: nil,
                                      userInfo: ["current": 0, "total": 0])
        Swift.print("🛑 Batched placement cancelled")
    }

    /// Handle dialog opened notification - cancel placement to prevent UI freezing
    @objc private func handleDialogOpened() {
        isDialogOpen = true
        cancelBatchedPlacement()
    }

    /// Handle dialog closed notification
    @objc private func handleDialogClosed() {
        isDialogOpen = false
    }

    // MARK: - AR World Map Integration

    /// Timer for periodic world map capture
    private var worldMapCaptureTimer: Timer?

    /// Start periodic world map capture for persistence
    private func startWorldMapCaptureTimer() {
        // Capture world map every 30 seconds when objects are placed
        worldMapCaptureTimer?.invalidate() // Cancel any existing timer
        worldMapCaptureTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.captureWorldMapIfNeeded()
        }
        Swift.print("🗺️ Started world map capture timer (30s intervals)")
    }

    /// Stop world map capture timer
    private func stopWorldMapCaptureTimer() {
        worldMapCaptureTimer?.invalidate()
        worldMapCaptureTimer = nil
        Swift.print("🗺️ Stopped world map capture timer")
    }

    /// Capture world map if there are objects to persist and quality is good enough
    private func captureWorldMapIfNeeded() {
        guard let worldMapService = worldMapPersistenceService,
              worldMapService.isPersistenceEnabled,
              !findableObjects.isEmpty, // Only capture if we have objects to persist
              let arView = arView,
              arView.session.currentFrame != nil else { return }

        // Only capture if world map quality is acceptable
        if worldMapService.worldMapQuality >= 0.3 {
            Task {
                await worldMapService.captureAndPersistWorldMap()
                Swift.print("🗺️ Captured world map for persistence (quality: \(String(format: "%.2f", worldMapService.worldMapQuality)))")
            }
        }
    }
    
    // Handle AR anchor updates - remove any unwanted plane anchors (especially ceilings)
    // Also re-ground objects when new horizontal planes are detected
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Only log in debug mode to reduce noise
        if UserDefaults.standard.bool(forKey: "showARDebugVisuals") {
            Swift.print("🎯 [DELEGATE] session(_:didAdd:) called with \(anchors.count) anchors - delegate IS working!")
        }
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

                        // No auto-randomization - only manual placement of database objects
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
        // Only log in debug mode to reduce noise
        if UserDefaults.standard.bool(forKey: "showARDebugVisuals") {
            Swift.print("🎯 [DELEGATE-ANCHORS] session(_:didUpdate anchors:) called with \(anchors.count) anchors")
        }
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
        Swift.print("🎯 [DELEGATE-ERROR] session(_:didFailWithError:) called: \(error.localizedDescription)")
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
            let config = vioSlamService?.getEnhancedARConfiguration() ?? ARWorldTrackingConfiguration()
            
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
        Swift.print("   Timestamp: \(Date())")
        Swift.print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")

        // Check if any dialogs are open that might have caused this
        Swift.print("   Dialog state: \(isDialogOpen ? "OPEN" : "CLOSED")")

        // Check if we're sharing session with placement view
        if let sharedARView = locationManager?.sharedARView {
            Swift.print("   Shared ARView exists: \(ObjectIdentifier(sharedARView))")
        } else {
            Swift.print("   No shared ARView")
        }
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        Swift.print("✅ [AR Session] AR Session interruption ended")
        Swift.print("   Timestamp: \(Date())")
        Swift.print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        Swift.print("   Placed objects: \(placedBoxes.count) anchors in placedBoxes dictionary")

        // Check camera state immediately
        if let frame = session.currentFrame {
            Swift.print("   Camera state after interruption ended: \(frame.camera.trackingState)")
        } else {
            Swift.print("   ❌ No frame available after interruption ended!")
        }

        // WORLD MAP PERSISTENCE: Handle session resumption
        onARSessionStarted()

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

    /// Attempt to recover AR session tracking when it becomes unavailable
    /// This can help restore camera feed when tracking gets stuck
    private func recoverARSessionTracking() {
        Swift.print("🔄 [RECOVERY] Attempting to recover AR session tracking...")

        guard let arView = arView else {
            Swift.print("⚠️ Cannot recover tracking - ARView is nil")
            return
        }

        // Only attempt recovery if session is running
        guard arView.session.configuration != nil else {
            Swift.print("⚠️ Cannot recover tracking - session not running")
            return
        }

        // Create a fresh configuration matching current settings
        let recoveryConfig = ARWorldTrackingConfiguration()
        recoveryConfig.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            recoveryConfig.sceneReconstruction = .mesh
        }
        recoveryConfig.environmentTexturing = .automatic

        // Apply current lens if available
        if let selectedLensId = locationManager?.selectedARLens,
           let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
            recoveryConfig.videoFormat = videoFormat
        }

        Swift.print("🔄 Running recovery session with resetTracking option")
        arView.session.run(recoveryConfig, options: [.resetTracking])

        // Monitor recovery after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self,
                  let frame = self.arView?.session.currentFrame else {
                Swift.print("❌ Recovery check failed - no frame available")
                return
            }

            Swift.print("🔍 Recovery result:")
            Swift.print("   Tracking state: \(frame.camera.trackingState)")

            if case .normal = frame.camera.trackingState {
                Swift.print("✅ Tracking recovered successfully!")
            } else {
                Swift.print("⚠️ Tracking still not recovered - may need manual intervention")
                Swift.print("💡 Try: Restart app, check lighting, move to different area")
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

        // PREFER CLOUD GEO ANCHORS: Use cloud geo anchors for maximum stability in multi-user scenarios
        if isCloudGeoAnchorsAvailable && isCloudGeoAnchorsEnabled {
            Task {
                do {
                    let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
                    let altitude = CLLocationDistance(location.grounding_height ?? 0)

                    // Calculate AR offset if available
                    var arOffset = SIMD3<Float>.zero
                    if let arOffsetX = location.ar_offset_x,
                       let arOffsetY = location.ar_offset_y,
                       let arOffsetZ = location.ar_offset_z {
                        arOffset = SIMD3<Float>(Float(arOffsetX), Float(arOffsetY), Float(arOffsetZ))
                    }

                    let anchorEntity = try await placeObjectWithCloudGeoAnchor(
                        objectId: location.id,
                        coordinate: coordinate,
                        altitude: altitude,
                        arOffset: arOffset
                    )

                    // Create entity and findable object using factory (same as regular placement)
                    let factory = location.type.factory
                    let sizeMultiplier: Float = 1.0 // Standard size for cloud geo anchors
                    let (entity, findable) = factory.createEntity(location: location, anchor: anchorEntity, sizeMultiplier: sizeMultiplier)

                    // Attach the entity to the anchor
                    anchorEntity.addChild(entity)

                    // Use consolidated tracking (same as placeBoxAtPosition)
                    findableObjects[location.id] = findable
                    objectPlacementTimes[location.id] = Date()

                    // Update tap handler for both backward compatibility
                    tapHandler?.placedBoxes[location.id] = anchorEntity
                    tapHandler?.findableObjects[location.id] = findable

                    // Update manager references
                    updateManagerReferences()

                    // Start loop animation if supported
                    factory.animateLoop(entity: entity)

                    // Notify about placement
                    objectPlaced.send(location.id)

                    Swift.print("☁️ Successfully placed '\(location.name)' using cloud geo anchor")
                    return

                } catch {
                    Swift.print("⚠️ Cloud geo anchor failed for '\(location.name)': \(error.localizedDescription)")
                    Swift.print("   Falling back to traditional AR placement")
                    // Continue with traditional placement below
                }
            }
        } else if isCloudGeoAnchorsAvailable {
            Swift.print("☁️ Cloud geo anchors available but not enabled - using traditional AR placement")
        } else {
            Swift.print("📍 Cloud geo anchors not available - using traditional AR placement")
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
            let storedAROriginGPS = CLLocation(latitude: arOriginLat, longitude: arOriginLon)

            // Check USER distance to object (8m threshold) for precision mode
            let objectLocation = location.location
            let userDistanceToObject = userLocation.distance(from: objectLocation)

            let useARCoordinates: Bool
            let storedARPosition = SIMD3<Float>(Float(arOffsetX), Float(arOffsetY), Float(arOffsetZ))
            let distanceFromStoredOrigin = length(storedARPosition)

            // Compute AR origin matching and distance for logging
            var arOriginsMatch = false
            var distanceFromOrigin = distanceFromStoredOrigin
            if let currentAROrigin = _arOriginLocation {
                let originDistance = currentAROrigin.distance(from: storedAROriginGPS)
                arOriginsMatch = originDistance < 1.0
                // For current session, distance from origin would be computed relative to current origin
                // but we keep the stored distance for consistency
            }

            // CRITICAL FIX: Use stored AR origin instead of current session's origin
            // Transform AR coordinates from stored origin's coordinate system to current session
            if let currentAROrigin = _arOriginLocation {
                let originDistance = currentAROrigin.distance(from: storedAROriginGPS)

                // Use AR coordinates when user is close to object (within 8m)
                // Even if AR origins don't match, we can transform between coordinate systems
                let withinPrecisionRange = userDistanceToObject < 8.0 && distanceFromStoredOrigin < 12.0
                useARCoordinates = withinPrecisionRange

                Swift.print("🎯 AR COORDINATE DECISION for '\(location.name)':")
                Swift.print("   📍 User distance to object: \(String(format: "%.2f", userDistanceToObject))m (threshold: 8.0m)")
                Swift.print("   🔗 Stored AR origin vs current: \(String(format: "%.3f", originDistance))m apart")
                Swift.print("   📏 Distance from stored AR origin: \(String(format: "%.2f", distanceFromStoredOrigin))m (max: 12.0m)")
                Swift.print("   🎯 FINAL DECISION: \(useARCoordinates ? "✅ USING AR COORDINATES (PRECISION MODE)" : "📍 USING GPS COORDINATES (STANDARD MODE)")")

                if useARCoordinates {
                    Swift.print("   💎 PRECISION PLACEMENT: Transforming coordinates from stored origin to current session")

                    // Use ARCoordinateTransformService for coordinate transformation and rotation
                    let transformedARPosition = ARCoordinateTransformService.shared.transformAndRotate(
                        storedPosition: storedARPosition,
                        storedOrigin: storedAROriginGPS,
                        storedHeading: location.ar_placement_heading,
                        currentOrigin: currentAROrigin,
                        currentHeading: userLocationManager?.heading,
                        geospatialService: geospatialService
                    )

                    // Check if we have AR anchor transform for even higher precision
                    if let arAnchorTransformString = location.ar_anchor_transform,
                       let arAnchorTransform = decodeARAnchorTransform(arAnchorTransformString) {
                        Swift.print("   🎯 AR ANCHOR AVAILABLE: Using exact camera transform for mm precision")

                        // Apply compass-based rotation to the anchor transform if heading data is available
                        let rotatedTransform = applyCompassRotationToAnchorTransform(
                            arAnchorTransform,
                            storedHeading: location.ar_placement_heading,
                            currentHeading: userLocationManager?.heading
                        )
                        placeObjectWithARAnchor(location, arAnchorTransform: rotatedTransform, in: arView)
                    } else {
                        // Apply compass-based rotation for consistent object orientation
                        let finalARPosition = rotateARCoordinatesForCompassHeading(
                            transformedARPosition,
                            storedHeading: location.ar_placement_heading,
                            currentHeading: userLocationManager?.heading
                        )

                        // Use transformed and rotated AR coordinates
                        Swift.print("✅ [Placement] Using transformed AR coordinates for \(location.name) (PRECISION MODE - cm accuracy)")
                        Swift.print("   Object ID: \(location.id)")
                        Swift.print("   Original position: (\(String(format: "%.4f", storedARPosition.x)), \(String(format: "%.4f", storedARPosition.y)), \(String(format: "%.4f", storedARPosition.z)))m")
                        Swift.print("   Transformed position: (\(String(format: "%.4f", transformedARPosition.x)), \(String(format: "%.4f", transformedARPosition.y)), \(String(format: "%.4f", transformedARPosition.z)))m")
                        Swift.print("   Final rotated position: (\(String(format: "%.4f", finalARPosition.x)), \(String(format: "%.4f", finalARPosition.y)), \(String(format: "%.4f", finalARPosition.z)))m")
                        Swift.print("   🎯 PRECISION ACHIEVED: Object placed with coordinate transformation and compass rotation for cross-user consistency")

                        placeBoxAtPosition(finalARPosition, location: location, in: arView, screenPoint: nil)
                    }
                    
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
                                } else if abs(currentPos.x - transformedARPosition.x) > 0.001 || abs(currentPos.y - transformedARPosition.y) > 0.001 || abs(currentPos.z - transformedARPosition.z) > 0.001 {
                                    Swift.print("   ⚠️ WARNING: Object moved! Original: (\(String(format: "%.4f", transformedARPosition.x)), \(String(format: "%.4f", transformedARPosition.y)), \(String(format: "%.4f", transformedARPosition.z))), Current: (\(String(format: "%.4f", currentPos.x)), \(String(format: "%.4f", currentPos.y)), \(String(format: "%.4f", currentPos.z)))")
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
                } else {
                    // Not using AR coordinates - explain why
                    if userDistanceToObject >= 8.0 { Swift.print("   📍 Reason: User >8m from object (\(String(format: "%.1f", userDistanceToObject))m)") }
                    if distanceFromStoredOrigin >= 12.0 { Swift.print("   📍 Reason: Too far from stored AR origin (\(String(format: "%.1f", distanceFromStoredOrigin))m)") }
                    Swift.print("   🌍 STANDARD PLACEMENT: Object positioned using GPS (meter accuracy)")
                }
            } else {
                // No current AR origin - cannot use AR coordinates (no origin to reference)
                // Must use GPS coordinates instead
                useARCoordinates = false
                Swift.print("⚠️ No current AR origin set - cannot use stored AR coordinates")
                Swift.print("   📍 Reason: No AR session active")
                Swift.print("   🌍 STANDARD PLACEMENT: Object positioned using GPS (meter accuracy)")
            }

            // AR coordinate handling complete - fallthrough to GPS placement if needed
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
                Swift.print("⚠️ Cannot place GPS-based object '\(location.name)' using GPS: Operating in degraded AR-only mode")
                Swift.print("   GPS-based objects require GPS accuracy < 20.0m")
                Swift.print("   🎯 Switching to AR-only placement for this object")
                
                // Use AR-only placement instead of GPS-based placement
                placeLootBoxInFrontOfCamera(location: location, in: arView)
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
                placeBoxAtPosition(intendedPosition, location: location, in: arView, screenPoint: nil)

                // Clean up - position has been used
                UserDefaults.standard.removeObject(forKey: arPositionKey)
                return
            }

            guard let arOrigin = _arOriginLocation else {
                Swift.print("⚠️ Cannot place \(location.name): AR origin not set yet")
                Swift.print("   Waiting for AR origin to be established (requires GPS accuracy < 20.0m)")
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
                placeBoxAtPosition(finalPosition, location: location, in: arView, screenPoint: nil)
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
        placeBoxAtPosition(boxPosition, location: location, in: arView, screenPoint: nil)
    }
    // Place an object at exact AR world transform position (highest precision)
    private func placeBoxAtARTransform(_ arWorldTransform: simd_float4x4, location: LootBoxLocation, in arView: ARView) {
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ [AR Transform Placement] Cannot place '\(location.name)': AR frame not available")
            return
        }

        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let objectPos = SIMD3<Float>(arWorldTransform.columns.3.x, arWorldTransform.columns.3.y, arWorldTransform.columns.3.z)
        let distance = length(objectPos - cameraPos)

        Swift.print("🎯 Placing '\(location.name)' at exact AR position (distance: \(String(format: "%.2f", distance))m)")

        // Create the 3D model entity
        let modelEntity = createModelEntity(for: location, in: arView)

        // Create anchor entity at the exact AR world transform
        let anchorEntity = AnchorEntity(world: arWorldTransform)
        anchorEntity.addChild(modelEntity)

        // Add to scene
        arView.scene.addAnchor(anchorEntity)

        // Update findable objects
        let findable = FindableObject(
            locationId: location.id,
            anchor: anchorEntity,
            sphereEntity: modelEntity,
            location: location
        )
        findableObjects[location.id] = findable

        // Mark as placed in the box set
        placedBoxesSet.insert(location.id)

        // Set up tap handler for this object
        tapHandler?.placedBoxes[location.id] = anchorEntity
        tapHandler?.findableObjects[location.id] = findable

        // Update all manager references
        updateManagerReferences()

        // Play placement sound
        AudioServicesPlaySystemSound(1104) // Tink sound

        // Notify that object was placed
        objectPlaced.send(location.id)

        Swift.print("✅ Placed '\(location.name)' at exact AR world transform position")
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
        
        // CRITICAL: Check for exact AR world transform first (highest precision)
        if let arWorldTransformData = location.ar_world_transform,
           arWorldTransformData.count == MemoryLayout<simd_float4x4>.size {
            let arWorldTransform = arWorldTransformData.withUnsafeBytes { bytes in
                bytes.load(as: simd_float4x4.self)
            }
            // EXACT AR positioning: Use the stored world transform directly
            print("🎯 Using exact AR world transform for \(location.name) - highest precision!")

            // Place object at the exact stored AR position
            let anchor = ARAnchor(transform: arWorldTransform)
            arView.session.add(anchor: anchor)
            activeAnchors[location.id] = anchor

            // Create the visual entity
            placeBoxAtARTransform(arWorldTransform, location: location, in: arView)

            // Skip the rest of GPS-based positioning
            return
        }

        // CRITICAL: Use AR coordinates second for mm-precision (primary fallback)
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
            if let currentAROrigin = _arOriginLocation {
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

                // Position sphere so its base (bottom) is at the anchor position
                sphere.position = SIMD3<Float>(0, sphereRadius, 0)

                let light = PointLightComponent(color: .orange, intensity: 200)
                sphere.components.set(light)

                // Create traditional anchor for sphere placement
                let anchor = AnchorEntity(world: arPosition)
                anchor.name = location.id
                anchor.addChild(sphere)
                arView.scene.addAnchor(anchor)

                print("📍 Placed sphere '\(location.name)' at AR position (\(String(format: "%.2f", arPosition.x)), \(String(format: "%.2f", arPosition.y)), \(String(format: "%.2f", arPosition.z)))")
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

                // CRITICAL: Update tap handler's dictionaries so the object is tappable
                // The tap handler checks both placedBoxes and findableObjects for tap detection
                tapHandler?.placedBoxes[location.id] = anchor
                if let findable = findableObjects[location.id] {
                    tapHandler?.findableObjects[location.id] = findable
                }

                // Update all manager references
                updateManagerReferences()

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
            arOriginGPS: _arOriginLocation
        ) else {
            Swift.print("⚠️ Precision positioning failed for sphere, using fallback")
            // Fallback to simple GPS conversion
            guard let arOrigin = _arOriginLocation else {
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

            // CRITICAL: Update tap handler's dictionaries so the object is tappable
            // The tap handler checks both placedBoxes and findableObjects for tap detection
            tapHandler?.placedBoxes[location.id] = anchor
            if let findable = findableObjects[location.id] {
                tapHandler?.findableObjects[location.id] = findable
            }

            // Update all manager references
            updateManagerReferences()

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

        // CRITICAL: Update tap handler's dictionaries so the object is tappable
        // The tap handler checks both placedBoxes and findableObjects for tap detection
        tapHandler?.placedBoxes[location.id] = anchor
        if let findable = findableObjects[location.id] {
            tapHandler?.findableObjects[location.id] = findable
        }

        // Update all manager references
        updateManagerReferences()

        Swift.print("✅ Placed AR sphere '\(location.name)' at AR position (\(String(format: "%.2f", precisePosition.x)), \(String(format: "%.2f", precisePosition.z)))")
    }
    
    // Helper method to place a randomly selected object at a specific position
    private func placeBoxAtPosition(_ boxPosition: SIMD3<Float>, location: LootBoxLocation, in arView: ARView, screenPoint: CGPoint? = nil) {
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
        
        // Determine object type based on location type from dropdown selection
        let selectedObjectType: PlacedObjectType
        switch location.type {
        case .chalice:
            selectedObjectType = .chalice
        case .sphere:
            selectedObjectType = .sphere
        case .cube:
            selectedObjectType = .cube
        case .templeRelic, .treasureChest, .lootChest, .lootCart, .turkey, .terrorEngine:
            selectedObjectType = .treasureBox
        default:
            selectedObjectType = .treasureBox // Default to treasure box for any new types
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
        let factoryTypeName = String(describing: type(of: factory))
        Swift.print("✅ Using factory \(factoryTypeName) for \(location.type.displayName)")

        // Create entity with temporary anchor (will be replaced by anchoring service)
        let tempAnchor = AnchorEntity()
        let (entity, findable) = factory.createEntity(location: location, anchor: tempAnchor, sizeMultiplier: sizeMultiplier)

        let placedEntity = entity
        let findableObject = findable

        // Create optimal anchor (plane anchor if possible, world anchor as fallback)
        let anchor = createOptimalAnchor(for: groundedPosition, screenPoint: screenPoint, objectType: location.type, in: arView)
        anchor.name = location.id
        anchor.addChild(placedEntity)
        arView.scene.addAnchor(anchor)

        Swift.print("📍 Placed '\(location.name)' at grounded position (\(String(format: "%.2f", groundedPosition.x)), \(String(format: "%.2f", groundedPosition.y)), \(String(format: "%.2f", groundedPosition.z)))")
        objectPlacementTimes[location.id] = Date() // Record placement time for grace period

        Swift.print("✅✅✅ DRIFT-RESISTANT ANCHOR ADDED TO SCENE! ✅✅✅")
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

        // CRITICAL: Update tap handler's dictionaries so the object is tappable
        // The tap handler checks both placedBoxes and findableObjects for tap detection
        tapHandler?.placedBoxes[location.id] = anchor
        tapHandler?.findableObjects[location.id] = findableObject
        Swift.print("   ✅ Updated tap handler's placedBoxes and findableObjects - object is now tappable")

        // Update all manager references
        updateManagerReferences()
        
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

                // Use ARPositioningService to set AR positioning data
                let arService = ARPositioningService.shared
                let arOriginStruct = ARPositioningService.AROrigin(
                    latitude: arOrigin.coordinate.latitude,
                    longitude: arOrigin.coordinate.longitude
                )
                let arOffsets = ARPositioningService.AROffsets.fromARPosition(groundedPosition)

                arService.applyARPositioning(
                    to: &updatedLocation,
                    origin: arOriginStruct,
                    offsets: arOffsets,
                    placementTimestamp: arService.createPlacementTimestamp()
                )

                locationManager.locations[index] = updatedLocation
                locationManager.saveLocations()
                Swift.print("✅ Saved AR coordinates for manually placed object '\(location.name)'")
                Swift.print("   AR offset: (\(String(format: "%.4f", arOffsets.x)), \(String(format: "%.4f", arOffsets.y)), \(String(format: "%.4f", arOffsets.z)))m")
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
                    source: .map // Use .map so NPCs sync and are visible to all users on the map
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
        placeBoxAtPosition(boxPosition, location: location, in: arView, screenPoint: nil)
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
        
        // NOTE: Object removal is now handled by FindableObject after confetti/animation completes
        // This ensures confetti animations work properly before object disappears
        
        // Use FindableObject's find() method - this encapsulates all the basic findable behavior
        // This will trigger: confetti, sound, animation
        // The object will be removed in the completion callback
        let objectName = findableObject.itemDescription()
        findableObject.find { [weak self] in
            // Show discovery notification AFTER animation completes
            DispatchQueue.main.async { [weak self] in
                // Get the object to access created_by field
                if let foundLocation = findableObject.location,
                   let createdBy = foundLocation.created_by {
                    
                    // Format: "Found <username>'s <itemname>!"
                    let username: String
                    if createdBy == APIService.shared.currentUserID {
                        username = "Your"
                    } else if createdBy == "admin-web-ui" {
                        username = "Admin"
                    } else {
                        username = "Another user's"
                    }
                    self?.collectionNotificationBinding?.wrappedValue = "🎉 Found \(username) \(objectName)!"
                } else {
                    // Fallback to original message
                    self?.collectionNotificationBinding?.wrappedValue = "🎉 Discovered: \(objectName)!"
                }
            }
            
            // Hide notification after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = nil
            }
            
            // CRITICAL: Remove anchor from AR scene to make object disappear
            // This happens AFTER confetti and animation complete
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // NOTE: Anchor removal is now handled by FindableObject after confetti/animation completes
                Swift.print("ℹ️ Object \(objectName) (ID: \(locationId)) removal handled by FindableObject")

                // Cleanup after find completes
                if self.placedBoxes[locationId] != nil {
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

        // CRITICAL: Update tap handler's dictionaries so the object is tappable
        // The tap handler checks both placedBoxes and findableObjects for tap detection
        tapHandler?.placedBoxes[item.id] = anchor
        if let findable = findableObjects[item.id] {
            tapHandler?.findableObjects[item.id] = findable
        }

        // Update all manager references
        updateManagerReferences()

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
        ARGPSUtilities.correctGPSCoordinates(
            location: location,
            intendedARPosition: intendedARPosition,
            arOrigin: arOrigin,
            cameraTransform: cameraTransform
        )

        // Reload locations to pick up the corrected coordinates (this needs to stay in coordinator)
        Task {
            await locationManager?.loadLocationsFromAPI(userLocation: userLocationManager?.currentLocation)
            Swift.print("   🔄 Locations reloaded with corrected GPS coordinates")
        }
    }
    
    /// Handles notification from ARPlacementView when an object is saved
    /// This triggers immediate placement so the object appears right after placement view dismisses
    @objc private func handleARPlacementObjectSaved(_ notification: Notification) {
        guard arView != nil,
              let userLocation = userLocationManager?.currentLocation else {
            Swift.print("⚠️ [Placement Notification] Cannot place object: Missing AR view or location")
            return
        }

        // Check if we have direct placement data (new format)
        if let placementData = notification.userInfo,
           let objectId = placementData["objectId"] as? String,
           let gpsCoordinate = placementData["gpsCoordinate"] as? CLLocationCoordinate2D,
           let arPositionArray = placementData["arPosition"] as? [Float], arPositionArray.count >= 3,
           let arOriginArray = placementData["arOrigin"] as? [Double], arOriginArray.count >= 2,
           let groundingHeight = placementData["groundingHeight"] as? Double,
           let scale = placementData["scale"] as? Float {

            // Direct placement with provided AR coordinates
            let arPosition = SIMD3<Float>(arPositionArray[0], arPositionArray[1], arPositionArray[2])
            let arOrigin = CLLocation(latitude: arOriginArray[0], longitude: arOriginArray[1])

            Swift.print("🔔 [Placement Notification] Direct placement for object: \(objectId)")
            Swift.print("   AR Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))")
            Swift.print("   AR Origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
            Swift.print("   Scale: \(String(format: "%.2f", scale))x")

            // CRITICAL: Try to get the actual location from locationManager (it should have AR coordinates already saved)
            // If found, use it directly. Otherwise create a temporary location.
            var locationToPlace: LootBoxLocation

            if let actualLocation = locationManager?.locations.first(where: { $0.id == objectId }) {
                Swift.print("✅ Found location in locationManager with saved AR coordinates")
                Swift.print("   Name: \(actualLocation.name), Type: \(actualLocation.type.displayName)")
                Swift.print("   AR Offset: (\(actualLocation.ar_offset_x ?? 0), \(actualLocation.ar_offset_y ?? 0), \(actualLocation.ar_offset_z ?? 0))")
                locationToPlace = actualLocation
            } else {
                Swift.print("⚠️ Location not found in locationManager, creating temporary location")

                // CRITICAL: Get object type and name from notification data
                let objectTypeString = notification.userInfo?["objectType"] as? String ?? "chalice"
                let objectType = LootBoxType(rawValue: objectTypeString) ?? .chalice
                let objectName = notification.userInfo?["objectName"] as? String ?? "New AR Object"
                Swift.print("   Using object type from notification: \(objectType.displayName)")
                Swift.print("   Using object name from notification: \(objectName)")

                // Create temporary location for immediate placement
                var tempLocation = LootBoxLocation(
                    id: objectId,
                    name: objectName, // Use the actual name from notification data
                    type: objectType, // Use type from notification
                    latitude: gpsCoordinate.latitude,
                    longitude: gpsCoordinate.longitude,
                    radius: 5.0,
                    grounding_height: groundingHeight,
                    source: .map // Direct placement should sync to API
                )

                // Set AR positioning data using ARPositioningService
                let arService = ARPositioningService.shared
                let arOriginStruct = ARPositioningService.AROrigin(
                    latitude: arOrigin.coordinate.latitude,
                    longitude: arOrigin.coordinate.longitude
                )
                let arOffsets = ARPositioningService.AROffsets.fromARPosition(arPosition)

                arService.applyARPositioning(
                    to: &tempLocation,
                    origin: arOriginStruct,
                    offsets: arOffsets,
                    placementTimestamp: arService.createPlacementTimestamp()
                )

                locationToPlace = tempLocation

                // CRITICAL FIX: Add temporary location to locationManager so tap detection works
                // Without this, the object is placed in AR but tap handler can't find it
                locationManager?.addLocation(tempLocation)
                Swift.print("✅ Added temporary location to locationManager for tap detection")
            }

            // Extract screen coordinates for plane anchor raycasting
            let screenPoint: CGPoint? = {
                if let coords = placementData["screenPoint"] as? [CGFloat], coords.count >= 2 {
                    return CGPoint(x: coords[0], y: coords[1])
                }
                return nil
            }()

            // Place immediately at the exact AR coordinates WITH the scale from placement view
            placeObjectAtARPosition(locationToPlace, arPosition: arPosition, userLocation: userLocation, scale: scale, screenPoint: screenPoint)

        } else {
            // Fallback to old method (reload and check nearby)
            guard let nearbyLocations = nearbyLocationsBinding?.wrappedValue else {
                Swift.print("⚠️ [Placement Notification] Missing nearbyLocations for fallback method")
                return
            }

            Swift.print("🔔 [Placement Notification] Fallback method - reloading locations")
            Swift.print("   Nearby locations: \(nearbyLocations.count)")

            // Force immediate placement check (bypass throttling)
            checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
        }
    }

    /// Place an object directly at specified AR coordinates (for immediate placement after AR creation)
    private func placeObjectAtARPosition(_ location: LootBoxLocation, arPosition: SIMD3<Float>, userLocation: CLLocation, scale: Float = 1.0, screenPoint: CGPoint? = nil) {
        guard let arView = arView else {
            Swift.print("⚠️ Cannot place object: No AR view")
            return
        }

        // Check if object is already placed
        if placedBoxes.keys.contains(location.id) {
            Swift.print("ℹ️ Object \(location.id) already placed, skipping")
            return
        }

        // CRITICAL FIX: For fresh AR placements from placement view, use the exact position provided
        // Don't try to be smart with world map anchoring or saved coordinates for fresh placements
        // The placement view already calculated the perfect position at the crosshairs
        let finalPosition = arPosition
        let useWorldMapAnchoring = false

        Swift.print("🎯 Using exact AR position from placement view (no repositioning)")
        Swift.print("   AR Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))")

        Swift.print("🎯 Placing object '\(location.name)' (ID: \(location.id)) in main AR view")
        Swift.print("   Final AR Position: (\(String(format: "%.4f", finalPosition.x)), \(String(format: "%.4f", finalPosition.y)), \(String(format: "%.4f", finalPosition.z)))")

        do {
            // Create optimal anchor (plane anchor if possible, world anchor as fallback)
            let anchor = createOptimalAnchor(for: finalPosition, screenPoint: screenPoint, objectType: location.type, in: arView)
            // CRITICAL: Set anchor name to location.id so tap detection works even if entity hit test fails
            anchor.name = location.id

            // Get factory and create entity
            let factory = LootBoxFactoryRegistry.factory(for: location.type)
            // CRITICAL: Use the findableObject returned by factory - it has proper sphere/container references
            // Use the scale parameter from the placement view to maintain consistent size
            let (entity, findableObject) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: scale)

            // Ensure entity is visible and enabled
            entity.isEnabled = true

            // Add to anchor
            anchor.addChild(entity)

            // Ground the object properly - but skip for AR-placed objects that already have precise positioning
            // AR-placed objects from placement view are already positioned correctly on surfaces
            if location.ar_offset_x == nil || location.ar_offset_y == nil || location.ar_offset_z == nil {
                // Only apply grounding for GPS-based objects that don't have precise AR coordinates
                let bounds = entity.visualBounds(relativeTo: anchor)
                let currentMinY = bounds.min.y
                let desiredMinY: Float = 0
                let deltaY = desiredMinY - currentMinY
                entity.position.y += deltaY
                Swift.print("📏 Applied grounding adjustment: ΔY=\(String(format: "%.3f", deltaY))m")
            } else {
                Swift.print("📏 Skipped grounding for AR-placed object (already positioned correctly)")
            }

            // Add to scene
            arView.scene.addAnchor(anchor)

            // Set callback to mark as collected when found
            findableObject.onFoundCallback = { [weak self] (id: String) in
                DispatchQueue.main.async {
                    if let locationManager = self?.locationManager {
                        locationManager.markCollected(id)
                    }
                }
            }

            // Track the placement
            findableObjects[location.id] = findableObject
            objectsInViewport.insert(location.id)
            objectPlacementTimes[location.id] = Date()

            // CRITICAL: Update tap handler's dictionaries so the object is tappable
            // The tap handler checks both placedBoxes and findableObjects for tap detection
            tapHandler?.placedBoxes[location.id] = anchor
            tapHandler?.findableObjects[location.id] = findableObject

            // AR WORLD MAP INTEGRATION: Save anchor transform for persistence
            if useWorldMapAnchoring,
               let worldMapService = worldMapPersistenceService,
               worldMapService.isPersistenceEnabled {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorData = ARPositioningService.shared.encodeAnchorTransform(anchorTransform)

                if let encodedTransform = anchorData {
                    // Save the anchor transform for this object
                    // This enables restoration of exact object positions when world map is reloaded
                    Task {
                        // Note: We would need to add an API method to save anchor transforms
                        // For now, store locally in the world map service
                        worldMapService.storeObjectWorldTransform(location.id, transform: anchorTransform)
                        Swift.print("🗺️ Saved anchor transform for object \(location.id)")
                    }
                }
            }

            // Update all manager references
            updateManagerReferences()

            // Start continuous loop animation if the factory supports it
            factory.animateLoop(entity: entity)

            // Apply uniform luminance if ambient light is disabled
            environmentManager?.applyUniformLuminanceToNewEntity(anchor)

            // Mark as manually placed to prevent removal by checkAndPlaceBoxes
            self.manuallyPlacedObjectIds.insert(location.id)

            Swift.print("✅ Successfully placed object '\(location.name)' at AR coordinates")
            Swift.print("   Object is now tappable and visible in AR")

        } catch {
            Swift.print("❌ Failed to place object '\(location.name)': \(error)")
        }
    }

    /// Handle dialog opened notification - pause AR session
    @objc private func handleDialogOpened(_ notification: Notification) {
        isDialogOpen = true
        pauseARSession()
    }

    /// Handle dialog closed notification - resume AR session
    @objc private func handleDialogClosed(_ notification: Notification) {
        isDialogOpen = false
        resumeARSession()
        // Clear conversationNPC binding to allow re-tapping
        DispatchQueue.main.async { [weak self] in
            self?.conversationNPCBinding?.wrappedValue = nil
        }
    }
    
    /// Public method to pause AR session (called from views that need to pause AR)
    public func pauseARSession() {
        pauseARSessionInternal()
    }

    /// Pause AR session when sheet is shown (saves battery and prevents UI freezes)
    private func pauseARSessionInternal() {
        Swift.print("⏸️ [AR SESSION] pauseARSession called")
        Swift.print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        Swift.print("   Timestamp: \(Date())")

        guard let arView = arView else {
            Swift.print("⚠️ Cannot pause AR session: AR view not available")
            return
        }

        Swift.print("   ARView ID: \(ObjectIdentifier(arView))")

        // Only pause if session is currently running
        guard arView.session.configuration != nil else {
            Swift.print("ℹ️ AR session not running, skipping pause")
            return
        }

        // Save current configuration for resuming
        if let config = arView.session.configuration as? ARWorldTrackingConfiguration {
            savedARConfiguration = config
            Swift.print("⏸️ Pausing AR session (sheet shown)")
            Swift.print("   Config saved for resume")
            arView.session.pause()
            Swift.print("   ✅ Session paused")
        } else {
            Swift.print("⚠️ Could not save AR configuration for resuming")
        }
    }
    
    /// Public method to resume AR session (called from views that need to resume AR)
    public func resumeARSession() {
        resumeARSessionInternal()
    }

    /// Resume AR session when sheet is dismissed
    private func resumeARSessionInternal() {
        Swift.print("▶️ [AR SESSION] resumeARSession called")
        Swift.print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        Swift.print("   Timestamp: \(Date())")

        guard let arView = arView else {
            Swift.print("⚠️ Cannot resume AR session: AR view not available")
            return
        }

        Swift.print("   ARView ID: \(ObjectIdentifier(arView))")
        Swift.print("   Session state before resume: \(arView.session.configuration != nil ? "CONFIGURED" : "NOT CONFIGURED")")

        // CRITICAL FIX: Always ensure we have a valid configuration to resume with
        let configToUse: ARWorldTrackingConfiguration
        if let savedConfig = savedARConfiguration {
            configToUse = savedConfig
            Swift.print("   Using saved configuration")
        } else {
            Swift.print("⚠️ No saved configuration - creating enhanced config")
            // Create enhanced configuration with VIO/SLAM optimizations
            configToUse = vioSlamService?.getEnhancedARConfiguration() ?? ARWorldTrackingConfiguration()

            // Apply current lens if available
            if let selectedLensId = locationManager?.selectedARLens,
               let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
                configToUse.videoFormat = videoFormat
                Swift.print("   Applied lens: \(selectedLensId)")
            }
        }

        // CRITICAL FIX: Use .resetTracking option to ensure camera feed comes back
        // Empty options [] can leave the session in a paused state
        let resumeOptions: ARSession.RunOptions = [.resetTracking]
        Swift.print("▶️ Resuming AR session with resetTracking option")
        Swift.print("   This ensures camera feed is restored after pause")

        arView.session.run(configToUse, options: resumeOptions)
        Swift.print("   ✅ Session resumed with resetTracking")
        Swift.print("   Session state after resume: \(arView.session.configuration != nil ? "CONFIGURED" : "NOT CONFIGURED")")

        // Wait for session to stabilize, then check tracking state
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if let frame = self.arView?.session.currentFrame {
                Swift.print("🔍 Post-resume tracking check:")
                Swift.print("   Camera tracking state: \(frame.camera.trackingState)")
                if case .notAvailable = frame.camera.trackingState {
                    Swift.print("⚠️ Camera tracking still not available after resume - this causes black screen")
                    Swift.print("💡 User may need to move device or wait for better lighting/GPS")
                } else {
                    Swift.print("✅ Camera tracking restored successfully")
                }
            } else {
                Swift.print("❌ No frame available after resume - camera not working")
            }
        }

        savedARConfiguration = nil // Clear saved config after resuming

        // CRITICAL FIX: Re-place all objects after resuming AR session
        // When the AR session is paused/resumed, world anchors may lose tracking or shift
        // Re-placing objects ensures they appear at their stored AR coordinates
        Swift.print("🔄 Re-placing objects after AR session resume...")
        if let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            Swift.print("   Found \(nearby.count) nearby locations to re-place")

            // Give AR session a brief moment to stabilize before re-placing objects
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                Swift.print("   Calling checkAndPlaceBoxes to restore objects...")
                self.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
            }
        } else {
            Swift.print("   ⚠️ Cannot re-place objects: No user location available")
        }
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

        // NUCLEAR CLEANUP: Remove ALL remaining anchors from the scene to prevent orphaned entities
        // This is a safety measure in case some entities weren't properly tracked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let arView = self.arView else { return }

            var orphanedCount = 0
            let allAnchors = arView.scene.anchors.map { $0 } // Create a copy to avoid mutation during iteration

            for anchor in allAnchors {
                // Keep only essential anchors (camera, system anchors)
                // Remove any AnchorEntity that might be orphaned
                if let anchorEntity = anchor as? AnchorEntity {
                    // Check if this anchor has any children (indicating it might be a placed object)
                    if !anchorEntity.children.isEmpty {
                        // Additional check: if it has a UUID-like name, it's likely an orphaned object
                        if anchorEntity.name.contains("-") && anchorEntity.name.count >= 36 {
                            Swift.print("🧹 Removing orphaned anchor: \(anchorEntity.name)")
                            anchorEntity.removeFromParent()
                            orphanedCount += 1
                        }
                    }
                }
            }

            if orphanedCount > 0 {
                Swift.print("🧹 Nuclear cleanup removed \(orphanedCount) orphaned anchors")
            }
        }
    }

    // MARK: - Debug Methods

    /// Debug method to identify and report orphaned entities in the AR scene
    func debugOrphanedEntities() {
        guard let arView = arView else {
            Swift.print("❌ No AR view available for orphaned entity debug")
            return
        }

        Swift.print("🔍 Orphaned Entities Debug:")
        Swift.print("   Total scene anchors: \(arView.scene.anchors.count)")
        Swift.print("   Tracked loot boxes: \(placedBoxes.count)")
        Swift.print("   Tracked NPCs: \(placedNPCs.count)")
        Swift.print("   Tracked findable objects: \(findableObjects.count)")

        var orphanedAnchors: [(String, Int)] = [] // (name, childCount)

        for anchor in arView.scene.anchors {
            if let anchorEntity = anchor as? AnchorEntity {
                let name = anchorEntity.name
                let childCount = anchorEntity.children.count

                // Check if this is likely an orphaned object
                let isTrackedLootBox = placedBoxes.keys.contains(name)
                let isTrackedNPC = placedNPCs.keys.contains(name)
                let isTrackedFindable = findableObjects.keys.contains(name)

                let isTracked = isTrackedLootBox || isTrackedNPC || isTrackedFindable

                if !isTracked && !name.isEmpty {
                    // This might be orphaned
                    if childCount > 0 || (name.contains("-") && name.count >= 36) {
                        orphanedAnchors.append((name, childCount))
                        Swift.print("   👻 Potential orphan: '\(name)' (\(childCount) children, type: \(type(of: anchorEntity)))")
                    }
                }
            }
        }

        if orphanedAnchors.isEmpty {
            Swift.print("   ✅ No orphaned entities detected")
        } else {
            Swift.print("   ⚠️ Found \(orphanedAnchors.count) potential orphaned entities")
        }
    }

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

    // MARK: - NFC Object Created Notification

    @objc private func handleNFCObjectCreated(_ notification: Notification) {
        // This method is called when an NFC object is created
        // You can add any additional logic you want to execute when an NFC object is created
        Swift.print("🎉 NFC Object Created Notification received!")
    }

    @objc private func handleNFCObjectPlaced(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let objectId = userInfo["objectId"] as? String,
              let anchorEntity = userInfo["anchorEntity"] as? AnchorEntity else {
            Swift.print("⚠️ NFC object placed notification missing required data")
            return
        }

        Swift.print("🎯 Handling NFC object placement: '\(objectId)'")

        // Create a basic LootBoxLocation for this NFC object
        // We don't have detailed object info here, so we use defaults
        let location = LootBoxLocation(
            id: objectId,
            name: "NFC Object", // Will be updated when tapped and API data is fetched
            type: .chalice,
            latitude: 0, // NFC objects may not have GPS coordinates
            longitude: 0,
            radius: 5.0,
            source: .map // NFC-placed objects should sync to API
        )

        // Register the anchor for tapping
        registerNFCObjectAnchor(objectId: objectId, anchorEntity: anchorEntity, location: location)

        Swift.print("✅ NFC object '\(objectId)' is now tappable")
    }

    /// Register an already-placed NFC object anchor for tapping
    /// This is called when NFC objects are placed by PreciseARPositioningService
    func registerNFCObjectAnchor(objectId: String, anchorEntity: AnchorEntity, location: LootBoxLocation? = nil) {
        Swift.print("🎯 Registering NFC object for tapping: '\(objectId)'")

        // Create findable object for tap handler
        let findable = FindableObject(
            locationId: objectId,
            anchor: anchorEntity,
            sphereEntity: nil, // NFC objects might not have a specific sphere entity
            location: location ?? LootBoxLocation(
                id: objectId,
                name: "NFC Object",
                type: .chalice,
                latitude: 0,
                longitude: 0,
                radius: 5.0
            )
        )
        findableObjects[objectId] = findable

        // Register with tap handler
        tapHandler?.placedBoxes[objectId] = anchorEntity
        tapHandler?.findableObjects[objectId] = findable

        // Update all manager references
        updateManagerReferences()

        // Mark as placed
        placedBoxesSet.insert(objectId)

        // Set entity name for tap detection (critical for entity hit testing)
        anchorEntity.name = objectId
        // Also set name on child entities
        for child in anchorEntity.children {
            if child.name.isEmpty {
                child.name = "\(objectId)_child"
            }
        }

        Swift.print("✅ NFC object '\(objectId)' registered for tapping")
    }

    @objc private func handleRealtimeObjectCreated(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let location = userInfo["location"] as? LootBoxLocation else {
            Swift.print("⚠️ Real-time object created notification missing location data")
            return
        }

        Swift.print("🚀 Real-time object created - attempting immediate AR placement: '\(location.name)' (ID: \(location.id))")

        Task { @MainActor in
            guard let arView = self.arView,
                  let userLocation = self.userLocationManager?.currentLocation else {
                Swift.print("⚠️ Cannot place real-time object - AR view or user location not available")
                return
            }

            // CRITICAL: Check if this object is already placed (e.g., by NFC direct placement)
            // This prevents double placement when NFC objects are both directly placed AND broadcast via WebSocket
            if placedBoxes.keys.contains(location.id) {
                Swift.print("⏭️ Object '\(location.id)' already placed - skipping real-time placement to avoid duplicate")
                return
            }

            // Get nearby locations including the new one
            let nearbyLocations = self.locationManager?.getNearbyLocations(userLocation: userLocation) ?? []

            // Check if the new location is actually nearby (within search distance)
            let newLocationNearby = nearbyLocations.contains { $0.id == location.id }

            if newLocationNearby {
                Swift.print("✅ New object is within range - placing in AR immediately")
                // Place the object using the existing placement logic
                self.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
            } else {
                Swift.print("ℹ️ New object is outside search range - will appear when user moves closer")
            }
        }
    }

    @objc private func handleRealtimeObjectDeleted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let objectId = userInfo["object_id"] as? String else {
            Swift.print("⚠️ Real-time object deleted notification missing object_id")
            return
        }

        Swift.print("🗑️ Real-time object deleted - removing from AR: '\(objectId)'")

        Task { @MainActor in
            guard let arView = self.arView else {
                Swift.print("⚠️ Cannot remove object - AR view not available")
                return
            }

            // Remove the object from AR scene if it's currently placed
            if let findableObject = self.findableObjects[objectId] {
                let objectName = findableObject.location?.name ?? "Unknown"
                Swift.print("   Removing object '\(objectName)' from AR scene")

                // Remove from AR scene
                findableObject.anchor.removeFromParent()

                // Clean up tracking
                self.findableObjects.removeValue(forKey: objectId)
                self.objectsInViewport.remove(objectId)
                self.objectPlacementTimes.removeValue(forKey: objectId)

                // Update manager references
                self.updateManagerReferences()

                // Clear found sets so object can be re-placed if it gets recreated
                self.distanceTracker?.foundLootBoxes.remove(objectId)
                self.tapHandler?.foundLootBoxes.remove(objectId)

                Swift.print("✅ Object '\(objectName)' removed from AR scene")
            } else {
                Swift.print("ℹ️ Object '\(objectId)' was not currently placed in AR - nothing to remove")
            }
        }
    }

    @objc private func handleRealtimeObjectUpdated(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let location = userInfo["location"] as? LootBoxLocation else {
            Swift.print("⚠️ Real-time object updated notification missing location data")
            return
        }

        let objectId = location.id
        let objectName = location.name
        Swift.print("🔄 Real-time object updated: '\(objectName)' (ID: \(objectId), collected: \(location.collected))")

        Task { @MainActor in
            guard let arView = self.arView,
                  let userLocation = self.userLocationManager?.currentLocation else {
                Swift.print("⚠️ Cannot update object - AR view or user location not available")
                return
            }

            // Check if this object is currently placed in AR
            if let existingFindableObject = self.findableObjects[objectId] {
                let wasCollected = existingFindableObject.location?.collected ?? false
                let nowCollected = location.collected

                if !wasCollected && nowCollected {
                    // Object was just collected - remove it from AR
                    Swift.print("   🗑️ Object '\(objectName)' was collected - removing from AR")

                    existingFindableObject.anchor.removeFromParent()
                    self.findableObjects.removeValue(forKey: objectId)
                    self.objectsInViewport.remove(objectId)
                    self.objectPlacementTimes.removeValue(forKey: objectId)

                    // Add to found sets to prevent re-placement
                    self.distanceTracker?.foundLootBoxes.insert(objectId)
                    self.tapHandler?.foundLootBoxes.insert(objectId)

                    // Update manager references
                    self.updateManagerReferences()

                    Swift.print("✅ Object '\(objectName)' removed from AR (collected by another user)")

                } else if wasCollected && !nowCollected {
                    // Object was uncollected (reset) - add it back to AR if it's nearby
                    Swift.print("   🔄 Object '\(objectName)' was reset to uncollected - checking if it should be re-placed")

                    // Clear found sets so it can be re-placed
                    self.distanceTracker?.foundLootBoxes.remove(objectId)
                    self.tapHandler?.foundLootBoxes.remove(objectId)

                    // Check if it's nearby and should be placed
                    let nearbyLocations = self.locationManager?.getNearbyLocations(userLocation: userLocation) ?? []
                    if nearbyLocations.contains(where: { $0.id == objectId }) {
                        Swift.print("   ✅ Object is nearby - re-placing in AR")
                        self.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
                    } else {
                        Swift.print("   ℹ️ Object is not nearby - will appear when user moves closer")
                    }
                } else {
                    // Object state didn't change in a way that affects AR placement
                    // Just update the location reference in case other properties changed
                    var updatedFindableObject = existingFindableObject
                    updatedFindableObject.location = location
                    self.findableObjects[objectId] = updatedFindableObject
                    Swift.print("   ℹ️ Object state unchanged for AR placement")
                }

            } else {
                // Object is not currently in AR
                if !location.collected {
                    // Object is uncollected and not in AR - check if it should be placed
                    Swift.print("   ➕ Object '\(objectName)' is uncollected and not in AR - checking if it should be placed")

                    let nearbyLocations = self.locationManager?.getNearbyLocations(userLocation: userLocation) ?? []
                    if nearbyLocations.contains(where: { $0.id == objectId }) {
                        Swift.print("   ✅ Object is nearby - placing in AR")
                        self.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearbyLocations)
                    } else {
                        Swift.print("   ℹ️ Object is not nearby - will appear when user moves closer")
                    }
                } else {
                    Swift.print("   ℹ️ Object '\(objectName)' is collected and not in AR - no action needed")
                }
            }
        }
    }

    // MARK: - AR Anchor Transform Support
    
    /// Decodes AR anchor transform from base64 string
    private func decodeARAnchorTransform(_ base64String: String) -> simd_float4x4? {
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
    
    /// Applies AR anchor transform to place object at exact position
    private func placeObjectWithARAnchor(_ location: LootBoxLocation, arAnchorTransform: simd_float4x4, in arView: ARView) {
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
        placeBoxAtPosition(position, location: location, in: arView, screenPoint: nil)
    }

    /// Check for and re-place unfound objects that should be visible but aren't in AR
    /// This handles the case where objects are reset from collected to unfound state
    private func replaceUnfoundObjects() {
        guard let locationManager = locationManager,
              let userLocation = userLocationManager?.currentLocation,
              let arView = arView else {
            return
        }
        
        // DEBUG: Log current placement state
        Swift.print("🔍 DEBUG: Placement check - Game mode: \(locationManager.gameMode.displayName), Search distance: \(locationManager.maxSearchDistance)m, User location: (\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude))")

        // Get nearby unfound objects that aren't currently placed
        let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
        let unfoundObjects = nearby.filter {
            !$0.collected &&
            placedBoxes[$0.id] == nil &&
            $0.latitude != 0 && // Skip manually placed objects (lat/lon 0,0)
            $0.longitude != 0
        }

        if !unfoundObjects.isEmpty {
            Swift.print("🔄 Found \(unfoundObjects.count) unfound objects that need re-placement")
            for location in unfoundObjects {
                let distance = userLocation.distance(from: location.location)
                Swift.print("   ↳ Re-placing: \(location.name) (ID: \(location.id), distance: \(String(format: "%.1f", distance))m, collected: \(location.collected))")
                placeLootBoxAtLocation(location, in: arView)
            }
        } else {
            // DEBUG: Log why no objects are being placed
            Swift.print("🔍 DEBUG: No unfound objects to place. Nearby count: \(nearby.count)")
            if !nearby.isEmpty {
                for location in nearby {
                    let distance = userLocation.distance(from: location.location)
                    let isPlaced = placedBoxes[location.id] != nil
                    Swift.print("   📍 Object: \(location.name) (ID: \(location.id), distance: \(String(format: "%.1f", distance))m, collected: \(location.collected), placed: \(isPlaced), coords: (\(location.latitude), \(location.longitude)))")
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// Creates a ModelEntity for a given loot box location
    private func createModelEntity(for location: LootBoxLocation, in arView: ARView) -> ModelEntity {
        // Create a simple box for the item
        let boxSize: Float = 0.3 // Same size as sphere diameter

        // Create a simple box mesh
        let boxMesh = MeshResource.generateBox(width: boxSize, height: boxSize, depth: boxSize, cornerRadius: 0.05)
        var boxMaterial = SimpleMaterial()
        boxMaterial.color = .init(tint: location.type.color)
        boxMaterial.roughness = 0.3
        boxMaterial.metallic = 0.5

        let boxEntity = ModelEntity(mesh: boxMesh, materials: [boxMaterial])
        boxEntity.name = location.id

        // Position box so bottom sits on ground
        boxEntity.position = SIMD3<Float>(0, boxSize/2, 0)

        // Add point light for visibility
        let light = PointLightComponent(color: location.type.glowColor, intensity: 150)
        boxEntity.components.set(light)

        return boxEntity
    }

    // MARK: - AR Mathematical Operations

    /// Converts AR world position back to GPS coordinates using AR origin
    /// - Parameters:
    ///   - arPosition: Position in AR world space (relative to AR origin at 0,0,0)
    ///   - arOrigin: GPS location of the AR origin point
    /// - Returns: GPS coordinates corresponding to the AR position
    private func convertARToGPS(arPosition: SIMD3<Float>, arOrigin: CLLocation) -> CLLocationCoordinate2D? {
        return ARMathUtilities.convertARToGPS(arPosition: arPosition, arOrigin: arOrigin)
    }

    /// Rotates AR coordinates based on compass heading to ensure consistent object orientation
    /// This ensures objects maintain the same orientation relative to magnetic north across different users/sessions
    private func rotateARCoordinatesForCompassHeading(_ arPosition: SIMD3<Float>, storedHeading: Double?, currentHeading: Double?) -> SIMD3<Float> {
        // If we don't have heading data, return coordinates unchanged
        guard let storedHeading = storedHeading, let currentHeading = currentHeading else {
            Swift.print("   🧭 No compass heading data available - using coordinates as-is")
            return arPosition
        }

        // Calculate the rotation angle needed to align with magnetic north
        let headingDifference = currentHeading - storedHeading
        let rotationAngleRadians = headingDifference * .pi / 180.0

        Swift.print("   🧭 Applying compass-based rotation:")
        Swift.print("      Stored heading: \(String(format: "%.1f", Float(storedHeading)))°")
        Swift.print("      Current heading: \(String(format: "%.1f", Float(currentHeading)))°")
        Swift.print("      Rotation needed: \(String(format: "%.1f", Float(headingDifference)))°")

        // Create rotation matrix around Y-axis (up/down axis) for compass rotation
        let rotationMatrix = simd_float3x3([
            SIMD3<Float>(Float(cos(rotationAngleRadians)), 0, Float(-sin(rotationAngleRadians))), // X rotation
            SIMD3<Float>(0, 1, 0),                                                  // Y unchanged (up)
            SIMD3<Float>(Float(sin(rotationAngleRadians)), 0, Float(cos(rotationAngleRadians)))  // Z rotation
        ])

        // Apply rotation to the AR position
        let rotatedPosition = rotationMatrix * arPosition

        Swift.print("      Original position: (\(String(format: "%.3f", arPosition.x)), \(String(format: "%.3f", arPosition.y)), \(String(format: "%.3f", arPosition.z)))")
        Swift.print("      Rotated position: (\(String(format: "%.3f", rotatedPosition.x)), \(String(format: "%.3f", rotatedPosition.y)), \(String(format: "%.3f", rotatedPosition.z)))")

        return rotatedPosition
    }

    /// Applies compass-based rotation to an AR anchor transform matrix
    /// This ensures objects maintain consistent orientation relative to magnetic north
    private func applyCompassRotationToAnchorTransform(_ transform: simd_float4x4, storedHeading: Double?, currentHeading: Double?) -> simd_float4x4 {
        // If we don't have heading data, return transform unchanged
        guard let storedHeading = storedHeading, let currentHeading = currentHeading else {
            Swift.print("   🧭 No compass heading data available for anchor transform - using as-is")
            return transform
        }

        // Calculate the rotation angle needed to align with magnetic north
        let headingDifference = currentHeading - storedHeading
        let rotationAngleRadians = headingDifference * .pi / 180.0

        // Extract translation component
        let translation = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )

        // Create rotation matrix around Y-axis
        let rotationMatrix = simd_float4x4([
            SIMD4<Float>(Float(cos(rotationAngleRadians)), 0, Float(-sin(rotationAngleRadians)), 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(Float(sin(rotationAngleRadians)), 0, Float(cos(rotationAngleRadians)), 0),
            SIMD4<Float>(0, 0, 0, 1)
        ])

        // Apply rotation to the transform
        let rotatedTransform = rotationMatrix * transform

        Swift.print("   🧭 Applied compass rotation to anchor transform:")
        Swift.print("      Heading difference: \(String(format: "%.1f", Float(headingDifference)))°")
        Swift.print("      Original transform translation: (\(String(format: "%.3f", translation.x)), \(String(format: "%.3f", translation.y)), \(String(format: "%.3f", translation.z)))")

        return rotatedTransform
    }

    /// Calculates the Euclidean distance between two 3D positions
    /// - Parameters:
    ///   - position1: First position
    ///   - position2: Second position
    /// - Returns: Distance in meters
    private func distanceBetween(_ position1: SIMD3<Float>, _ position2: SIMD3<Float>) -> Float {
        return length(position2 - position1)
    }

    /// Calculates horizontal distance (X-Z plane only) between two positions
    /// - Parameters:
    ///   - position1: First position
    ///   - position2: Second position
    /// - Returns: Horizontal distance in meters
    private func horizontalDistanceBetween(_ position1: SIMD3<Float>, _ position2: SIMD3<Float>) -> Float {
        let deltaX = position2.x - position1.x
        let deltaZ = position2.z - position1.z
        return sqrt(deltaX * deltaX + deltaZ * deltaZ)
    }

    /// Generates a random position within a specified distance range from a center point
    /// - Parameters:
    ///   - center: Center position
    ///   - minDistance: Minimum distance from center
    ///   - maxDistance: Maximum distance from center
    /// - Returns: Random position within the distance range
    private func generateRandomPosition(center: SIMD3<Float>, minDistance: Float, maxDistance: Float) -> SIMD3<Float> {
        let randomDistance = Float.random(in: minDistance...maxDistance)
        let randomAngle = Float.random(in: 0...(2 * Float.pi))

        let x = center.x + randomDistance * cos(randomAngle)
        let z = center.z + randomDistance * sin(randomAngle)

        return SIMD3<Float>(x, center.y, z)
    }

    // MARK: - Enhanced AR Stabilization

    /// Applies enhanced stabilization to all active AR objects using VIO/SLAM and multi-plane anchoring
    private func applyEnhancedStabilization() {
        // Apply stabilization to all findable objects
        for (objectId, findableObject) in findableObjects {
            stabilizeObject(objectId: objectId, findableObject: findableObject)
        }
    }

    /// Stabilizes a specific object using enhanced anchoring techniques
    private func stabilizeObject(objectId: String, findableObject: FindableObject) {
        let currentTransform = findableObject.anchor.transformMatrix(relativeTo: nil)
        let currentPosition = SIMD3<Float>(currentTransform.columns.3.x, currentTransform.columns.3.y, currentTransform.columns.3.z)

        var targetTransform = currentTransform
        var needsUpdate = false

        // Apply VIO/SLAM stabilization
        if let vioSlamService = vioSlamService {
            targetTransform = vioSlamService.stabilizeObject(objectId, currentTransform: targetTransform)
            needsUpdate = true

            // Apply drift compensation
            let compensatedPosition = vioSlamService.compensateDrift(for: objectId, currentPosition: SIMD3<Float>(targetTransform.columns.3.x, targetTransform.columns.3.y, targetTransform.columns.3.z))
            targetTransform.columns.3 = SIMD4<Float>(compensatedPosition.x, compensatedPosition.y, compensatedPosition.z, 1.0)
        }

        // Enhanced plane anchor corrections are handled by the GeometricStabilizer timer
        // which directly modifies the anchor entity position

        // Apply gradual stabilization to avoid sudden jumps
        if needsUpdate && targetTransform != currentTransform {
            // Smooth the transition to prevent jarring movements
            let smoothingFactor: Float = 0.1 // 10% correction per frame
            let smoothedTransform = interpolateTransform(from: currentTransform, to: targetTransform, factor: smoothingFactor)

            // Final validation before applying to RealityKit to prevent NaN errors
            if isValidTransform(smoothedTransform) {
                findableObject.anchor.transform = Transform(matrix: smoothedTransform)
            } else {
                Swift.print("⚠️ ARCoordinator: Rejecting invalid smoothed transform to prevent RealityKit NaN errors")
            }
        }
    }

    /// DEBUG: Comprehensive AR status report for troubleshooting invisible objects
    func debugARStatus() {
        Swift.print("🔍 === AR STATUS REPORT ===")
        Swift.print("📍 Placed objects: \(placedBoxes.count)")
        Swift.print("👁️ Objects in viewport: \(objectsInViewport.count)")
        Swift.print("🎮 Game mode: \(locationManager?.gameMode.displayName ?? "Unknown")")
        Swift.print("📏 Search distance: \(locationManager?.maxSearchDistance ?? 0)m")

        if let userLocation = userLocationManager?.currentLocation {
            Swift.print("📍 User location: (\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)) ±\(userLocation.horizontalAccuracy)m")

            let nearby = locationManager?.getNearbyLocations(userLocation: userLocation) ?? []
            Swift.print("📍 Nearby objects: \(nearby.count)")
            for location in nearby {
                let distance = userLocation.distance(from: location.location)
                let isPlaced = placedBoxes[location.id] != nil
                let isCollected = location.collected
                Swift.print("   • \(location.name): \(String(format: "%.1f", distance))m away, placed: \(isPlaced), collected: \(isCollected)")
            }
        } else {
            Swift.print("❌ No user location available")
        }

        if let arView = arView, let frame = arView.session.currentFrame {
            Swift.print("📹 AR tracking state: \(frame.camera.trackingState)")
        } else {
            Swift.print("❌ No AR frame available")
        }

        Swift.print("🔍 === END REPORT ===")
    }

    /// Force restart AR session when camera feed is frozen
    func forceRestartARSession() {
        Swift.print("🔄 FORCE RESTARTING AR SESSION - Attempting to fix frozen camera")

        guard let arView = arView else {
            Swift.print("❌ Cannot restart AR session: no ARView available")
            return
        }

        // Stop the current session
        Swift.print("⏹️ Stopping current AR session...")
        arView.session.pause()

        // Wait a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            Swift.print("▶️ Starting new AR session...")

            // Create fresh configuration
            let config = self.vioSlamService?.getEnhancedARConfiguration() ?? ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic

            // Apply lens if available
            if let selectedLensId = self.locationManager?.selectedARLens,
               let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
                config.videoFormat = videoFormat
                Swift.print("   Applied lens: \(selectedLensId)")
            }

            // Run with reset tracking
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

            Swift.print("✅ AR session restarted with reset tracking")

            // Re-place objects after restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                Swift.print("🔄 Re-placing objects after forced restart...")
                self.replaceUnfoundObjectsAsync()
            }
        }
    }

    /// Interpolates between two transforms for smooth stabilization
    private func interpolateTransform(from: simd_float4x4, to: simd_float4x4, factor: Float) -> simd_float4x4 {
        // Validate inputs to prevent NaN propagation
        guard isValidTransform(from) && isValidTransform(to) && !factor.isNaN && !factor.isInfinite else {
            Swift.print("⚠️ ARCoordinator: Invalid inputs to interpolateTransform, returning 'from'")
            return from
        }

        // Interpolate translation
        let fromPos = SIMD3<Float>(from.columns.3.x, from.columns.3.y, from.columns.3.z)
        let toPos = SIMD3<Float>(to.columns.3.x, to.columns.3.y, to.columns.3.z)
        let interpolatedPos = fromPos + (toPos - fromPos) * factor

        // Validate interpolated result
        guard isValidVector(interpolatedPos) else {
            Swift.print("⚠️ ARCoordinator: Interpolation produced invalid position, returning 'from'")
            return from
        }

        // For now, just interpolate position. Rotation interpolation would be more complex
        // and may not be necessary for small corrections
        var result = from
        result.columns.3 = SIMD4<Float>(interpolatedPos.x, interpolatedPos.y, interpolatedPos.z, 1.0)

        return result
    }

    /// Check if a vector contains valid (non-NaN, non-infinite) values
    private func isValidVector(_ vector: SIMD3<Float>) -> Bool {
        return !vector.x.isNaN && !vector.x.isInfinite &&
               !vector.y.isNaN && !vector.y.isInfinite &&
               !vector.z.isNaN && !vector.z.isInfinite
    }

    /// Check if a transform matrix contains valid (non-NaN, non-infinite) values
    /// - Parameter transform: The 4x4 transform matrix to validate
    /// - Returns: True if all values are valid, false otherwise
    private func isValidTransform(_ transform: simd_float4x4) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 {
                let value = transform[column][row]
                if value.isNaN || value.isInfinite {
                    return false
                }
            }
        }
        return true
    }

}

// MARK: - CLLocationCoordinate2D Extensions

extension CLLocationCoordinate2D {
    /// Calculate a new coordinate at a given distance and bearing from this coordinate
    /// - Parameters:
    ///   - distance: Distance in meters
    ///   - bearing: Bearing in degrees (0 = North, 90 = East, etc.)
    /// - Returns: New coordinate at the specified distance and bearing
    func coordinateAt(distance: Double, bearing: Double) -> CLLocationCoordinate2D {
        let earthRadius: Double = 6371000 // meters

        let lat1 = self.latitude * .pi / 180.0
        let lon1 = self.longitude * .pi / 180.0
        let bearingRad = bearing * .pi / 180.0

        let lat2 = asin(sin(lat1) * cos(distance / earthRadius) + cos(lat1) * sin(distance / earthRadius) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(distance / earthRadius) * cos(lat1), cos(distance / earthRadius) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(latitude: lat2 * 180.0 / .pi, longitude: lon2 * 180.0 / .pi)
    }
}

// Extension to calculate coordinate at distance and bearing
extension CLLocationCoordinate2D {
    func coordinate(atDistance distance: Double, atBearing bearing: Double) -> CLLocationCoordinate2D {
        let earthRadius: Double = 6371000 // meters

        let lat1 = self.latitude * .pi / 180.0
        let lon1 = self.longitude * .pi / 180.0
        let bearingRad = bearing * .pi / 180.0

        let lat2 = asin(sin(lat1) * cos(distance / earthRadius) + cos(lat1) * sin(distance / earthRadius) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(distance / earthRadius) * cos(lat1), cos(distance / earthRadius) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(latitude: lat2 * 180.0 / .pi, longitude: lon2 * 180.0 / .pi)
    }
}
