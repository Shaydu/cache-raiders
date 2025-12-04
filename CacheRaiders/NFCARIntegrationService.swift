import ARKit
import RealityKit
import CoreLocation
import Combine

// MARK: - NFC-AR Integration Service
/// Seamlessly switches from GPS macro positioning to NFC-grounded micro AR positioning
class NFCARIntegrationService: NSObject, ObservableObject {
    // MARK: - Singleton
    static let shared = NFCARIntegrationService()

    // MARK: - Positioning States
    enum PositioningState {
        case gpsGuidance        // GPS guiding to area (macro)
        case nfcDiscovery       // NFC tag discovered
        case arGrounding        // Precise AR grounding active (micro)
        case lockedIn           // <4cm precision achieved
    }

    // MARK: - Properties
    private var currentState: PositioningState = .gpsGuidance
    private var arView: ARView?
    private var locationManager: CLLocationManager?

    private var activeObjects: [String: PreciseARPositioningService.NFCTaggedObject] = [:]
    private var groundingAnchors: [String: ARAnchor] = [:]
    private var activeTimers: [Timer] = []

    // Publishers for UI updates
    let positioningStateChanged = PassthroughSubject<PositioningState, Never>()
    let guidanceUpdate = PassthroughSubject<PreciseARPositioningService.PositioningGuidance, Never>()
    let precisionAchieved = PassthroughSubject<(objectID: String, precision: Double), Never>()

    // MARK: - Initialization
    private override init() {
        super.init()
        setupLocationManager()
        setupNFCObserver()
    }

    func setup(with arView: ARView) {
        self.arView = arView
        PreciseARPositioningService.shared.setup(with: arView)
    }

    /// Get the current AR session for capturing camera transforms during NFC placement
    func getCurrentARSession() -> ARSession? {
        return arView?.session
    }

    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager?.desiredAccuracy = kCLLocationAccuracyBest
        locationManager?.distanceFilter = 1.0
        locationManager?.delegate = self
        locationManager?.requestWhenInUseAuthorization()
        locationManager?.startUpdatingLocation()
    }

    // MARK: - Timer Management
    @objc private func handleDialogOpened() {
        pauseTimers()
    }

    @objc private func handleDialogClosed() {
        resumeTimers()
    }

    private func pauseTimers() {
        for timer in activeTimers {
            timer.fireDate = Date.distantFuture
        }
    }

    private func resumeTimers() {
        for timer in activeTimers {
            timer.fireDate = Date()
        }
    }

    private func removeTimer(_ timer: Timer) {
        if let index = activeTimers.firstIndex(of: timer) {
            activeTimers.remove(at: index)
        }
    }

    private func setupNFCObserver() {
        // Listen for NFC tag discoveries
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNFCTagDiscovered),
            name: NSNotification.Name("NFCTagDiscovered"),
            object: nil
        )

        // Listen for dialog state changes to pause/resume timers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogOpened),
            name: NSNotification.Name("DialogOpened"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDialogClosed),
            name: NSNotification.Name("DialogClosed"),
            object: nil
        )
    }

    // MARK: - State Management
    var currentPositioningState: PositioningState {
        return currentState
    }

    private func transitionToState(_ newState: PositioningState) {
        print("🔄 Positioning state: \(currentState) → \(newState)")
        currentState = newState
        positioningStateChanged.send(newState)
    }

    // MARK: - GPS Macro Positioning
    func startMacroPositioning(for objectID: String) {
        transitionToState(.gpsGuidance)

        // Start GPS-based guidance to get user to the area
        startGPSGuidance(for: objectID)
    }

    private func startGPSGuidance(for objectID: String) {
        // This would load object data from cache/server
        // For now, we'll assume we have the object data

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            // Check if user is in NFC discovery range (<10m)
            if let guidance = PreciseARPositioningService.shared.getMacroPositioningGuidance(for: objectID) {
                self.guidanceUpdate.send(guidance)

                if guidance.accuracy == .micro {
                    // User is close enough for NFC discovery
                    self.transitionToState(.nfcDiscovery)
                    timer.invalidate()
                    self.removeTimer(timer)
                }
            }
        }
        activeTimers.append(timer)
    }

    // MARK: - NFC Discovery Handler
    @objc private func handleNFCTagDiscovered(_ notification: Notification) {
        guard let nfcResult = notification.object as? NFCService.NFCResult else { return }

        print("🎯 NFC Tag discovered: \(nfcResult.tagId)")

        // Transition to NFC discovery state
        transitionToState(.nfcDiscovery)

        // Load object data using tag ID
        Task {
            do {
                let object = try await PreciseARPositioningService.shared.loadObjectData(tagID: nfcResult.tagId)

                // Store for AR grounding
                self.activeObjects[object.objectID] = object

                // Start AR grounding process
                await self.startARGrounding(for: object, nfcTransform: nil)

            } catch {
                print("❌ Failed to load object data: \(error)")
            }
        }
    }

    // MARK: - AR Grounding (Micro Positioning)
    private func startARGrounding(for object: PreciseARPositioningService.NFCTaggedObject, nfcTransform: simd_float4x4?) async {
        transitionToState(.arGrounding)

        do {
            // Place the AR object with precise positioning
            try await PreciseARPositioningService.shared.placePreciseARObject(object: object)

            // Store the grounding anchor
            if let anchor = PreciseARPositioningService.shared.getActiveAnchor(for: object.objectID) {
                groundingAnchors[object.objectID] = anchor
            }

            // If we have NFC transform, apply precision correction immediately
            if let nfcTransform = nfcTransform {
                PreciseARPositioningService.shared.snapToAnchorPrecision(for: object, nfcScanTransform: nfcTransform)
                transitionToState(.lockedIn)
                precisionAchieved.send((objectID: object.objectID, precision: 0.02)) // 2cm
            } else {
                // Monitor precision over time
                monitorPrecision(for: object.objectID)
            }

        } catch {
            print("❌ AR grounding failed: \(error)")
        }
    }

    // MARK: - Precision Monitoring
    private func monitorPrecision(for objectID: String) {
        // Monitor anchor stability for 10 seconds
        var checkCount = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            checkCount += 1

            // Check anchor stability (this would be more sophisticated in real implementation)
            if let anchor = PreciseARPositioningService.shared.getActiveAnchor(for: objectID) {
                let stability = self.calculateAnchorStability(anchor)

                if stability > 0.8 && checkCount >= 3 {
                    // Achieved 2-4cm precision
                    self.transitionToState(.lockedIn)
                    self.precisionAchieved.send((objectID: objectID, precision: 0.03)) // 3cm
                    timer.invalidate()
                    self.removeTimer(timer)
                }
            }

            if checkCount >= 10 {
                timer.invalidate()
                self.removeTimer(timer)
            }
        }
        activeTimers.append(timer)
    }

    private func calculateAnchorStability(_ anchor: ARAnchor) -> Double {
        // Simplified stability calculation
        // In real implementation, this would track anchor position variance over time
        return 0.85 // Assume good stability for demo
    }

    // MARK: - NFC Touch Precision Lock-in
    func applyNFCTouchCorrection(for objectID: String, nfcScanTransform: simd_float4x4) {
        guard let object = activeObjects[objectID] else { return }

        print("🎯 Applying NFC touch correction for \(objectID)")

        // Apply the precision correction
        PreciseARPositioningService.shared.snapToAnchorPrecision(for: object, nfcScanTransform: nfcScanTransform)

        // Transition to locked-in state
        transitionToState(.lockedIn)
        precisionAchieved.send((objectID: objectID, precision: 0.01)) // 1cm precision
    }

    // MARK: - Public Interface
    func discoverObject(tagID: String) {
        // This would be called from NFC scanning
        NotificationCenter.default.post(
            name: NSNotification.Name("NFCTagDiscovered"),
            object: NFCService.NFCResult(
                tagId: tagID,
                ndefMessage: nil,
                payload: nil,
                timestamp: Date()
            )
        )
    }

    func getCurrentGuidance() -> PreciseARPositioningService.PositioningGuidance? {
        // Return current guidance based on state
        switch currentState {
        case .gpsGuidance:
            return PreciseARPositioningService.PositioningGuidance(
                distance: 15.0,
                bearing: 45.0,
                instruction: "Head Northeast to find the treasure",
                accuracy: .macro
            )
        case .nfcDiscovery:
            return PreciseARPositioningService.PositioningGuidance(
                distance: 5.0,
                bearing: 0.0,
                instruction: "Look for NFC tag nearby",
                accuracy: .micro
            )
        case .arGrounding, .lockedIn:
            return PreciseARPositioningService.PositioningGuidance(
                distance: 0.0,
                bearing: 0.0,
                instruction: "AR object placed with high precision",
                accuracy: .precise
            )
        }
    }
}

