import SwiftUI
import RealityKit
import ARKit
import Combine

// MARK: - AR Loot Box View
struct ARLootBoxView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Binding var nearbyLocations: [LootBoxLocation]
    @Binding var distanceToNearest: Double?
    @Binding var temperatureStatus: String?
    @Binding var collectionNotification: String?
    @Binding var nearestObjectDirection: Double?
    @Binding var conversationNPC: ConversationNPC?
    @ObservedObject var treasureHuntService: TreasureHuntService

    @StateObject private var conversationManager = ARConversationManager()

    var body: some View {
        ZStack {
            ARViewContainer(
                locationManager: locationManager,
                userLocationManager: userLocationManager,
                nearbyLocations: $nearbyLocations,
                distanceToNearest: $distanceToNearest,
                temperatureStatus: $temperatureStatus,
                collectionNotification: $collectionNotification,
                nearestObjectDirection: $nearestObjectDirection,
                conversationNPC: $conversationNPC,
                conversationManager: conversationManager,
                treasureHuntService: treasureHuntService
            )
            .edgesIgnoringSafeArea(.all)

            // Conversation overlay in bottom third
            if let message = conversationManager.currentMessage {
                ARConversationOverlay(
                    npcName: message.npcName,
                    message: message.message,
                    isUserMessage: message.isUserMessage
                )
            }
            
            // Game mode indicator in center of screen
            GameModeIndicator(locationManager: locationManager)
        }
    }
}

// MARK: - Game Mode Indicator
struct GameModeIndicator: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @State private var isVisible: Bool = false
    @State private var currentDisplayedMode: GameMode?
    @State private var fadeOutTask: Task<Void, Never>?
    
    var body: some View {
        VStack {
            Spacer()
            
            if isVisible, let mode = currentDisplayedMode {
                Text(mode.displayName)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(mode == .deadMensSecrets ? Color.yellow : Color.blue, lineWidth: 2)
                            )
                    )
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            
            Spacer()
        }
        .onChange(of: locationManager.gameMode) { oldMode, newMode in
            print("🎮 GameModeIndicator onChange triggered: \(oldMode.displayName) → \(newMode.displayName)")
            handleGameModeChange(oldMode: oldMode, newMode: newMode)
        }
        .onReceive(locationManager.$gameMode.dropFirst()) { newMode in
            // Listen to published property changes (dropFirst to skip initial value)
            if let current = currentDisplayedMode {
                if current != newMode {
                    print("🎮 GameModeIndicator onReceive triggered: \(current.displayName) → \(newMode.displayName)")
                    handleGameModeChange(oldMode: current, newMode: newMode)
                }
            } else {
                // First time receiving - just update the displayed mode
                print("🎮 GameModeIndicator onReceive: Initial mode \(newMode.displayName)")
                currentDisplayedMode = newMode
            }
        }
        .onAppear {
            // Show badge initially when view appears
            print("🎮 GameModeIndicator onAppear: Initial mode is \(locationManager.gameMode.displayName)")
            currentDisplayedMode = locationManager.gameMode
            isVisible = true
            scheduleFadeOut()
        }
        .id(locationManager.gameMode) // Force view refresh when game mode changes
    }
    
    private func handleGameModeChange(oldMode: GameMode, newMode: GameMode) {
        // Only show badge if game mode actually changed (not initial load)
        guard oldMode != newMode else {
            print("🎮 GameModeIndicator: Mode unchanged, skipping")
            return
        }
        
        print("🎮 GameModeIndicator: Game mode changed from \(oldMode.displayName) to \(newMode.displayName)")
        print("   Current isVisible: \(isVisible)")
        print("   Current displayed mode: \(currentDisplayedMode?.displayName ?? "nil")")
        
        // Cancel any existing fade-out task
        fadeOutTask?.cancel()
        
        // Update the displayed mode
        currentDisplayedMode = newMode
        
        // Show the badge immediately when mode changes
        // Use MainActor to ensure UI updates happen on main thread
        Task { @MainActor in
            print("🎮 GameModeIndicator: Setting isVisible to true on main thread")
            withAnimation(.easeIn(duration: 0.3)) {
                isVisible = true
            }
            
            // Schedule new fade-out after 5 seconds
            scheduleFadeOut()
        }
    }
    
    private func scheduleFadeOut() {
        // Cancel any existing task
        fadeOutTask?.cancel()
        
        // Create new fade-out task
        fadeOutTask = Task {
            // Wait 5 seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            // Check if task was cancelled
            guard !Task.isCancelled else { 
                print("🎮 GameModeIndicator: Fade-out task was cancelled")
                return 
            }
            
            // Fade out with animation
            await MainActor.run {
                print("🎮 GameModeIndicator: Fading out notification")
                withAnimation(.easeOut(duration: 0.5)) {
                    isVisible = false
                }
            }
        }
    }
}

