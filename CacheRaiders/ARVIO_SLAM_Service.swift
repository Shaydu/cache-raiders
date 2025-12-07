import Foundation
import RealityKit
import ARKit
import CoreLocation
import CoreMotion
import Combine

// MARK: - AR VIO/SLAM Enhancement Service
/// Advanced service that enhances AR tracking stability using VIO (Visual Inertial Odometry)
/// and SLAM (Simultaneous Localization and Mapping) techniques
class ARVIO_SLAM_Service: ObservableObject {

    // MARK: - Properties

    @Published var trackingQuality: Double = 0.0
    @Published var vioConfidence: Double = 0.0
    @Published var slamMapPoints: Int = 0

    private weak var arView: ARView?
    private weak var arCoordinator: ARCoordinator?

    // VIO (Visual Inertial Odometry) components
    private let motionManager = CMMotionManager()
    private var inertialDataBuffer: [CMDeviceMotion] = []
    private var vioProcessor: VIOProcessor?

    // SLAM (Simultaneous Localization and Mapping) components
    private var slamMap: SLAMMap?
    private var featureTracker: FeatureTracker?
    private var poseGraph: PoseGraph?

    // Enhanced tracking
    private var trackingStateHistory: [ARCamera.TrackingState] = []
    private var frameProcessingTimer: Timer?
    private var lastFrameTimestamp: TimeInterval = 0.0 // Track timestamp instead of retaining frame

    // Stabilization
    private var stabilizationTransforms: [String: simd_float4x4] = [:]
    private var driftCompensation: [String: SIMD3<Float>] = [:]

    // MARK: - Initialization

    init(arView: ARView?, arCoordinator: ARCoordinator?) {
        self.arView = arView
        self.arCoordinator = arCoordinator

        initializeVIOComponents()
        initializeSLAMComponents()
        setupFrameProcessing()
        startInertialDataCollection()

        print("🎯 ARVIO_SLAM_Service initialized")
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        frameProcessingTimer?.invalidate()
    }

    // MARK: - VIO (Visual Inertial Odometry) Implementation

    private func initializeVIOComponents() {
        vioProcessor = VIOProcessor()
        print("📱 VIO processor initialized")
    }

    private func startInertialDataCollection() {
        guard motionManager.isDeviceMotionAvailable else {
            print("⚠️ Device motion not available for VIO")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60Hz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            if let error = error {
                print("❌ Motion data error: \(error.localizedDescription)")
                return
            }

            if let motion = motion {
                self?.processInertialData(motion)
            }
        }

        print("📱 Started inertial data collection for VIO")
    }

    private func processInertialData(_ motion: CMDeviceMotion) {
        // Buffer inertial data for VIO processing
        inertialDataBuffer.append(motion)

        // Keep only recent data (last 2 seconds at 60Hz = 120 samples)
        if inertialDataBuffer.count > 120 {
            inertialDataBuffer.removeFirst()
        }

        // Update VIO confidence based on data quality
        updateVIOConfidence()

        // Process VIO data if we have sufficient samples
        if inertialDataBuffer.count >= 30 { // 0.5 seconds of data
            vioProcessor?.processInertialData(inertialDataBuffer)
        }
    }

    private func updateVIOConfidence() {
        guard !inertialDataBuffer.isEmpty else {
            vioConfidence = 0.0
            return
        }

        let recentData = inertialDataBuffer.suffix(30) // Last 0.5 seconds

        // Calculate confidence based on data consistency and sensor quality
        let accelerometerMagnitudes = recentData.map { sqrt($0.userAcceleration.x*$0.userAcceleration.x + $0.userAcceleration.y*$0.userAcceleration.y + $0.userAcceleration.z*$0.userAcceleration.z) }
        let gyroMagnitudes = recentData.map { sqrt($0.rotationRate.x*$0.rotationRate.x + $0.rotationRate.y*$0.rotationRate.y + $0.rotationRate.z*$0.rotationRate.z) }

        let accelVariance = variance(accelerometerMagnitudes)
        let gyroVariance = variance(gyroMagnitudes)

        // Lower variance indicates more stable measurements (higher confidence)
        let accelConfidence = max(0, 1.0 - accelVariance * 1000) // Scale variance appropriately
        let gyroConfidence = max(0, 1.0 - gyroVariance * 1000)

        vioConfidence = (accelConfidence + gyroConfidence) / 2.0
    }

    // MARK: - SLAM (Simultaneous Localization and Mapping) Implementation

    private func initializeSLAMComponents() {
        slamMap = SLAMMap()
        featureTracker = FeatureTracker()
        poseGraph = PoseGraph()

        print("🗺️ SLAM components initialized")
    }

