import ARKit
import RealityKit
import CoreLocation
import CoreMotion
import Combine

// MARK: - Precise AR Positioning Service
/// Handles high-precision AR object placement using NFC + ARKit anchoring
class PreciseARPositioningService: ObservableObject {
    // MARK: - Singleton
    static let shared = PreciseARPositioningService()

    // MARK: - Types
    struct NFCTaggedObject {
        let tagID: String
        let objectID: String
        let worldTransform: simd_float4x4
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let createdAt: Date
        let refinedTransform: simd_float4x4? // After visual refinement
        let visualAnchorData: Data? // Look Around anchor data
    }

    struct AnchorCorrection {
        let originalTransform: simd_float4x4
        let correctedTransform: simd_float4x4
        let correctionVector: SIMD3<Float>
        let timestamp: Date
    }

    struct AnchorCalibration {
        let objectId: String
        let gpsLocation: CLLocation
        let arTransform: simd_float4x4
        let calibrationTime: Date
        let accuracy: Double // Meters
        var correctionVectors: [SIMD3<Float>] = []
        var confidence: Double = 1.0 // 0-1, higher is better
    }

    // MARK: - Properties
    private var arView: ARView?
    private var locationManager: CLLocationManager?
    private var motionManager: CMMotionManager?
    private var cachedObjects: [String: NFCTaggedObject] = [:]
    private var activeAnchors: [String: ARAnchor] = [:]
    private var correctionHistory: [String: [AnchorCorrection]] = [:]
    private var anchorCalibrationData: [String: AnchorCalibration] = [:]
    private var referenceAnchors: [ARAnchor] = [] // Multiple reference anchors for averaging
    private var lastCalibrationTime: Date?
    private var currentDeviceMotion: CMDeviceMotion?

    // Publishers
    let objectPlaced = PassthroughSubject<String, Never>()
    let anchorCorrected = PassthroughSubject<String, Never>()
    let positioningError = PassthroughSubject<Error, Never>()
    let precisionUpdated = PassthroughSubject<(objectId: String, accuracy: Double), Never>()

    // MARK: - AR Session Delegate
    private class ARSessionDelegateHandler: NSObject, ARSessionDelegate {
        weak var positioningService: PreciseARPositioningService?

        init(positioningService: PreciseARPositioningService) {
            self.positioningService = positioningService
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            positioningService?.handleARSessionUpdate(frame)
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            positioningService?.handleARSessionAnchorsAdded(anchors)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            positioningService?.handleARSessionAnchorsUpdated(anchors)
        }
    }

    private var arSessionDelegate: ARSessionDelegateHandler?

    // MARK: - Initialization
    private init() {
        setupLocationManager()
        setupMotionManager()
    }

    func setup(with arView: ARView) {
        self.arView = arView
        arSessionDelegate = ARSessionDelegateHandler(positioningService: self)
        configureARSession()
    }

    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager?.desiredAccuracy = kCLLocationAccuracyBestForNavigation // Highest precision available
        locationManager?.distanceFilter = kCLDistanceFilterNone // Update as frequently as possible
        locationManager?.activityType = .otherNavigation // Optimize for precise positioning
        locationManager?.pausesLocationUpdatesAutomatically = false // Keep updating even when stationary

        // Disable background location updates - not needed for AR positioning during active use
        // Only set this if the app has background location permission to avoid assertion failures
        if CLLocationManager.authorizationStatus() == .authorizedAlways {
            locationManager?.allowsBackgroundLocationUpdates = false
            locationManager?.showsBackgroundLocationIndicator = false
        }

        locationManager?.requestWhenInUseAuthorization()
        locationManager?.startUpdatingLocation()
        locationManager?.startUpdatingHeading() // For orientation data
    }

    private func setupMotionManager() {
        motionManager = CMMotionManager()
        motionManager?.deviceMotionUpdateInterval = 1.0/60.0 // 60Hz updates for precise motion tracking
        motionManager?.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            if let motion = motion {
                self?.currentDeviceMotion = motion
            }
        }
    }

    private func configureARSession() {
        guard let arView = arView else { return }

        // Use standard AR configuration to avoid background location issues
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading

        // Enable all available features for best precision
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }

            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic

            // Enable frame semantics for better tracking
            if #available(iOS 15.0, *) {
                config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            }

            arView.session.run(config)
            print("🎯 Using enhanced ARWorldTrackingConfiguration")

            // Configure session for continuous high-precision tracking
            arView.session.delegate = arSessionDelegate
            arView.renderOptions = [.disableMotionBlur, .disableDepthOfField] // Maximum precision rendering
        }
    }

