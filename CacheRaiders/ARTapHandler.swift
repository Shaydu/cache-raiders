import Foundation
import SwiftUI
import RealityKit
import ARKit
import UIKit
import CoreLocation

// MARK: - AR Origin Provider Protocol
protocol AROriginProvider {
    var arOriginLocation: CLLocation? { get }
}

// MARK: - AR Tap Handler
/// Handles tap gesture detection and loot box finding
class ARTapHandler {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    weak var userLocationManager: UserLocationManager? // Add reference to user location manager
    weak var arCoordinator: ARCoordinator? // Add reference to AR coordinator
    var arOriginProvider: AROriginProvider? // Protocol for getting AR origin location

    var placedBoxes: [String: AnchorEntity] = [:]
    var findableObjects: [String: FindableObject] = [:]
    var foundLootBoxes: Set<String> = []
    var distanceTextEntities: [String: ModelEntity] = [:]
    var collectionNotificationBinding: Binding<String?>?
    var sphereModeActive: Bool = false

    // Callback for finding loot boxes
    var onFindLootBox: ((String, AnchorEntity, SIMD3<Float>, ModelEntity?, SIMD3<Float>?) -> Void)?


    // Callback for NPC taps (takes NPC ID string, ARCoordinator will convert to NPCType)
    var onNPCTap: ((String) -> Void)?

    // Callback for showing info panel for user's own objects
    var onShowObjectInfo: ((LootBoxLocation) -> Void)?

    // Callback for long press on objects - shows detailed information
    var onLongPressObject: ((String) -> Void)?

    // Reference to placed NPCs for tap detection
    var placedNPCs: [String: AnchorEntity] = [:] {
        didSet {
            Swift.print("🎯 ARTapHandler.placedNPCs updated: \(placedNPCs.count) NPCs - \(placedNPCs.keys.sorted())")
        }
    }

    init(arView: ARView?, locationManager: LootBoxLocationManager?, userLocationManager: UserLocationManager?, arCoordinator: ARCoordinator?, arOriginProvider: AROriginProvider?) {
        self.arView = arView
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.arCoordinator = arCoordinator
        self.arOriginProvider = arOriginProvider
    }
    
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        Swift.print("👆 ========== TAP DETECTED ==========")
        Swift.print("   Gesture recognizer state: \(sender.state.rawValue)")
        Swift.print("   ARView exists: \(arView != nil)")
        Swift.print("   LocationManager exists: \(locationManager != nil)")
        Swift.print("   Current frame exists: \(arView?.session.currentFrame != nil)")