    private func setupFrameProcessing() {
        // Reduced from 30fps to 10fps to reduce CPU load and prevent camera freezing
        frameProcessingTimer = Timer.scheduledTimer(withTimeInterval: 1.0/10.0, repeats: true) { [weak self] _ in
            self?.processCurrentFrame()
        }
    }

    private func processCurrentFrame() {
        guard let frame = arView?.session.currentFrame else { return }

        // Prevent processing the same frame multiple times by checking timestamp
        let currentTimestamp = frame.timestamp
        guard currentTimestamp > lastFrameTimestamp else { return }
        lastFrameTimestamp = currentTimestamp

        // Extract features for SLAM
        processSLAMFeatures(frame)

        // Update tracking quality
        updateTrackingQuality(frame)

        // Perform pose optimization if needed
        optimizeSLAMPose()
    }

    private func processSLAMFeatures(_ frame: ARFrame) {
        guard let featureTracker = featureTracker,
              let slamMap = slamMap else { return }

        // Extract feature points from the frame
        if let featurePoints = frame.rawFeaturePoints {
            let features = featurePoints.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }

            // Track features across frames
            featureTracker.trackFeatures(features, in: frame)

            // Add new landmarks to SLAM map
            slamMap.addLandmarks(featureTracker.newLandmarks)

            slamMapPoints = slamMap.landmarkCount
        }
    }

    private func updateTrackingQuality(_ frame: ARFrame) {
        let camera = frame.camera

        // Track tracking state history
        trackingStateHistory.append(camera.trackingState)
        if trackingStateHistory.count > 10 {
            trackingStateHistory.removeFirst()
        }

        // Calculate quality based on recent tracking states
        let normalStates = trackingStateHistory.filter { state in
            if case .normal = state { return true }
            return false
        }.count

        let qualityFromTracking = Double(normalStates) / Double(trackingStateHistory.count)

        // Factor in feature point count
        let featureCount = frame.rawFeaturePoints?.points.count ?? 0
        let qualityFromFeatures = min(Double(featureCount) / 500.0, 1.0)

        // Combine factors
        trackingQuality = (qualityFromTracking + qualityFromFeatures) / 2.0
    }

    private func optimizeSLAMPose() {
        guard let poseGraph = poseGraph,
              let slamMap = slamMap,
              poseGraph.needsOptimization else { return }

        // Perform pose graph optimization for SLAM
        let optimizedPoses = poseGraph.optimize()

        // Apply pose corrections to stabilize AR objects
        applyPoseCorrections(optimizedPoses)

        print("🔧 Applied SLAM pose optimization")
    }

    // MARK: - Drift Prevention and Stabilization

    /// Applies stabilization transform to an AR object
    func stabilizeObject(_ objectId: String, currentTransform: simd_float4x4) -> simd_float4x4 {
        // Get stabilization correction
        let correction = stabilizationTransforms[objectId] ?? matrix_identity_float4x4

        // Apply VIO-based stabilization if available
        if let vioCorrection = vioProcessor?.getStabilizationCorrection(),
           isValidTransform(vioCorrection) {
            let stabilizedTransform = currentTransform * correction * vioCorrection

            // Validate the result of matrix multiplication to prevent NaN propagation
            if isValidTransform(stabilizedTransform) {
                stabilizationTransforms[objectId] = stabilizedTransform
                return stabilizedTransform
            } else {
                print("⚠️ VIO/SLAM: Matrix multiplication produced invalid transform, using original")
            }
        }

        // Fallback to basic stabilization
        let fallbackTransform = currentTransform * correction

        // Validate fallback result too
        if isValidTransform(fallbackTransform) {
            return fallbackTransform
        } else {
            print("⚠️ VIO/SLAM: Fallback stabilization produced invalid transform, using current")
            return currentTransform
        }
    }

    /// Compensates for drift in object positioning
    func compensateDrift(for objectId: String, currentPosition: SIMD3<Float>) -> SIMD3<Float> {
        let driftCompensation = self.driftCompensation[objectId] ?? SIMD3<Float>(0, 0, 0)

        // Apply SLAM-based drift compensation
        if let slamCorrection = slamMap?.getDriftCorrection(for: currentPosition),
           isValidVector(slamCorrection) {
            let compensatedPosition = currentPosition + driftCompensation + slamCorrection

            // Validate result to prevent NaN propagation
            if isValidVector(compensatedPosition) {
                return compensatedPosition
            } else {
                print("⚠️ VIO/SLAM: Drift compensation produced invalid position, using current")
                return currentPosition
            }
        }

        let fallbackPosition = currentPosition + driftCompensation

        // Validate fallback result
        if isValidVector(fallbackPosition) {
            return fallbackPosition
        } else {
            print("⚠️ VIO/SLAM: Fallback drift compensation produced invalid position, using current")
            return currentPosition
        }
    }

    /// Applies pose corrections from SLAM optimization
    private func applyPoseCorrections(_ optimizedPoses: [String: simd_float4x4]) {
        for (objectId, optimizedPose) in optimizedPoses {
            stabilizationTransforms[objectId] = optimizedPose
        }
    }

    // MARK: - Enhanced AR Session Configuration

    /// Gets enhanced AR configuration with VIO/SLAM optimizations
    func getEnhancedARConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()

        // Enable plane detection for SLAM
        configuration.planeDetection = [.horizontal, .vertical]

        // Enable scene reconstruction for better SLAM
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            print("✅ Scene reconstruction enabled for SLAM")
        }

        // Enable frame semantics for better feature extraction
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            print("✅ Scene depth enabled for SLAM")
        }

        // Configure for high-frequency tracking
        configuration.isAutoFocusEnabled = true

        return configuration
    }

    // MARK: - Integration with AR Coordinator

    /// Processes frame data for VIO/SLAM enhancement
    func processFrameForEnhancement(_ frame: ARFrame) {
        // Update VIO with camera data
        vioProcessor?.processCameraData(frame)

        // Update SLAM with new frame
        featureTracker?.processFrame(frame)

        // Check for tracking degradation and apply corrections
        if case .limited = frame.camera.trackingState {
            applyTrackingRecovery()
        }
    }

    /// Applies recovery measures when tracking is limited
    private func applyTrackingRecovery() {
        print("🔄 Applying VIO/SLAM tracking recovery")

        // Use inertial data to maintain pose estimation
        if let inertialPose = vioProcessor?.getInertialPose() {
            // Apply inertial stabilization
            applyInertialStabilization(inertialPose)
        }

        // Use SLAM map for relocalization
        if let slamRelocalization = slamMap?.attemptRelocalization() {
            applySLAMRelocalization(slamRelocalization)
        }
    }

    private func applyInertialStabilization(_ inertialPose: simd_float4x4) {
        // Validate transform before applying to prevent NaN issues
        guard isValidTransform(inertialPose) else {
            print("⚠️ Skipping inertial stabilization - invalid transform")
            return
        }

        // Apply inertial pose corrections to all tracked objects
        for (objectId, _) in stabilizationTransforms {
            stabilizationTransforms[objectId] = inertialPose
        }

        print("📱 Applied inertial stabilization")
    }

    private func applySLAMRelocalization(_ relocalizationPose: simd_float4x4) {
        // Validate transform before applying to prevent NaN issues
        guard isValidTransform(relocalizationPose) else {
            print("⚠️ Skipping SLAM relocalization - invalid transform")
            return
        }

        // Apply SLAM-based relocalization
        for (objectId, _) in stabilizationTransforms {
            stabilizationTransforms[objectId] = relocalizationPose
        }

        print("🗺️ Applied SLAM relocalization")
    }

    /// Check if a transform matrix contains valid (non-NaN, non-infinite) values
    private func isValidTransform(_ transform: simd_float4x4) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 {
                let value = transform[column][row]
                if value.isNaN || value.isInfinite {
                    return false
                }
            }
        }
        return true
    }

    /// Check if a vector contains valid (non-NaN, non-infinite) values
    private func isValidVector(_ vector: SIMD3<Float>) -> Bool {
        return !vector.x.isNaN && !vector.x.isInfinite &&
               !vector.y.isNaN && !vector.y.isInfinite &&
               !vector.z.isNaN && !vector.z.isInfinite
    }

    // MARK: - Diagnostics

    func getVIO_SLAM_Diagnostics() -> [String: Any] {
        return [
            "trackingQuality": trackingQuality,
            "vioConfidence": vioConfidence,
            "slamMapPoints": slamMapPoints,
            "inertialDataBufferSize": inertialDataBuffer.count,
            "stabilizedObjects": stabilizationTransforms.count,
            "featureTrackerActive": featureTracker != nil,
            "poseGraphNeedsOptimization": poseGraph?.needsOptimization ?? false
        ]
    }

    // MARK: - Utility Functions

    private func variance(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let squaredDifferences = values.map { pow($0 - mean, 2) }
        return squaredDifferences.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Supporting Classes

class VIOProcessor {
    private var inertialHistory: [CMDeviceMotion] = []
    private var cameraTransforms: [simd_float4x4] = [] // Store only transforms, not entire frames
    private var currentPose: simd_float4x4 = matrix_identity_float4x4

    func processInertialData(_ data: [CMDeviceMotion]) {
        inertialHistory = data
        updatePoseEstimation()
    }

    func processCameraData(_ frame: ARFrame) {
        // Store only the camera transform, not the entire frame
        cameraTransforms.append(frame.camera.transform)
        if cameraTransforms.count > 30 { // Keep last 30 transforms
            cameraTransforms.removeFirst()
        }
        updatePoseEstimation()
    }

    private func updatePoseEstimation() {
        // Simplified VIO pose estimation
        // In a real implementation, this would use proper VIO algorithms
        // combining visual features with inertial measurements

        guard !inertialHistory.isEmpty && !cameraTransforms.isEmpty else { return }

        // Use latest camera transform as base pose
        let latestTransform = cameraTransforms.last!

        // Validate transform before using it
        if isValidTransform(latestTransform) {
            currentPose = latestTransform
        } else {
            print("⚠️ VIO Processor: Rejecting invalid camera transform")
        }
    }

    /// Check if a transform matrix contains valid (non-NaN, non-infinite) values
    private func isValidTransform(_ transform: simd_float4x4) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 {
                let value = transform[column][row]
                if value.isNaN || value.isInfinite {
                    return false
                }
            }
        }
        return true
    }

    /// Check if a vector contains valid (non-NaN, non-infinite) values
    private func isValidVector(_ vector: SIMD3<Float>) -> Bool {
        return !vector.x.isNaN && !vector.x.isInfinite &&
               !vector.y.isNaN && !vector.y.isInfinite &&
               !vector.z.isNaN && !vector.z.isInfinite
    }

    func getStabilizationCorrection() -> simd_float4x4? {
        // Return stabilization correction based on VIO data
        return currentPose
    }

    func getInertialPose() -> simd_float4x4? {
        return currentPose
    }
}