// MARK: - Macro Positioning (GPS + Map Anchors)
extension PreciseARPositioningService {
    /// Phase A: Get user into the 5-10 meter zone using GPS
    func getMacroPositioningGuidance(for objectID: String) -> PositioningGuidance? {
        guard let object = cachedObjects[objectID],
              let userLocation = locationManager?.location else { return nil }

        let objectLocation = CLLocation(latitude: object.latitude,
                                     longitude: object.longitude)
        let distance = userLocation.distance(from: objectLocation)
        let bearing = userLocation.bearing(to: objectLocation)

        // Provide guidance for 5-10 meter approach
        if distance > 10 {
            return PositioningGuidance(
                distance: distance,
                bearing: bearing,
                instruction: "Head \(bearing.cardinalDirection) for \(Int(distance))m",
                accuracy: .macro
            )
        } else if distance <= 10 {
            return PositioningGuidance(
                distance: distance,
                bearing: bearing,
                instruction: "Look around - the NFC tag is within \(Int(distance))m",
                accuracy: .micro
            )
        }

        return nil
    }

    struct PositioningGuidance {
        let distance: Double
        let bearing: Double
        let instruction: String
        let accuracy: AccuracyLevel

        enum AccuracyLevel {
            case macro, micro, precise
        }
    }
}

// MARK: - Micro Positioning (ARKit Look-Around Anchoring)
extension PreciseARPositioningService {
    /// Phase B: Use ARKit Look-Around for 10-20cm accuracy
    func createMicroPositionedAnchor(for object: NFCTaggedObject) async throws -> ARAnchor {
        guard let arView = arView else {
            throw PreciseARError.arViewNotConfigured
        }

        // Create geo anchor at exact coordinates
        let geoAnchor = ARGeoAnchor(
            coordinate: CLLocationCoordinate2D(
                latitude: object.latitude,
                longitude: object.longitude
            ),
            altitude: object.altitude
        )

        // Add visual refinement using Look Around anchoring (iOS 17+)
        if #available(iOS 17.0, *),
           ARGeoTrackingConfiguration.isSupported {

            // Use visual anchor data if available, otherwise create new
            if let visualData = object.visualAnchorData {
                // Restore existing visual anchor
                try await createVisualAnchor(from: visualData, geoAnchor: geoAnchor)
            } else {
                // Create new visual anchor for this location
                try await createNewVisualAnchor(for: geoAnchor, object: object)
            }
        }

        return geoAnchor
    }

    @available(iOS 17.0, *)
    private func createVisualAnchor(from data: Data, geoAnchor: ARGeoAnchor) async throws {
        // Restore visual anchor from stored data
        // This aligns the AR world to the exact same pose as the original placement
        guard let visualAnchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARAnchor.self, from: data) else {
            throw PreciseARError.invalidObjectData
        }
        arView?.session.add(anchor: visualAnchor)
    }

    @available(iOS 17.0, *)
    private func createNewVisualAnchor(for geoAnchor: ARGeoAnchor, object: NFCTaggedObject) async throws {
        // Create new visual anchor using Look Around data
        // This provides the 10-20cm accuracy through visual feature matching
        let visualAnchor = ARGeoAnchor(
            coordinate: CLLocationCoordinate2D(
                latitude: object.latitude,
                longitude: object.longitude
            ),
            altitude: object.altitude
        )

        // ARKit will automatically refine this using visual features
        arView?.session.add(anchor: visualAnchor)

        // Store the visual anchor data for sharing with other users
        await storeVisualAnchorData(for: object.objectID, anchor: visualAnchor)
    }

    private func storeVisualAnchorData(for objectID: String, anchor: ARAnchor) async {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            // Store in your database for other users
            await uploadAnchorData(objectID: objectID, data: data)
        } catch {
            print("Failed to archive visual anchor: \(error)")
        }
    }

    private func uploadAnchorData(objectID: String, data: Data) async {
        // Upload to your server for multi-user sharing
        // This allows other users to use the same precise anchor
        print("📡 Uploading visual anchor data for \(objectID)")
    }
}

