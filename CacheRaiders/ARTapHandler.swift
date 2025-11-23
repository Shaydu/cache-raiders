import Foundation
import SwiftUI
import RealityKit
import ARKit
import UIKit

// MARK: - AR Tap Handler
/// Handles tap gesture detection and loot box finding
class ARTapHandler {
    weak var arView: ARView?
    weak var locationManager: LootBoxLocationManager?
    
    var placedBoxes: [String: AnchorEntity] = [:]
    var findableObjects: [String: FindableObject] = [:]
    var foundLootBoxes: Set<String> = []
    var distanceTextEntities: [String: ModelEntity] = [:]
    var collectionNotificationBinding: Binding<String?>?
    var sphereModeActive: Bool = false
    
    var lastTapPlacementTime: Date?
    
    // Callback for finding loot boxes
    var onFindLootBox: ((String, AnchorEntity, SIMD3<Float>, ModelEntity?) -> Void)?
    
    // Callback for placing loot box at tap location
    var onPlaceLootBoxAtTap: ((LootBoxLocation, ARRaycastResult) -> Void)?
    
    init(arView: ARView?, locationManager: LootBoxLocationManager?) {
        self.arView = arView
        self.locationManager = locationManager
    }
    
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        guard let arView = arView,
              let locationManager = locationManager,
              let frame = arView.session.currentFrame else {
            Swift.print("⚠️ Tap handler: Missing AR view, location manager, or frame")
            return
        }
        
        let tapLocation = sender.location(in: arView)
        let cameraTransform = frame.camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        
        Swift.print("👆 Tap detected at screen: (\(tapLocation.x), \(tapLocation.y))")
        Swift.print("   Placed boxes count: \(placedBoxes.count), keys: \(placedBoxes.keys.sorted())")
        
        // Get tap world position using raycast
        var tapWorldPosition: SIMD3<Float>? = nil
        if let raycastResult = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first {
            tapWorldPosition = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
        }
        
        // Check if tapped on existing loot box
        // First try direct entity hit
        let tappedEntity: Entity? = arView.entity(at: tapLocation)
        var locationId: String? = nil

        Swift.print("🎯 Tap entity hit test result: \(tappedEntity != nil ? "hit entity" : "no entity hit")")

        // Walk up the entity hierarchy to find the location ID
        var entityToCheck = tappedEntity
        while let currentEntity = entityToCheck {
            let entityName = currentEntity.name
            Swift.print("🎯 Checking entity: '\(entityName)'")
            // Entity.name is a String, not String?, so check if it's not empty
            if !entityName.isEmpty {
                let idString = entityName
                // Check if this ID matches a placed box
                if placedBoxes[idString] != nil {
                    locationId = idString
                    Swift.print("🎯 Found matching placed box ID: \(idString)")
                    break
                }
            }
            entityToCheck = currentEntity.parent
        }
        