        guard let arView = arView,
              let locationManager = locationManager,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Tap handler: Missing AR view, location manager, or frame")
            return
        }

        let tapLocation = sender.location(in: arView)
        Swift.print("   Tap location in ARView: \(tapLocation)")
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        Swift.print("   Screen location: (\(tapLocation.x), \(tapLocation.y))")
        Swift.print("   Placed boxes: \(placedBoxes.count) - \(placedBoxes.keys.sorted())")
        Swift.print("   Findable objects: \(findableObjects.count) - \(findableObjects.keys.sorted())")
        Swift.print("   Placed NPCs: \(placedNPCs.count) - \(placedNPCs.keys.sorted())")
        Swift.print("   Found loot boxes: \(foundLootBoxes.count) - \(Array(foundLootBoxes))")
        Swift.print("   onNPCTap callback exists: \(onNPCTap != nil)")
        Swift.print("   onFindLootBox callback exists: \(onFindLootBox != nil)")

        // Check if tapped on existing loot box
        // First try direct entity hit
        let tappedEntity: Entity? = arView.entity(at: tapLocation)

        // Get tap world position - prefer the actual tapped entity's position over raycast to plane
        var tapWorldPosition: SIMD3<Float>? = nil
        if let tappedEntity = tappedEntity {
            // Use the actual tapped entity's world position for precise confetti placement
            let entityTransform = tappedEntity.transformMatrix(relativeTo: nil)
            tapWorldPosition = SIMD3<Float>(
                entityTransform.columns.3.x,
                entityTransform.columns.3.y,
                entityTransform.columns.3.z
            )
            Swift.print("   👆 Tap world position (from entity): (\(String(format: "%.2f", tapWorldPosition!.x)), \(String(format: "%.2f", tapWorldPosition!.y)), \(String(format: "%.2f", tapWorldPosition!.z)))")
        } else if let raycastResult = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first {
            // Fallback to raycast if no entity was hit
            tapWorldPosition = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
            Swift.print("   👆 Tap world position (raycast fallback): (\(String(format: "%.2f", tapWorldPosition!.x)), \(String(format: "%.2f", tapWorldPosition!.y)), \(String(format: "%.2f", tapWorldPosition!.z)))")
        }
        var locationId: String? = nil

        Swift.print("🎯 Tap entity hit test result: \(tappedEntity != nil ? "hit entity" : "no entity hit")")

        // Walk up the entity hierarchy to find the location ID
        // Check the tapped entity and all its parents
        var entityToCheck = tappedEntity
        var checkedEntities = Set<String>() // Track checked entity names to prevent loops

        while let currentEntity = entityToCheck {
            let entityName = currentEntity.name
            Swift.print("🎯 Checking entity: '\(entityName)' (type: \(type(of: currentEntity)))")

            // Entity.name is a String, not String?, so check if it's not empty
            if !entityName.isEmpty {
                // Use entity name as unique identifier for loop prevention
                let entityKey = "\(ObjectIdentifier(currentEntity))"
                guard !checkedEntities.contains(entityKey) else {
                    break // Already checked this entity
                }
                checkedEntities.insert(entityKey)

                let idString = entityName

                // CLEANUP: Check if this is a "ghost" entity (UUID-named but not tracked)
                // This can happen when objects are cleared but entities remain in scene
                // Instead of just removing them, treat them as collectible items that trigger confetti/sound
                if idString.contains("-") && idString.count == 36 &&
                   !placedBoxes.keys.contains(idString) &&
                   !placedNPCs.keys.contains(idString) &&
                   !findableObjects.keys.contains(idString) {
                    Swift.print("👻 Found ghost entity '\(idString)' - treating as collectible item")

                    // Create a minimal FindableObject for the ghost entity to trigger confetti/sound
                    if let anchorEntity = currentEntity as? AnchorEntity ?? currentEntity.parent as? AnchorEntity {
                        let ghostFindableObject = FindableObject(
                            locationId: idString,
                            anchor: anchorEntity,
                            sphereEntity: currentEntity as? ModelEntity,
                            container: nil,
                            location: nil // No location data for ghosts
                        )

                        // Set a callback that just removes the entity
                        ghostFindableObject.onFoundCallback = { [weak self] _ in
                            DispatchQueue.main.async {
                                anchorEntity.removeFromParent()
                            }
                        }

                        // Trigger the find animation (confetti + sound) and removal
                        ghostFindableObject.find(tapWorldPosition: tapWorldPosition) {
                            Swift.print("✅ Ghost entity '\(idString)' collected with confetti/sound")
                        }

                        return // Don't process as regular object
                    } else {
                        // Fallback: just remove the entity if we can't create a proper FindableObject
                        Swift.print("⚠️ Could not create FindableObject for ghost entity - removing directly")
                        currentEntity.removeFromParent()
                        continue
                    }
                }
                
                // FIRST: Check if this is an NPC (skeleton, corgi, etc.)
                // CRITICAL: NPCs should NEVER be treated as loot boxes, even if they're accidentally in placedBoxes
                Swift.print("🔍 DEBUG TAP: Checking if '\(idString)' is an NPC")
                Swift.print("   placedNPCs keys: \(placedNPCs.keys.sorted())")
                Swift.print("   Is in placedNPCs? \(placedNPCs[idString] != nil)")
                if placedNPCs[idString] != nil {
                    Swift.print("💬 ✅ NPC TAPPED (ID: \(idString)) - triggering onNPCTap callback")
                    Swift.print("   onNPCTap callback exists: \(onNPCTap != nil)")
                    onNPCTap?(idString)
                    Swift.print("   ✅ onNPCTap callback invoked")
                    return // Don't process as regular object - NPCs are not loot boxes
                } else {
                    Swift.print("   ℹ️ Not an NPC (not in placedNPCs)")
                }
                
                // Check if this ID matches a placed box (but NOT an NPC)
                // Double-check it's not an NPC to prevent accidental matching
                if placedBoxes[idString] != nil && placedNPCs[idString] == nil {
                    locationId = idString
                    Swift.print("🎯 Found matching placed box ID: \(idString)")
                    break
                }
            }
            
            // Also check parent's name (in case name is on parent)
            if let parent = currentEntity.parent {
                let parentName = parent.name
                if !parentName.isEmpty {
                    let parentKey = "\(ObjectIdentifier(parent))"
                    if !checkedEntities.contains(parentKey) {
                        checkedEntities.insert(parentKey)
                        
                        // FIRST: Check if parent is an NPC
                        if placedNPCs[parentName] != nil {
                            Swift.print("💬 ✅ NPC TAPPED via parent (ID: \(parentName)) - triggering onNPCTap callback")
                            Swift.print("   onNPCTap callback exists: \(onNPCTap != nil)")
                            onNPCTap?(parentName)
                            Swift.print("   ✅ onNPCTap callback invoked")
                            return // Don't process as regular object - NPCs are not loot boxes
                        }
                        
                        // Then check if parent is a loot box
                        if placedBoxes[parentName] != nil {
                            locationId = parentName
                            Swift.print("🎯 Found matching placed box ID via parent: \(parentName)")
                            break
                        }
                    }
                }
            }
            
            entityToCheck = currentEntity.parent
        }
        
        // If entity hit didn't work, try proximity-based detection for NPCs first
        // Check all placed NPCs to see if tap is near any of them on screen
        // Also check even if we got an entity hit, in case the hit was on a child entity
        if !placedNPCs.isEmpty {
            var closestNPCId: String? = nil
            var closestNPCScreenDistance: CGFloat = CGFloat.infinity
            let maxNPCScreenDistance: CGFloat = 300.0 // Maximum screen distance in points to consider a tap "on" the NPC (increased for easier tapping)
            
            for (npcId, anchor) in placedNPCs {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Project the NPC's world position to screen coordinates
                guard let screenPoint = arView.project(anchorWorldPos) else {
                    continue // NPC is not visible (behind camera or outside view)
                }
                
                // Check if the projection is valid (NPC is visible on screen)
                let viewWidth = CGFloat(arView.bounds.width)
                let viewHeight = CGFloat(arView.bounds.height)
                let isOnScreen = screenPoint.x >= 0 && screenPoint.x <= viewWidth &&
                                screenPoint.y >= 0 && screenPoint.y <= viewHeight
                
                if isOnScreen {
                    // Calculate screen-space distance from tap to NPC
                    let tapX = CGFloat(tapLocation.x)
                    let tapY = CGFloat(tapLocation.y)
                    let dx = tapX - screenPoint.x
                    let dy = tapY - screenPoint.y
                    let screenDistance = sqrt(dx * dx + dy * dy)
                    
                    // If screen distance is within threshold, consider it a hit
                    if screenDistance < maxNPCScreenDistance && screenDistance < closestNPCScreenDistance {
                        closestNPCScreenDistance = screenDistance
                        closestNPCId = npcId
                        Swift.print("💬 Found candidate NPC \(npcId): screen dist=\(String(format: "%.1f", screenDistance))px")
                    }
                }
            }
            
            if let npcId = closestNPCId {
                Swift.print("💬 NPC tapped via proximity detection (ID: \(npcId)) - opening conversation")
                onNPCTap?(npcId)
                return // Don't process as regular object
            }
        }
        
        // If entity hit didn't work, try proximity-based detection using screen-space projection
        // Check all placed boxes to see if tap is near any of them on screen
        if locationId == nil && !placedBoxes.isEmpty {
            var closestBoxId: String? = nil
            var closestScreenDistance: CGFloat = CGFloat.infinity
            let maxScreenDistance: CGFloat = 150.0 // Maximum screen distance in points to consider a tap "on" the box
            
            // Get camera forward direction for fallback checks
            let cameraForward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
            let normalizedCameraForward = normalize(cameraForward)
            
            // Use ARView's project method to convert world positions to screen coordinates
            for (boxId, anchor) in placedBoxes {
                // CRITICAL: Skip NPCs - they should never be treated as loot boxes
                // NPCs are in placedNPCs, but double-check to prevent accidental matching
                if placedNPCs[boxId] != nil {
                    Swift.print("⏭️ Skipping \(boxId) in loot box proximity check - it's an NPC")
                    continue
                }
                
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Calculate world-space distance from camera to object
                let cameraToObject = anchorWorldPos - cameraPos
                let worldDistanceFromCamera = length(cameraToObject)
                let normalizedToObject = normalize(cameraToObject)
                
                // Check if object is in front of camera (dot product > 0)
                let dotProduct = dot(normalizedCameraForward, normalizedToObject)
                let isInFrontOfCamera = dotProduct > 0.0
                
                // Try to project the box's world position to screen coordinates
                var screenPoint: CGPoint? = nil
                var isOnScreen = false
                
                if let projectedPoint = arView.project(anchorWorldPos) {
                    // Projection succeeded - use it
                    screenPoint = projectedPoint
                    
                    // Check if the projection is valid (box is visible on screen)
                    let viewWidth = CGFloat(arView.bounds.width)
                    let viewHeight = CGFloat(arView.bounds.height)
                    let pointX = projectedPoint.x
                    let pointY = projectedPoint.y
                    isOnScreen = pointX >= 0 && pointX <= viewWidth &&
                                 pointY >= 0 && pointY <= viewHeight
                } else {
                    // Projection failed - this can happen for very close objects
                    // Use fallback: check if object is very close and in front of camera
                    if isInFrontOfCamera && worldDistanceFromCamera < 3.0 {
                        // Object is very close (< 3m) and in front of camera
                        // Use center of screen as estimated position for very close objects
                        let viewWidth = CGFloat(arView.bounds.width)
                        let viewHeight = CGFloat(arView.bounds.height)
                        screenPoint = CGPoint(x: viewWidth / 2.0, y: viewHeight / 2.0)
                        isOnScreen = true
                        Swift.print("🎯 Using fallback for close object \(boxId): distance=\(String(format: "%.2f", worldDistanceFromCamera))m, projection failed")
                    } else {
                        // Object is not close or behind camera - skip it
                        continue
                    }
                }
                
                if isOnScreen, let screenPos = screenPoint {
                    // Calculate screen-space distance from tap to box
                    let tapX = CGFloat(tapLocation.x)
                    let tapY = CGFloat(tapLocation.y)
                    let dx = tapX - screenPos.x
                    let dy = tapY - screenPos.y
                    let screenDistance = sqrt(dx * dx + dy * dy)
                    
                    // Also check world-space distance if we have tap world position (for validation)
                    var worldDistance: Float = Float.infinity
                    if let tapPos = tapWorldPosition {
                        worldDistance = length(anchorWorldPos - tapPos)
                    }
                    
                    // For very close objects (< 1m), use a more lenient screen distance threshold
                    // because screen projection can be inaccurate for close objects
                    let effectiveMaxScreenDistance = worldDistanceFromCamera < 1.0 ? maxScreenDistance * 1.5 : maxScreenDistance
                    
                    // If screen distance is within threshold, consider it a hit
                    if screenDistance < effectiveMaxScreenDistance {
                        // If we have world position, prefer boxes that are also close in world space
                        // For very close objects, be more lenient with world distance check
                        let worldDistanceThreshold: Float = worldDistanceFromCamera < 1.0 ? 2.0 : 10.0
                        let isCloseInWorld = worldDistance < worldDistanceThreshold
                        let shouldSelect = worldDistance == Float.infinity || isCloseInWorld
                        
                        if shouldSelect && screenDistance < closestScreenDistance {
                            closestScreenDistance = screenDistance
                            closestBoxId = boxId
                            if worldDistance != Float.infinity {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px, world dist=\(String(format: "%.2f", worldDistance))m, camera dist=\(String(format: "%.2f", worldDistanceFromCamera))m")
                            } else {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px, camera dist=\(String(format: "%.2f", worldDistanceFromCamera))m")
                            }
                        }
                    }
                }
            }
            
            if let closestId = closestBoxId {
                locationId = closestId
                Swift.print("🎯 Detected tap on box via screen projection: \(closestId), screen distance: \(String(format: "%.1f", closestScreenDistance))px")
            }
        }
        
        // UNIFIED FINDABLE BEHAVIOR: Handle different tap behaviors based on object type and creator
        Swift.print("🎯 Tap result: locationId = \(locationId ?? "nil")")
        if let idString = locationId {
            Swift.print("🎯 Processing tap on: \(idString)")

            // Get the location object to check its properties
            guard let location = locationManager.locations.first(where: { $0.id == idString }) else {
                Swift.print("⚠️ Location not found in locationManager for \(idString)")
                return
            }

            // CRITICAL: Check if object is already collected - this is the primary check
            // If collected, don't allow tapping (object should have been removed from AR)
            if location.collected {
                Swift.print("⚠️ \(idString) has already been collected - ignoring tap")
                return
            }

            // Check if this is an NFC object created by the current user
            let currentUserId = APIService.shared.currentUserID
            let isNFCObject = idString.hasPrefix("nfc_")
            let isCreatedByCurrentUser = location.created_by == currentUserId

            Swift.print("🎯 Object analysis: NFC=\(isNFCObject), created_by_current_user=\(isCreatedByCurrentUser), current_user=\(currentUserId)")

            // SPECIAL HANDLING FOR NFC OBJECTS CREATED BY CURRENT USER
            if isNFCObject && isCreatedByCurrentUser {
                Swift.print("ℹ️ NFC object created by current user - showing info panel instead of collecting")
                onShowObjectInfo?(location)
                return
            }
            
            // Clear from foundLootBoxes if location was reset (allows re-tapping after reset)
            if foundLootBoxes.contains(idString) && !location.collected {
                foundLootBoxes.remove(idString)
                Swift.print("🔄 Object \(idString) was reset - clearing from found set, allowing tap again")
            }
            
            // Get the anchor for this object
            guard let anchor = placedBoxes[idString] else {
                Swift.print("⚠️ Anchor not found for \(idString)")
                return
            }

            // Find the sphere entity if it exists
            // For simple objects (spheres/cubes), check the findableObjects dictionary first
            var sphereEntity: ModelEntity? = nil

            // First, check if we have a FindableObject with sphereEntity set (for spheres/cubes)
            if let findableObject = findableObjects[idString],
               let sphere = findableObject.sphereEntity {
                sphereEntity = sphere
                Swift.print("🎯 Found sphere entity via findableObject: \(sphere.name)")
            } else {
                // Fallback: search children for entities with PointLightComponent (for containers)
                for child in anchor.children {
                    if let modelEntity = child as? ModelEntity,
                       modelEntity.components[PointLightComponent.self] != nil {
                        sphereEntity = modelEntity
                        Swift.print("🎯 Found sphere entity via PointLightComponent in children: \(modelEntity.name)")
                        break
                    }
                }
            }

            // Use callback to find loot box
            Swift.print("🎯 Finding object: \(idString) (type: sphere=\(sphereEntity != nil), has findableObject=\(findableObjects[idString] != nil))")
            onFindLootBox?(idString, anchor, cameraPos, sphereEntity, tapWorldPosition)
            return
        }
    }

    // MARK: - Long Press Handler
    @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
        // Only trigger on the began state to avoid multiple calls
        guard sender.state == .began else { return }

        Swift.print("👆 ========== LONG PRESS DETECTED ==========")
        guard let arView = arView else {
            Swift.print("⚠️ Long press handler: Missing AR view")
            return
        }

        let pressLocation = sender.location(in: arView)
        Swift.print("   Screen location: (\(pressLocation.x), \(pressLocation.y))")
        Swift.print("   Placed boxes: \(placedBoxes.count)")
        Swift.print("   Placed box IDs: \(Array(placedBoxes.keys).sorted())")

        // Use ARObjectDetailService to detect object at press location
        guard let objectId = ARObjectDetailService.shared.detectObjectAtLocation(
            pressLocation,
            in: arView,
            placedBoxes: placedBoxes
        ) else {
            Swift.print("❌ No object detected at long press location")
            Swift.print("👆 ========== LONG PRESS END (NO OBJECT) ==========")
            return
        }

        Swift.print("📋 Object long-pressed: \(objectId)")

        // Handle orphaned entities specially
        if objectId.hasPrefix("orphan:") {
            let orphanId = String(objectId.dropFirst(7)) // Remove "orphan:" prefix
            Swift.print("   👻 Long-pressed orphaned entity: \(orphanId)")

            // Try to get the entity from the scene for AR coordinate extraction
            if let tappedEntity = arView.entity(at: pressLocation),
               let anchorEntity = tappedEntity as? AnchorEntity ?? tappedEntity.parent as? AnchorEntity {

                let transform = anchorEntity.transformMatrix(relativeTo: nil)
                let arCoordinates = SIMD3<Float>(
                    transform.columns.3.x,
                    transform.columns.3.y,
                    transform.columns.3.z
                )

                // Create detail object for orphaned entity
                let detail = ARObjectDetail(
                    id: orphanId,
                    name: "Orphaned Object (ID: \(orphanId))",
                    itemType: "Unknown Type",
                    placerName: "Unknown",
                    datePlaced: nil,
                    gpsCoordinates: nil,
                    arCoordinates: arCoordinates,
                    arOrigin: nil,
                    arOffsets: nil,
                    anchors: [anchorEntity.name]
                )

                Swift.print("   📋 Created detail view for orphaned entity")
                // For now, we'll use the regular callback but with special handling
                // In a full implementation, you'd want a separate callback for orphaned entities
                onLongPressObject?(objectId)
            } else {
                Swift.print("   ⚠️ Could not extract AR coordinates for orphaned entity")
                onLongPressObject?(objectId)
            }

            Swift.print("👆 ========== LONG PRESS END (ORPHANED ENTITY) ==========")
            return
        }

        Swift.print("   Triggering detail view callback")
        Swift.print("👆 ========== LONG PRESS END (SUCCESS) ==========")

        // Trigger the callback to show object details
        onLongPressObject?(objectId)
    }
}

