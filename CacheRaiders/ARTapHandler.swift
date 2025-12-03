import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - Tap Handler Service
class ARTapHandler: NSObject {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var objectPlacementService: ARObjectPlacementService?
    private var npcService: ARNPCService?
    private var conversationManager: ARConversationManager?
    
    // Performance tracking
    private var lastTapTime: Date?
    private let tapCooldown: TimeInterval = 0.3
    
    func setup(locationManager: LootBoxLocationManager,
              userLocationManager: UserLocationManager,
              objectPlacementService: ARObjectPlacementService,
              npcService: ARNPCService,
              conversationManager: ARConversationManager,
              arView: ARView) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.objectPlacementService = objectPlacementService
        self.npcService = npcService
        self.conversationManager = conversationManager
        self.arView = arView
    }
    
    // Tap gesture handling methods will be moved here from ARCoordinator
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        // Implementation to be moved from ARCoordinator
    }
    
    private func handleObjectTap(hitEntity: Entity, location: CGPoint) {
        // Implementation to be moved from ARCoordinator
    }
    
    private func handleNPCInteraction(hitEntity: Entity) {
        // Implementation to be moved from ARCoordinator
    }
    
    private func handleBackgroundTap(location: CGPoint) {
        // Implementation to be moved from ARCoordinator
    }
    
    // Utility methods for tap handling
    private func isTapOnCooldown() -> Bool {
        // Implementation to be moved from ARCoordinator
        return false
    }
    
    // MARK: - Manual Placement Methods
    
    /// Place a single random sphere for testing
    func placeSingleSphere(locationId: String? = nil) {
        Swift.print("🎯 ARTapHandler.placeSingleSphere() called with locationId: \(locationId ?? "nil")")
        // This should delegate to the object placement service
        objectPlacementService?.placeSingleSphere(locationId: locationId)
    }
    
    /// Place a specific AR item
    func placeARItem(_ item: LootBoxLocation) {
        Swift.print("🎯 ARTapHandler.placeARItem() called for: \(item.name) (ID: \(item.id))")
        // This should delegate to the object placement service
        objectPlacementService?.placeARItem(item)
    }
}

