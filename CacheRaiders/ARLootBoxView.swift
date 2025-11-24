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
    @State private var arView: ARView?
    @State private var lastLocationsCount: Int = 0 // Track location count to detect new additions
    @State private var lastUpdateTime: Date = Date() // Throttle updateUIView to prevent excessive calls
    private let updateThrottleInterval: TimeInterval = 0.1 // Update at most every 100ms (10 FPS for UI updates)
    
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
        // Throttle updateUIView to prevent excessive calls and freezing
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
        let shouldUpdate = timeSinceLastUpdate >= updateThrottleInterval
        
        // Always handle critical updates (lens changes, location changes)
        let currentLocationsCount = locationManager.locations.count
        let locationsChanged = currentLocationsCount != lastLocationsCount
        let currentLensId = locationManager.selectedARLens
        // Only update lens if the ID actually changed (not just video format object comparison)
        // Use coordinator's persistent property instead of @State which wasn't working
        let needsLensUpdate = currentLensId != context.coordinator.lastAppliedLensId
        let hasCriticalUpdate = locationsChanged || needsLensUpdate || uiView.session.configuration == nil
        
        // Only proceed if we should update OR if there's a critical update
        guard shouldUpdate || hasCriticalUpdate else {
            return // Skip this update to prevent excessive calls
        }
        
        lastUpdateTime = now
        
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
                print("📷 Updating AR lens to: \(selectedLensId)")
            }

            let options: ARSession.RunOptions = needsLensUpdate ? [.resetTracking] : [.resetTracking]
            uiView.session.run(config, options: options)

            // Remember the lens we just applied to prevent redundant updates
            context.coordinator.lastAppliedLensId = currentLensId
        }
        
        // Check if locations have changed (new object added)
        if locationsChanged {
            lastLocationsCount = currentLocationsCount
            // PERFORMANCE: Logging disabled - runs frequently
        }

        // Update nearby locations when user location changes OR when locations change
        // Move expensive operations to background thread to prevent freezing
        if let userLocation = userLocationManager.currentLocation {
            // Update location manager with current location for API refresh timer (lightweight)
            locationManager.updateUserLocation(userLocation)

            // Defer state updates to avoid "Modifying state during view update" warning
            let coordinator = context.coordinator
            let shouldCheckPlacement = locationsChanged

            DispatchQueue.main.async {
                Task.detached(priority: .userInitiated) {
                    let nearby = locationManager.getNearbyLocations(userLocation: userLocation)

                    // Update UI on main thread
                    await MainActor.run {
                        nearbyLocations = nearby
                    }

                    // CRITICAL FIX: Only call checkAndPlaceBoxes when locations actually changed
                    // This prevents re-placement of already-placed objects on every frame
                    // Objects should be placed ONCE and stay fixed at their AR coordinates
                    if shouldCheckPlacement {
                        // PERFORMANCE: Logging disabled
                        coordinator.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
                    }
                }
            }
        }
        
        // Handle randomization trigger
        if locationManager.shouldRandomize {
            print("🎯 Randomize button pressed - triggering sphere placement...")
            // Defer the randomization to avoid view update publishing issues
            DispatchQueue.main.async {
                context.coordinator.randomizeLootBoxes()
                // Reset the flag after randomization is complete
                DispatchQueue.main.async {
                    locationManager.shouldRandomize = false
                    print("🔄 Randomize flag reset")
                }
            }
        }

        // Handle single sphere placement trigger
        if locationManager.shouldPlaceSphere {
            print("🎯 Single sphere placement triggered in ARLootBoxView...")
            // Get the location ID if one was provided (from map marker)
            let locationId = locationManager.pendingSphereLocationId
            // Defer the sphere placement to avoid view update publishing issues
            DispatchQueue.main.async {
                context.coordinator.placeSingleSphere(locationId: locationId)
                // Reset the flags after placement is complete
                DispatchQueue.main.async {
                    locationManager.shouldPlaceSphere = false
                    locationManager.pendingSphereLocationId = nil
                    print("🔄 Single sphere flag reset")
                }
            }
        }

        // Handle pending AR item placement
        if let pendingItem = locationManager.pendingARItem {
            print("🎯 Pending AR item placement triggered: \(pendingItem.name)")
            // Clear the pending item IMMEDIATELY to prevent duplicate placements
            // This prevents updateUIView from calling placeARItem multiple times
            locationManager.pendingARItem = nil
            print("🔄 Pending AR item cleared immediately to prevent duplicates")
            // Defer the actual placement to avoid view update publishing issues
            DispatchQueue.main.async {
                context.coordinator.placeARItem(pendingItem)
            }
        }
        
        // Handle AR object reset trigger (when locations are reset)
        if locationManager.shouldResetARObjects {
            print("🔄 Reset AR objects triggered - removing all placed objects...")
            // Clear the flag IMMEDIATELY to prevent duplicate resets
            locationManager.shouldResetARObjects = false
            // Defer the reset to avoid view update publishing issues
            DispatchQueue.main.async {
                context.coordinator.removeAllPlacedObjects()
                // Update nearby locations binding so UI reflects reset state
                // Re-placement will happen automatically on next AR frame update when tracking is ready
                if let userLocation = userLocationManager.currentLocation {
                    let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
                    DispatchQueue.main.async {
                        nearbyLocations = nearby
                        // Note: Re-placement will be triggered by session(_:didUpdate:) when AR tracking is ready
                        // The shouldForceReplacement flag in ARCoordinator ensures objects are re-placed
                    }
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

