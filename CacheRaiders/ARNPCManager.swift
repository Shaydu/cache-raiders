import RealityKit
import ARKit
import CoreLocation

// Import NPCType since it's now in its own file
import Foundation // NPCType needs Foundation

// MARK: - AR NPC Manager
class ARNPCManager {

    private weak var arCoordinator: ARCoordinatorCore?
    private var uiManager: ARUIManager?
    private var npcService: ARNPCService?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore, uiManager: ARUIManager, npcService: ARNPCService) {
        self.arCoordinator = arCoordinator
        self.uiManager = uiManager
        self.npcService = npcService
    }

    // MARK: - NPC Placement

    /// Place an NPC in AR for story mode
    func placeNPC(type: NPCType, in arView: ARView) {
        npcService?.placeNPC(type, at: nil)
    }

    /// Remove an NPC from the scene
    func removeNPC(type: NPCType) {
        npcService?.removeAllNPCs()
    }

    /// Remove all NPCs
    func removeAllNPCs() {
        npcService?.removeAllNPCs()
    }

    // MARK: - NPC Interaction

    /// Handle NPC tap interaction
    func handleNPCTap(npcId: String, in arView: ARView) {
        npcService?.handleNPCInteraction(npcId)
    }

    private func getNPCType(for npcId: String) -> NPCType? {
        if npcId == NPCType.skeleton.npcId {
            return NPCType.skeleton
        } else if npcId == NPCType.corgi.npcId {
            return NPCType.corgi
        }
        return nil
    }

    // MARK: - NPC State Queries

    /// Check if a specific NPC type is placed
    func isNPCPlaced(_ type: NPCType) -> Bool {
        return arCoordinator?.state.placedNPCs[type.npcId] != nil
    }

    /// Get all placed NPCs
    var placedNPCs: [String: AnchorEntity] {
        return arCoordinator?.state.placedNPCs ?? [:]
    }

    /// Check if skeleton is placed
    var isSkeletonPlaced: Bool {
        return arCoordinator?.state.skeletonPlaced ?? false
    }

    /// Check if corgi is placed
    var isCorgiPlaced: Bool {
        return arCoordinator?.state.corgiPlaced ?? false
    }

    // MARK: - NPC Sync and State Management

    /// Sync NPC state with server
    func syncNPCState() {
        npcService?.syncNPCsWithServer()
    }

    /// Handle NPC placement from server data
    func handleNPCPlacement(from serverData: [String: Any]) {
        // This method is no longer needed as NPC placement is handled by the service
        // Server data handling should be implemented in the service if needed
    }

    /// Update NPC conversation bindings
    func updateConversationBindings() {
        // Delegate to service or UI manager
        uiManager?.updateConversationNPC(nil) // Pass appropriate NPC data
    }
}
