import Foundation
import ARKit

// MARK: - AR Coordinator Services Container
struct ARCoordinatorServices {
    var objectPlacement: ARObjectPlacementServiceProtocol?
    var npc: ARNPCServiceProtocol?
    var nfc: NFCIntegrationServiceProtocol?
    var location: ARLocationServiceProtocol?
    var environment: AREnvironmentServiceProtocol?
    var state: ARStateServiceProtocol?
    var ui: ARUIServiceProtocol?
    
    init() {
        // Services will be initialized by the coordinator
    }
    
    // MARK: - Service Configuration
    mutating func configureAllServices(with coordinator: ARCoordinatorCoreProtocol) {
        objectPlacement?.configure(with: coordinator)
        npc?.configure(with: coordinator)
        nfc?.configure(with: coordinator)
        location?.configure(with: coordinator)
        environment?.configure(with: coordinator)
        state?.configure(with: coordinator)
        ui?.configure(with: coordinator)
    }
    
    // MARK: - Service Cleanup
    func cleanupAllServices() {
        objectPlacement?.cleanup()
        npc?.cleanup()
        nfc?.cleanup()
        location?.cleanup()
        environment?.cleanup()
        state?.cleanup()
        ui?.cleanup()
    }
    
    // MARK: - Session Delegation
    func handleSessionUpdate(_ session: ARSession, frame: ARFrame) {
        environment?.session(session, didUpdate: frame)
    }
    
    func handleAnchorsAdded(_ session: ARSession, anchors: [ARAnchor]) {
        environment?.session(session, didAdd: anchors)
    }
    
    func handleAnchorsUpdated(_ session: ARSession, anchors: [ARAnchor]) {
        environment?.session(session, didUpdate: anchors)
    }
    
    func handleAnchorsRemoved(_ session: ARSession, anchors: [ARAnchor]) {
        environment?.session(session, didRemove: anchors)
    }
}
