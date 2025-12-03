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
    private var objectPlacementService: ARObjectPlacer?
    private var npcService: ARNPCService?
    private var conversationManager: ARConversationManager?
    var foundLootBoxes: Set<String> = []
    var placedBoxes: [String: AnchorEntity] = [:] // Track all placed boxes by location ID
    var findableObjects: [String: FindableObject] = [:] // Track all findable objects
    var placedNPCs: [String: AnchorEntity] = [:] // Track all placed NPCs by ID
    var collectionNotificationBinding: Binding<String?>? // Binding for collection notifications

    // Callback closures
    var onFindLootBox: ((String, AnchorEntity, SIMD3<Float>, ModelEntity?) -> Void)?
    var onPlaceLootBoxAtTap: ((LootBoxLocation, ARRaycastResult) -> Void)?
    var onNPCTap: ((String) -> Void)?
    var onShowObjectInfo: ((LootBoxLocation) -> Void)?
    
    // Performance tracking
    private var lastTapTime: Date?
    private let tapCooldown: TimeInterval = 0.3
    
    override init() { super.init() }
    
    func setup(locationManager: LootBoxLocationManager,
              userLocationManager: UserLocationManager,
              objectPlacementService: ARObjectPlacer,
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
        Swift.print("🎯 ARTapHandler.handleTap() called - gesture state: \(gesture.state.rawValue)")

        guard let arView = arView,
              let locationManager = locationManager,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Tap handler: Missing AR view, location manager, or frame")
            Swift.print("   arView: \(arView != nil ? "✓" : "✗")")
            Swift.print("   locationManager: \(locationManager != nil ? "✓" : "✗")")
            Swift.print("   frame: \(arView?.session.currentFrame != nil ? "✓" : "✗")")
            return
        }

        let tapLocation = gesture.location(in: arView)
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        Swift.print("👆 Tap detected at screen: (\(tapLocation.x), \(tapLocation.y))")
        Swift.print("   Findable objects count: \(findableObjects.count), keys: \(findableObjects.keys.sorted())")

        // Get tap world position using raycast
        var tapWorldPosition: SIMD3<Float>? = nil
        if let raycastResult = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first {
            tapWorldPosition = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
        }

        // Check if tapped on existing object
        // First try direct entity hit
        let tappedEntity: Entity? = arView.entity(at: tapLocation)
        var locationId: String? = nil

        Swift.print("🎯 Tap entity hit test result: \(tappedEntity != nil ? "hit entity" : "no entity hit")")

        // Walk up the entity hierarchy to find the location ID
        var entityToCheck = tappedEntity
        while let currentEntity = entityToCheck {
            let entityName = currentEntity.name
            Swift.print("🎯 Checking entity: '\(entityName)'")
            // Check if this name matches a findable object
            if !entityName.isEmpty && findableObjects[entityName] != nil {
                locationId = entityName
                Swift.print("🎯 Found matching findable object ID: \(entityName)")
                break
            }
            // Also check the anchor name
            if let anchor = currentEntity as? AnchorEntity, !anchor.name.isEmpty, findableObjects[anchor.name] != nil {
                locationId = anchor.name
                Swift.print("🎯 Found matching anchor ID: \(anchor.name)")
                break
            }
            entityToCheck = currentEntity.parent
        }

        // If entity hit didn't work, try proximity-based detection using screen-space projection
        if locationId == nil && !findableObjects.isEmpty {
            var closestObjectId: String? = nil
            var closestScreenDistance: CGFloat = CGFloat.infinity
            let maxScreenDistance: CGFloat = 150.0 // Maximum screen distance in points

            for (objectId, findable) in findableObjects {
                let anchorTransform = findable.anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )

                // Project the object's world position to screen coordinates
                guard let screenPoint = arView.project(anchorWorldPos) else {
                    continue
                }

                // Check if the projection is valid (object is visible on screen)
                let viewWidth = CGFloat(arView.bounds.width)
                let viewHeight = CGFloat(arView.bounds.height)
                let isOnScreen = screenPoint.x >= 0 && screenPoint.x <= viewWidth &&
                                 screenPoint.y >= 0 && screenPoint.y <= viewHeight

                if isOnScreen {
                    // Calculate screen-space distance from tap to object
                    let dx = CGFloat(tapLocation.x) - screenPoint.x
                    let dy = CGFloat(tapLocation.y) - screenPoint.y
                    let screenDistance = sqrt(dx * dx + dy * dy)

                    if screenDistance < maxScreenDistance && screenDistance < closestScreenDistance {
                        closestScreenDistance = screenDistance
                        closestObjectId = objectId
                        Swift.print("🎯 Found candidate object \(objectId): screen dist=\(String(format: "%.1f", screenDistance))px")
                    }
                }
            }

            if let closestId = closestObjectId {
                locationId = closestId
                Swift.print("🎯 Detected tap on object via screen projection: \(closestId), distance: \(String(format: "%.1f", closestScreenDistance))px")
            }
        }

        // Process tap if we found an object
        Swift.print("🎯 Tap result: locationId = \(locationId ?? "nil")")
        if let idString = locationId {
            Swift.print("🎯 Processing tap on: \(idString)")

            // Check if already found
            let isLocationCollected = locationManager.locations.first(where: { $0.id == idString })?.collected ?? false
            let isFound = foundLootBoxes.contains(idString)

            if isFound && isLocationCollected {
                Swift.print("⚠️ Object \(idString) has already been found and collected")
                return
            } else if isFound && !isLocationCollected {
                // Location was reset - clear from found set
                foundLootBoxes.remove(idString)
                Swift.print("🔄 Object \(idString) was reset - allowing tap again")
            }

            // Check if in location manager and already collected
            if let location = locationManager.locations.first(where: { $0.id == idString }),
               location.collected {
                Swift.print("⚠️ \(location.name) has already been collected")
                return
            }

            // Get the findable object
            guard let findable = findableObjects[idString] else {
                Swift.print("⚠️ FindableObject not found for \(idString)")
                return
            }

            // Trigger collection callback
            Swift.print("🎯 Triggering collection for: \(idString)")
            onFindLootBox?(idString, findable.anchor, cameraPos, findable.sphereEntity)
        }
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

