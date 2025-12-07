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
// NPCType is defined in NPCType.swift

// MARK: - AR Coordinator Core
class ARCoordinatorCore: NSObject, AROriginProvider {

    // Managers
    var environmentManager: AREnvironmentManager?
    var occlusionManager: AROcclusionManager?
    var objectRecognizer: ARObjectRecognizer?
    var distanceTracker: ARDistanceTracker?
    var tapHandler: ARTapHandler?
    var databaseIndicatorService: ARDatabaseIndicatorService?
    var groundingService: ARGroundingService?
    var precisionPositioningService: ARPrecisionPositioningService? // Legacy - kept for compatibility
    var geospatialService: ARGeospatialService? // New ENU-based geospatial service
    var treasureHuntService: TreasureHuntService? // Treasure hunt game mode service
    var npcService: ARNPCService? // NPC management service

    weak var arView: ARView?
    var locationManager: LootBoxLocationManager?
    var userLocationManager: UserLocationManager?
    private var nearbyLocationsBinding: Binding<[LootBoxLocation]>?
    private var conversationManager: ARConversationManager?

    // MEMORY OPTIMIZATION: Consolidated tracking - findableObjects contains the anchor, so no need for separate placedBoxes dictionary
    var findableObjects: [String: FindableObject] = [:] // Track all findable objects (contains anchor reference)
    var objectPlacementTimes: [String: Date] = [:] // Track when objects were placed (for grace period)

    // BACKWARD COMPATIBILITY: Computed property for services that still reference placedBoxes
    var placedBoxes: [String: AnchorEntity] {
        return findableObjects.mapValues { $0.anchor }
    }


    // MARK: - Skeleton Size Constants (defined in one place)
    // Target: 6-7 feet tall (1.83-2.13m) in AR space
    // Assuming base model is ~1.4m at scale 1.0, scale of 1.4 gives ~1.96m (6.4 feet)
    static let SKELETON_SCALE: Float = 1.4 // Results in approximately 6.5 feet tall skeleton
    static let SKELETON_COLLISION_SIZE = SIMD3<Float>(0.66, 2.0, 0.66) // Scaled proportionally for 6-7ft skeleton
    static let SKELETON_HEIGHT_OFFSET: Float = 1.65 // Scaled proportionally

    // NPC tracking
    var placedNPCs: [String: AnchorEntity] = [:] // Track all placed NPCs by ID
    var skeletonPlaced: Bool = false // Track if skeleton has been placed
    var corgiPlaced: Bool = false // Track if corgi has been placed
    var treasureXPlaced: Bool = false // Track if treasure X has been placed in AR
    var skeletonAnchor: AnchorEntity? // Reference to skeleton anchor (kept for backward compatibility)
    let SKELETON_NPC_ID = "skeleton-1" // ID for the skeleton NPC

    var hasTalkedToSkeleton: Bool = false // Track if player has talked to skeleton
    var collectedMapPieces: Set<Int> = [] // Track which map pieces player has collected (1 = skeleton, 2 = corgi)

    // AR Origin and location tracking
    var arOriginLocation: CLLocation? // GPS location when AR session started
    var arOriginSetTime: Date? // When AR origin was set (for degraded mode timeout)
    var isDegradedMode: Bool = false // True if operating without GPS (AR-only mode)
    var arOriginGroundLevel: Float? // Fixed ground level at AR origin (never changes)

    // UI Bindings
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var collectionNotificationBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    var conversationNPCBinding: Binding<ConversationNPC?>?

    // Placement state
    var lastSpherePlacementTime: Date? // Prevent rapid duplicate sphere placements
    var sphereModeActive: Bool = false // Track when we're in sphere randomization mode
    var hasAutoRandomized: Bool = false // Track if we've already auto-randomized spheres
    var shouldForceReplacement: Bool = false // Force re-placement after reset when AR is ready
    var lastAppliedLensId: String? = nil // Track last applied AR lens to prevent redundant session resets

