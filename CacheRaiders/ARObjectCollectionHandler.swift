import SwiftUI
import RealityKit
import CoreLocation

/// Handler for managing object collection events (collected by other users, uncollected, etc.)
class ARObjectCollectionHandler {
    weak var locationManager: LootBoxLocationManager?
    weak var userLocationManager: UserLocationManager?
    weak var distanceTracker: ARDistanceTracker?
    weak var tapHandler: ARTapHandler?
    
    // Callbacks for ARCoordinator to handle state updates
    var onRemoveObject: ((String) -> Void)?
    var onClearFoundSets: ((String) -> Void)?
    var onRePlaceObject: ((String, CLLocation, [LootBoxLocation]) -> Void)?
    
    init(locationManager: LootBoxLocationManager?,
         userLocationManager: UserLocationManager?,
         distanceTracker: ARDistanceTracker?,
         tapHandler: ARTapHandler?) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self.distanceTracker = distanceTracker
        self.tapHandler = tapHandler
    }
    
    /// Handle when an object is collected by another user - remove it from AR scene
    func handleObjectCollectedByOtherUser(objectId: String, 
                                         placedBoxes: inout [String: AnchorEntity],
                                         findableObjects: inout [String: FindableObject],
                                         objectsInViewport: inout Set<String>) {
        // Check if this object is currently placed in AR
        guard let anchor = placedBoxes[objectId] else {
            Swift.print("ℹ️ Object \(objectId) collected by another user but not currently in AR scene")
            return
        }
        
        // Get object name for logging
        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"
        
        Swift.print("🗑️ Removing object '\(objectName)' (ID: \(objectId)) from AR - collected by another user")
        
        // Remove from AR scene
        anchor.removeFromParent()
        
        // Remove from tracking dictionaries
        placedBoxes.removeValue(forKey: objectId)
        findableObjects.removeValue(forKey: objectId)
        objectsInViewport.remove(objectId)
        
        // Also remove from distance tracker if applicable
        distanceTracker?.foundLootBoxes.insert(objectId)
        if let textEntity = distanceTracker?.distanceTextEntities[objectId] {
            textEntity.removeFromParent()
            distanceTracker?.distanceTextEntities.removeValue(forKey: objectId)
        }
        
        Swift.print("✅ Object '\(objectName)' removed from AR scene")
    }
    
    /// Handle when an object is uncollected (marked as unfound) - clear found sets and re-place it
    func handleObjectUncollected(objectId: String,
                                 placedBoxes: inout [String: AnchorEntity],
                                 findableObjects: inout [String: FindableObject],
                                 objectsInViewport: inout Set<String>,
                                 objectPlacementTimes: inout [String: Date]) {
        // Get object name for logging
        let location = locationManager?.locations.first(where: { $0.id == objectId })
        let objectName = location?.name ?? "Unknown"
        
        Swift.print("🔄 Object uncollected: '\(objectName)' (ID: \(objectId)) - clearing found sets and re-placing")
        
        // CRITICAL: Clear from found sets so object can be placed again
        distanceTracker?.foundLootBoxes.remove(objectId)
        tapHandler?.foundLootBoxes.remove(objectId)
        
        // Remove from AR scene if it's currently placed (so it can be re-placed)
        if let anchor = placedBoxes[objectId] {
            anchor.removeFromParent()
            placedBoxes.removeValue(forKey: objectId)
            findableObjects.removeValue(forKey: objectId)
            objectsInViewport.remove(objectId)
            objectPlacementTimes.removeValue(forKey: objectId)
            Swift.print("   ✅ Removed object from AR scene - will be re-placed on next checkAndPlaceBoxes")
        }
        
        // Trigger immediate re-placement if we have user location
        if let userLocation = userLocationManager?.currentLocation,
           let locationManager = locationManager {
            let nearby = locationManager.getNearbyLocations(userLocation: userLocation)
            // Check if this object is in nearby locations
            if nearby.contains(where: { $0.id == objectId }) {
                Swift.print("   🔄 Object is nearby - triggering immediate re-placement")
                onRePlaceObject?(objectId, userLocation, nearby)
            } else {
                Swift.print("   ℹ️ Object is not nearby (outside search radius) - will appear when you get closer")
            }
        }
    }
}


