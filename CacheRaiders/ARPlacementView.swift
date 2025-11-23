import SwiftUI
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Placement View
struct ARPlacementView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedObject: LootBoxLocation?
    @State private var selectedObjectType: LootBoxType = .chalice
    @State private var isPlacingNew = false
    @State private var showObjectSelector = true
    @State private var crosshairPosition: CGPoint = .zero
    @State private var placementMode: PlacementMode = .selecting
    
    enum PlacementMode {
        case selecting
        case placing
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                if placementMode == .selecting {
                    // Object selection view
                    VStack(spacing: 16) {
                        Text("Select an object to move, or create new")
                            .font(.headline)
                            .padding()
                        
                        // List of existing objects
                        List {
                            Section("Existing Objects") {
                                ForEach(locationManager.locations.sorted(by: { $0.name < $1.name })) { location in
                                    Button(action: {
                                        selectedObject = location
                                        placementMode = .placing
                                        showObjectSelector = false
                                    }) {
                                        HStack {
                                            Image(systemName: location.collected ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(location.collected ? .green : .orange)
                                            VStack(alignment: .leading) {
                                                Text(location.name)
                                                    .foregroundColor(.primary)
                                                Text(location.type.displayName)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            if location.collected {
                                                Text("Found")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                            }
                                        }
                                    }
                                }
                            }
                            
                            Section("Create New Object") {
                                Picker("Object Type", selection: $selectedObjectType) {
                                    ForEach([LootBoxType.chalice, .templeRelic, .treasureChest, .lootChest, .sphere, .cube], id: \.self) { type in
                                        Text(type.displayName).tag(type)
                                    }
                                }
                                
                                Button(action: {
                                    isPlacingNew = true
                                    placementMode = .placing
                                    showObjectSelector = false
                                }) {
                                    HStack {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.blue)
                                        Text("Create New \(selectedObjectType.displayName)")
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // AR placement view with placement reticle and overlay
                    ARPlacementARViewWrapper(
                        locationManager: locationManager,
                        userLocationManager: userLocationManager,
                        selectedObject: selectedObject,
                        objectType: isPlacingNew ? selectedObjectType : selectedObject?.type ?? .chalice,
                        isNewObject: isPlacingNew,
                        onPlace: { gpsCoordinate in
                            // Handle placement
                            Task {
                                if let selected = selectedObject {
                                    // Update existing object
                                    await updateObjectLocation(objectId: selected.id, coordinate: gpsCoordinate)
                                } else {
                                    // Create new object
                                    await createNewObject(type: selectedObjectType, coordinate: gpsCoordinate)
                                }
                                dismiss()
                            }
                        },
                        onCancel: {
                            placementMode = .selecting
                            showObjectSelector = true
                        }
                    )
                }
            }
            .navigationTitle(placementMode == .selecting ? "Place Objects" : "Position Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if placementMode == .placing {
                        Button("Cancel") {
                            placementMode = .selecting
                            showObjectSelector = true
                        }
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
    
    private func updateObjectLocation(objectId: String, coordinate: CLLocationCoordinate2D) async {
        do {
            try await APIService.shared.updateObjectLocation(
                objectId: objectId,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            // Reload locations to get updated data
            await locationManager.loadLocationsFromAPI(userLocation: userLocationManager.currentLocation, includeFound: true)
        } catch {
            print("❌ Failed to update object location: \(error)")
        }
    }
    
    private func createNewObject(type: LootBoxType, coordinate: CLLocationCoordinate2D) async {
        let newLocation = LootBoxLocation(
            id: UUID().uuidString,
            name: "New \(type.displayName)",
            type: type,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: 5.0
        )
        
        do {
            _ = try await APIService.shared.createObject(newLocation)
            // Reload locations to get new object
            await locationManager.loadLocationsFromAPI(userLocation: userLocationManager.currentLocation, includeFound: true)
        } catch {
            print("❌ Failed to create object: \(error)")
        }
    }
}

// MARK: - AR Placement AR View Wrapper (combines AR view + overlay)
struct ARPlacementARViewWrapper: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    let selectedObject: LootBoxLocation?
    let objectType: LootBoxType
    let isNewObject: Bool
    let onPlace: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void

    @StateObject private var placementReticle = ARPlacementReticle(arView: nil)
    @State private var isPlacementMode = true

    var body: some View {
        ZStack {
            // AR View
            ARPlacementARView(
                locationManager: locationManager,
                userLocationManager: userLocationManager,
                selectedObject: selectedObject,
                objectType: objectType,
                isNewObject: isNewObject,
                placementReticle: placementReticle,
                onPlace: onPlace,
                onCancel: onCancel
            )

            // Placement overlay UI
            ObjectPlacementOverlay(
                isPlacementMode: $isPlacementMode,
                placementPosition: $placementReticle.currentPosition,
                placementDistance: $placementReticle.distanceFromCamera,
                groundHeight: $placementReticle.heightFromGround,
                objectType: objectType,
                onPlaceObject: {
                    // Get placement position and convert to GPS
                    if let position = placementReticle.getPlacementPosition() {
                        // This will be handled by the coordinator
                        print("✅ Place button tapped at position: \(position)")
                    }
                },
                onCancel: onCancel
            )
        }
    }
}

// MARK: - AR Placement AR View
struct ARPlacementARView: UIViewRepresentable {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    let selectedObject: LootBoxLocation?
    let objectType: LootBoxType
    let isNewObject: Bool
    @ObservedObject var placementReticle: ARPlacementReticle
    let onPlace: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        // Add tap gesture for placement
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)

        context.coordinator.setup(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager, selectedObject: selectedObject, objectType: objectType, isNewObject: isNewObject, placementReticle: placementReticle)
        context.coordinator.onPlace = onPlace
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Update wireframes when locations change
        context.coordinator.updateWireframes()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPlace: onPlace, onCancel: onCancel)
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        weak var locationManager: LootBoxLocationManager?
        weak var userLocationManager: UserLocationManager?
        var selectedObject: LootBoxLocation?
        var objectType: LootBoxType
        var isNewObject: Bool
        var onPlace: (CLLocationCoordinate2D) -> Void
        var onCancel: () -> Void
        var arOriginGPS: CLLocation?
        var crosshairEntity: ModelEntity?
        var crosshairAnchor: AnchorEntity?
        var placementReticle: ARPlacementReticle?
        
        init(onPlace: @escaping (CLLocationCoordinate2D) -> Void, onCancel: @escaping () -> Void) {
            self.onPlace = onPlace
            self.onCancel = onCancel
            self.objectType = .chalice
            self.isNewObject = false
        }
        
        var wireframeAnchors: [String: AnchorEntity] = [:]
        var precisionPositioningService: ARPrecisionPositioningService?

        func setup(arView: ARView, locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, selectedObject: LootBoxLocation?, objectType: LootBoxType, isNewObject: Bool, placementReticle: ARPlacementReticle) {
            self.arView = arView
            self.locationManager = locationManager
            self.userLocationManager = userLocationManager
            self.selectedObject = selectedObject
            self.objectType = objectType
            self.isNewObject = isNewObject
            self.placementReticle = placementReticle

            // Initialize placement reticle with AR view
            placementReticle.arView = arView
            placementReticle.show()

            // Initialize precision positioning service
            precisionPositioningService = ARPrecisionPositioningService(arView: arView)

            // Set AR origin on first location update
            if let userLocation = userLocationManager.currentLocation {
                arOriginGPS = userLocation
            }

            // Set up AR session delegate to update crosshair position and reticle
            arView.session.delegate = self

            // Create crosshairs (keeping old system for now)
            createCrosshairs()

            // Place all existing objects as wireframes
            placeAllObjectsAsWireframes()
        }
        
        func placeAllObjectsAsWireframes() {
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let userLocation = userLocationManager?.currentLocation,
                  let arOrigin = arOriginGPS else {
                print("⚠️ Cannot place wireframes: Missing AR view, frame, or location")
                return
            }
            
            let cameraTransform = frame.camera.transform
            
            // Place each existing object as a wireframe
            for location in locationManager?.locations ?? [] {
                // Skip if this is the selected object (will be shown differently)
                if let selected = selectedObject, location.id == selected.id {
                    continue
                }
                
                // Skip if no GPS coordinates
                guard location.latitude != 0 || location.longitude != 0 else {
                    continue
                }
                
                let targetLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                
                // Convert GPS to AR position
                if let arPosition = precisionPositioningService?.convertGPSToARPosition(
                    targetGPS: targetLocation,
                    userGPS: userLocation,
                    cameraTransform: cameraTransform,
                    arOriginGPS: arOrigin
                ) {
                    // Use stored grounding height if available
                    let finalY = location.grounding_height.map { Float($0) } ?? arPosition.y
                    let finalPosition = SIMD3<Float>(arPosition.x, finalY, arPosition.z)
                    // Create wireframe model
                    let wireframeEntity = createWireframeModel(for: location.type, size: location.type.size)
                    
                    // Create anchor at AR position
                    let anchor = AnchorEntity(world: finalPosition)
                    anchor.addChild(wireframeEntity)
                    arView.scene.addAnchor(anchor)
                    
                    wireframeAnchors[location.id] = anchor
                }
            }
            
            print("✅ Placed \(wireframeAnchors.count) objects as wireframes")
        }
        
        func updateWireframes() {
            // Remove old wireframes
            for (_, anchor) in wireframeAnchors {
                anchor.removeFromParent()
            }
            wireframeAnchors.removeAll()
            
            // Place updated wireframes
            placeAllObjectsAsWireframes()
        }
        
        func createWireframeModel(for type: LootBoxType, size: Float) -> ModelEntity {
            // Create wireframe material (unlit, semi-transparent, colored outline)
            var wireframeMaterial = SimpleMaterial()
            wireframeMaterial.color = .init(tint: UIColor.cyan.withAlphaComponent(0.6))
            wireframeMaterial.roughness = 1.0
            wireframeMaterial.metallic = 0.0
            
            // Create wireframe based on object type
            let wireframeEntity: ModelEntity
            
            switch type {
            case .chalice, .templeRelic:
                // Cylinder wireframe for chalice
                let mesh = MeshResource.generateCylinder(height: size * 0.6, radius: size * 0.3)
                wireframeEntity = ModelEntity(mesh: mesh, materials: [wireframeMaterial])
                
            case .treasureChest, .lootChest, .lootCart:
                // Box wireframe for chest
                let mesh = MeshResource.generateBox(width: size * 0.6, height: size * 0.6, depth: size * 0.6)
                wireframeEntity = ModelEntity(mesh: mesh, materials: [wireframeMaterial])
                
            case .sphere:
                // Sphere wireframe
                let mesh = MeshResource.generateSphere(radius: size * 0.3)
                wireframeEntity = ModelEntity(mesh: mesh, materials: [wireframeMaterial])
                
            case .cube:
                // Cube wireframe
                let mesh = MeshResource.generateBox(width: size * 0.4, height: size * 0.4, depth: size * 0.4)
                wireframeEntity = ModelEntity(mesh: mesh, materials: [wireframeMaterial])
            }
            
            // Add outline effect by creating a slightly larger wireframe behind
            let outlineEntity = wireframeEntity.clone(recursive: false)
            if var outlineModel = outlineEntity.model {
                var outlineMaterial = SimpleMaterial()
                outlineMaterial.color = .init(tint: UIColor.cyan.withAlphaComponent(0.3))
                outlineMaterial.roughness = 1.0
                outlineMaterial.metallic = 0.0
                outlineModel.materials = [outlineMaterial]
                outlineEntity.model = outlineModel
            }
            outlineEntity.scale *= 1.05 // Slightly larger for outline effect
            
            let container = ModelEntity()
            container.addChild(outlineEntity)
            container.addChild(wireframeEntity)
            
            return container
        }
        
        func createCrosshairs() {
            guard let arView = arView else { return }
            
            // Create crosshair lines
            let lineLength: Float = 0.1 // 10cm
            let lineThickness: Float = 0.002 // 2mm
            
            // Horizontal line
            var horizontalMaterial = SimpleMaterial()
            horizontalMaterial.color = .init(tint: .red)
            horizontalMaterial.metallic = 0.0
            let horizontalMesh = MeshResource.generateBox(width: lineLength, height: lineThickness, depth: lineThickness)
            let horizontalEntity = ModelEntity(mesh: horizontalMesh, materials: [horizontalMaterial])
            
            // Vertical line
            var verticalMaterial = SimpleMaterial()
            verticalMaterial.color = .init(tint: .red)
            verticalMaterial.metallic = 0.0
            let verticalMesh = MeshResource.generateBox(width: lineThickness, height: lineLength, depth: lineThickness)
            let verticalEntity = ModelEntity(mesh: verticalMesh, materials: [verticalMaterial])
            
            // Center circle
            var circleMaterial = SimpleMaterial()
            circleMaterial.color = .init(tint: .red)
            circleMaterial.metallic = 0.0
            let circleMesh = MeshResource.generateSphere(radius: 0.01) // 1cm radius
            let circleEntity = ModelEntity(mesh: circleMesh, materials: [circleMaterial])
            
            // Create parent entity
            let crosshairEntity = ModelEntity()
            crosshairEntity.addChild(horizontalEntity)
            crosshairEntity.addChild(verticalEntity)
            crosshairEntity.addChild(circleEntity)
            
            self.crosshairEntity = crosshairEntity
            
            // Position crosshair 2 meters in front of camera
            updateCrosshairPosition()
        }
        
        func updateCrosshairPosition() {
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let crosshair = crosshairEntity else { return }
            
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            
            // Position 2 meters in front of camera
            let forward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
            let crosshairDistance: Float = 2.0
            let crosshairPos = cameraPos + normalize(forward) * crosshairDistance
            
            // Raycast to find surface
            let raycastQuery = ARRaycastQuery(
                origin: SIMD3<Float>(crosshairPos.x, cameraPos.y, crosshairPos.z),
                direction: SIMD3<Float>(0, -1, 0),
                allowing: .estimatedPlane,
                alignment: .horizontal
            )
            
            if let result = arView.session.raycast(raycastQuery).first {
                let surfaceY = result.worldTransform.columns.3.y
                let finalPos = SIMD3<Float>(crosshairPos.x, surfaceY + 0.01, crosshairPos.z) // Slightly above surface
                
                if crosshairAnchor == nil {
                    crosshairAnchor = AnchorEntity(world: finalPos)
                    crosshairAnchor!.addChild(crosshair)
                    arView.scene.addAnchor(crosshairAnchor!)
                } else {
                    crosshairAnchor!.position = finalPos
                }
            }
        }
        
        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let userLocation = userLocationManager?.currentLocation,
                  let arOrigin = arOriginGPS else {
                print("⚠️ Cannot place: Missing AR view, frame, or location")
                return
            }
            
            let tapLocation = sender.location(in: arView)
            
            // Raycast to find tap position
            guard let raycastResult = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .horizontal).first else {
                print("⚠️ No surface found at tap location")
                return
            }
            
            let tapWorldPos = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
            
            // Convert AR world position to GPS coordinates
            if let gpsCoordinate = convertARToGPS(arPosition: tapWorldPos, arOrigin: arOrigin, userLocation: userLocation, cameraTransform: frame.camera.transform) {
                print("✅ Placing object at GPS: \(gpsCoordinate.latitude), \(gpsCoordinate.longitude)")
                onPlace(gpsCoordinate)
            } else {
                print("❌ Failed to convert AR position to GPS")
            }
        }
        
        // Convert AR world position back to GPS coordinates
        func convertARToGPS(arPosition: SIMD3<Float>, arOrigin: CLLocation, userLocation: CLLocation, cameraTransform: simd_float4x4) -> CLLocationCoordinate2D? {
            // Calculate offset from AR origin
            let arOriginPos = SIMD3<Float>(0, 0, 0) // AR origin is at (0,0,0) in AR space
            
            // Get current camera position relative to AR origin
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            
            // Calculate offset from camera to tap position
            let offset = arPosition - cameraPos
            
            // Convert offset to meters (AR units are in meters)
            let distanceX = Double(offset.x)
            let distanceZ = Double(offset.z)
            
            // Calculate distance and bearing
            let distance = sqrt(distanceX * distanceX + distanceZ * distanceZ)
            
            // Get camera's forward direction (north in AR space)
            let cameraForward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                0,
                -cameraTransform.columns.2.z
            )
            let cameraRight = SIMD3<Float>(
                cameraTransform.columns.0.x,
                0,
                cameraTransform.columns.0.z
            )
            
            // Project offset onto camera's forward and right vectors
            let forwardComponent = dot(offset, normalize(cameraForward))
            let rightComponent = dot(offset, normalize(cameraRight))
            
            // Calculate bearing (angle from north)
            let bearingRad = atan2(Double(rightComponent), Double(forwardComponent))
            let bearingDeg = bearingRad * 180.0 / .pi
            
            // Convert bearing to compass bearing (0 = north, clockwise)
            let compassBearing = (bearingDeg + 360).truncatingRemainder(dividingBy: 360)
            
            // Calculate GPS coordinate from user location
            let targetGPS = userLocation.coordinate.coordinate(atDistance: distance, atBearing: compassBearing)
            
            return targetGPS
        }
        
        // MARK: - ARSessionDelegate
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Update crosshair position as camera moves
            updateCrosshairPosition()
        }
    }
}

// Extension to calculate coordinate at distance and bearing
extension CLLocationCoordinate2D {
    func coordinate(atDistance distance: Double, atBearing bearing: Double) -> CLLocationCoordinate2D {
        let earthRadius: Double = 6371000 // meters
        
        let lat1 = self.latitude * .pi / 180.0
        let lon1 = self.longitude * .pi / 180.0
        let bearingRad = bearing * .pi / 180.0
        
        let lat2 = asin(sin(lat1) * cos(distance / earthRadius) + cos(lat1) * sin(distance / earthRadius) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(distance / earthRadius) * cos(lat1), cos(distance / earthRadius) - sin(lat1) * sin(lat2))
        
        return CLLocationCoordinate2D(latitude: lat2 * 180.0 / .pi, longitude: lon2 * 180.0 / .pi)
    }
}