// MARK: - AR View Container (UIViewRepresentable)
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Binding var nearbyLocations: [LootBoxLocation]
    @Binding var distanceToNearest: Double?
    @Binding var temperatureStatus: String?
    @Binding var collectionNotification: String?
    @Binding var nearestObjectDirection: Double?
    @Binding var conversationNPC: ConversationNPC?
    @ObservedObject var conversationManager: ARConversationManager
    @ObservedObject var treasureHuntService: TreasureHuntService
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // CRITICAL: Load latest locations from API when entering AR mode
        // This ensures any objects placed via admin interface appear immediately
        Task {
            await locationManager.loadLocationsFromAPI(userLocation: userLocationManager.currentLocation, includeFound: true)
            print("✅ Loaded latest locations from API when entering AR mode")
        }

        // AR session configuration
        let config = ARWorldTrackingConfiguration()
        // Detect both horizontal (ground) and vertical (walls) planes
        // Vertical planes are used for occlusion (hiding loot boxes behind walls)
        config.planeDetection = [.horizontal, .vertical]

        // Enable scene reconstruction for better surface detection and grounding
        // This provides mesh-based surface data for more accurate object placement
        // Note: Scene reconstruction can cause pose prediction warnings during fast movement
        // These warnings are harmless and ARKit recovers automatically
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            print("✅ Scene reconstruction (mesh) enabled for better object grounding")
            print("ℹ️ Note: Pose prediction warnings during fast movement are normal and harmless")
        } else {
            print("⚠️ Scene reconstruction not supported on this device")
        }
        
        // Optimize for better tracking stability
        // This helps reduce pose prediction failures during movement
        if #available(iOS 16.0, *) {
            // Use collaborative session mode if available for better tracking
            // This can help reduce pose prediction warnings
            config.userFaceTrackingEnabled = false // Disable face tracking to reduce overhead
        }

        // NOTE: environmentTexturing may produce warnings like:
        // "Could not resolve material name 'arInPlacePostProcessCombinedPermute...'"
        // These are HARMLESS internal RealityKit materials - they load correctly via fallback path

        // Note: environmentTexturing may produce harmless warnings about internal RealityKit materials
        // These warnings (e.g., 'arInPlacePostProcessCombinedPermute14.rematerial') can be safely ignored
        // They are internal framework materials used for AR post-processing effects
        config.environmentTexturing = .automatic
        
        // Apply selected lens if available
        if let selectedLensId = locationManager.selectedARLens,
           let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
            config.videoFormat = videoFormat
            print("📷 Using selected AR lens: \(selectedLensId)")
        }
        
        // Check if AR is supported
        guard ARWorldTrackingConfiguration.isSupported else {
            print("❌ AR World Tracking is not supported on this device")
            return arView
        }

        // CRITICAL: Setup ARView and set delegate BEFORE running the session
        // This ensures session(_:didUpdate:) delegate methods are received from the very first frame
        context.coordinator.setupARView(arView, locationManager: locationManager, userLocationManager: userLocationManager, nearbyLocations: $nearbyLocations, distanceToNearest: $distanceToNearest, temperatureStatus: $temperatureStatus, collectionNotification: $collectionNotification, nearestObjectDirection: $nearestObjectDirection, conversationNPC: $conversationNPC, conversationManager: conversationManager, treasureHuntService: treasureHuntService)

        // CRITICAL: Initialize lastAppliedLensId to prevent updateUIView from thinking lens changed on first call
        context.coordinator.lastAppliedLensId = locationManager.selectedARLens
        print("🎯 [MAKEVIEW] Initialized lastAppliedLensId to: \(context.coordinator.lastAppliedLensId ?? "nil")")

        // Run the session AFTER setting up the coordinator and delegate
        print("🎯 [MAKEVIEW] Starting AR session...")
        print("🎯 [MAKEVIEW] Delegate before run: \(arView.session.delegate != nil ? "SET" : "NIL")")
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("🎯 [MAKEVIEW] AR session.run() called")
        print("🎯 [MAKEVIEW] Delegate after run: \(arView.session.delegate != nil ? "SET" : "NIL")")
        print("🎯 [MAKEVIEW] Session configuration: \(arView.session.configuration != nil ? "SET" : "NIL")")

        // Verify delegate is still set after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("🎯 [MAKEVIEW] Delegate after 0.5s: \(arView.session.delegate != nil ? "SET (\(type(of: arView.session.delegate!)))" : "NIL - DELEGATE WAS CLEARED!")")
        }

        // IMPORTANT: Automatic environment lighting is controlled through the AR session configuration
        // The config.environmentTexturing = .automatic above ensures virtual objects are lit by real-world lighting
        // Note: Lighting is controlled through the AR session configuration, not a property on ARView

        // Debug visuals disabled for cleaner AR experience
        // Uncomment the line below to enable debug visuals (green feature points, anchor origins)
        // arView.debugOptions = [.showFeaturePoints, .showAnchorOrigins]

        // CRITICAL: Set up NFC-AR integration service so NFC placement can capture AR positions
        // This allows centimeter-level accuracy when tapping NFC tags while in AR mode
        NFCARIntegrationService.shared.setup(with: arView)

        // Tap gesture for placing and collecting loot boxes - ADD AFTER setupARView so tapHandler is initialized
        let tapGesture = UITapGestureRecognizer(target: context.coordinator.tapHandler, action: #selector(ARTapHandler.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        let coordinator = context.coordinator
        
        // Throttle updateUIView to prevent excessive calls and freezing
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(context.coordinator.stateManager?.lastViewUpdateTime ?? Date())
        let shouldUpdate = timeSinceLastUpdate >= (context.coordinator.stateManager?.viewUpdateThrottleInterval ?? 0.1)
        
        // Always handle critical updates (lens changes, location changes)
        let currentLocationsCount = locationManager.locations.count
        let locationsChanged = currentLocationsCount != (context.coordinator.stateManager?.lastLocationsCount ?? 0)
        let currentLensId = locationManager.selectedARLens
        // Only update lens if the ID actually changed (not just video format object comparison)
        // Use coordinator's persistent property instead of @State which wasn't working
        let needsLensUpdate = currentLensId != context.coordinator.lastAppliedLensId
        let hasCriticalUpdate = locationsChanged || needsLensUpdate || uiView.session.configuration == nil
        
        // Only proceed if we should update OR if there's a critical update
        guard shouldUpdate || hasCriticalUpdate else {
            return // Skip this update to prevent excessive calls
        }
        
        context.coordinator.stateManager?.lastViewUpdateTime = now
        
        // Check if lens has changed and update AR configuration if needed
        // CRITICAL: Don't re-run session if configuration is nil - this means makeUIView is still running
        // Only re-run if there's an actual lens update and the session is already running
        let configIsNil = uiView.session.configuration == nil
        print("🎯 [UPDATEVIEW] Checking session status: config nil=\(configIsNil), needsLensUpdate=\(needsLensUpdate)")

        // Only proceed if session is already running AND lens needs update
        // Skip if config is nil (session not fully started yet)
        if !configIsNil && needsLensUpdate {
            print("🎯 [UPDATEVIEW] Lens changed - re-running AR session with new configuration")
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for walls (occlusion)
            // Note: environmentTexturing may produce harmless warnings about internal RealityKit materials
            // These warnings (e.g., 'arInPlacePostProcessCombinedPermute14.rematerial') can be safely ignored
            // They are internal framework materials used for AR post-processing effects
            config.environmentTexturing = .automatic
            
            // Apply selected lens if available
            if let selectedLensId = currentLensId,
               let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
                config.videoFormat = videoFormat
                print("📷 Updating AR lens to: \(selectedLensId) (format: \(videoFormat.imageResolution.width)x\(videoFormat.imageResolution.height) @ \(videoFormat.framesPerSecond)fps)")
            } else {
                print("📷 Using default AR lens (no specific lens selected)")
            }

            // When lens changes, fully reset the session to apply the new video format
            // This requires removing anchors and resetting tracking for the FOV change to take effect
            let options: ARSession.RunOptions = needsLensUpdate 
                ? [.resetTracking, .removeExistingAnchors] 
                : [.resetTracking, .removeExistingAnchors]
            
            uiView.session.run(config, options: options)
            
            // If we changed the lens, we need to re-place objects after the session resets
            if needsLensUpdate {
                print("🔄 Lens changed - session reset, objects will be re-placed when tracking is ready")
                // Set flag to force re-placement when AR tracking is ready
                context.coordinator.shouldForceReplacement = true
            }

            // Remember the lens we just applied to prevent redundant updates
            context.coordinator.lastAppliedLensId = currentLensId
        }
        
        // Check if locations have changed (new object added)
        if locationsChanged {
            context.coordinator.stateManager?.lastLocationsCount = currentLocationsCount
            // PERFORMANCE: Logging disabled - runs frequently
        }

        // Update nearby locations when user location changes OR when locations change
        // Move expensive operations to background thread to prevent freezing
        if let userLocation = userLocationManager.currentLocation {
            // Defer state updates to avoid "Modifying state during view update" warning
            let coordinator = context.coordinator
            let shouldCheckPlacement = locationsChanged

            // Use Task to properly defer ALL state updates outside of view update cycle
            // This prevents "Modifying state during view update" warnings
            Task { @MainActor in
                // Update location manager with current location for API refresh timer (lightweight)
                // This is now deferred to avoid state modification during view update
                locationManager.updateUserLocation(userLocation)
                
                // Get nearby locations (synchronous call, no need for Task.detached)
                let nearby = locationManager.getNearbyLocations(userLocation: userLocation)

                // Update UI on main thread - deferred outside view update cycle
                nearbyLocations = nearby

                // CRITICAL FIX: Only call checkAndPlaceBoxes when locations actually changed
                // This prevents re-placement of already-placed objects on every frame
                // Objects should be placed ONCE and stay fixed at their AR coordinates
                if shouldCheckPlacement {
                    // PERFORMANCE: Logging disabled
                    coordinator.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
                }
            }
        }
        
        // Handle randomization trigger
        if locationManager.shouldRandomize {
            print("🎯 Randomize button pressed - triggering sphere placement...")
            // Defer ALL state modifications to avoid "Modifying state during view update" warning
            Task { @MainActor in
                context.coordinator.randomizeLootBoxes()
                // Reset the flag after randomization is complete
                locationManager.shouldRandomize = false
                print("🔄 Randomize flag reset")
            }
        }

        // Handle single sphere placement trigger
        if locationManager.shouldPlaceSphere {
            print("🎯 Single sphere placement triggered in ARLootBoxView...")
            // Get the location ID if one was provided (from map marker)
            let locationId = locationManager.pendingSphereLocationId
            // Defer ALL state modifications to avoid "Modifying state during view update" warning
            Task { @MainActor in
                context.coordinator.placeSingleSphere(locationId: locationId)
                // Reset the flags after placement is complete
                locationManager.shouldPlaceSphere = false
                locationManager.pendingSphereLocationId = nil
                print("🔄 Single sphere flag reset")
            }
        }

        // Handle pending AR item placement
        if let pendingItem = locationManager.pendingARItem {
            print("🎯 Pending AR item placement triggered: \(pendingItem.name)")
            // Defer ALL state modifications to avoid "Modifying state during view update" warning
            Task { @MainActor in
                // Clear the pending item to prevent duplicate placements
                locationManager.pendingARItem = nil
                print("🔄 Pending AR item cleared to prevent duplicates")
                // Defer the actual placement
                context.coordinator.placeARItem(pendingItem)
            }
        }
        
        // Handle AR object reset trigger (when locations are reset)
        if locationManager.shouldResetARObjects {
            print("🔄 Reset AR objects triggered - removing all placed objects...")
            // Defer ALL state modifications to avoid "Modifying state during view update" warning
            Task { @MainActor in
                // Clear the flag to prevent duplicate resets
                locationManager.shouldResetARObjects = false
                context.coordinator.removeAllPlacedObjects()
                // Update nearby locations binding so UI reflects reset state
                // Re-placement will happen automatically on next AR frame update when tracking is ready
                if let userLocation = userLocationManager.currentLocation {
                    let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
                    nearbyLocations = nearby
                    // Note: Re-placement will be triggered by session(_:didUpdate:) when AR tracking is ready
                    // The shouldForceReplacement flag in ARCoordinator ensures objects are re-placed
                }
            }
        }
        
        // Update ambient light setting when it changes
        context.coordinator.updateAmbientLight()
    }
    
    func makeCoordinator() -> ARCoordinator {
        ARCoordinator()
    }
}