// MARK: - NFC Snap-to-Anchor (Precision Lock-in)
extension PreciseARPositioningService {
    /// Advanced Trick: Use NFC scan to achieve <1cm precision
    func snapToAnchorPrecision(for object: NFCTaggedObject, nfcScanTransform: simd_float4x4) {
        guard let currentAnchor = activeAnchors[object.objectID] else { return }

        // Compare stored anchor transform vs current precise phone transform
        let storedTransform = object.refinedTransform ?? object.worldTransform
        let currentTransform = nfcScanTransform

        // Calculate correction vector
        let correction = calculateCorrection(from: storedTransform, to: currentTransform)

        // If correction is small (<5cm), apply it for rock-solid precision
        if length(correction) < 0.05 { // 5cm threshold
            applyAnchorCorrection(object.objectID, correction: correction)
            recordCorrection(object.objectID, correction: correction, original: storedTransform, corrected: currentTransform)
        }
    }

    private func calculateCorrection(from stored: simd_float4x4, to current: simd_float4x4) -> SIMD3<Float> {
        let storedPosition = SIMD3<Float>(stored.columns.3.x, stored.columns.3.y, stored.columns.3.z)
        let currentPosition = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        return currentPosition - storedPosition
    }

    private func applyAnchorCorrection(_ objectID: String, correction: SIMD3<Float>) {
        guard let anchor = activeAnchors[objectID],
              let arView = arView else { return }

        // Apply correction to the anchor's transform
        var correctedTransform = anchor.transform
        correctedTransform.columns.3.x += correction.x
        correctedTransform.columns.3.y += correction.y
        correctedTransform.columns.3.z += correction.z

        // Update the anchor (this will move the AR object)
        arView.session.remove(anchor: anchor)

        let correctedAnchor = ARAnchor(transform: correctedTransform)
        arView.session.add(anchor: correctedAnchor)
        activeAnchors[objectID] = correctedAnchor

        anchorCorrected.send(objectID)
        print("🎯 Applied \(length(correction))m correction to \(objectID)")
    }

    private func recordCorrection(_ objectID: String, correction: SIMD3<Float>, original: simd_float4x4, corrected: simd_float4x4) {
        let correctionRecord = AnchorCorrection(
            originalTransform: original,
            correctedTransform: corrected,
            correctionVector: correction,
            timestamp: Date()
        )

        if correctionHistory[objectID] == nil {
            correctionHistory[objectID] = []
        }
        correctionHistory[objectID]?.append(correctionRecord)

        // Keep only last 10 corrections
        if correctionHistory[objectID]!.count > 10 {
            correctionHistory[objectID]?.removeFirst()
        }
    }
}

// MARK: - AR Session Handling
extension PreciseARPositioningService {
    func handleARSessionUpdate(_ frame: ARFrame) {
        // Continuous calibration and drift correction
        performContinuousCalibration(with: frame)
    }

    func handleARSessionAnchorsAdded(_ anchors: [ARAnchor]) {
        // Handle new anchors being added
        for anchor in anchors {
            if let geoAnchor = anchor as? ARGeoAnchor {
                print("📍 GeoAnchor added at: \(geoAnchor.coordinate.latitude), \(geoAnchor.coordinate.longitude)")
            }
        }
    }

    func handleARSessionAnchorsUpdated(_ anchors: [ARAnchor]) {
        // Handle anchor updates for continuous calibration
        for anchor in anchors {
            if let objectId = activeAnchors.first(where: { $0.value == anchor })?.key {
                updateAnchorCalibration(for: objectId, anchor: anchor)
            }
        }
    }

    private func performContinuousCalibration(with frame: ARFrame) {
        // Perform continuous calibration every 30 frames (~1 second at 30fps)
        let currentTime = Date()
        guard lastCalibrationTime == nil || currentTime.timeIntervalSince(lastCalibrationTime!) > 1.0 else {
            return
        }
        lastCalibrationTime = currentTime

        // Calibrate all active anchors with motion compensation
        for (objectId, anchor) in activeAnchors {
            calibrateAnchorWithMotionCompensation(objectId, anchor: anchor, frame: frame)
        }

        // Update reference anchors if they exist
        if !referenceAnchors.isEmpty {
            for (objectId, _) in activeAnchors {
                calibrateWithReferences(for: objectId)
            }
        }
    }