    // PERFORMANCE: Disable verbose placement logging (causes freezing when many objects)
    let verbosePlacementLogging = false // Set to true only when debugging placement issues

    // Arrow direction tracking
    @Published var nearestObjectDirection: Double? = nil // Direction in degrees (0 = north, 90 = east, etc.)

    // Viewport visibility tracking for chime sounds
    var objectsInViewport: Set<String> = [] // Track which objects are currently visible
    var lastViewportCheck: Date = Date() // Throttle viewport checks to improve framerate

    // Dialog state tracking - pause AR session when sheet is open
    var isDialogOpen: Bool = false {
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
    var savedARConfiguration: ARWorldTrackingConfiguration?

    override init() {
        super.init()
    }

    /// Setup AR view with all necessary managers and bindings
    /// - Parameters:
    ///   - arView: The AR view to setup
    ///   - locationManager: Location manager for loot boxes
    ///   - userLocationManager: User location manager
    ///   - nearbyLocations: Binding for nearby locations
    ///   - distanceToNearest: Binding for distance to nearest object
    ///   - temperatureStatus: Binding for temperature status
    ///   - collectionNotification: Binding for collection notifications
    ///   - nearestObjectDirection: Binding for nearest object direction
    ///   - conversationNPC: Binding for conversation NPC
    ///   - conversationManager: AR conversation manager
    ///   - treasureHuntService: Treasure hunt service
    func setupARView(_ arView: ARView,
                     locationManager: LootBoxLocationManager,
                     userLocationManager: UserLocationManager,
                     nearbyLocations: Binding<[LootBoxLocation]>,
                     distanceToNearest: Binding<Double?>,
                     temperatureStatus: Binding<String?>,
                     collectionNotification: Binding<String?>,
                     nearestObjectDirection: Binding<Double?>,
                     conversationNPC: Binding<ConversationNPC?>,
                     conversationManager: ARConversationManager,
                     treasureHuntService: TreasureHuntService? = nil) {

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
        self.treasureHuntService = treasureHuntService

        // Initialize all managers
        initializeManagers(with: conversationManager)

        // Configure managers that depend on AR view now that it's available
        configureManagersWithARView()

        // Configure AR session
        configureARSession(for: arView)

        // Setup audio session
        setupAudioSession()

        // Register gesture recognizers
        registerGestureRecognizers(for: arView)

        // Start location updates
        startLocationUpdates()
    }

    private func initializeManagers(with conversationManager: ARConversationManager) {
        // Initialize managers that don't need arView/locationManager immediately
        // Managers that need arView/locationManager will be initialized later in configureManagersWithARView

        // Initialize object recognizer (no dependencies)
        objectRecognizer = ARObjectRecognizer()

        // Initialize database indicator service (no init parameters needed)
        databaseIndicatorService = ARDatabaseIndicatorService()

        // Initialize geospatial service
        geospatialService = ARGeospatialService()
    }

    private func configureManagersWithARView() {
        // Configure managers that need arView and locationManager now that they're available
        guard let arView = arView, let locationManager = locationManager else {
            print("⚠️ Cannot configure managers: arView or locationManager not available")
            return
        }

        // Configure environment manager
        environmentManager = AREnvironmentManager(arView: arView, locationManager: locationManager)

        // Configure occlusion manager
        occlusionManager = AROcclusionManager(arView: arView, locationManager: locationManager, distanceTracker: distanceTracker)

        // Configure distance tracker
        distanceTracker = ARDistanceTracker(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager, treasureHuntService: treasureHuntService)

        // Configure tap handler
        tapHandler = ARTapHandler(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager, arCoordinator: nil, arOriginProvider: self)

        // Configure grounding service
        groundingService = ARGroundingService(arView: arView)

        // Configure precision positioning service
        precisionPositioningService = ARPrecisionPositioningService(arView: arView)

        // Configure NPC service
        if let conversationManager = conversationManager {
            npcService = ARNPCService(arCoordinator: self, arView: arView, locationManager: locationManager, groundingService: groundingService, tapHandler: tapHandler, conversationManager: conversationManager, conversationNPCBinding: conversationNPCBinding)
        }
    }

    private func configureARSession(for arView: ARView) {
        // Create AR configuration with all features enabled
        let configuration = ARWorldTrackingConfiguration()

        // Enable plane detection
        configuration.planeDetection = [.horizontal, .vertical]

        // Enable scene reconstruction for better occlusion
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }

        // Enable environment texturing for better lighting
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // Enable person segmentation for better occlusion
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            configuration.frameSemantics.insert(.personSegmentationWithDepth)
        }

