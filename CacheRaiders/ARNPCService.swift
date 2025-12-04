import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - NPC Service
class ARNPCService: NSObject, ARNPCServiceProtocol {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var conversationManager: ARConversationManager?
    private var treasureHuntService: TreasureHuntService?
    
    private var placedNPCs: [String: AnchorEntity] = [:] // Track all placed NPCs by ID
    private var skeletonPlaced: Bool = false // Track if skeleton has been placed
    private var corgiPlaced: Bool = false // Track if corgi has been placed
    private var skeletonAnchor: AnchorEntity? // Reference to skeleton anchor
    private let SKELETON_NPC_ID = "skeleton-1" // ID for the skeleton NPC
    
    // MARK: - Skeleton Size Constants
    private static let SKELETON_SCALE: Float = 1.4 // Results in approximately 6.5 feet tall skeleton
    private static let SKELETON_COLLISION_SIZE = SIMD3<Float>(0.66, 2.0, 0.66) // Scaled proportionally for 6-7ft skeleton
    private static let SKELETON_HEIGHT_OFFSET: Float = 1.65 // Scaled proportionally
    private var hasTalkedToSkeleton: Bool = false // Track if player has talked to skeleton
    private var collectedMapPieces: Set<Int> = [] // Track which map pieces player has collected
    
    init(arView: ARView,
         locationManager: LootBoxLocationManager,
         groundingService: ARGroundingService,
         tapHandler: ARTapHandler,
         conversationNPCBinding: Binding<ConversationNPC?>?) {
        self.arView = arView
        self.locationManager = locationManager
        super.init()
    }
    
    // NPC placement and interaction methods will be moved here from ARCoordinator
    func checkAndPlaceNPCs(userLocation: CLLocation) {
        // Implementation to be moved from ARCoordinator
    }
    
    func placeSkeletonNPC() {
        // Implementation to be moved from ARCoordinator
    }
    
    func placeCorgiNPC() {
        // Implementation to be moved from ARCoordinator
    }
    
    func handleNPCInteraction(npcId: String, npcType: NPCType) {
        // Implementation to be moved from ARCoordinator
    }
    
    func removeAllNPCs() {
        // Implementation to be moved from ARCoordinator
    }

    // MARK: - ARNPCServiceProtocol Methods
    
    func configure(with coordinator: ARCoordinatorCoreProtocol) {
        // Implementation not needed for this service
    }
    
    func cleanup() {
        // Implementation not needed for this service
    }
    
    func placeNPC(_ npcType: NPCType, at location: CLLocation?) {
        // Implementation to be added from ARCoordinator
    }
    
    func handleNPCInteraction(_ npcId: String) {
        // Implementation to be added from ARCoordinator
    }
    
    func syncNPCsWithServer() {
        // Implementation to be added from ARCoordinator
    }
}

