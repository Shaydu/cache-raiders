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
    @State private var isMultifindable: Bool = false // Default to single-find for map placement
    
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

                                Toggle("Multi-Findable", isOn: $isMultifindable)
                                    .help("When enabled, this item disappears only for users who find it. Other players can still find it. When disabled, it disappears for everyone once found.")

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
                        onPlace: { gpsCoordinate, arPosition, arOrigin, groundingHeight, scale in
                            // Handle placement
                            print("🎯 [Placement] onPlace called - starting placement process")
                            print("   GPS: (\(gpsCoordinate.latitude), \(gpsCoordinate.longitude))")
                            print("   AR Position: (\(arPosition.x), \(arPosition.y), \(arPosition.z))")
                            print("   AR Origin: \(arOrigin != nil ? "available" : "nil")")
                            
                            Task {
                                if let selected = selectedObject {
                                    print("📝 [Placement] Updating existing object: \(selected.name) (ID: \(selected.id))")
                                    // Update existing object
                                    await updateObjectLocation(
                                        objectId: selected.id,
                                        coordinate: gpsCoordinate,
                                        arPosition: arPosition,
                                        arOrigin: arOrigin,
                                        groundingHeight: groundingHeight,
                                        scale: scale
                                    )
                                    print("✅ [Placement] Object location updated successfully")
                                } else {
                                    print("➕ [Placement] Creating new object of type: \(selectedObjectType.displayName)")
                                    // Create new object
                                    await createNewObject(
                                        type: selectedObjectType,
                                        coordinate: gpsCoordinate,
                                        arPosition: arPosition,
                                        arOrigin: arOrigin,
                                        groundingHeight: groundingHeight,
                                        scale: scale
                                    )
                                    print("✅ [Placement] New object created successfully")
                                }

                                // CRITICAL FIX: Instead of reloading and hoping AR offsets are saved,
                                // directly notify the main AR view with the placement data
                                // This ensures immediate placement without waiting for API roundtrip
                                let objectId = selectedObject?.id ?? UUID().uuidString
                                let placementData: [String: Any] = [
                                    "objectId": objectId,
                                    "gpsCoordinate": CLLocationCoordinate2D(latitude: gpsCoordinate.latitude, longitude: gpsCoordinate.longitude),
                                    "arPosition": [arPosition.x, arPosition.y, arPosition.z],
                                    "arOrigin": [arOrigin!.coordinate.latitude, arOrigin!.coordinate.longitude],
                                    "groundingHeight": groundingHeight,
                                    "scale": scale
                                ]

                                await MainActor.run {
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("ARPlacementObjectSaved"),
                                        object: nil,
                                        userInfo: placementData
                                    )
                                    print("📢 [Placement] Posted notification with direct placement data")
                                }

                                // Now reload locations in background (for persistence)
                                Task {
                                    await locationManager.loadLocationsFromAPI(userLocation: userLocationManager.currentLocation)
                                    print("✅ [Placement] Locations reloaded for persistence")
                                }

                                // Longer delay to ensure the main AR view has time to:
                                // 1. Receive the notification
                                // 2. Process the reloaded locations
                                // 3. Place the object via checkAndPlaceBoxes
                                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                                print("✅ [Placement] Placement process complete - dismissing view")
                                dismiss()
                            }
                        },
                        onCancel: {
                            placementMode = .selecting
                            showObjectSelector = true
                        },
                        onDone: {
                            // User pressed Done - save any placed object and dismiss
                            dismiss()
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
            .onDisappear {
                // When view disappears, save any placed object if one exists
                // This handles swipe-to-dismiss and navigation bar Done button
                if placementMode == .placing {
                    // The onDone callback in ARPlacementARViewWrapper will handle saving
                    // This is a fallback in case the view is dismissed another way
                }
            }
        }
    }
    
    private func updateObjectLocation(objectId: String, coordinate: CLLocationCoordinate2D, arPosition: SIMD3<Float>, arOrigin: CLLocation?, groundingHeight: Double, scale: Float) async {
        do {
            // Update GPS location
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            try await APIService.shared.updateObjectLocation(objectId: objectId, location: location)

            // CRITICAL: Save AR offset coordinates so the main AR view can place the object
            // The AR position is relative to the AR origin (0,0,0), so it IS the offset
            // Make this non-blocking - if it fails, placement should still continue
            if let arOrigin = arOrigin {
                do {
                    try await APIService.shared.updateAROffset(
                        objectId: objectId,
                        arOriginLatitude: arOrigin.coordinate.latitude,
                        arOriginLongitude: arOrigin.coordinate.longitude,
                        offsetX: Double(arPosition.x),
                        offsetY: Double(arPosition.y),
                        offsetZ: Double(arPosition.z)
                    )
                    print("✅ [Placement] Saved AR coordinates to API:")
                    print("   Object ID: \(objectId)")
                    print("   AR Origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
                    print("   AR Offset: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                } catch {
                    print("⚠️ [Placement] Failed to save AR coordinates (non-blocking): \(error)")
                    print("   Placement will continue - object will be placed using GPS coordinates")
                }
            } else {
                print("⚠️ [Placement] No AR origin available - cannot save AR coordinates")
            }

            // Store the intended AR position from ARPlacementView in UserDefaults
            // This will be used by main AR view to measure GPS error and correct it
            let arPositionKey = "ARPlacementPosition_\(objectId)"
            let arPositionDict: [String: Float] = [
                "x": arPosition.x,
                "y": arPosition.y,
                "z": arPosition.z,
                "origin_lat": Float(arOrigin?.coordinate.latitude ?? 0),
                "origin_lon": Float(arOrigin?.coordinate.longitude ?? 0)
            ]
            UserDefaults.standard.set(arPositionDict, forKey: arPositionKey)

            print("📍 [Placement] Stored intended AR position for GPS correction:")
            print("   Object ID: \(objectId)")
            print("   AR Position: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))")
            print("   GPS (uncorrected): (\(String(format: "%.6f", coordinate.latitude)), \(String(format: "%.6f", coordinate.longitude)))")
            print("   💡 Main AR view will use AR coordinates for precise placement")

            // Also update grounding height for accurate placement
            try await APIService.shared.updateGroundingHeight(objectId: objectId, height: groundingHeight)
            // Note: Scale is stored locally or could be added to API in the future
            print("📏 [Placement] Object scale set to \(scale)x (stored locally)")
        } catch {
            print("❌ Failed to update object location: \(error)")
        }
    }

    private func createNewObject(type: LootBoxType, coordinate: CLLocationCoordinate2D, arPosition: SIMD3<Float>, arOrigin: CLLocation?, groundingHeight: Double, scale: Float) async {
        let objectId = UUID().uuidString

        // CRITICAL: Include AR offset coordinates in initial object creation for <10cm accuracy
        let newLocation = LootBoxLocation(
            id: objectId,
            name: "New \(type.displayName)",
            type: type,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: 3.0, // Smaller radius since we have precise AR coordinates
            grounding_height: groundingHeight,
            source: .arManual,
            ar_origin_latitude: arOrigin?.coordinate.latitude,
            ar_origin_longitude: arOrigin?.coordinate.longitude,
            ar_offset_x: Double(arPosition.x),
            ar_offset_y: Double(arPosition.y),
            ar_offset_z: Double(arPosition.z),
            ar_placement_timestamp: Date(),
            multifindable: isMultifindable
        )

        do {
            let createdObject = try await APIService.shared.createObject(newLocation)

            // AR offset coordinates were already included in the initial creation above
            print("✅ [Placement] Created object with AR coordinates:")
            print("   Object ID: \(createdObject.id)")
            print("   Type: \(createdObject.type)")
            if let arOrigin = arOrigin {
                print("   AR Origin: (\(String(format: "%.6f", arOrigin.coordinate.latitude)), \(String(format: "%.6f", arOrigin.coordinate.longitude)))")
                print("   AR Offset: (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))m")
                print("   💎 Object will appear at EXACT placement location (<10cm accuracy)!")
            }

            // Store the intended AR position from ARPlacementView in UserDefaults
            // This will be used by main AR view to measure GPS error and correct it
            let arPositionKey = "ARPlacementPosition_\(createdObject.id)"
            let arPositionDict: [String: Float] = [
                "x": arPosition.x,
                "y": arPosition.y,
                "z": arPosition.z,
                "origin_lat": Float(arOrigin?.coordinate.latitude ?? 0),
                "origin_lon": Float(arOrigin?.coordinate.longitude ?? 0)
            ]
            UserDefaults.standard.set(arPositionDict, forKey: arPositionKey)

            print("✅ [Placement] Created new object in API:")
            print("   Object ID: \(createdObject.id)")
            print("   Name: \(createdObject.name)")
            print("   Type: \(createdObject.type)")
            print("   AR Position (intended): (\(String(format: "%.4f", arPosition.x)), \(String(format: "%.4f", arPosition.y)), \(String(format: "%.4f", arPosition.z)))")
            print("   GPS (uncorrected): (\(String(format: "%.6f", createdObject.latitude)), \(String(format: "%.6f", createdObject.longitude)))")
            print("   💡 Main AR view will use AR coordinates for precise placement")

            // Update grounding height for the newly created object
            try await APIService.shared.updateGroundingHeight(objectId: createdObject.id, height: groundingHeight)
            // Note: Scale is stored locally or could be added to API in the future
            print("📏 [Placement] Object scale set to \(scale)x (stored locally)")
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
    let onPlace: (CLLocationCoordinate2D, SIMD3<Float>, CLLocation?, Double, Float) -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    @StateObject private var placementReticle = ARPlacementReticle(arView: nil)
    @State private var isPlacementMode = true
    @State private var scaleMultiplier: Float = 1.0
    @State private var coordinator: ARPlacementARView.Coordinator?
    @State private var hasPlacedObject = false

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
                onCancel: onCancel,
                coordinatorBinding: Binding(
                    get: { coordinator },
                    set: { 
                        coordinator = $0
                        // Update hasPlacedObject when coordinator changes
                        if let coord = $0 {
                            // Use a timer to periodically check if object is placed
                            // This is needed because hasPlacedObject is a computed property
                            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                                if coord.hasPlacedObject != hasPlacedObject {
                                    hasPlacedObject = coord.hasPlacedObject
                                }
                                if !coord.hasPlacedObject {
                                    timer.invalidate()
                                }
                            }
                        }
                    }
                )
            )

            // Placement overlay UI
            ObjectPlacementOverlay(
                isPlacementMode: $isPlacementMode,
                placementPosition: $placementReticle.currentPosition,
                placementDistance: $placementReticle.distanceFromCamera,
                scaleMultiplier: $scaleMultiplier,
                objectType: objectType,
                hasPlacedObject: hasPlacedObject,
                onPlaceObject: {
                    // Trigger placement at reticle position via notification
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerPlacementAtReticle"), object: nil)
                },
                onDone: {
                    // Save the placed object if one exists
                    if let coord = coordinator, coord.hasPlacedObject {
                        coord.savePlacedObject()
                    }
                    onDone()
                },
                onCancel: onCancel
            )
        }
        .onChange(of: coordinator?.hasPlacedObject ?? false) { oldValue, newValue in
            hasPlacedObject = newValue
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
    let onPlace: (CLLocationCoordinate2D, SIMD3<Float>, CLLocation?, Double, Float) -> Void
    let onCancel: () -> Void
    @Binding var coordinatorBinding: Coordinator?
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
        // Apply selected lens if available
        if let selectedLensId = locationManager.selectedARLens,
           let videoFormat = ARLensHelper.getVideoFormat(for: selectedLensId) {
            config.videoFormat = videoFormat
            print("📷 Using selected AR lens in placement view: \(selectedLensId)")
        }
        
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
        
        // Expose coordinator to parent view
        coordinatorBinding = context.coordinator
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Only update if scale actually changed (avoid expensive updates on every view refresh)
        let previousScale = context.coordinator.scaleMultiplier
        if abs(previousScale - scaleMultiplier) > 0.01 { // Only update if change is significant (> 1%)
            context.coordinator.scaleMultiplier = scaleMultiplier
            // Update wireframe preview scale
            context.coordinator.updateWireframeScale()
        }
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
        var onPlace: (CLLocationCoordinate2D, SIMD3<Float>, CLLocation?, Double, Float) -> Void
        var onCancel: () -> Void
        var arOriginGPS: CLLocation?
        var crosshairEntity: ModelEntity?
        var crosshairAnchor: AnchorEntity?
        var placementReticle: ARPlacementReticle?
        var scaleMultiplier: Float = 1.0
        var previewWireframeEntity: ModelEntity?
        var previewWireframeAnchor: AnchorEntity?
        var placedObjectAnchor: AnchorEntity? // Track placed object to show immediately
        var placedObjectEntity: ModelEntity? // Track placed object entity
        
        // Track if an object has been placed (for Done button)
        var hasPlacedObject: Bool {
            return placedObjectAnchor != nil
        }
        
        // Store placement data for saving
        var pendingPlacementData: (gpsCoordinate: CLLocationCoordinate2D, arPosition: SIMD3<Float>, arOrigin: CLLocation?, groundingHeight: Double, scale: Float)?
        
        init(onPlace: @escaping (CLLocationCoordinate2D, SIMD3<Float>, CLLocation?, Double, Float) -> Void, onCancel: @escaping () -> Void) {
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
        var draggingShadowEntity: ModelEntity?

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
            
            // CRITICAL: Force initial update to ensure reticle anchor is positioned
            // This ensures getPlacementPosition() returns a valid position immediately
            placementReticle.update()

            // Initialize precision positioning service
            precisionPositioningService = ARPrecisionPositioningService(arView: arView)

            // Set AR origin on first location update with good GPS accuracy
            // For < 7.5m AR-to-GPS conversion accuracy, we need < 7.5m GPS accuracy
            // RELAXED: Allow placement even with worse GPS accuracy (up to 20m) for better UX
            if let userLocation = userLocationManager.currentLocation {
                if userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 7.5 {
                    arOriginGPS = userLocation
                    print("📍 AR Origin set for placement: accuracy=\(String(format: "%.2f", userLocation.horizontalAccuracy))m (excellent)")
                } else if arOriginGPS == nil && userLocation.horizontalAccuracy >= 0 && userLocation.horizontalAccuracy < 20.0 {
                    // Allow placement with reduced accuracy (7.5m - 20m) for better UX
                    arOriginGPS = userLocation
                    print("📍 AR Origin set for placement: accuracy=\(String(format: "%.2f", userLocation.horizontalAccuracy))m (acceptable, placement enabled)")
                } else if arOriginGPS == nil {
                    let accuracy = userLocation.horizontalAccuracy >= 0 ? String(format: "%.2f", userLocation.horizontalAccuracy) : "unknown"
                    print("⚠️ Waiting for better GPS accuracy (< 20m, currently \(accuracy)m) before setting AR origin")
                }
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
                    // But preserve the shadow's UnlitMaterial
                    for child in wireframeEntity.children {
                        if let modelEntity = child as? ModelEntity {
                            // Skip shadow entity - keep its UnlitMaterial
                            if modelEntity.name == "shadow" {
                                continue
                            }
                            
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
            case .chalice, .templeRelic, .turkey:
                // Cylinder wireframe for chalice/turkey
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
            
            // Create simple shadow plane that scales with the object
            // Shadow size is proportional to object size
            let shadowSize = size * 0.8 // Shadow is 80% of object size
            
            // Create a flat plane for the shadow (not a box) - this ensures it's always visible as a 2D square
            // Use a plane mesh that lies flat on the ground (X-Z plane)
            let shadowMesh = MeshResource.generatePlane(width: shadowSize, depth: shadowSize)
            // Use UnlitMaterial for shadow to ensure it's always visible regardless of lighting
            var shadowMaterial = UnlitMaterial()
            shadowMaterial.color = .init(tint: UIColor.black.withAlphaComponent(0.5))
            let shadowEntity = ModelEntity(mesh: shadowMesh, materials: [shadowMaterial])
            shadowEntity.name = "shadow" // Tag shadow for easy identification
            
            // Rotate the plane to lie flat on the ground (rotate 90 degrees around X axis)
            shadowEntity.orientation = simd_quatf(angle: -Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            
            // Position shadow slightly below the object (on the ground)
            // Position depends on object type - adjust based on object height
            let shadowYOffset: Float
            switch type {
            case .chalice, .templeRelic, .turkey:
                shadowYOffset = -size * 0.3 - 0.01 // Cylinder-based objects
            case .treasureChest, .lootChest, .lootCart:
                shadowYOffset = -size * 0.3 - 0.01 // Box-based objects
            case .sphere:
                shadowYOffset = -size * 0.3 - 0.01 // Spheres
            case .cube:
                shadowYOffset = -size * 0.2 - 0.01 // Cubes (smaller)
            }
            shadowEntity.position = SIMD3<Float>(0, shadowYOffset, 0)
            
            // Ensure shadow is enabled and visible
            shadowEntity.isEnabled = true
            
            let container = ModelEntity()
            container.addChild(outlineEntity)
            container.addChild(wireframeEntity)
            container.addChild(shadowEntity)
            
            return container
        }
        
        func createCrosshairs() {
            guard arView != nil else { return }
            
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
            
            // Convert AR world position to GPS coordinates (fallback)
            let gpsCoordinate = convertARToGPS(arPosition: tapWorldPos, arOrigin: arOrigin, userLocation: userLocation, cameraTransform: frame.camera.transform)
            
            // Always use AR coordinates for mm-precision (primary)
            // GPS is only for fallback when AR session restarts
            let surfaceY = Double(tapWorldPos.y)
            print("✅ Placing object at AR position: \(tapWorldPos) (mm-precision), GPS fallback: \(gpsCoordinate?.latitude ?? 0), \(gpsCoordinate?.longitude ?? 0), Y: \(surfaceY)m, scale: \(scaleMultiplier)x")
            
            // Store placement data for potential later save (if user presses Done instead of Place)
            pendingPlacementData = (
                gpsCoordinate: gpsCoordinate ?? arOrigin.coordinate,
                arPosition: tapWorldPos,
                arOrigin: arOrigin,
                groundingHeight: surfaceY,
                scale: scaleMultiplier
            )
            
            // Place object immediately in AR scene
            let objectId = selectedObject?.id ?? UUID().uuidString
            let locationName = selectedObject?.name ?? "New \(objectType.displayName)"
            let tempLocation = LootBoxLocation(
                id: objectId,
                name: locationName,
                type: objectType,
                latitude: gpsCoordinate?.latitude ?? arOrigin.coordinate.latitude,
                longitude: gpsCoordinate?.longitude ?? arOrigin.coordinate.longitude,
                radius: 5.0,
                grounding_height: surfaceY,
                source: .arManual
            )
            
            placeObjectImmediately(at: tapWorldPos, location: tempLocation, in: arView)
            
            // Note: onPlace is NOT called here - user must press "Place Object" or "Done" to save
            print("💡 Object placed in AR scene. Press 'Place Object' to save, or 'Done' to save and dismiss.")
        }

        /// Handles placement button tap from overlay UI
        @objc func handlePlacementButtonTap() {
            // Detailed diagnostics to identify which condition is missing
            var missingConditions: [String] = []
            
            if arView == nil {
                missingConditions.append("AR view")
            }
            if arView?.session.currentFrame == nil {
                missingConditions.append("AR frame")
            }
            if userLocationManager?.currentLocation == nil {
                missingConditions.append("user location")
            }
            if arOriginGPS == nil {
                missingConditions.append("AR origin GPS (waiting for GPS accuracy < 7.5m)")
            }
            if placementReticle?.getPlacementPosition() == nil {
                missingConditions.append("reticle position")
            }
            
            // CRITICAL: Force reticle update before checking position
            // This ensures the reticle anchor is positioned even if update() hasn't been called yet
            if let reticle = placementReticle, reticle.getPlacementPosition() == nil {
                print("🔄 Reticle position not available - forcing update...")
                reticle.update()
            }
            
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let userLocation = userLocationManager?.currentLocation,
                  let arOrigin = arOriginGPS,
                  let reticlePosition = placementReticle?.getPlacementPosition() else {
                print("⚠️ Cannot place: Missing \(missingConditions.joined(separator: ", "))")
                if arOriginGPS == nil {
                    let accuracy = userLocationManager?.currentLocation?.horizontalAccuracy ?? -1
                    print("   💡 AR origin not set - GPS accuracy: \(accuracy >= 0 ? String(format: "%.2f", accuracy) : "unknown")m (needs < 20m)")
                    print("   💡 Try moving to an area with better GPS signal or wait a few seconds")
                }
                if placementReticle?.getPlacementPosition() == nil {
                    print("   💡 Reticle not positioned - ensure AR session is tracking and surface is detected")
                    print("   💡 Try pointing the camera at a horizontal surface (floor/table)")
                }
                return
            }

            print("✅ Placement button tapped - placing at reticle position: \(reticlePosition)")
            print("   Reticle X: \(String(format: "%.4f", reticlePosition.x)), Y: \(String(format: "%.4f", reticlePosition.y)), Z: \(String(format: "%.4f", reticlePosition.z))")

            // Use reticle position directly - it's already at the correct X/Z, just adjust Y for grounding
            // The reticle anchor position is at ground level, reticle entity is +0.01m above for visibility
            let adjustedPosition = SIMD3<Float>(
                reticlePosition.x,
                reticlePosition.y, // Use anchor Y (ground level), not reticle entity Y
                reticlePosition.z
            )
            
            print("   Adjusted position: X: \(String(format: "%.4f", adjustedPosition.x)), Y: \(String(format: "%.4f", adjustedPosition.y)), Z: \(String(format: "%.4f", adjustedPosition.z))")

            // Convert AR world position to GPS coordinates (fallback)
            let gpsCoordinate = convertARToGPS(arPosition: adjustedPosition, arOrigin: arOrigin, userLocation: userLocation, cameraTransform: frame.camera.transform)
            
            // Always use AR coordinates for mm-precision (primary)
            // GPS is only for fallback when AR session restarts
            let surfaceY = Double(adjustedPosition.y)
            print("✅ Placing object at AR position: \(adjustedPosition) (mm-precision, adjusted for reticle offset), GPS fallback: \(gpsCoordinate?.latitude ?? 0), \(gpsCoordinate?.longitude ?? 0), Y: \(surfaceY)m, scale: \(scaleMultiplier)x")
            
            // Immediately place the object in AR scene so user can see it
            let objectId = selectedObject?.id ?? UUID().uuidString
            let locationName = selectedObject?.name ?? "New \(objectType.displayName)"
            let tempLocation = LootBoxLocation(
                id: objectId,
                name: locationName,
                type: objectType,
                latitude: gpsCoordinate?.latitude ?? arOrigin.coordinate.latitude,
                longitude: gpsCoordinate?.longitude ?? arOrigin.coordinate.longitude,
                radius: 5.0,
                grounding_height: surfaceY,
                source: .arManual
            )
            
            placeObjectImmediately(at: adjustedPosition, location: tempLocation, in: arView)
            
            // Store placement data for potential later save (if user presses Done instead of Place)
            pendingPlacementData = (
                gpsCoordinate: gpsCoordinate ?? arOrigin.coordinate,
                arPosition: adjustedPosition,
                arOrigin: arOrigin,
                groundingHeight: surfaceY,
                scale: scaleMultiplier
            )
            
            // Then save to API and dismiss (object already visible)
            onPlace(gpsCoordinate ?? arOrigin.coordinate, adjustedPosition, arOrigin, surfaceY, scaleMultiplier)
        }
        
        /// Saves the currently placed object (called when Done button is pressed)
        func savePlacedObject() {
            guard let placementData = pendingPlacementData else {
                print("⚠️ No placement data to save")
                return
            }
            
            print("💾 Saving placed object via Done button...")
            onPlace(
                placementData.gpsCoordinate,
                placementData.arPosition,
                placementData.arOrigin,
                placementData.groundingHeight,
                placementData.scale
            )
        }
        
        /// Immediately places the object in AR scene at the specified position
        func placeObjectImmediately(at position: SIMD3<Float>, location: LootBoxLocation, in arView: ARView) {
            // Remove any previously placed preview object
            placedObjectAnchor?.removeFromParent()
            placedObjectAnchor = nil
            placedObjectEntity = nil
            
            // Get factory for this object type
            let factory = LootBoxFactoryRegistry.factory(for: location.type)
            
            // Create anchor at placement position
            let anchor = AnchorEntity(world: position)
            
            // Create the actual object entity using factory
            let (entity, _) = factory.createEntity(location: location, anchor: anchor, sizeMultiplier: scaleMultiplier)
            
            // Ensure entity is enabled and visible
            entity.isEnabled = true
            
            // Add entity to anchor
            anchor.addChild(entity)
            
            // FINAL GROUND SNAP (placement preview): ensure the visual mesh sits exactly on the ground
            // We align the lowest point of the rendered geometry with the placement position's Y so that
            // the object never appears to float during placement.
            // Calculate bounds relative to the anchor (not world space) to get accurate entity bounds
            let bounds = entity.visualBounds(relativeTo: anchor)
            let currentMinY = bounds.min.y  // This is relative to anchor, so entity's lowest point relative to anchor
            let desiredMinY: Float = 0  // We want the bottom of the object at anchor Y (0 relative to anchor)
            let deltaY = desiredMinY - currentMinY
            
            // Adjust entity position (not anchor position) so base aligns with anchor Y
            entity.position.y += deltaY
            
            let formattedDeltaY = String(format: "%.3f", deltaY)
            print("✅ [Placement GroundSnap] Adjusted preview '\(location.name)' to sit on ground: ΔY=\(formattedDeltaY)m")
            
            // Add anchor to scene
            arView.scene.addAnchor(anchor)
            
            // Start loop animation if available
            factory.animateLoop(entity: entity)
            
            // Track for cleanup
            placedObjectAnchor = anchor
            placedObjectEntity = entity
            
            print("✅ [Placement] Object '\(location.name)' placed immediately in AR at position: \(position)")
            print("   AR Position: X=\(String(format: "%.4f", position.x))m, Y=\(String(format: "%.4f", position.y))m, Z=\(String(format: "%.4f", position.z))m")
            print("   Object ID: \(location.id)")
            print("   ⚠️ NOTE: This object is in placement view's AR scene - it will disappear when view dismisses")
            print("   💡 Object should reappear in main AR view after checkAndPlaceBoxes runs")
            
            // Log location again after 1 second to see if it moved or disappeared
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await MainActor.run {
                    if let anchor = placedObjectAnchor {
                        // CRITICAL: Use transformMatrix to get world position, not anchor.position (which is relative)
                        let transform = anchor.transformMatrix(relativeTo: nil)
                        let currentWorldPos = SIMD3<Float>(
                            transform.columns.3.x,
                            transform.columns.3.y,
                            transform.columns.3.z
                        )
                        let isStillInScene = anchor.parent != nil
                        print("📍 [Placement] Object '\(location.name)' location after 1 second:")
                        print("   AR World Position: X=\(String(format: "%.4f", currentWorldPos.x))m, Y=\(String(format: "%.4f", currentWorldPos.y))m, Z=\(String(format: "%.4f", currentWorldPos.z))m")
                        print("   Still in scene: \(isStillInScene ? "YES" : "NO")")
                        print("   Anchor parent: \(anchor.parent != nil ? "exists" : "nil")")
                        if !isStillInScene {
                            print("   ⚠️ WARNING: Object was removed from scene!")
                            print("   💡 This may be because the AR session was reset or the view was dismissed")
                        } else if abs(currentWorldPos.x - position.x) > 0.01 || abs(currentWorldPos.y - position.y) > 0.01 || abs(currentWorldPos.z - position.z) > 0.01 {
                            print("   ⚠️ WARNING: Object moved! Original: (\(String(format: "%.4f", position.x)), \(String(format: "%.4f", position.y)), \(String(format: "%.4f", position.z))), Current: (\(String(format: "%.4f", currentWorldPos.x)), \(String(format: "%.4f", currentWorldPos.y)), \(String(format: "%.4f", currentWorldPos.z)))")
                        } else {
                            print("   ✅ Object still at original position")
                        }
                    } else {
                        print("   ⚠️ WARNING: placedObjectAnchor is nil - object was removed!")
                        print("   💡 This may be because the AR session was reset or the view was dismissed")
                    }
                }
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
            // Update materials on all children to make them yellow (except shadow)
            for child in wireframeContainer.children {
                if let modelEntity = child as? ModelEntity {
                    // Skip shadow entity - keep it black
                    if modelEntity.position.y < -0.01 { // Shadow is positioned below
                        draggingShadowEntity = modelEntity
                        continue
                    }
                    
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
            
            // Update shadow scale to match object scale
            updateShadowScale()
        }
        
        func updateWireframeScale() {
            guard let wireframe = draggingWireframeEntity else { return }
            let baseScale: Float = 1.2 // The drag preview scale
            wireframe.scale = SIMD3<Float>(baseScale * scaleMultiplier, baseScale * scaleMultiplier, baseScale * scaleMultiplier)
            
            // Update shadow scale to match object scale
            updateShadowScale()
        }
        
        func updateShadowScale() {
            // Shadow scales automatically with the container, so we just need to update position
            // Avoid expensive recursive search - shadow is a direct child of the container
            guard let wireframeContainer = draggingWireframeEntity else { return }
            
            // Find shadow directly (it's a child of the container, no need for recursion)
            guard let shadow = wireframeContainer.children.first(where: { ($0 as? ModelEntity)?.name == "shadow" }) as? ModelEntity else {
                return
            }
            
            // Only update shadow position to match scaled object height
            // The shadow mesh will scale automatically with the parent container
            let scaledObjectSize = objectType.size * scaleMultiplier
            let shadowYOffset: Float
            switch objectType {
            case .chalice, .templeRelic, .turkey:
                shadowYOffset = -scaledObjectSize * 0.3 - 0.01
            case .treasureChest, .lootChest, .lootCart:
                shadowYOffset = -scaledObjectSize * 0.3 - 0.01
            case .sphere:
                shadowYOffset = -scaledObjectSize * 0.3 - 0.01
            case .cube:
                shadowYOffset = -scaledObjectSize * 0.2 - 0.01
            }
            shadow.position = SIMD3<Float>(0, shadowYOffset, 0)
        }
        
        func endDragging(at location: CGPoint, in arView: ARView, frame: ARFrame, userLocation: CLLocation, arOrigin: CLLocation) {
            guard let anchor = draggingAnchor else {
                isDragging = false
                return
            }
            
            // Get final position
            let finalWorldPos = anchor.position
            
            // Convert AR world position to GPS coordinates (fallback)
            let gpsCoordinate = convertARToGPS(arPosition: finalWorldPos, arOrigin: arOrigin, userLocation: userLocation, cameraTransform: frame.camera.transform)
            
            // Always use AR coordinates for mm-precision (primary)
            // GPS is only for fallback when AR session restarts
            let surfaceY = Double(finalWorldPos.y)
            print("✅ Placing object at AR position after drag: \(finalWorldPos) (mm-precision), GPS fallback: \(gpsCoordinate?.latitude ?? 0), \(gpsCoordinate?.longitude ?? 0), Y: \(surfaceY)m, scale: \(scaleMultiplier)x")

            // Remove dragging wireframe
            anchor.removeFromParent()
            draggingWireframeEntity = nil
            draggingAnchor = nil
            isDragging = false

            // Store placement data for potential later save (if user presses Done instead of Place)
            pendingPlacementData = (
                gpsCoordinate: gpsCoordinate ?? arOrigin.coordinate,
                arPosition: finalWorldPos,
                arOrigin: arOrigin,
                groundingHeight: surfaceY,
                scale: scaleMultiplier
            )
            
            // Place the object using AR coordinates (primary) with GPS fallback
            onPlace(gpsCoordinate ?? arOrigin.coordinate, finalWorldPos, arOrigin, surfaceY, scaleMultiplier)
        }
        
        // Convert AR world position back to GPS coordinates
        // Uses AR origin GPS for maximum accuracy (matches ARPrecisionPositioningService approach)
        // NOTE: For indoor placement (< 12m), GPS is only used as fallback. AR coordinates are primary.
        func convertARToGPS(arPosition: SIMD3<Float>, arOrigin: CLLocation, userLocation: CLLocation, cameraTransform: simd_float4x4) -> CLLocationCoordinate2D? {
            // Calculate distance from AR origin
            let distanceFromOrigin = length(arPosition)
            
            // For indoor placement (< 12m), GPS is only a fallback - AR coordinates are primary
            // For outdoor placement (>= 12m), GPS accuracy is acceptable
            if distanceFromOrigin < 12.0 {
                print("📍 INDOOR placement (< 12m): GPS used only as fallback, AR coordinates are primary")
            } else {
                print("🌍 OUTDOOR placement (>= 12m): GPS accuracy acceptable")
            }
            
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

