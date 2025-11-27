import SwiftUI
import RealityKit
import ARKit

// MARK: - AR Loot Box View
struct ARLootBoxView: UIViewRepresentable {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Binding var nearbyLocations: [LootBoxLocation]
    @Binding var distanceToNearest: Double?
    @Binding var temperatureStatus: String?
    @Binding var collectionNotification: String?
    @Binding var nearestObjectDirection: Double?
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // AR session configuration
        let config = ARWorldTrackingConfiguration()
        // Detect both horizontal (ground) and vertical (walls) planes
        // Vertical planes are used for occlusion (hiding loot boxes behind walls)
        config.planeDetection = [.horizontal, .vertical]
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
        
        // Run the session
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        // Tap gesture for placing and collecting loot boxes
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        // Debug visuals disabled for cleaner AR experience
        // Uncomment the line below to enable debug visuals (green feature points, anchor origins)
        // arView.debugOptions = [.showFeaturePoints, .showAnchorOrigins]
        
        context.coordinator.setupARView(arView, locationManager: locationManager, userLocationManager: userLocationManager, nearbyLocations: $nearbyLocations, distanceToNearest: $distanceToNearest, temperatureStatus: $temperatureStatus, collectionNotification: $collectionNotification, nearestObjectDirection: $nearestObjectDirection)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        let coordinator = context.coordinator
        
        // Throttle updateUIView to prevent excessive calls and freezing
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(coordinator.lastViewUpdateTime)
        let shouldUpdate = timeSinceLastUpdate >= coordinator.viewUpdateThrottleInterval
        
        // Always handle critical updates (lens changes, location changes)
        let currentLocationsCount = locationManager.locations.count
        let locationsChanged = currentLocationsCount != coordinator.lastLocationsCount
        let currentLensId = locationManager.selectedARLens
        // Only update lens if the ID actually changed (not just video format object comparison)
        // Use coordinator's persistent property instead of @State which wasn't working
        let needsLensUpdate = currentLensId != context.coordinator.lastAppliedLensId
        let hasCriticalUpdate = locationsChanged || needsLensUpdate || uiView.session.configuration == nil
        
        // Only proceed if we should update OR if there's a critical update
        guard shouldUpdate || hasCriticalUpdate else {
            return // Skip this update to prevent excessive calls
        }
        
        coordinator.lastViewUpdateTime = now
        
        // Check if lens has changed and update AR configuration if needed
        // Ensure AR session is running or update if lens changed
        if uiView.session.configuration == nil || needsLensUpdate {
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
            coordinator.lastLocationsCount = currentLocationsCount
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
                
                // Get nearby locations on background thread
                let nearby = await Task.detached(priority: .userInitiated) {
                    locationManager.getNearbyLocations(userLocation: userLocation)
                }.value

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