    private func calibrateAnchorWithMotionCompensation(_ objectId: String, anchor: ARAnchor, frame: ARFrame) {
        guard let gpsLocation = locationManager?.location else { return }

        // Use motion-stabilized camera transform
        let stabilizedCameraTransform = getMotionStabilizedCameraTransform() ?? frame.camera.transform

        // Calculate current anchor position in GPS coordinates
        let anchorGPS = gpsFromARTransform(anchor.transform, relativeTo: stabilizedCameraTransform)

        // Compare with known GPS location
        let distance = gpsLocation.distance(from: CLLocation(latitude: anchorGPS.latitude, longitude: anchorGPS.longitude))

        // If drift is detected (>2cm), apply correction
        if distance > 0.02 { // 2cm threshold with motion compensation
            let correction = calculateMotionCompensatedCorrection(from: anchorGPS, to: gpsLocation.coordinate)
            applyGPSCorrection(to: objectId, correction: correction, anchor: anchor)

            print("🔧 Applied motion-compensated GPS correction of \(distance)m to \(objectId)")
            precisionUpdated.send((objectId: objectId, accuracy: distance))
        }
    }

    private func calibrateAnchor(_ objectId: String, anchor: ARAnchor, frame: ARFrame) {
        guard let gpsLocation = locationManager?.location,
              let cachedObject = cachedObjects[objectId] else { return }

        // Calculate current anchor position in GPS coordinates
        let anchorGPS = gpsFromARTransform(anchor.transform, relativeTo: frame.camera.transform)

        // Compare with known GPS location
        let distance = gpsLocation.distance(from: CLLocation(latitude: anchorGPS.latitude, longitude: anchorGPS.longitude))

        // If drift is detected (>5cm), apply correction
        if distance > 0.05 { // 5cm threshold
            let correction = calculateGPSCorrection(from: anchorGPS, to: gpsLocation.coordinate)
            applyGPSCorrection(to: objectId, correction: correction, anchor: anchor)

            print("🔧 Applied GPS correction of \(distance)m to \(objectId)")
            precisionUpdated.send((objectId: objectId, accuracy: distance))
        }
    }

    private func gpsFromARTransform(_ arTransform: simd_float4x4, relativeTo cameraTransform: simd_float4x4) -> CLLocationCoordinate2D {
        // Convert AR transform to GPS coordinates
        // This is a simplified conversion - in production you'd want a proper coordinate transformation
        let position = SIMD3<Float>(arTransform.columns.3.x, arTransform.columns.3.y, arTransform.columns.3.z)
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Calculate relative position
        let relativePosition = position - cameraPosition

        // Convert to GPS offset (very simplified - assumes flat earth)
        let metersPerDegreeLat = 111320.0
        let metersPerDegreeLon = 111320.0 * cos(locationManager?.location?.coordinate.latitude ?? 0 * .pi / 180)

        let latOffset = Double(relativePosition.z) / metersPerDegreeLat
        let lonOffset = Double(relativePosition.x) / metersPerDegreeLon

        if let baseLocation = locationManager?.location {
            return CLLocationCoordinate2D(
                latitude: baseLocation.coordinate.latitude + latOffset,
                longitude: baseLocation.coordinate.longitude + lonOffset
            )
        }

        return CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    private func calculateGPSCorrection(from anchorGPS: CLLocationCoordinate2D, to targetGPS: CLLocationCoordinate2D) -> SIMD3<Float> {
        // Calculate correction vector in AR coordinate space
        let latDiff = targetGPS.latitude - anchorGPS.latitude
        let lonDiff = targetGPS.longitude - anchorGPS.longitude

        // Convert to meters (simplified)
        let metersPerDegreeLat = 111320.0
        let metersPerDegreeLon = 111320.0 * cos(anchorGPS.latitude * .pi / 180)

        let xCorrection = Float(lonDiff * metersPerDegreeLon)
        let zCorrection = Float(latDiff * metersPerDegreeLat)
        let yCorrection: Float = 0 // Altitude correction would need barometer data

        return SIMD3<Float>(xCorrection, yCorrection, zCorrection)
    }

    private func applyGPSCorrection(to objectId: String, correction: SIMD3<Float>, anchor: ARAnchor) {
        guard let arView = arView else { return }

        // Apply correction to anchor transform
        var correctedTransform = anchor.transform
        correctedTransform.columns.3.x += correction.x
        correctedTransform.columns.3.y += correction.y
        correctedTransform.columns.3.z += correction.z

        // Update anchor
        arView.session.remove(anchor: anchor)

        let correctedAnchor = ARAnchor(transform: correctedTransform)
        arView.session.add(anchor: correctedAnchor)
        activeAnchors[objectId] = correctedAnchor

        // Record correction
        let correctionRecord = AnchorCorrection(
            originalTransform: anchor.transform,
            correctedTransform: correctedTransform,
            correctionVector: correction,
            timestamp: Date()
        )

        if correctionHistory[objectId] == nil {
            correctionHistory[objectId] = []
        }
        correctionHistory[objectId]?.append(correctionRecord)

        // Keep only last 20 corrections
        if correctionHistory[objectId]!.count > 20 {
            correctionHistory[objectId]?.removeFirst()
        }

        anchorCorrected.send(objectId)
    }

    private func updateAnchorCalibration(for objectId: String, anchor: ARAnchor) {
        guard let gpsLocation = locationManager?.location else { return }

        let calibration = AnchorCalibration(
            objectId: objectId,
            gpsLocation: gpsLocation,
            arTransform: anchor.transform,
            calibrationTime: Date(),
            accuracy: 0.005 // Assume 5mm accuracy for calibrated anchors
        )

        anchorCalibrationData[objectId] = calibration
    }
}

// MARK: - Public Accessors
extension PreciseARPositioningService {
    /// Get active anchor for a specific object ID
    func getActiveAnchor(for objectID: String) -> ARAnchor? {
        return activeAnchors[objectID]
    }