        // If entity hit didn't work, try proximity-based detection using screen-space projection
        // Check all placed boxes to see if tap is near any of them on screen
        if locationId == nil && !placedBoxes.isEmpty {
            var closestBoxId: String? = nil
            var closestScreenDistance: CGFloat = CGFloat.infinity
            let maxScreenDistance: CGFloat = 150.0 // Maximum screen distance in points to consider a tap "on" the box
            
            // Use ARView's project method to convert world positions to screen coordinates
            for (boxId, anchor) in placedBoxes {
                let anchorTransform = anchor.transformMatrix(relativeTo: nil)
                let anchorWorldPos = SIMD3<Float>(
                    anchorTransform.columns.3.x,
                    anchorTransform.columns.3.y,
                    anchorTransform.columns.3.z
                )
                
                // Project the box's world position to screen coordinates
                guard let optionalScreenPoint = arView.project(anchorWorldPos) else {
                    // Box is not visible (behind camera or outside view)
                    continue
                }
                let screenPoint = optionalScreenPoint
                
                // Check if the projection is valid (box is visible on screen)
                let viewWidth = CGFloat(arView.bounds.width)
                let viewHeight = CGFloat(arView.bounds.height)
                let pointX = screenPoint.x
                let pointY = screenPoint.y
                let isOnScreen = pointX >= 0 && pointX <= viewWidth &&
                                 pointY >= 0 && pointY <= viewHeight
                
                if isOnScreen {
                    // Calculate screen-space distance from tap to box
                    let tapX = CGFloat(tapLocation.x)
                    let tapY = CGFloat(tapLocation.y)
                    let dx = tapX - screenPoint.x
                    let dy = tapY - screenPoint.y
                    let screenDistance = sqrt(dx * dx + dy * dy)
                    
                    // Also check world-space distance if we have tap world position (for validation)
                    var worldDistance: Float = Float.infinity
                    if let tapPos = tapWorldPosition {
                        worldDistance = length(anchorWorldPos - tapPos)
                    }
                    
                    // If screen distance is within threshold, consider it a hit
                    if screenDistance < maxScreenDistance {
                        // If we have world position, prefer boxes that are also close in world space
                        let isCloseInWorld = worldDistance < 10.0
                        let shouldSelect = worldDistance == Float.infinity || isCloseInWorld
                        
                        if shouldSelect && screenDistance < closestScreenDistance {
                            closestScreenDistance = screenDistance
                            closestBoxId = boxId
                            if worldDistance != Float.infinity {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px, world dist=\(String(format: "%.2f", worldDistance))m")
                            } else {
                                Swift.print("🎯 Found candidate box \(boxId): screen dist=\(String(format: "%.1f", screenDistance))px")
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
        
        // UNIFIED FINDABLE BEHAVIOR: All objects in placedBoxes are findable and clickable
        // If we found a location ID (tapped on any findable object), trigger find behavior
        Swift.print("🎯 Tap result: locationId = \(locationId ?? "nil")")
        if let idString = locationId {
            Swift.print("🎯 Processing tap on: \(idString)")
            
            // Check if already found - but also check if location was reset
            // If location is not collected, allow tapping again (reset functionality)
            let isLocationCollected = locationManager.locations.first(where: { $0.id == idString })?.collected ?? false
            
            if foundLootBoxes.contains(idString) && isLocationCollected {
                Swift.print("⚠️ Object \(idString) has already been found and is still marked as collected")
                return
            } else if foundLootBoxes.contains(idString) && !isLocationCollected {
                // Location was reset - clear from found set to allow tapping again
                foundLootBoxes.remove(idString)
                Swift.print("🔄 Object \(idString) was reset - clearing from found set, allowing tap again")
            }
            
            // Check if in location manager and already collected
            if let location = locationManager.locations.first(where: { $0.id == idString }),
               location.collected {
                Swift.print("⚠️ \(location.name) has already been collected")
                return
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
            onFindLootBox?(idString, anchor, cameraPos, sphereEntity)
            return
        }
        
        // If no location-based system or not at a location, allow manual placement
        // Place a test loot box where user taps (for testing without locations)
        if placedBoxes.count >= 3 {
            Swift.print("🎯 Maximum 3 objects reached - cannot place more via tap")
            return
        }

        // Prevent rapid duplicate tap placements (debounce)
        let now = Date()
        if let lastTap = lastTapPlacementTime,
           now.timeIntervalSince(lastTap) < 1.0 {
            Swift.print("⚠️ Tap placement blocked - too soon since last placement (\(String(format: "%.1f", now.timeIntervalSince(lastTap)))s ago)")
            return
        }
        lastTapPlacementTime = now

        if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first,
           let frame = arView.session.currentFrame {
            let cameraY = frame.camera.transform.columns.3.y
            let hitY = result.worldTransform.columns.3.y
            if hitY <= cameraY - 0.2 {
                // Generate unique name for tap-placed artifact
                let tapCount = placedBoxes.count + 1
                let testLocation = LootBoxLocation(
                    id: UUID().uuidString,
                    name: "Test Artifact #\(tapCount)",
                    type: .templeRelic,
                    latitude: 0,
                    longitude: 0,
                    radius: 100
                )
                // For manual tap placement, allow closer placement (1-2m instead of 3-5m)
                // Add to locationManager FIRST so it's tracked, then place it
                // This ensures the location exists before placement and prevents duplicates
                locationManager.addLocation(testLocation)
                onPlaceLootBoxAtTap?(testLocation, result)
            } else {
                Swift.print("⚠️ Tap raycast hit likely ceiling. Ignoring manual placement.")
            }
        }
    }
}

