import SwiftUI
import RealityKit
import ARKit
import UIKit

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

// MARK: - NPC Size Constants
struct ARNPCConstants {
    // Target: 6-7 feet tall (1.83-2.13m) in AR space
    // Assuming base model is ~1.4m at scale 1.0, scale of 1.4 gives ~1.96m (6.4 feet)
    static let SKELETON_SCALE: Float = 1.4 // Results in approximately 6.5 feet tall skeleton
    static let SKELETON_COLLISION_SIZE = SIMD3<Float>(0.66, 2.0, 0.66) // Scaled proportionally for 6-7ft skeleton
    static let SKELETON_HEIGHT_OFFSET: Float = 1.65 // Scaled proportionally
    static let SKELETON_NPC_ID = "skeleton-1" // ID for the skeleton NPC
}

/// Service for managing NPC placement and interactions in AR
class ARNPCService {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var groundingService: ARGroundingService?
    weak var tapHandler: ARTapHandler?
    weak var conversationManager: ARConversationManager?
    
    var placedNPCs: [String: AnchorEntity] = [:]
    var skeletonPlaced: Bool = false
    var corgiPlaced: Bool = false
    var skeletonAnchor: AnchorEntity?
    var hasTalkedToSkeleton: Bool = false
    var collectedMapPieces: Set<Int> = []
    
    var conversationNPCBinding: Binding<ConversationNPC?>?
    var collectionNotificationBinding: Binding<String?>?
    
    init(arView: ARView?,
         locationManager: LootBoxLocationManager?,
         groundingService: ARGroundingService?,
         tapHandler: ARTapHandler?,
         conversationManager: ARConversationManager?) {
        self.arView = arView
        self.locationManager = locationManager
        self.groundingService = groundingService
        self.tapHandler = tapHandler
        self.conversationManager = conversationManager
    }
    
    /// Place an NPC in the AR scene
    func placeNPC(type: NPCType, in arView: ARView) {
        // Check if already placed
        if placedNPCs[type.npcId] != nil {
            Swift.print("💬 \(type.defaultName) already placed, skipping")
            return
        }
        
        guard let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Cannot place \(type.defaultName): AR frame not available")
            return
        }
        
        Swift.print("💬 Placing \(type.defaultName) NPC for story mode...")
        Swift.print("   Game mode: \(locationManager?.gameMode.displayName ?? "unknown")")
        Swift.print("   Model: \(type.modelName).usdz")
        
        // Load the NPC model
        guard let modelURL = Bundle.main.url(forResource: type.modelName, withExtension: "usdz") else {
            Swift.print("❌ Could not find \(type.modelName).usdz in bundle")
            Swift.print("   Make sure \(type.modelName).usdz is added to the Xcode project")
            Swift.print("   Bundle path: \(Bundle.main.bundlePath)")
            return
        }
        
        Swift.print("✅ Found model at: \(modelURL.path)")
        
        do {
            // Load the NPC model
            let loadedEntity = try Entity.loadModel(contentsOf: modelURL)
            
            // Wrap in ModelEntity for proper scaling
            let npcEntity = ModelEntity()
            npcEntity.addChild(loadedEntity)
            
            // Scale NPC to reasonable size
            let npcScale: Float = type == .skeleton ? ARNPCConstants.SKELETON_SCALE : 0.5
            npcEntity.scale = SIMD3<Float>(repeating: npcScale)
            
            // Position NPC in front of camera
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            let forward = SIMD3<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.y, -cameraTransform.columns.2.z)
            
            // Place NPCs at different distances to avoid overlap
            // Skeleton: 5.5m (more distant), Corgi: 4.5m (to the side)
            let baseDistance: Float = type == .skeleton ? 5.5 : 4.5
            let sideOffset: Float = type == .corgi ? 1.5 : 0.0 // Place corgi to the side
            let right = SIMD3<Float>(-cameraTransform.columns.0.x, -cameraTransform.columns.0.y, -cameraTransform.columns.0.z)
            let targetPosition = cameraPos + forward * baseDistance + right * sideOffset
            
