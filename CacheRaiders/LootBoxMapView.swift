import SwiftUI
import MapKit
import CoreLocation

// MARK: - Map Annotation Model
struct MapAnnotationItem: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let isUserLocation: Bool
    let lootBoxLocation: LootBoxLocation?
}

// MARK: - Loot Box Map View
struct LootBoxMapView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @State private var position = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0), // Will be updated when user location is available
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    ))
    @State private var hasInitialized = false

    // Add mode state
    @State private var isAddModeActive = false
    @State private var selectedItemType: LootBoxType = .goldenIdol
    @State private var crosshairPosition: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var crosshairScreenPosition: CGPoint = .zero

    // Map stability controls
    @State private var shouldAutoCenter = false // Start with manual control
    @State private var lastUpdateTime = Date()

    // Feedback state
    @State private var showSuccessMessage = false
    @State private var successMessage = ""
    @State private var lastAddTime = Date()
    
    // Combine user location and loot boxes into a single annotation array
    private var allAnnotations: [MapAnnotationItem] {
        var annotations: [MapAnnotationItem] = []
        
        // Add user location pin
        if let userLocation = userLocationManager.currentLocation {
            annotations.append(MapAnnotationItem(
                id: "user_location",
                coordinate: userLocation.coordinate,
                isUserLocation: true,
                lootBoxLocation: nil
            ))
        }
        
        // Add crosshair preview marker when in add mode
        if isAddModeActive {
            annotations.append(MapAnnotationItem(
                id: "crosshair_preview",
                coordinate: crosshairPosition,
                isUserLocation: false,
                lootBoxLocation: LootBoxLocation(
                    id: "preview",
                    name: "New \(selectedItemType.displayName)",
                    type: selectedItemType,
                    latitude: crosshairPosition.latitude,
                    longitude: crosshairPosition.longitude,
                    radius: 5.0
                )
            ))
        }
        
        // Add all uncollected loot box locations that have valid GPS coordinates
        // Exclude AR-only locations (AR_SPHERE_ prefix but not AR_SPHERE_MAP_) and locations with invalid coordinates (0,0)
        let filteredLocations = locationManager.locations.filter { location in
            guard !location.collected else { 
                return false 
            }
            guard !(location.latitude == 0 && location.longitude == 0) else { 
                return false // Exclude invalid GPS coordinates
            }
            
            // Include map-added spheres (AR_SPHERE_MAP_ prefix)
            if location.id.hasPrefix("AR_SPHERE_MAP_") {
                print("🗺️ Including map sphere: \(location.name) at (\(location.latitude), \(location.longitude))")
                return true
            }
            
            // Exclude AR-only spheres (AR_SPHERE_ prefix without MAP)
            if location.id.hasPrefix("AR_SPHERE_") {
                return false
            }
            
            // Include all other items (AR_ITEM_, GPS-based, etc.)
            return true
        }
        
        annotations.append(contentsOf: filteredLocations
            .map { location in
                return MapAnnotationItem(
                    id: location.id,
                    coordinate: location.coordinate,
                    isUserLocation: false,
                    lootBoxLocation: location
                )
            })
        
        return annotations
    }
    
    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $position) {
                    ForEach(allAnnotations, id: \.id) { annotation in
                        if annotation.isUserLocation {
                            // User location pin
                            Annotation("", coordinate: annotation.coordinate) {
                                VStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .foregroundColor(.blue)
                                        .font(.title2)
                                        .background(Circle().fill(.white))
                                        .shadow(radius: 3)

                                    Text("You")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .padding(4)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                }
                            }
                        } else if let location = annotation.lootBoxLocation {
                            // Check if this is the preview marker (crosshair)
                            let isPreview = location.id == "preview"
                            
                            // Loot box pin
                            Annotation(location.name, coordinate: annotation.coordinate) {
                                VStack(spacing: 4) {
                                    Image(systemName: isPreview ? "plus.circle.fill" :
                                          (location.collected ? "checkmark.circle.fill" :
                                          (location.type == .sphere ? "circle.fill" : "mappin.circle.fill")))
                                        .foregroundColor(isPreview ? .blue :
                                                        (location.collected ? .green :
                                                        (location.type == .sphere ? .red : .red)))
                                        .font(.title)
                                        .background(Circle().fill(isPreview ? .white.opacity(0.8) : .white))
                                        .shadow(radius: 3)
                                        .opacity(isPreview ? 0.7 : 1.0)

                                    Text(isPreview ? "New \(location.type.displayName)" : location.name)
                                        .font(.caption)
                                        .padding(4)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                .gesture(
                    isAddModeActive ?
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Update crosshair position based on drag/tap
                            crosshairScreenPosition = value.location
                            if let coordinate = proxy.convert(value.location, from: .local) {
                                crosshairPosition = coordinate
                            }
                        }
                    : nil
                )
                .onChange(of: isAddModeActive) { isActive in
                    // When entering add mode, initialize crosshair to map center
                    if isActive {
                        // Extract center from current map position
                        if let center = getCenterFromPosition(position) {
                            crosshairPosition = center
                        }
                        // Reset screen position - will be set by GeometryReader
                        crosshairScreenPosition = .zero
                    }
                }
            }

            // Crosshairs overlay when in add mode
            if isAddModeActive {
                GeometryReader { geometry in
                    ZStack {
                        // Drag instruction
                        VStack {
                            HStack {
                                Spacer()
                                Text("Drag anywhere to move crosshairs")
                                    .font(.caption)
                                    .padding(6)
                                    .background(Color.red.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                                    .padding(.top, 40)
                                Spacer()
                            }

                            Spacer()
                        }

                        // Initialize crosshair to center if not set
                        let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        let crosshairPos = crosshairScreenPosition == .zero ? center : crosshairScreenPosition
                        
                        VStack(spacing: 4) {
                            // Coordinates display
                            Text(String(format: "%.6f, %.6f", crosshairPosition.latitude, crosshairPosition.longitude))
                                .font(.system(size: 10, design: .monospaced))
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                            
                            ZStack {
                                // Crosshair lines
                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 3, height: 40)
                                    .shadow(radius: 2)
                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 40, height: 3)
                                    .shadow(radius: 2)
                                Circle()
                                    .fill(Color.red.opacity(0.4))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.red, lineWidth: 2)
                                    )
                            }
                        }
                        .position(crosshairPos)
                    }
                    .onAppear {
                        // Initialize crosshair screen position to center
                        if crosshairScreenPosition == .zero {
                            crosshairScreenPosition = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        }
                    }
                }
            }

            // Add mode controls overlay
            VStack {
                HStack {
                    // Instructions when not in add mode
                    if !isAddModeActive {
                        Text("Tap + to add items")
                            .font(.caption)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding(.leading)
                    }

                    Spacer()

                    // Map control buttons (always visible)
                    VStack(spacing: 8) {
                        Button(action: {
                            updateRegion()
                        }) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.blue.opacity(0.8))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            shouldAutoCenter.toggle()
                        }) {
                            Image(systemName: shouldAutoCenter ? "location.slash.fill" : "location")
                                .foregroundColor(shouldAutoCenter ? .red : .green)
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.trailing)

                    if isAddModeActive {
                        VStack(spacing: 10) {
                            // Item type picker
                            Picker("Item Type", selection: $selectedItemType) {
                                ForEach(LootBoxType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .background(Color.white.opacity(0.9))
                            .cornerRadius(8)
                            .padding(.horizontal)

                            // Add button
                            Button(action: {
                                addFindableItem(at: crosshairPosition)
                            }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add Findable Item")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .cornerRadius(10)
                                .shadow(radius: 4)
                            }

                            // Cancel button
                            Button(action: {
                                withAnimation {
                                    isAddModeActive = false
                                }
                            }) {
                                Text("Cancel")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Color.red)
                                    .cornerRadius(10)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(15)
                        .padding(.trailing)
                    }
                }

                Spacer()

                // Main add button
                Button(action: {
                    withAnimation {
                        isAddModeActive.toggle()
                        if isAddModeActive {
                            // Center crosshairs on current map center
                            updateCrosshairToMapCenter()
                        }
                    }
                }) {
                    Image(systemName: isAddModeActive ? "xmark" : "plus")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(16)
                        .background(isAddModeActive ? Color.red : Color.blue)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .padding(.bottom, 30)
            }

            // Success message overlay
            if showSuccessMessage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(successMessage)
                            .font(.headline)
                            .padding()
                            .background(Color.green.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .shadow(radius: 4)
                            .padding(.bottom, 100)
                        Spacer()
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            // Request location permission and start updating location
            userLocationManager.requestLocationPermission()
            userLocationManager.startUpdatingLocation()
            
            // Try to center on user location immediately if available
            if let userLocation = userLocationManager.currentLocation {
                updateRegion()
                hasInitialized = true
            }
        }
        .onChange(of: userLocationManager.currentLocation) {
            // On first location update, center the map if not already initialized
            if !hasInitialized, let userLocation = userLocationManager.currentLocation {
                updateRegion()
                hasInitialized = true
            }
            
            // Only auto-center if enabled and debounce to prevent rapid updates
            if shouldAutoCenter && hasInitialized {
                let now = Date()
                if now.timeIntervalSince(lastUpdateTime) > 1.0 { // Minimum 1 second between updates
                    lastUpdateTime = now
                    updateRegion()
                }
            }
        }
    }
    
    // Helper function to extract center coordinate from MapCameraPosition
    private func getCenterFromPosition(_ position: MapCameraPosition) -> CLLocationCoordinate2D? {
        // MapCameraPosition doesn't support pattern matching directly
        // Instead, we'll use the user's current location or a default
        if let userLocation = userLocationManager.currentLocation {
            return userLocation.coordinate
        }
        return nil
    }
    
    private func updateRegion() {
        // Center on user location if available, otherwise use default
        if let userLocation = userLocationManager.currentLocation {
            // Center on user location with a reasonable zoom level
            position = .region(MKCoordinateRegion(
                center: userLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // ~1km view
            ))
        } else if !locationManager.locations.isEmpty {
            // Fallback: center on first loot box if no user location
            let firstLocation = locationManager.locations[0]
            position = .region(MKCoordinateRegion(
                center: firstLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    private func updateCrosshairToMapCenter() {
        // Extract center coordinate from current map position
        if let center = getCenterFromPosition(position) {
            crosshairPosition = center
        } else {
            // Fallback to user location or first loot box
            if let userLocation = userLocationManager.currentLocation {
                crosshairPosition = userLocation.coordinate
            } else if !locationManager.locations.isEmpty {
                crosshairPosition = locationManager.locations[0].coordinate
            }
        }

        // Reset crosshair to center (will be set properly by GeometryReader)
        crosshairScreenPosition = .zero
    }

    private func addFindableItem(at coordinate: CLLocationCoordinate2D) {
        if selectedItemType == .sphere {
            // For spheres, trigger placement in the current AR room AND create a map marker
            locationManager.shouldPlaceSphere = true

            // Also create a map location for the sphere so it shows on the map
            let sphereLocation = LootBoxLocation(
                id: "AR_SPHERE_MAP_" + UUID().uuidString, // Special prefix to identify map-only spheres
                name: "Mysterious Sphere",
                type: .sphere,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: 5.0
            )

            locationManager.addLocation(sphereLocation)
            
            // Debug: Verify the location was added correctly
            print("🗺️ Added sphere location to map:")
            print("   ID: \(sphereLocation.id)")
            print("   Name: \(sphereLocation.name)")
            print("   Coordinates: (\(sphereLocation.latitude), \(sphereLocation.longitude))")
            print("   Collected: \(sphereLocation.collected)")
            print("   Total locations in manager: \(locationManager.locations.count)")

            // Show success message
            successMessage = "Sphere added to AR room!"
            showSuccessMessage = true

            // Hide message after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSuccessMessage = false
            }

            print("🎯 Triggered sphere placement in AR room and added map marker at (\(coordinate.latitude), \(coordinate.longitude))")
        } else {
            // For other items, queue them for AR placement
            let itemNames = [
                LootBoxType.goldenIdol: ["Golden Idol", "Golden Statue", "Gold Relic"],
                LootBoxType.chalice: ["Sacred Chalice", "Ancient Chalice", "Golden Chalice"],
                LootBoxType.ancientArtifact: ["Ancient Artifact", "Ancient Pottery", "Ancient Scroll"],
                LootBoxType.templeRelic: ["Temple Relic", "Sacred Relic", "Temple Treasure"],
                LootBoxType.puzzleBox: ["Puzzle Box", "Mystery Box", "Enigma Container"],
                LootBoxType.stoneTablet: ["Stone Tablet", "Ancient Tablet", "Carved Stone"],
                LootBoxType.treasureChest: ["Treasure Chest", "Ancient Chest", "Locked Chest"]
            ]

            let names = itemNames[selectedItemType] ?? ["Unknown Item"]
            let randomName = names.randomElement() ?? "Findable Item"

            // Create AR item location for placement
            let arLocation = LootBoxLocation(
                id: "AR_ITEM_" + UUID().uuidString,
                name: randomName,
                type: selectedItemType,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: 5.0
            )

            // Queue it for AR placement
            locationManager.pendingARItem = arLocation
            locationManager.addLocation(arLocation)
            successMessage = "\(selectedItemType.displayName) added to AR room!"
            print("✅ Queued \(selectedItemType.displayName) '\(arLocation.name)' for AR placement")
        }

        // Show success message (if not already set for spheres)
        if successMessage.isEmpty {
            successMessage = "\(selectedItemType.displayName) added!"
        }
        showSuccessMessage = true

        // Hide message after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showSuccessMessage = false
        }

        print("🎯 Added \(selectedItemType.displayName) to AR room and map at (\(coordinate.latitude), \(coordinate.longitude))")

        // Reset add mode after adding
        withAnimation {
            isAddModeActive = false
        }
    }
}

