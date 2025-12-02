import RealityKit
import ARKit
import CoreLocation

// Import NPCType since it's now in its own file
import Foundation // NPCType needs Foundation

// MARK: - AR NPC Manager
class ARNPCManager {

    private weak var arCoordinator: ARCoordinatorCore?
    private var uiManager: ARUIManager?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore, uiManager: ARUIManager) {
        self.arCoordinator = arCoordinator
        self.uiManager = uiManager
    }

    // MARK: - NPC Placement

    /// Place an NPC in AR for story mode
    func placeNPC(type: NPCType, in arView: ARView) {
        // Check if already placed
        if let existingAnchor = arCoordinator?.placedNPCs[type.npcId] {
            if arView.scene.anchors.contains(where: { ($0 as? AnchorEntity) === existingAnchor }) {
                Swift.print("💬 \(type.defaultName) already placed and in scene, skipping")
                return
            } else {
                // Clean up removed anchor
                removeNPC(type: type)
            }
        }

        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place \(type.defaultName): AR frame not available")
            return
        }

        Swift.print("💬 Placing \(type.defaultName) NPC for story mode...")

        // Load and place the NPC model
        loadAndPlaceNPCModel(type: type, in: arView, frame: frame)
    }

    private func loadAndPlaceNPCModel(type: NPCType, in arView: ARView, frame: ARFrame) {
        guard let modelURL = Bundle.main.url(forResource: type.modelName, withExtension: "usdz") else {
            Swift.print("❌ Could not find \(type.modelName).usdz in bundle")
            return
        }

        Swift.print("✅ Found model at: \(modelURL.path)")

        do {
            // Load the NPC model
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)

            // Wrap in ModelEntity for proper scaling
            let npcEntity = ModelEntity()
            npcEntity.addChild(loadedEntity)

            // Scale NPC appropriately
            let npcScale: Float = type == .skeleton ? ARCoordinatorCore.SKELETON_SCALE : 0.5
            npcEntity.scale = SIMD3<Float>(repeating: npcScale)

            // Calculate placement position
            let placementPosition = calculateNPCPlacementPosition(type: type, frame: frame)

            // Create anchor and add to scene
            let npcAnchor = AnchorEntity(world: placementPosition)
            npcAnchor.name = type.npcId
            npcAnchor.addChild(npcEntity)

            arView.scene.addAnchor(npcAnchor)

            // Track the NPC
            arCoordinator?.placedNPCs[type.npcId] = npcAnchor
            updateNPCPlacementState(type: type, placed: true)

            Swift.print("✅ Placed \(type.defaultName) at position: (\(String(format: "%.2f", placementPosition.x)), \(String(format: "%.2f", placementPosition.y)), \(String(format: "%.2f", placementPosition.z)))")

        } catch {
            Swift.print("❌ Failed to load NPC model: \(error)")
        }
    }

    private func calculateNPCPlacementPosition(type: NPCType, frame: ARFrame) -> SIMD3<Float> {
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
        let right = SIMD3<Float>(-cameraTransform.columns.0.x, -cameraTransform.columns.0.y, -cameraTransform.columns.0.z)

        // Place NPCs at different distances to avoid overlap
        let baseDistance: Float = type == .skeleton ? 5.5 : 4.5
        let sideOffset: Float = type == .corgi ? 1.5 : 0.0
        let targetPosition = cameraPos + forward * baseDistance + right * sideOffset

        // Ground the position
        if let groundingService = arCoordinator?.groundingService {
            let groundedPosition = groundingService.groundPosition(targetPosition, cameraPos: cameraPos)
            Swift.print("✅ \(type.defaultName) grounded using ARGroundingService")
            return groundedPosition
        } else {
            // Fallback: simple raycast
            return targetPosition
        }
    }

    private func updateNPCPlacementState(type: NPCType, placed: Bool) {
        switch type {
        case .skeleton:
            arCoordinator?.skeletonPlaced = placed
        case .corgi:
            arCoordinator?.corgiPlaced = placed
        }
    }

    /// Remove an NPC from the scene
    func removeNPC(type: NPCType) {
        guard let npcAnchor = arCoordinator?.placedNPCs[type.npcId] else { return }

        arCoordinator?.arView?.scene.removeAnchor(npcAnchor)
        arCoordinator?.placedNPCs.removeValue(forKey: type.npcId)
        updateNPCPlacementState(type: type, placed: false)

        Swift.print("🗑️ Removed \(type.defaultName) NPC")
    }

    /// Remove all NPCs
    func removeAllNPCs() {
        for (npcId, npcAnchor) in arCoordinator?.placedNPCs ?? [:] {
            arCoordinator?.arView?.scene.removeAnchor(npcAnchor)
        }
        arCoordinator?.placedNPCs.removeAll()
        arCoordinator?.skeletonPlaced = false
        arCoordinator?.corgiPlaced = false
        arCoordinator?.skeletonAnchor = nil
    }

    // MARK: - NPC Interaction

    /// Handle NPC tap interaction
    func handleNPCTap(npcId: String, in arView: ARView) {
        guard let npcType = getNPCType(for: npcId) else {
            Swift.print("⚠️ Unknown NPC ID: \(npcId)")
            return
        }

        switch npcType {
        case .skeleton:
            handleSkeletonInteraction(in: arView, npcId: npcId)
        case .corgi:
            handleCorgiInteraction(in: arView, npcId: npcId)
        }
    }

    private func getNPCType(for npcId: String) -> NPCType? {
        if npcId == NPCType.skeleton.npcId {
            return NPCType.skeleton
        } else if npcId == NPCType.corgi.npcId {
            return NPCType.corgi
        }
        return nil
    }

    private func handleSkeletonInteraction(in arView: ARView, npcId: String) {
        guard let skeletonAnchor = arCoordinator?.placedNPCs[npcId] else { return }

        // Always allow interaction with Captain Bones for treasure hunt gameplay
        // The player should be able to ask for treasure maps multiple times
        uiManager?.showSkeletonTextInput(for: skeletonAnchor, in: arView, npcId: npcId, npcName: "Captain Bones",
                                       treasureHuntService: arCoordinator?.treasureHuntService,
                                       userLocationManager: arCoordinator?.userLocationManager)

        // Mark as talked to (for other game logic if needed)
        arCoordinator?.hasTalkedToSkeleton = true
    }

    private func handleCorgiInteraction(in arView: ARView, npcId: String) {
        // Corgi interaction - show server unavailable for now
        uiManager?.showServerUnavailableAlert(for: NPCType.corgi)
    }

    // MARK: - Map Piece Management

    /// Award a map piece to the player
    func awardMapPiece(pieceNumber: Int, from npcType: NPCType) {
        guard var collectedPieces = arCoordinator?.collectedMapPieces else { return }

        if !collectedPieces.contains(pieceNumber) {
            collectedPieces.insert(pieceNumber)

            Swift.print("🗺️ Player collected map piece #\(pieceNumber) from \(npcType.defaultName)")

            // Check if all pieces are collected
            if collectedPieces.count >= 2 { // Assuming 2 pieces total
                uiManager?.combineMapPieces()
            }

            arCoordinator?.collectedMapPieces = collectedPieces
        }
    }

    /// Check if player has collected a specific map piece
    func hasMapPiece(_ pieceNumber: Int) -> Bool {
        return arCoordinator?.collectedMapPieces.contains(pieceNumber) ?? false
    }

    /// Get the count of collected map pieces
    var collectedMapPieceCount: Int {
        return arCoordinator?.collectedMapPieces.count ?? 0
    }

    // MARK: - NPC State Queries

    /// Check if a specific NPC type is placed
    func isNPCPlaced(_ type: NPCType) -> Bool {
        return arCoordinator?.placedNPCs[type.npcId] != nil
    }

    /// Get all placed NPCs
    var placedNPCs: [String: AnchorEntity] {
        return arCoordinator?.placedNPCs ?? [:]
    }

    /// Check if treasure X has been placed
    var isTreasureXPlaced: Bool {
        return arCoordinator?.treasureXPlaced ?? false
    }

    /// Set treasure X placement state
    func setTreasureXPlaced(_ placed: Bool) {
        arCoordinator?.treasureXPlaced = placed
    }

    // MARK: - NPC Sync and State Management

    /// Sync NPC state with server
    func syncNPCState() {
        // This would sync NPC states with the server
        // For now, just log the current state
        Swift.print("🔄 Syncing NPC state...")
        Swift.print("   Skeleton placed: \(isNPCPlaced(.skeleton))")
        Swift.print("   Corgi placed: \(isNPCPlaced(.corgi))")
        Swift.print("   Treasure X placed: \(isTreasureXPlaced)")
        Swift.print("   Map pieces collected: \(collectedMapPieceCount)")
    }

    /// Handle NPC placement from server data
    func handleNPCPlacement(from serverData: [String: Any]) {
        guard let npcTypeString = serverData["npc_type"] as? String,
              let npcType = NPCType(rawValue: npcTypeString) else { return }

        // Check if we should force placement
        if arCoordinator?.shouldForceReplacement == true {
            Swift.print("🔄 Force replacing \(npcType.defaultName) after AR reset")
            placeNPC(type: npcType, in: arCoordinator?.arView ?? ARView())
            arCoordinator?.shouldForceReplacement = false
        }
    }

    /// Update NPC conversation bindings
    func updateConversationBindings() {
        // Find the active NPC for conversation
        var activeNPC: ConversationNPC? = nil

        if let skeletonAnchor = arCoordinator?.placedNPCs[NPCType.skeleton.npcId] {
            activeNPC = ConversationNPC(
                id: NPCType.skeleton.npcId,
                name: NPCType.skeleton.defaultName
            )
        } else if let corgiAnchor = arCoordinator?.placedNPCs[NPCType.corgi.npcId] {
            activeNPC = ConversationNPC(
                id: NPCType.corgi.npcId,
                name: NPCType.corgi.defaultName
            )
        }

        uiManager?.updateConversationNPC(activeNPC)
    }
}