            // Use grounding service to properly ground the NPC on surfaces
            let npcPosition: SIMD3<Float>
            if let groundingService = groundingService {
                npcPosition = groundingService.groundPosition(targetPosition, cameraPos: cameraPos)
                Swift.print("✅ \(type.defaultName) grounded using ARGroundingService at Y: \(String(format: "%.2f", npcPosition.y))")
            } else {
                // Fallback: use simple raycast if grounding service not available
                let raycastQuery = ARRaycastQuery(
                    origin: SIMD3<Float>(targetPosition.x, cameraPos.y, targetPosition.z),
                    direction: SIMD3<Float>(0, -1, 0),
                    allowing: .estimatedPlane,
                    alignment: .horizontal
                )
                
                let raycastResults = arView.session.raycast(raycastQuery)
                
                if let firstResult = raycastResults.first {
                    npcPosition = SIMD3<Float>(
                        firstResult.worldTransform.columns.3.x,
                        firstResult.worldTransform.columns.3.y,
                        firstResult.worldTransform.columns.3.z
                    )
                } else {
                    // Final fallback: use camera Y position (assume ground level)
                    npcPosition = SIMD3<Float>(
                        targetPosition.x,
                        cameraPos.y - (type == .skeleton ? ARNPCConstants.SKELETON_HEIGHT_OFFSET : 1.2),
                        targetPosition.z
                    )
                    Swift.print("⚠️ \(type.defaultName) using fallback ground height: Y=\(String(format: "%.2f", npcPosition.y))")
                }
            }
            
            // Create anchor for NPC
            let anchor = AnchorEntity(world: npcPosition)
            anchor.name = type.npcId
            npcEntity.name = type.npcId // Make it tappable

            // Add collision component for tap detection
            let collisionSize: SIMD3<Float> = type == .skeleton
                ? ARNPCConstants.SKELETON_COLLISION_SIZE
                : SIMD3<Float>(0.8, 0.6, 0.8) // Corgi: short and wide
            let collisionShape = ShapeResource.generateBox(size: collisionSize)
            npcEntity.collision = CollisionComponent(shapes: [collisionShape])
            
            // Enable input handling so the entity can be tapped
            npcEntity.components.set(InputTargetComponent())

            // Make NPC face the camera while keeping it upright
            let cameraDirection = normalize(cameraPos - npcPosition)
            let horizontalDirection = normalize(SIMD3<Float>(cameraDirection.x, 0, cameraDirection.z))
            let modelForward = SIMD3<Float>(0, 0, -1)
            var angle = atan2(horizontalDirection.x, horizontalDirection.z) - atan2(modelForward.x, modelForward.z)
            
            // Fix skeleton rotation: add 180° (π radians) to face the correct direction
            if type == .skeleton {
                angle += Float.pi
            }
            
            // Create rotation quaternion around Y-axis only (keeps model upright)
            let yAxis = SIMD3<Float>(0, 1, 0)
            let rotation = simd_quatf(angle: angle, axis: yAxis)
            npcEntity.orientation = rotation
            
            anchor.addChild(npcEntity)
            arView.scene.addAnchor(anchor)
            
            // Track NPC
            placedNPCs[type.npcId] = anchor
            tapHandler?.placedNPCs = placedNPCs
            
            if type == .skeleton {
                skeletonAnchor = anchor
                skeletonPlaced = true
            } else if type == .corgi {
                corgiPlaced = true
            }
            