        // Enable camera grain estimation for tracking quality assessment
        if #available(iOS 16.0, *), ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        // Start AR session
        arView.session.run(configuration)
        savedARConfiguration = configuration
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session: \(error)")
        }
    }

    private func registerGestureRecognizers(for arView: ARView) {
        // Add tap gesture recognizer for object interaction
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
    }

    private func startLocationUpdates() {
        userLocationManager?.startUpdatingLocation()
    }

    // MARK: - Core Methods (to be implemented by subclasses or coordinators)

    func pauseARSession() {
        // Implementation will be in main coordinator
    }

    func resumeARSession() {
        // Implementation will be in main coordinator
    }

    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        // Forward to tap handler
        tapHandler?.handleTap(sender)
    }

    // MARK: - Utility Methods

    func clearFoundLootBoxes() {
        // Clear collected state for all loot boxes
        locationManager?.resetAllLocations()

        // Remove all placed objects from AR scene
        removeAllPlacedObjects()
    }

    func removeAllPlacedObjects() {
        guard let arView = arView else { return }

        // Remove all findable objects
        for (_, findable) in findableObjects {
            arView.scene.removeAnchor(findable.anchor)
        }
        findableObjects.removeAll()
        objectPlacementTimes.removeAll()

        // Remove all NPCs
        for (_, npcAnchor) in placedNPCs {
            arView.scene.removeAnchor(npcAnchor)
        }
        placedNPCs.removeAll()
        skeletonPlaced = false
        corgiPlaced = false
        skeletonAnchor = nil
        treasureXPlaced = false

        // Reset state
        arOriginLocation = nil
        arOriginSetTime = nil
        isDegradedMode = false
        arOriginGroundLevel = nil

        Swift.print("🧹 Cleared all AR objects and reset AR origin")
    }

    func updateAmbientLight() {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return }

        // Get camera transform for lighting direction
        let cameraTransform = frame.camera.transform

        // Create directional light that follows camera
        let light = DirectionalLight()
        light.light.intensity = 1000
        light.light.color = .white

        // Position light above and behind camera
        let lightPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y + 2.0, // 2m above camera
            cameraTransform.columns.3.z - 1.0  // 1m behind camera
        )
        light.position = lightPosition

        // Orient light toward scene center
        light.look(at: SIMD3<Float>(0, 0, 0), from: lightPosition, relativeTo: nil)

        // Add or update light in scene
        if let existingLightAnchor = arView.scene.anchors.first(where: { ($0 as? AnchorEntity)?.name == "ambientLight" }) as? AnchorEntity {
            // Update existing light
            if let existingLight = existingLightAnchor.children.first as? DirectionalLight {
                existingLight.light.intensity = light.light.intensity
                existingLight.light.color = light.light.color
                existingLight.position = light.position
                existingLight.look(at: SIMD3<Float>(0, 0, 0), from: lightPosition, relativeTo: nil)
            }
        } else {
            // Add new light
            let lightAnchor = AnchorEntity(world: .zero)
            lightAnchor.name = "ambientLight"
            lightAnchor.addChild(light)
            arView.scene.addAnchor(lightAnchor)
        }
    }
}