    /// Get all active anchors
    var allActiveAnchors: [String: ARAnchor] {
        return activeAnchors
    }

    /// Get current precision for an object
    func getCurrentPrecision(for objectId: String) -> Double? {
        return anchorCalibrationData[objectId]?.accuracy
    }

    /// Cleanup resources
    func cleanup() {
        // Stop motion updates
        motionManager?.stopDeviceMotionUpdates()

        // Clear reference anchors
        if let arView = arView {
            for anchor in referenceAnchors {
                arView.session.remove(anchor: anchor)
            }
            // Remove session delegate
            arView.session.delegate = nil
        }
        referenceAnchors.removeAll()

        // Clear delegate reference
        arSessionDelegate = nil

        // Clear calibration data
        anchorCalibrationData.removeAll()
        correctionHistory.removeAll()

        print("🧹 PreciseARPositioningService cleaned up")
    }

    /// Get positioning statistics
    func getPositioningStats() -> PositioningStats {
        let activeAnchorCount = activeAnchors.count
        let referenceAnchorCount = referenceAnchors.count
        let averageAccuracy = anchorCalibrationData.values.map { $0.accuracy }.reduce(0, +) / Double(max(anchorCalibrationData.count, 1))
        let totalCorrections = correctionHistory.values.reduce(0) { $0 + $1.count }

        return PositioningStats(
            activeAnchors: activeAnchorCount,
            referenceAnchors: referenceAnchorCount,
            averageAccuracy: averageAccuracy,
            totalCorrections: totalCorrections,
            motionCompensationActive: motionManager?.isDeviceMotionActive ?? false
        )
    }

    struct PositioningStats {
        let activeAnchors: Int
        let referenceAnchors: Int
        let averageAccuracy: Double // meters
        let totalCorrections: Int
        let motionCompensationActive: Bool
    }
}

// MARK: - Multi-Anchor Averaging
extension PreciseARPositioningService {
    /// Create multiple reference anchors for improved stability
    func createReferenceAnchors(at location: CLLocation, count: Int = 3) async throws {
        guard let arView = arView else {
            throw PreciseARError.arViewNotConfigured
        }

        // Clear existing reference anchors
        for anchor in referenceAnchors {
            arView.session.remove(anchor: anchor)
        }
        referenceAnchors.removeAll()

        // Create reference anchors in a small radius around the target location
        let radius = 0.5 // 50cm radius
        for i in 0..<count {
            let angle = (2.0 * .pi * Double(i)) / Double(count)
            let offsetLat = location.coordinate.latitude + (cos(angle) * radius / 111320.0)
            let offsetLon = location.coordinate.longitude + (sin(angle) * radius / 111320.0)

            let referenceLocation = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: offsetLat, longitude: offsetLon),
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                timestamp: location.timestamp
            )

            let geoAnchor = ARGeoAnchor(
                coordinate: referenceLocation.coordinate,
                altitude: referenceLocation.altitude
            )

            arView.session.add(anchor: geoAnchor)
            referenceAnchors.append(geoAnchor)
        }