class SLAMMap {
    private var landmarks: [SIMD3<Float>] = []
    private var landmarkDescriptors: [[Float]] = []

    var landmarkCount: Int { landmarks.count }

    func addLandmarks(_ newLandmarks: [SIMD3<Float>]) {
        landmarks.append(contentsOf: newLandmarks)
    }

    func getDriftCorrection(for position: SIMD3<Float>) -> SIMD3<Float>? {
        // Simplified drift correction based on nearest landmarks
        guard !landmarks.isEmpty else { return nil }

        let nearestLandmark = landmarks.min { landmark1, landmark2 in
            let dist1 = simd_length(landmark1 - position)
            let dist2 = simd_length(landmark2 - position)
            return dist1 < dist2
        }

        if let nearest = nearestLandmark {
            let correction = nearest - position
            return correction * 0.1 // 10% correction
        }

        return nil
    }

    func attemptRelocalization() -> simd_float4x4? {
        // Simplified relocalization - in real SLAM this would be much more complex
        return matrix_identity_float4x4
    }
}

class FeatureTracker {
    private var trackedFeatures: [CGPoint] = []
    var newLandmarks: [SIMD3<Float>] = []

    func trackFeatures(_ features: [CGPoint], in frame: ARFrame) {
        // Simplified feature tracking
        trackedFeatures = features

        // Convert some features to 3D landmarks using depth if available
        if let sceneDepth = frame.sceneDepth {
            for feature in features.prefix(10) { // Process first 10 features
                if let depth = getDepthAtPoint(feature, from: sceneDepth) {
                    let camera = frame.camera
                    if let ray = camera.unprojectPoint(feature, ontoPlane: camera.transform * matrix_identity_float4x4, orientation: .portrait, viewportSize: CGSize(width: 1920, height: 1080)) {
                        let landmark3D = SIMD3<Float>(Float(ray.x), Float(ray.y), Float(ray.z)) * depth
                        newLandmarks.append(landmark3D)
                    }
                }
            }
        }
    }

    private func getDepthAtPoint(_ point: CGPoint, from sceneDepth: ARDepthData) -> Float? {
        // Simplified depth extraction
        return 1.0 // Placeholder
    }

    func processFrame(_ frame: ARFrame) {
        // Process frame for feature tracking
        newLandmarks.removeAll()
    }
}

class PoseGraph {
    private var poses: [String: simd_float4x4] = [:]
    private var constraints: [(String, String, simd_float4x4)] = []
    var needsOptimization: Bool = false

    func addPose(_ poseId: String, pose: simd_float4x4) {
        poses[poseId] = pose
        needsOptimization = true
    }

    func addConstraint(from: String, to: String, relativePose: simd_float4x4) {
        constraints.append((from, to, relativePose))
        needsOptimization = true
    }

    func optimize() -> [String: simd_float4x4] {
        // Simplified pose graph optimization
        // In a real implementation, this would use proper graph optimization algorithms

        needsOptimization = false
        return poses
    }
}