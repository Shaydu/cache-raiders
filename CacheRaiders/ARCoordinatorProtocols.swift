import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import Combine
import Foundation

// MARK: - AR Service Protocol
protocol ARServiceProtocol: AnyObject {
    func configure(with coordinator: ARCoordinatorCoreProtocol)
    func cleanup()
}

// MARK: - AR Session Service Protocol
protocol ARSessionService: ARServiceProtocol {
    func session(_ session: ARSession, didUpdate frame: ARFrame)
    func session(_ session: ARSession, didAdd anchors: [ARAnchor])
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor])
    func session(_ session: ARSession, didRemove anchors: [ARAnchor])
}

// MARK: - AR Coordinator Core Protocol
protocol ARCoordinatorCoreProtocol: AnyObject {
    var arView: ARView? { get }
    var userLocationManager: UserLocationManager? { get }
    var locationManager: LootBoxLocationManager? { get }
    var services: ARCoordinatorServices { get }
    var state: ARCoordinatorState { get set }
    
    // Common methods needed by services
    func showDebugMessage(_ message: String)
    func playHapticFeedback()
    func scheduleBackgroundTask(_ task: @escaping () -> Void)
}

// MARK: - Object Placement Service Protocol
protocol ARObjectPlacementServiceProtocol: ARServiceProtocol {
    func placeLootBoxAtLocation(_ location: LootBoxLocation, in arView: ARView)
    func removeAllPlacedObjects()
    func findLootBox(_ location: LootBoxLocation, source: FoundSource)
    func handleObjectTap(_ entity: Entity)
    func checkAndPlaceBoxes(userLocation: CLLocation, nearbyLocations: [LootBoxLocation])
    func randomizeLootBoxes()
    func placeARItem(_ item: LootBoxLocation)
}

// MARK: - NPC Service Protocol
protocol ARNPCServiceProtocol: ARServiceProtocol {
    func placeNPC(_ npcType: NPCType, at location: CLLocation?)
    func removeAllNPCs()
    func handleNPCInteraction(_ npcId: String)
    func syncNPCsWithServer()
}

// MARK: - NFC Integration Service Protocol
protocol NFCIntegrationServiceProtocol: ARServiceProtocol {
    func startNFCScan(for objectId: String)
    func stopNFCScan(for objectId: String)
    func handleNFCDiscovery(_ objectId: String, tagId: String)
    func updateNFCGuidanceState(_ state: NFCGuidanceState)
}

// MARK: - Location Service Protocol
protocol ARLocationServiceProtocol: ARServiceProtocol {
    func updateUserLocation(_ location: CLLocation)
    func calculateARPosition(from location: CLLocation) -> SIMD3<Float>?
    func correctGPSDrift()
    func getAREnhancedLocation() -> (latitude: Double, longitude: Double, arOffsetX: Double, arOffsetY: Double, arOffsetZ: Double)?
}

// MARK: - Environment Service Protocol
protocol AREnvironmentServiceProtocol: ARSessionService {
    func configureEnvironment()
    func updateOcclusion()
    func recognizeObjects(in frame: ARFrame)
    func setAROriginGroundLevel(_ groundLevel: Float)
}

// MARK: - State Service Protocol
protocol ARStateServiceProtocol: ARServiceProtocol {
    func throttle(_ key: String, interval: TimeInterval, operation: @escaping () -> Void)
    func scheduleBackgroundOperation(_ operation: @escaping () -> Void)
    func updateObjectPlacementTime(_ objectId: String, time: Date)
}

// MARK: - UI Service Protocol
protocol ARUIServiceProtocol: ARServiceProtocol {
    func showObjectInfoPanel(for entity: Entity)
    func hideObjectInfoPanel()
    func updateDistanceOverlay(for entity: Entity)
    func showDebugOverlay(_ message: String)
}
