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
                        onPlace: { gpsCoordinate, groundingHeight, scale in
                            // Handle placement
                            Task {
                                if let selected = selectedObject {
                                    // Update existing object
                                    await updateObjectLocation(objectId: selected.id, coordinate: gpsCoordinate, groundingHeight: groundingHeight, scale: scale)
                                } else {
                                    // Create new object
                                    await createNewObject(type: selectedObjectType, coordinate: gpsCoordinate, groundingHeight: groundingHeight, scale: scale)
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
    
    private func updateObjectLocation(objectId: String, coordinate: CLLocationCoordinate2D, groundingHeight: Double, scale: Float) async {
        do {
            try await APIService.shared.updateObjectLocation(
                objectId: objectId,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            // Also update grounding height for accurate placement
            try await APIService.shared.updateGroundingHeight(objectId: objectId, height: groundingHeight)
            // Note: Scale is stored locally or could be added to API in the future
            print("📏 Object scale set to \(scale)x (stored locally)")
            // Reload locations to get updated data
            await locationManager.loadLocationsFromAPI(userLocation: userLocationManager.currentLocation, includeFound: true)
        } catch {
            print("❌ Failed to update object location: \(error)")
        }
    }

    private func createNewObject(type: LootBoxType, coordinate: CLLocationCoordinate2D, groundingHeight: Double, scale: Float) async {
        let newLocation = LootBoxLocation(
            id: UUID().uuidString,
            name: "New \(type.displayName)",
            type: type,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: 5.0
        )

        do {
            let createdObject = try await APIService.shared.createObject(newLocation)
            // Update grounding height for the newly created object
            try await APIService.shared.updateGroundingHeight(objectId: createdObject.id, height: groundingHeight)
            // Note: Scale is stored locally or could be added to API in the future
            print("📏 Object scale set to \(scale)x (stored locally)")
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
    let onPlace: (CLLocationCoordinate2D, Double, Float) -> Void
    let onCancel: () -> Void

    @StateObject private var placementReticle = ARPlacementReticle(arView: nil)
    @State private var isPlacementMode = true
    @State private var scaleMultiplier: Float = 1.0

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
                scaleMultiplier: $scaleMultiplier,
                onPlace: onPlace,
                onCancel: onCancel
            )

            // Placement overlay UI
            ObjectPlacementOverlay(
                isPlacementMode: $isPlacementMode,
                placementPosition: $placementReticle.currentPosition,
                placementDistance: $placementReticle.distanceFromCamera,
                groundHeight: $placementReticle.heightFromGround,
                scaleMultiplier: $scaleMultiplier,
                objectType: objectType,
                onPlaceObject: {
                    // Trigger placement at reticle position via notification
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerPlacementAtReticle"), object: nil)
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
    @Binding var scaleMultiplier: Float
    let onPlace: (CLLocationCoordinate2D, Double, Float) -> Void
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
        
        // Add long press gesture for drag-to-place
        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.3 // 300ms to activate
        arView.addGestureRecognizer(longPressGesture)
        
        // Make tap gesture require long press to fail (so tap still works for quick placement)
        tapGesture.require(toFail: longPressGesture)

        context.coordinator.setup(arView: arView, locationManager: locationManager, userLocationManager: userLocationManager, selectedObject: selectedObject, objectType: objectType, isNewObject: isNewObject, placementReticle: placementReticle)
        context.coordinator.onPlace = onPlace
        context.coordinator.scaleMultiplier = scaleMultiplier
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Update scale multiplier when it changes
        context.coordinator.scaleMultiplier = scaleMultiplier
        // Update wireframe preview scale
        context.coordinator.updateWireframeScale()
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
        var onPlace: (CLLocationCoordinate2D, Double, Float) -> Void
        var onCancel: () -> Void
        var arOriginGPS: CLLocation?
        var crosshairEntity: ModelEntity?
        var crosshairAnchor: AnchorEntity?
        var placementReticle: ARPlacementReticle?
        var scaleMultiplier: Float = 1.0
        var previewWireframeEntity: ModelEntity?
        var previewWireframeAnchor: AnchorEntity?
        
        init(onPlace: @escaping (CLLocationCoordinate2D, Double, Float) -> Void, onCancel: @escaping () -> Void) {
            self.onPlace = onPlace
            self.onCancel = onCancel
            self.objectType = .chalice
            self.isNewObject = false
            super.init()

            // Listen for placement button taps from overlay
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePlacementButtonTap),
                name: NSNotification.Name("TriggerPlacementAtReticle"),
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        var wireframeAnchors: [String: AnchorEntity] = [:]
        var precisionPositioningService: ARPrecisionPositioningService?
        
        // Dragging state
        var draggingWireframeEntity: ModelEntity?
        var draggingAnchor: AnchorEntity?
        var isDragging = false

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
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )

            // Place each existing object as a wireframe
            for location in locationManager?.locations ?? [] {
                // SELECTED OBJECT: Place directly in front of camera for easy repositioning
                if let selected = selectedObject, location.id == selected.id {
                    // Calculate position 2 meters in front of camera
                    let cameraForward = SIMD3<Float>(
                        -cameraTransform.columns.2.x,
                        -cameraTransform.columns.2.y,
                        -cameraTransform.columns.2.z
                    )
                    let distance: Float = 2.0
                    let targetPosition = cameraPos + normalize(cameraForward) * distance

                    // Place at ground level (camera height - 1.5m)
                    let groundY = cameraPos.y - 1.5
                    let finalPosition = SIMD3<Float>(targetPosition.x, groundY, targetPosition.z)

                    // Create a highlighted wireframe for selected object
                    let wireframeEntity = createWireframeModel(for: location.type, size: location.type.size)

                    // Make it yellow/gold to indicate it's selected
                    for child in wireframeEntity.children {
                        if let modelEntity = child as? ModelEntity {
                            if var model = modelEntity.model {
                                var material = SimpleMaterial()
                                material.color = .init(tint: UIColor.systemYellow.withAlphaComponent(0.8))
                                material.roughness = 1.0
                                material.metallic = 0.0
                                model.materials = [material]
                                modelEntity.model = model
                            }
                        }
                    }

                    let anchor = AnchorEntity(world: finalPosition)
                    anchor.addChild(wireframeEntity)
                    arView.scene.addAnchor(anchor)

                    wireframeAnchors[location.id] = anchor
                    print("✅ Placed selected object '\(location.name)' in front of camera at \(finalPosition)")
                    continue
                }

                // OTHER OBJECTS: Show at their GPS positions
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
            // Don't handle tap if we're dragging
            guard !isDragging else { return }
            
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
                // Calculate height relative to camera (which represents eye level)
                // This makes the height portable across different AR sessions
                let cameraPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                let relativeHeight = Double(tapWorldPos.y - cameraPos.y)
                print("✅ Placing object at GPS: \(gpsCoordinate.latitude), \(gpsCoordinate.longitude), relative height: \(relativeHeight)m from camera, scale: \(scaleMultiplier)x")
                onPlace(gpsCoordinate, relativeHeight, scaleMultiplier)
            } else {
                print("❌ Failed to convert AR position to GPS")
            }
        }

        /// Handles placement button tap from overlay UI
        @objc func handlePlacementButtonTap() {
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let userLocation = userLocationManager?.currentLocation,
                  let arOrigin = arOriginGPS,
                  let reticlePosition = placementReticle?.getPlacementPosition() else {
                print("⚠️ Cannot place: Missing AR view, frame, location, or reticle position")
                return
            }

            print("✅ Placement button tapped - placing at reticle position: \(reticlePosition)")

            // Convert AR world position to GPS coordinates
            if let gpsCoordinate = convertARToGPS(arPosition: reticlePosition, arOrigin: arOrigin, userLocation: userLocation, cameraTransform: frame.camera.transform) {
                // Calculate height relative to camera (which represents eye level)
                // This makes the height portable across different AR sessions
                let cameraPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                let relativeHeight = Double(reticlePosition.y - cameraPos.y)
                print("✅ Placing object at GPS: \(gpsCoordinate.latitude), \(gpsCoordinate.longitude), relative height: \(relativeHeight)m from camera, scale: \(scaleMultiplier)x")
                onPlace(gpsCoordinate, relativeHeight, scaleMultiplier)
            } else {
                print("❌ Failed to convert AR position to GPS")
            }
        }

        @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let userLocation = userLocationManager?.currentLocation,
                  let arOrigin = arOriginGPS else {
                return
            }
            
            let touchLocation = sender.location(in: arView)
            
            switch sender.state {
            case .began:
                // Start dragging - create wireframe at touch location
                startDragging(at: touchLocation, in: arView, frame: frame)
                
            case .changed:
                // Update wireframe position as user drags
                updateDragging(at: touchLocation, in: arView, frame: frame)
                
            case .ended, .cancelled:
                // End dragging - place object at final position
                endDragging(at: touchLocation, in: arView, frame: frame, userLocation: userLocation, arOrigin: arOrigin)
                
            default:
                break
            }
        }
        
        func startDragging(at location: CGPoint, in arView: ARView, frame: ARFrame) {
            // Raycast to find surface at touch location
            guard let raycastResult = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal).first else {
                print("⚠️ No surface found for drag start")
                return
            }
            
            let worldPos = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
            
            // Create wireframe model for the object type with scale applied
            let wireframeContainer = createWireframeModel(for: objectType, size: objectType.size * scaleMultiplier)
            
            // Make it more visible when dragging (brighter, larger)
            // Update materials on all children to make them yellow
            for child in wireframeContainer.children {
                if let modelEntity = child as? ModelEntity {
                    if var model = modelEntity.model {
                        var material = SimpleMaterial()
                        material.color = .init(tint: UIColor.yellow.withAlphaComponent(0.8))
                        material.roughness = 1.0
                        material.metallic = 0.0
                        model.materials = [material]
                        modelEntity.model = model
                    }
                }
            }
            wireframeContainer.scale *= 1.2 // Make it slightly larger when dragging
            
            // Create anchor at the touch position
            let anchor = AnchorEntity(world: worldPos)
            anchor.addChild(wireframeContainer)
            arView.scene.addAnchor(anchor)
            
            draggingWireframeEntity = wireframeContainer
            draggingAnchor = anchor
            isDragging = true
            
            print("🎯 Started dragging wireframe at \(worldPos)")
        }
        
        func updateDragging(at location: CGPoint, in arView: ARView, frame: ARFrame) {
            guard let anchor = draggingAnchor,
                  let wireframe = draggingWireframeEntity else { return }
            
            // Raycast to find new position
            guard let raycastResult = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal).first else {
                return // Keep at last valid position if no surface found
            }
            
            let newWorldPos = SIMD3<Float>(
                raycastResult.worldTransform.columns.3.x,
                raycastResult.worldTransform.columns.3.y,
                raycastResult.worldTransform.columns.3.z
            )
            
            // Update anchor position
            anchor.position = newWorldPos
            
            // Update wireframe scale if it changed
            // Remove old scale multiplier (1.2) and apply new scale
            let baseScale: Float = 1.2 // The drag preview scale
            wireframe.scale = SIMD3<Float>(baseScale * scaleMultiplier, baseScale * scaleMultiplier, baseScale * scaleMultiplier)
        }
        
        func updateWireframeScale() {
            guard let wireframe = draggingWireframeEntity else { return }
            let baseScale: Float = 1.2 // The drag preview scale
            wireframe.scale = SIMD3<Float>(baseScale * scaleMultiplier, baseScale * scaleMultiplier, baseScale * scaleMultiplier)
        }
        
        func endDragging(at location: CGPoint, in arView: ARView, frame: ARFrame, userLocation: CLLocation, arOrigin: CLLocation) {
            guard let anchor = draggingAnchor else {
                isDragging = false
                return
            }
            
            // Get final position
            let finalWorldPos = anchor.position
            
            // Convert AR world position to GPS coordinates
            if let gpsCoordinate = convertARToGPS(arPosition: finalWorldPos, arOrigin: arOrigin, userLocation: userLocation, cameraTransform: frame.camera.transform) {
                // Calculate height relative to camera (which represents eye level)
                // This makes the height portable across different AR sessions
                let cameraPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                let relativeHeight = Double(finalWorldPos.y - cameraPos.y)
                print("✅ Placing object at GPS after drag: \(gpsCoordinate.latitude), \(gpsCoordinate.longitude), relative height: \(relativeHeight)m from camera, scale: \(scaleMultiplier)x")

                // Remove dragging wireframe
                anchor.removeFromParent()
                draggingWireframeEntity = nil
                draggingAnchor = nil
                isDragging = false

                // Place the object
                onPlace(gpsCoordinate, relativeHeight, scaleMultiplier)
            } else {
                print("❌ Failed to convert AR position to GPS after drag")
                // Clean up anyway
                anchor.removeFromParent()
                draggingWireframeEntity = nil
                draggingAnchor = nil
                isDragging = false
            }
        }
        
        // Convert AR world position back to GPS coordinates
        // Uses AR origin GPS for maximum accuracy (matches ARPrecisionPositioningService approach)
        func convertARToGPS(arPosition: SIMD3<Float>, arOrigin: CLLocation, userLocation: CLLocation, cameraTransform: simd_float4x4) -> CLLocationCoordinate2D? {
            // CRITICAL: Calculate position relative to AR origin GPS location (not current user location)
            // This matches the precision used in ARPrecisionPositioningService.convertGPSToARPosition
            // and ensures objects stay fixed in space when camera/user moves
            
            // AR origin is at (0,0,0) in AR world space
            // The arPosition is already in AR world space relative to origin
            let arOriginPos = SIMD3<Float>(0, 0, 0)
            
            // Calculate offset from AR origin to target position
            let offset = arPosition - arOriginPos
            
            // Convert offset to meters (AR units are in meters)
            let distanceX = Double(offset.x)
            let distanceZ = Double(offset.z)
            
            // Calculate distance from AR origin
            let distance = sqrt(distanceX * distanceX + distanceZ * distanceZ)
            
            // Calculate bearing from AR origin
            // In AR space: +X = East, +Z = North
            // Bearing: 0° = North, 90° = East, 180° = South, 270° = West
            let bearingRad = atan2(distanceX, distanceZ) // atan2(x, z) gives angle from north
            let bearingDeg = bearingRad * 180.0 / .pi
            
            // Normalize bearing to 0-360 range
            let compassBearing = (bearingDeg + 360).truncatingRemainder(dividingBy: 360)
            
            // Calculate GPS coordinate from AR origin GPS location (not current user location)
            // This is the key difference - using AR origin ensures accuracy
            let targetGPS = arOrigin.coordinate.coordinate(atDistance: distance, atBearing: compassBearing)
            
            return targetGPS
        }
        
        // MARK: - ARSessionDelegate
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Update crosshair position as camera moves
            updateCrosshairPosition()

            // Update placement reticle position
            placementReticle?.update()
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

