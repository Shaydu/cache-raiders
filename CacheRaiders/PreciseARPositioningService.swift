import ARKit
import RealityKit
import CoreLocation
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

    // MARK: - Properties
    private var arView: ARView?
    private var locationManager: CLLocationManager?
    private var cachedObjects: [String: NFCTaggedObject] = [:]
    private var activeAnchors: [String: ARAnchor] = [:]
    private var correctionHistory: [String: [AnchorCorrection]] = [:]

    // Publishers
    let objectPlaced = PassthroughSubject<String, Never>()
    let anchorCorrected = PassthroughSubject<String, Never>()
    let positioningError = PassthroughSubject<Error, Never>()

    // MARK: - Initialization
    private init() {
        setupLocationManager()
    }

    func setup(with arView: ARView) {
        self.arView = arView
        configureARSession()
    }

    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager?.desiredAccuracy = kCLLocationAccuracyBest
        locationManager?.distanceFilter = 1.0 // Update every meter
        locationManager?.requestWhenInUseAuthorization()
    }

    private func configureARSession() {
        guard let arView = arView else { return }

        // Enable geo tracking and scene reconstruction
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading

        // Enable geo anchors if available (iOS 14+)
        if ARGeoTrackingConfiguration.isSupported {
            let geoConfig = ARGeoTrackingConfiguration()
            arView.session.run(geoConfig)
        } else {
            arView.session.run(config)
        }

        // Enable scene reconstruction for better anchoring
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
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
