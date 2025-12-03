import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import Combine

// MARK: - NPC Service
class ARNPCService: NSObject {
    weak var arView: ARView?
    private var locationManager: LootBoxLocationManager?
    private var userLocationManager: UserLocationManager?
    private var conversationManager: ARConversationManager?
    private var treasureHuntService: TreasureHuntService?
    
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
    private var skeletonAnchor: AnchorEntity? // Reference to skeleton anchor
    private let SKELETON_NPC_ID = "skeleton-1" // ID for the skeleton NPC
    
    // MARK: - Skeleton Size Constants
    private static let SKELETON_SCALE: Float = 1.4 // Results in approximately 6.5 feet tall skeleton
    private static let SKELETON_COLLISION_SIZE = SIMD3<Float>(0.66, 2.0, 0.66) // Scaled proportionally for 6-7ft skeleton
    private static let SKELETON_HEIGHT_OFFSET: Float = 1.65 // Scaled proportionally
    private var hasTalkedToSkeleton: Bool = false // Track if player has talked to skeleton
    private var collectedMapPieces: Set<Int> = [] // Track which map pieces player has collected
    
    func setup(locationManager: LootBoxLocationManager, 
              userLocationManager: UserLocationManager, 
              conversationManager: ARConversationManager, 
              treasureHuntService: TreasureHuntService, 
              arView: ARView) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.conversationManager = conversationManager
        self.treasureHuntService = treasureHuntService
        self.arView = arView
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
}