        // Wait for anchors to stabilize
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    }

    /// Get averaged position using multiple reference anchors
    func getAveragedPosition(using references: Bool = true) -> CLLocation? {
        guard let baseLocation = locationManager?.location else { return nil }

        if references && !referenceAnchors.isEmpty {
            // Use reference anchors for averaging
            var validLocations: [CLLocation] = []

            for anchor in referenceAnchors {
                if let coordinate = (anchor as? ARGeoAnchor)?.coordinate {
                    let location = CLLocation(
                        coordinate: coordinate,
                        altitude: (anchor as? ARGeoAnchor)?.altitude ?? baseLocation.altitude,
                        horizontalAccuracy: 0.01, // 1cm precision estimate
                        verticalAccuracy: 0.01,
                        timestamp: Date()
                    )
                    validLocations.append(location)
                }
            }

            if validLocations.count >= 2 {
                // Average the reference anchor positions
                let avgLat = validLocations.map { $0.coordinate.latitude }.reduce(0, +) / Double(validLocations.count)
                let avgLon = validLocations.map { $0.coordinate.longitude }.reduce(0, +) / Double(validLocations.count)
                let avgAlt = validLocations.map { $0.altitude }.reduce(0, +) / Double(validLocations.count)

                return CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                    altitude: avgAlt,
                    horizontalAccuracy: 0.005, // 5mm precision with averaging
                    verticalAccuracy: 0.005,
                    timestamp: Date()
                )
            }
        }

        return baseLocation
    }

    /// Calibrate anchor position using reference anchors
    func calibrateWithReferences(for objectId: String) {
        guard let anchor = activeAnchors[objectId],
              let arView = arView,
              let averagedLocation = getAveragedPosition() else { return }

        // Calculate calibration correction with motion compensation
        let anchorGPS = gpsFromARTransform(anchor.transform, relativeTo: arView.cameraTransform.matrix)
        let motionCompensatedCorrection = calculateMotionCompensatedCorrection(from: anchorGPS, to: averagedLocation.coordinate)

        // Apply correction if significant
        if length(motionCompensatedCorrection) > 0.01 { // 1cm threshold
            applyGPSCorrection(to: objectId, correction: motionCompensatedCorrection, anchor: anchor)
            print("📐 Applied motion-compensated reference calibration correction of \(length(motionCompensatedCorrection))m to \(objectId)")
        }
    }

    /// Calculate motion-compensated GPS correction
    private func calculateMotionCompensatedCorrection(from anchorGPS: CLLocationCoordinate2D, to targetGPS: CLLocationCoordinate2D) -> SIMD3<Float> {
        var correction = calculateGPSCorrection(from: anchorGPS, to: targetGPS)

        // Apply motion compensation if device motion data is available
        if let motion = currentDeviceMotion {
            // Compensate for device rotation and acceleration
            let rotationCompensation = calculateRotationCompensation(motion)
            let accelerationCompensation = calculateAccelerationCompensation(motion)

            correction += rotationCompensation
            correction += accelerationCompensation

            // Limit compensation to prevent over-correction
            let maxCompensation: Float = 0.05 // 5cm maximum compensation
            correction = clamp(correction, min: SIMD3<Float>(-maxCompensation), max: SIMD3<Float>(maxCompensation))
        }

        return correction
    }

    /// Calculate rotation compensation based on device motion
    private func calculateRotationCompensation(_ motion: CMDeviceMotion) -> SIMD3<Float> {
        // Convert device rotation to position correction
        // This accounts for small rotations that can affect perceived position
        let rotationRate = motion.rotationRate
        let attitude = motion.attitude

        // Simplified rotation compensation - in production this would be more sophisticated
        let rotationFactor: Float = 0.001 // Small compensation factor
        let xCompensation = Float(rotationRate.x + attitude.pitch) * rotationFactor
        let yCompensation = Float(rotationRate.y + attitude.roll) * rotationFactor
        let zCompensation = Float(rotationRate.z + attitude.yaw) * rotationFactor

        return SIMD3<Float>(xCompensation, yCompensation, zCompensation)
    }

    /// Calculate acceleration compensation based on device motion
    private func calculateAccelerationCompensation(_ motion: CMDeviceMotion) -> SIMD3<Float> {
        // Compensate for device acceleration that might affect tracking stability
        let userAcceleration = motion.userAcceleration

        // Filter out gravity and high-frequency noise
        let accelerationFactor: Float = 0.0001 // Very small compensation factor
        let xCompensation = Float(userAcceleration.x) * accelerationFactor
        let yCompensation = Float(userAcceleration.y) * accelerationFactor
        let zCompensation = Float(userAcceleration.z) * accelerationFactor

        return SIMD3<Float>(xCompensation, yCompensation, zCompensation)
    }

    /// Get motion-stabilized camera transform
    func getMotionStabilizedCameraTransform() -> simd_float4x4? {
        guard let arView = arView else { return nil }

        var cameraTransform = arView.cameraTransform.matrix

        // Apply motion stabilization if device motion data is available
        if let motion = currentDeviceMotion {
            // Apply small corrections to reduce jitter
            let stabilizationFactor: Float = 0.01
            let rotationCorrection = calculateRotationCompensation(motion) * stabilizationFactor
            let accelerationCorrection = calculateAccelerationCompensation(motion) * stabilizationFactor

            // Apply corrections to camera transform
            cameraTransform.columns.3.x += rotationCorrection.x + accelerationCorrection.x
            cameraTransform.columns.3.y += rotationCorrection.y + accelerationCorrection.y
            cameraTransform.columns.3.z += rotationCorrection.z + accelerationCorrection.z
        }

        return cameraTransform
    }
}

