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
    @State private var arView: ARView?
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // AR session configuration
        let config = ARWorldTrackingConfiguration()
        // Detect both horizontal (ground) and vertical (walls) planes
        // Vertical planes are used for occlusion (hiding loot boxes behind walls)
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
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
        
        context.coordinator.setupARView(arView, locationManager: locationManager, userLocationManager: userLocationManager, nearbyLocations: $nearbyLocations, distanceToNearest: $distanceToNearest, temperatureStatus: $temperatureStatus, collectionNotification: $collectionNotification)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Ensure AR session is running
        if uiView.session.configuration == nil {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical] // Horizontal for ground, vertical for walls (occlusion)
            config.environmentTexturing = .automatic
            uiView.session.run(config, options: [.resetTracking])
        }
        
        // Update nearby locations when user location changes
        if let userLocation = userLocationManager.currentLocation {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            DispatchQueue.main.async {
                nearbyLocations = nearby
            }
            context.coordinator.checkAndPlaceBoxes(userLocation: userLocation, nearbyLocations: nearby)
        }
        
        // Handle randomization trigger
        if locationManager.shouldRandomize {
            print("🎯 Randomize button pressed - triggering sphere placement...")
            context.coordinator.randomizeLootBoxes()
            DispatchQueue.main.async {
                locationManager.shouldRandomize = false
                print("🔄 Randomize flag reset")
            }
        }
    }
    
    func makeCoordinator() -> ARCoordinator {
        ARCoordinator()
    }
}