            Swift.print("✅ \(type.defaultName) NPC placed at position: \(npcPosition)")
            Swift.print("   \(type.defaultName) is tappable and ready for interaction")
            
        } catch {
            Swift.print("❌ Error loading \(type.defaultName) model: \(error)")
        }
    }
    
    /// Handle tap on any NPC - opens conversation
    func handleNPCTap(type: NPCType) {
        Swift.print("💬 ========== handleNPCTap CALLED ==========")
        Swift.print("   NPC Type: \(type.rawValue)")
        Swift.print("   NPC Name: \(type.defaultName)")
        Swift.print("   NPC ID: \(type.npcId)")

        DispatchQueue.main.async { [weak self] in
            Swift.print("   📞 Calling showNPCConversation on main thread")
            self?.showNPCConversation(type: type)
        }
    }
    
    /// Show NPC conversation UI
    func showNPCConversation(type: NPCType) {
        Swift.print("   ========== showNPCConversation CALLED ==========")
        Swift.print("   NPC: \(type.defaultName)")

        guard let locationManager = locationManager else {
            Swift.print("   ❌ ERROR: locationManager is nil!")
            return
        }

        Swift.print("   Current game mode: \(locationManager.gameMode.rawValue)")

        // For skeleton, always open the conversation view
        if type == .skeleton {
            Swift.print("   📱 Opening SkeletonConversationView (full-screen dialog)")
            DispatchQueue.main.async { [weak self] in
                self?.conversationNPCBinding?.wrappedValue = ConversationNPC(
                    id: type.npcId,
                    name: type.defaultName
                )
                Swift.print("   ✅ ConversationNPC binding set")
            }
        }

        // Handle different game modes
        Swift.print("   🎮 Checking game mode for AR sign...")
        switch locationManager.gameMode {
        case .open:
            Swift.print("   ℹ️ Open mode - no AR sign in this mode")
            break

        case .deadMensSecrets:
            Swift.print("   🎯 Dead Men's Secrets mode - checking AR sign conditions...")
            if type == .skeleton, let arView = arView, let skeletonEntity = placedNPCs[type.npcId] {
                Swift.print("   🎬 TRIGGERING AR SIGN: showSkeletonTextInput")
                showSkeletonTextInput(for: skeletonEntity, in: arView, npcId: type.npcId, npcName: type.defaultName)
            } else {
                Swift.print("   ❌ AR sign NOT triggered - conditions not met")
            }
            
        case .splitLegacy:
            // Split Legacy: Each NPC gives half the map
            if type == .skeleton {
                if !collectedMapPieces.contains(1) {
                    collectionNotificationBinding?.wrappedValue = "💀 Captain Bones: I have the first half of the map! The Corgi Traveller has the other half. Find them near the old oak tree!"
                    collectedMapPieces.insert(1)
                    
                    // Spawn corgi after getting first map piece
                    if !corgiPlaced, let arView = arView {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.placeNPC(type: .corgi, in: arView)
                        }
                    }
                } else {
                    collectionNotificationBinding?.wrappedValue = "💀 Captain Bones: Ye already have me half of the map, matey! Find the Corgi for the other half!"
                }
            } else if type == .corgi {
                if !collectedMapPieces.contains(2) {
                    collectionNotificationBinding?.wrappedValue = "🐕 Corgi Traveller: Woof! Here's the second half of the map! Combine both halves to find the treasure!"
                    collectedMapPieces.insert(2)
                    
                    // If player has both pieces, combine them
                    if collectedMapPieces.contains(1) && collectedMapPieces.contains(2) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.combineMapPieces()
                        }
                    }
                } else {
                    collectionNotificationBinding?.wrappedValue = "🐕 Corgi Traveller: You already have my half! Combine both pieces to see where X marks the spot!"
                }
            }
            
            // Hide notification after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.collectionNotificationBinding?.wrappedValue = nil
            }
        }
    }
    
    /// Combine map pieces to reveal treasure location (Split Legacy mode)
    func combineMapPieces() {
        Swift.print("🗺️ Combining map pieces - revealing treasure location!")
        
        collectionNotificationBinding?.wrappedValue = "🗺️ Map Combined! The treasure location has been revealed on the map!"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.collectionNotificationBinding?.wrappedValue = nil
        }
        
        Swift.print("💡 Map pieces combined - treasure location should be revealed")
    }
    
    /// Show text input prompt for skeleton conversation (Dead Men's Secrets mode)
    func showSkeletonTextInput(for skeletonEntity: AnchorEntity, in arView: ARView, npcId: String, npcName: String) {
        Swift.print("   ========== showSkeletonTextInput CALLED ==========")
        Swift.print("   NPC ID: \(npcId)")
        Swift.print("   NPC Name: \(npcName)")
        Swift.print("   Skeleton Entity: \(skeletonEntity.name)")

        DispatchQueue.main.async {
            Swift.print("   📝 Creating UIAlertController for text input...")
            let alert = UIAlertController(title: "💀 Talk to \(npcName)", message: "Ask the skeleton about the treasure...", preferredStyle: .alert)
            
            alert.addTextField { textField in
                textField.placeholder = "Ask about the treasure..."
                textField.autocapitalizationType = .sentences
            }
            
            alert.addAction(UIAlertAction(title: "Ask", style: .default) { [weak self] _ in
                guard let self = self,
                      let textField = alert.textFields?.first,
                      let message = textField.text,
                      !message.isEmpty else {
                    return
                }

                self.conversationManager?.showMessage(
                    npcName: npcName,
                    message: message,
                    isUserMessage: true,
                    duration: 2.0
                )
                
                Task {
                    do {
                        let response = try await APIService.shared.interactWithNPC(
                            npcId: npcId,
                            message: message,
                            npcName: npcName,
                            npcType: "skeleton",
                            isSkeleton: true
                        )
                        
                        await MainActor.run {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                                self?.conversationManager?.showMessage(
                                    npcName: npcName,
                                    message: response.response,
                                    isUserMessage: false,
                                    duration: 10.0
                                )
                            }
                        }
                    } catch {
                        await MainActor.run { [weak self] in
                            let errorMessage: String
                            if let apiError = error as? APIError {
                                switch apiError {
                                case .serverError(let message):
                                    if message.contains("LLM service not available") || message.contains("not available") {
                                        errorMessage = "Arr, the treasure map service be down! The server needs the LLM service running. Check the server logs, matey!"
                                    } else {
                                        errorMessage = message
                                    }
                                case .serverUnreachable:
                                    errorMessage = "Arr, I can't reach the server! Make sure it's running and we're on the same network, matey!"
                                case .httpError(let code):
                                    if code == 503 {
                                        errorMessage = "The treasure map service be unavailable! Check if the LLM service is running on the server."
                                    } else {
                                        errorMessage = "Server error \(code). Check the server, matey!"
                                    }
                                default:
                                    errorMessage = apiError.localizedDescription
                                }
                            } else {
                                let errorDesc = error.localizedDescription
                                if errorDesc.contains("not available") || errorDesc.contains("unreachable") {
                                    errorMessage = "Arr, I can't reach the server! Make sure it's running, matey!"
                                } else {
                                    errorMessage = errorDesc
                                }
                            }

                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                self?.conversationManager?.showMessage(
                                    npcName: npcName,
                                    message: errorMessage,
                                    isUserMessage: false,
                                    duration: 8.0
                                )
                            }
                        }
                    }
                }
            })
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
            Swift.print("   🎭 Attempting to present UIAlertController...")
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                Swift.print("   ✅ Found root view controller")

                if let presentedVC = rootViewController.presentedViewController {
                    Swift.print("   ⚠️ Found existing presented view controller: \(type(of: presentedVC))")
                    Swift.print("   Dismissing it first...")
                    presentedVC.dismiss(animated: false) {
                        Swift.print("   ✅ Existing alert dismissed, presenting new alert")
                        rootViewController.present(alert, animated: true)
                        Swift.print("   ✅ Alert presented successfully")
                    }
                } else {
                    Swift.print("   ✅ No existing alerts, presenting directly")
                    rootViewController.present(alert, animated: true)
                    Swift.print("   ✅ Alert presented successfully")
                }
            } else {
                Swift.print("   ❌ ERROR: Could not find root view controller!")
            }
        }
    }
}