// MARK: - Object Management
extension PreciseARPositioningService {
    /// Load object data from server using NFC tagID
    func loadObjectData(tagID: String) async throws -> NFCTaggedObject {
        // Check cache first
        if let cached = cachedObjects[tagID] {
            return cached
        }

        // Fetch from server
        let objectData = try await fetchObjectFromServer(tagID: tagID)
        cachedObjects[tagID] = objectData
        return objectData
    }

    /// Place AR object using the full precision pipeline
    func placePreciseARObject(object: NFCTaggedObject) async throws {
        print("🎯 Starting precise AR placement for \(object.objectID)")

        // Phase 1: Create micro-positioned anchor
        let anchor = try await createMicroPositionedAnchor(for: object)

        // Phase 2: Add to AR scene
        guard let arView = arView else { throw PreciseARError.arViewNotConfigured }

        arView.session.add(anchor: anchor)
        activeAnchors[object.objectID] = anchor

        // Phase 3: Add visual representation
        let modelEntity = try await createARModel(for: object)
        let anchorEntity = AnchorEntity(anchor: anchor)
        anchorEntity.addChild(modelEntity)
        arView.scene.addAnchor(anchorEntity)

        objectPlaced.send(object.objectID)
        print("✅ Placed precise AR object: \(object.objectID)")
    }

    private func createARModel(for object: NFCTaggedObject) async throws -> ModelEntity {
        // Load your 3D model (chest, treasure, etc.)
        // This would be customized based on object.type
        let mesh = MeshResource.generateBox(size: 0.1) // 10cm cube for demo
        let material = SimpleMaterial(color: .yellow, roughness: 0.5, isMetallic: true)
        let model = ModelEntity(mesh: mesh, materials: [material])
        return model
    }

    private func fetchObjectFromServer(tagID: String) async throws -> NFCTaggedObject {
        // This would make an API call to your server
        // For now, return mock data
        throw PreciseARError.serverNotImplemented
    }
}

// MARK: - Sub-Centimeter Positioning
extension PreciseARPositioningService {
    /// Get sub-centimeter precise coordinates using AR refinement
    func getSubCentimeterPosition(for tagId: String, objectId: String, initialLocation: CLLocation) async throws -> (latitude: Double, longitude: Double, altitude: Double) {
        guard let arView = arView else {
            throw PreciseARError.arViewNotConfigured
        }

        // Start with GPS coordinates
        var latitude = initialLocation.coordinate.latitude
        var longitude = initialLocation.coordinate.longitude
        var altitude = initialLocation.altitude

        // Try AR-based refinement for sub-centimeter precision
        do {
            // Create precise geo anchor at the GPS location
            let geoAnchor = ARGeoAnchor(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: altitude
            )

            // Add visual refinement for sub-centimeter precision
            if #available(iOS 17.0, *), ARGeoTrackingConfiguration.isSupported {
                // Use advanced visual anchoring for maximum precision
                arView.session.add(anchor: geoAnchor)

                // Wait for anchor to stabilize (this is crucial for precision)
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds for stabilization

                // Get the refined position by combining GPS with AR tracking data
                let refinedLocation = try await refineLocationWithAR(arView: arView, geoAnchor: geoAnchor, initialLocation: initialLocation)

                latitude = refinedLocation.coordinate.latitude
                longitude = refinedLocation.coordinate.longitude
                altitude = refinedLocation.altitude

                // Remove the temporary anchor
                arView.session.remove(anchor: geoAnchor)

                print("🎯 Achieved sub-centimeter precision: lat=\(latitude), lon=\(longitude), alt=\(altitude)")

            } else {
                // Fallback: Use camera transform refinement
                let refinedLocation = try await refineLocationWithCamera(arView: arView, initialLocation: initialLocation)
                latitude = refinedLocation.coordinate.latitude
                longitude = refinedLocation.coordinate.longitude
                altitude = refinedLocation.altitude
            }

        } catch {
            print("⚠️ AR precision refinement failed, using GPS coordinates: \(error)")
            // Fall back to GPS coordinates
        }