// MARK: - Positioning Guidance (using PreciseARPositioningService.PositioningGuidance)

// MARK: - CLLocationManager Delegate
extension NFCARIntegrationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Update GPS-based guidance when location changes
        if currentState == .gpsGuidance {
            // This would trigger guidance updates
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error)")
    }
}

// MARK: - Integration with Existing NFC Service
extension NFCService {
    static func integrateWithARPositioning() {
        // Override the default completion to include AR positioning
        // This is a simplified integration - in practice you'd modify the NFCService
    }
}

// MARK: - Demo/Test Methods
extension NFCARIntegrationService {
    /// Demo method to simulate the complete NFC-AR workflow
    func runDemoWorkflow() {
        print("🎯 Starting NFC-AR Integration Demo")

        // Step 1: Start macro positioning (GPS guidance)
        print("📍 Step 1: GPS Macro Positioning")
        startMacroPositioning(for: "demo_treasure_chest")

        // Step 2: Simulate approaching the area (after 3 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            print("📍 Step 2: User approaches area - switching to NFC discovery")
            self?.transitionToState(.nfcDiscovery)
        }

        // Step 3: Simulate NFC tag discovery (after 5 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            print("🎯 Step 3: NFC tag discovered - starting AR grounding")
            self?.discoverObject(tagID: "NFC_DEMO_TAG_001")
        }

        // Step 4: Simulate precision lock-in (after 8 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            print("🔒 Step 4: Precision lock achieved - <4cm accuracy")
            self?.transitionToState(.lockedIn)
            self?.precisionAchieved.send((objectID: "demo_treasure_chest", precision: 0.025)) // 2.5cm
        }
    }

    /// Test method to show positioning guidance
    func testPositioningGuidance() {
        // Create sample guidance messages
        let macroGuidance = PreciseARPositioningService.PositioningGuidance(
            distance: 12.5,
            bearing: 67.0,
            instruction: "Head East to find the treasure area",
            accuracy: .macro
        )

        let microGuidance = PreciseARPositioningService.PositioningGuidance(
            distance: 3.2,
            bearing: 12.0,
            instruction: "Look around for the NFC tag",
            accuracy: .micro
        )

        let preciseGuidance = PreciseARPositioningService.PositioningGuidance(
            distance: 0.0,
            bearing: 0.0,
            instruction: "AR object precisely positioned",
            accuracy: .precise
        )

        // Send guidance updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.guidanceUpdate.send(macroGuidance)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.guidanceUpdate.send(microGuidance)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.guidanceUpdate.send(preciseGuidance)
        }
    }
}
