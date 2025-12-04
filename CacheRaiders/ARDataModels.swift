import SwiftUI
import RealityKit
import CoreLocation
import ARKit

// MARK: - Found Source Types
enum FoundSource {
    case proximity
    case tap
    case nfc
    case manual
}

// MARK: - NFC Guidance State
enum NFCGuidanceState {
    case gpsGuidance
    case nfcDiscovery
    case objectFound
}

// MARK: - AR Coordinator State
struct ARCoordinatorState {
    var placedObjects: [String: FindableObject]
    var placedBoxes: [String: AnchorEntity]
    var objectPlacementTimes: [String: Date]
    var activeNFCScans: Set<String>
    var placedNPCs: [String: AnchorEntity]
    var skeletonPlaced: Bool
    var corgiPlaced: Bool
    var nfcDiscoveryState: NFCGuidanceState
    var lastSpherePlacementTime: Date?
    var sphereModeActive: Bool
    var objectsInViewport: Set<String> // Track which objects are currently visible in viewport
    var arOriginSetTime: Date?
    var isDegradedMode: Bool
    var arOriginGroundLevel: Float?
    var hasAutoRandomized: Bool
    var savedARConfiguration: ARConfiguration?
    var collectionNotificationBinding: Binding<String?>?
    var distanceToNearestBinding: Binding<Double?>?
    var temperatureStatusBinding: Binding<String?>?
    var nearestObjectDirectionBinding: Binding<Double?>?
    var conversationNPCBinding: Binding<ConversationNPC?>?
    
    init() {
        self.placedObjects = [:] 
        self.placedBoxes = [:] 
        self.objectPlacementTimes = [:] 
        self.activeNFCScans = [] 
        self.placedNPCs = [:] 
        self.skeletonPlaced = false 
        self.corgiPlaced = false 
        self.nfcDiscoveryState = .gpsGuidance
        self.lastSpherePlacementTime = nil
        self.sphereModeActive = false
        self.objectsInViewport = []
        self.arOriginSetTime = nil
        self.isDegradedMode = false
        self.arOriginGroundLevel = nil
        self.hasAutoRandomized = false
        self.savedARConfiguration = nil
    }
}

// MARK: - Service Configuration
struct ARServiceConfiguration {
    let coordinator: ARCoordinatorCoreProtocol
    let arView: ARView?
    let userLocationManager: UserLocationManager?
    let locationManager: LootBoxLocationManager?
}
