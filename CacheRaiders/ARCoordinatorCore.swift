import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import Combine
import AudioToolbox

// MARK: - AR Coordinator Core
class ARCoordinatorCore: NSObject, ARSessionDelegate, ARCoordinatorProtocol, ARCoordinatorCoreProtocol {
    
    // MARK: - Public Properties (from ARCoordinatorProtocol)
    weak var arView: ARView?
    var userLocationManager: UserLocationManager?
    var locationManager: LootBoxLocationManager?
    var arOriginLocation: CLLocation?
    var geospatialService: ARGeospatialService?
    var groundingService: ARGroundingService?
    var tapHandler: ARTapHandler?
    
    // State properties (moved to state struct)
    var findableObjects: [String: FindableObject] {
        get { state.placedObjects }
        set { state.placedObjects = newValue }
    }
    
    var placedBoxes: [String: AnchorEntity] {
        get { state.placedBoxes }
        set { state.placedBoxes = newValue }
    }
    
    var objectPlacementTimes: [String: Date] {
        get { state.objectPlacementTimes }
        set { state.objectPlacementTimes = newValue }
    }
    
    var lastSpherePlacementTime: Date? {
        get { state.lastSpherePlacementTime }
        set { state.lastSpherePlacementTime = newValue }
    }
    
    var sphereModeActive: Bool {
        get { state.sphereModeActive }
        set { state.sphereModeActive = newValue }
    }
    
    var objectsInViewport: Set<String> {
        get { state.objectsInViewport }
        set { state.objectsInViewport = newValue }
    }
    
    // MARK: - Internal Properties
    var state: ARCoordinatorState
    var services: ARCoordinatorServices
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    override init() {
        self.state = ARCoordinatorState()
        self.services = ARCoordinatorServices()
        super.init()
    }
    
    // MARK: - Configuration
    func configure(arView: ARView, userLocationManager: UserLocationManager, locationManager: LootBoxLocationManager, geospatialService: ARGeospatialService, groundingService: ARGroundingService, tapHandler: ARTapHandler) {
        print("🔧 [ARCoordinatorCore] configure() called - initializing AR services")
        self.arView = arView
        self.userLocationManager = userLocationManager
        self.locationManager = locationManager
        self.geospatialService = geospatialService
        self.groundingService = groundingService
        self.tapHandler = tapHandler

        // Set up location monitoring
        setupLocationMonitoring()

        // Initialize services after all properties are set
        initializeServices()
        print("✅ [ARCoordinatorCore] Configuration complete - AR services initialized")
    }
    
    // MARK: - Location Monitoring Setup
    private func setupLocationMonitoring() {
        // Subscribe to location updates
        userLocationManager?.$currentLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                guard let self = self, let location = location else { return }
                self.handleLocationUpdate(location)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Location Update Handling
    private func handleLocationUpdate(_ location: CLLocation) {
        guard let locationManager = locationManager,
              let objectPlacer = services.objectPlacement,
              let arView = arView else {
            return
        }
        
        // Get nearby locations and place objects in AR
        let nearbyLocations = locationManager.getNearbyLocations(userLocation: location)
        objectPlacer.checkAndPlaceBoxes(userLocation: location, nearbyLocations: nearbyLocations)
        
        // Update last known user location for services
        services.location?.updateUserLocation(location)
    }
    
    // MARK: - Service Initialization
    private func initializeServices() {
        // Initialize all services here using existing implementations
        services.objectPlacement = ARObjectPlacer(arCoordinator: self, locationManager: locationManager!)
        services.npc = ARNPCService(arView: arView!,
                                      locationManager: locationManager!,
                                  groundingService: groundingService!,
                                  tapHandler: tapHandler!,
                                      conversationNPCBinding: nil)
        services.nfc = NFCService()
        services.location = ARLocationManager(arCoordinator: self)
        services.environment = AREnvironmentService()
        services.state = ARStateManager()
        services.ui = ARUIManager(arCoordinator: self)
        
        // Configure all services
        services.configureAllServices(with: self)
    }
    
    // MARK: - ARSessionDelegate
    private var frameUpdateCount = 0
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Log first few frames to confirm delegate is working
        frameUpdateCount += 1
        if frameUpdateCount <= 3 {
            print("📸 [ARCoordinatorCore] AR frame update #\(frameUpdateCount) received - delegate is working!")
        } else if frameUpdateCount == 4 {
            print("✅ [ARCoordinatorCore] AR frame updates confirmed - future updates will be silent")
        }
        services.handleSessionUpdate(session, frame: frame)
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        services.handleAnchorsAdded(session, anchors: anchors)
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        services.handleAnchorsUpdated(session, anchors: anchors)
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        services.handleAnchorsRemoved(session, anchors: anchors)
    }
    
    // MARK: - ARCoordinatorCoreProtocol Methods
    func showDebugMessage(_ message: String) {
        print("🔍 [DEBUG]: \(message)")
        services.ui?.showDebugOverlay(message)
    }
    
    func playHapticFeedback() {
        AudioServicesPlaySystemSound(1519) // Actuate "Peek" feedback (weak boom)
    }
    
    func scheduleBackgroundTask(_ task: @escaping () -> Void) {
        services.state?.scheduleBackgroundOperation(task)
    }
    
    // MARK: - Cleanup
    func cleanup() {
        services.cleanupAllServices()
        cancellables.removeAll()
    }
    
    // MARK: - Object Management (delegated to services)
    func removeAllPlacedObjects() {
        services.objectPlacement?.removeAllPlacedObjects()
        services.npc?.removeAllNPCs()
    }
    
    deinit {
        cleanup()
    }
}