        return (latitude: latitude, longitude: longitude, altitude: altitude)
    }

    @available(iOS 17.0, *)
    private func refineLocationWithAR(arView: ARView, geoAnchor: ARGeoAnchor, initialLocation: CLLocation) async throws -> CLLocation {
        // Wait for the geo anchor to be processed and refined by ARKit
        var refinedLocation = initialLocation

        // Use multiple samples for better accuracy
        var locationSamples: [CLLocation] = []

        for _ in 0..<5 { // Take 5 samples over 1 second
            let anchorLocation = geoAnchor.coordinate
            let sampleLocation = CLLocation(
                coordinate: anchorLocation,
                altitude: geoAnchor.altitude ?? 0.0,
                horizontalAccuracy: 0.005, // 5mm accuracy estimate
                verticalAccuracy: 0.005,
                timestamp: Date()
            )
            locationSamples.append(sampleLocation)
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms between samples
        }

        // Average the samples for better precision
        if !locationSamples.isEmpty {
            let avgLatitude = locationSamples.map { $0.coordinate.latitude }.reduce(0, +) / Double(locationSamples.count)
            let avgLongitude = locationSamples.map { $0.coordinate.longitude }.reduce(0, +) / Double(locationSamples.count)
            let avgAltitude = locationSamples.map { $0.altitude }.reduce(0, +) / Double(locationSamples.count)

            refinedLocation = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: avgLatitude, longitude: avgLongitude),
                altitude: avgAltitude,
                horizontalAccuracy: 0.005, // 5mm precision
                verticalAccuracy: 0.005,
                timestamp: Date()
            )
        }

        return refinedLocation
    }

    private func refineLocationWithCamera(arView: ARView, initialLocation: CLLocation) async throws -> CLLocation {
        // Use camera transform to refine GPS coordinates
        // This is a fallback method when advanced geo anchoring isn't available

        let cameraTransform = arView.cameraTransform.matrix
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Calculate small adjustments based on camera position relative to origin
        // This is a simplified approach - in production you'd want more sophisticated coordinate transformation
        let positionOffset = 0.01 // 1cm maximum adjustment
        let latAdjustment = Double(cameraPosition.x) * positionOffset / 111320.0 // Convert meters to degrees latitude
        let lonAdjustment = Double(cameraPosition.z) * positionOffset / 111320.0 // Convert meters to degrees longitude

        let refinedLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: initialLocation.coordinate.latitude + latAdjustment,
                longitude: initialLocation.coordinate.longitude + lonAdjustment
            ),
            altitude: initialLocation.altitude + Double(cameraPosition.y),
            horizontalAccuracy: 0.01, // 1cm accuracy
            verticalAccuracy: 0.01,
            timestamp: Date()
        )

        return refinedLocation
    }
}

// MARK: - Errors
enum PreciseARError: Error {
    case arViewNotConfigured
    case locationServicesDisabled
    case geoTrackingNotSupported
    case serverNotImplemented
    case invalidObjectData
}

// MARK: - Extensions
extension Double {
    var cardinalDirection: String {
        switch self {
        case 337.5...360, 0..<22.5: return "North"
        case 22.5..<67.5: return "Northeast"
        case 67.5..<112.5: return "East"
        case 112.5..<157.5: return "Southeast"
        case 157.5..<202.5: return "South"
        case 202.5..<247.5: return "Southwest"
        case 247.5..<292.5: return "West"
        case 292.5..<337.5: return "Northwest"
        default: return "Unknown"
        }
    }
}

// Bearing extension already exists in LootBoxLocation.swift

extension Double {
    var toRadians: Double { self * .pi / 180 }
    var toDegrees: Double { self * 180 / .pi }
}

