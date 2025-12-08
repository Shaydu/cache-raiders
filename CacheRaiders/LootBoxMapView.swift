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
    @Binding var nearestObjectDirection: Double?
    let onObjectTap: (LootBoxLocation) -> Void

    init(locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager, nearestObjectDirection: Binding<Double?>, onObjectTap: @escaping (LootBoxLocation) -> Void = { _ in }) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        self._nearestObjectDirection = nearestObjectDirection
        self.onObjectTap = onObjectTap
    }
    @State private var position = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0), // Will be updated when user location is available
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    ))
    @State private var hasInitialized = false

    // Add mode state
    @State private var isAddModeActive = false
    @State private var selectedItemType: LootBoxType = .chalice
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
    // Explicitly depend on showFoundOnMap, collected status, selection, and locations count to ensure view updates
    private var allAnnotations: [MapAnnotationItem] {
        // Access showFoundOnMap to create explicit dependency for SwiftUI updates
        let showFound = locationManager.showFoundOnMap
        // Also access collected count to force updates when items are found
        let collectedCount = locationManager.locations.filter { $0.collected }.count
        _ = collectedCount // Explicitly use to create dependency
        // Access selectedDatabaseObjectId to force updates when selection changes
        let selectedId = locationManager.selectedDatabaseObjectId
        _ = selectedId // Explicitly use to create dependency
        // Access total locations count to force updates when objects are added via WebSocket
        let totalLocationsCount = locationManager.locations.count
        _ = totalLocationsCount // Explicitly use to create dependency

        // Explicitly access user location and heading to create dependencies for SwiftUI updates
        let userLocation = userLocationManager.currentLocation
        let userHeading = userLocationManager.heading
        _ = userHeading // Explicitly use to create dependency
        
        var annotations: [MapAnnotationItem] = []
        
        // Add user location pin
        if let location = userLocation {
            annotations.append(MapAnnotationItem(
                id: "user_location",
                coordinate: location.coordinate,
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
        
        // Add loot box locations that have valid GPS coordinates
        // Filter by game mode: Open mode shows all items, Story mode shows only NPCs
        // Also filter by selection: if an item is selected, show only that item
        let filteredLocations = locationManager.locations.filter { location in
            let isNPC = location.id.hasPrefix("npc_")

            // Game Mode Filtering
            switch locationManager.gameMode {
            case .open:
                // Open Mode: Show all items (API objects, NPCs, map-added items)
                break // Continue with other filters

            case .deadMensSecrets:
                // Story Mode: Only show NPCs (story mode doesn't use API objects)
                if !isNPC {
                    return false // Hide all non-NPC items in story mode
                }
            }

            // Selection doesn't hide other items on map - it's just for navigation
            // Unlike AR which highlights the selected item, map shows all valid items
            // This provides better situational awareness

            // NPCs are always shown (never collected, always visible)
            if isNPC {
                guard !(location.latitude == 0 && location.longitude == 0) else {
                    return false // Exclude invalid GPS coordinates
                }
                return true // Always show NPCs
            }

            // If showFoundOnMap is disabled, exclude collected items
            if !showFound && location.collected {
                return false
            }

            // Exclude invalid GPS coordinates
            guard !(location.latitude == 0 && location.longitude == 0) else {
                return false
            }

            // Include items that should show on map
            if !location.shouldShowOnMap {
                return false
            }

            // Include map-added items (spheres, cubes, etc.)
            if location.source == .map {
                return true
            }

            // Include all other valid items
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
        
        // Removed excessive debug logging to improve performance
        // State modification moved to onChange modifier to avoid modifying state during view update
        
        return annotations
    }
    
    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $position, bounds: MapCameraBounds(minimumDistance: 1, maximumDistance: nil)) {
                    ForEach(allAnnotations, id: \.id) { annotation in
                        if annotation.isUserLocation {
                            // User location pin
                            Annotation("", coordinate: annotation.coordinate) {
                                VStack(spacing: 4) {
                                    // Rotate the icon based on user's heading/direction of travel
                                    // MapKit uses 0 = north, so we rotate the icon to match
                                    // Apply same 180° adjustment as admin panel for iOS course/direction of travel
                                    // Use location.north.line.fill for a directional indicator
                                    let adjustedHeading = (userLocationManager.heading ?? 0) + 180.0
                                    Image(systemName: "location.north.line.fill")
                                        .foregroundColor(.blue)
                                        .font(.title2)
                                        .background(Circle().fill(.white))
                                        .shadow(radius: 3)
                                        .rotationEffect(.degrees(adjustedHeading))

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
                            // Check if this is an NPC (Dead Men's Secrets mode)
                            let isNPC = location.id.hasPrefix("npc_")

                            // Loot box pin
                            Annotation("", coordinate: annotation.coordinate) {
                                LootBoxAnnotationView(
                                    location: location,
                                    isPreview: isPreview,
                                    isNPC: isNPC,
                                    onTap: {
                                        // Don't show detail sheet for preview markers
                                        if !isPreview {
                                            onObjectTap(location)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onMapCameraChange { context in
                    // Force scale to always be visible by accessing the underlying map view
                    // This is handled via the MapStyle and should show scale by default
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
                .onChange(of: isAddModeActive) {
                    // When entering add mode, initialize crosshair to map center
                    if isAddModeActive {
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
                            Text(String(format: "%.8f, %.8f", crosshairPosition.latitude, crosshairPosition.longitude))
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
                    Spacer()

                    // Map control button - follow me toggle
                    Button(action: {
                        shouldAutoCenter.toggle()
                        // Also center immediately when toggling on
                        if shouldAutoCenter {
                            updateRegion()
                        }
                    }) {
                        Image(systemName: shouldAutoCenter ? "location.fill" : "location")
                            .foregroundColor(shouldAutoCenter ? .green : .white)
                            .padding(8)
                            .background(shouldAutoCenter ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                            .clipShape(Circle())
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
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(8)

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

            // Direction indicator overlay (shows when navigating to target)
            if let direction = nearestObjectDirection, !direction.isNaN, direction.isFinite {
                GeometryReader { geometry in
                    VStack {
                        HStack {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 60, height: 60)
                                Image(systemName: "location.north.line.fill")
                                    .font(.title)
                                    .foregroundColor(.blue)
                                    .rotationEffect(.degrees(direction))
                                    .shadow(radius: 2)
                            }
                            .padding(.trailing, 20)
                            .padding(.top, geometry.safeAreaInsets.top + 20)
                        }
                        Spacer()
                    }
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            // Request location permission and start updating location
            userLocationManager.requestLocationPermission()
            userLocationManager.startUpdatingLocation()
            
            // Try to center on user location immediately if available
            if userLocationManager.currentLocation != nil {
                updateRegion()
                hasInitialized = true
            }
        }
        // Debug logging removed to avoid state modification during view update
        // Annotation count tracking was causing "Modifying state during view update" warning
        .onChange(of: userLocationManager.currentLocation) {
            // On first location update, center the map if not already initialized
            if !hasInitialized, userLocationManager.currentLocation != nil {
                updateRegion()
                hasInitialized = true
            }
            
            // Only auto-center if enabled and debounce to prevent rapid updates
            // Increased debounce time from 1.0s to 2.0s to reduce map jumping
            if shouldAutoCenter && hasInitialized {
                let now = Date()
                if now.timeIntervalSince(lastUpdateTime) > 2.0 { // Minimum 2 seconds between updates
                    lastUpdateTime = now
                    updateRegion()
                }
            }
        }
        .onChange(of: locationManager.showFoundOnMap) {
            // Force view update when showFoundOnMap toggle changes
            // Removed debug print to improve performance
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
            // Create a map location for the sphere FIRST (this will be used for both map and AR)
            let sphereLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: "Mysterious Sphere",
                type: .sphere,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: 5.0,
                source: .map // Map-added sphere
            )

            locationManager.addLocation(sphereLocation)
            
            // Queue it for AR placement (same as other items)
            locationManager.pendingARItem = sphereLocation
            
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
        } else if selectedItemType == .cube {
            // Create AR item location for cube with fixed name
            let arLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: "Mysterious Cube",
                type: selectedItemType,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: 5.0,
                source: .map // Map-added item
            )

            // Queue it for AR placement
            locationManager.pendingARItem = arLocation
            locationManager.addLocation(arLocation)
            successMessage = "\(selectedItemType.displayName) added to AR room!"
            print("✅ Queued \(selectedItemType.displayName) '\(arLocation.name)' for AR placement")
        } else {
            // For other items, queue them for AR placement
            // Use factories to get item names (eliminates hardcoded dictionary)
            let itemNames = Dictionary(uniqueKeysWithValues: LootBoxType.allCases.map { ($0, $0.factory.itemNames) })

            let names = itemNames[selectedItemType] ?? ["Unknown Item"]
            let randomName = names.randomElement() ?? "Findable Item"

            // Create AR item location for placement
            let arLocation = LootBoxLocation(
                id: UUID().uuidString,
                name: randomName,
                type: selectedItemType,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: 5.0,
                source: .map // Map-added item
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

// MARK: - Loot Box Annotation View Helper
/// Helper view to simplify complex annotation rendering
struct LootBoxAnnotationView: View {
    let location: LootBoxLocation
    let isPreview: Bool
    let isNPC: Bool
    let onTap: () -> Void
    
    private var iconName: String {
        if isPreview {
            return "plus.circle.fill"
        } else if isNPC {
            // NPC icon - person for skeleton, paw for corgi
            if location.name.contains("Bones") || location.name.contains("skeleton") {
                return "person.fill"
            } else {
                return "pawprint.fill"
            }
        } else if location.collected {
            return "checkmark.circle.fill"
        } else {
            switch location.type {
            case .sphere:
                return "circle.fill"
            case .cube:
                return "cube.fill"
            default:
                return "mappin.circle.fill"
            }
        }
    }
    
    private var iconColor: Color {
        if isPreview {
            return .blue
        } else if isNPC {
            // Gold color for NPCs (Captain Bones theme)
            return Color(red: 1.0, green: 0.843, blue: 0.0)
        } else if location.collected {
            return .red
        } else {
            // Gold for unfound items
            return Color(red: 1.0, green: 0.843, blue: 0.0)
        }
    }
    
    private var displayText: String {
        if isPreview {
            return "New \(location.type.displayName)"
        } else {
            return location.name
        }
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.title)
                    .background(Circle().fill(isPreview ? .white.opacity(0.8) : .white))
                    .shadow(radius: 3)
                    .opacity(isPreview ? 0.7 : 1.0)

                Text(displayText)
                    .font(.caption)
                    .padding(4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(4)
            }
        }
        .buttonStyle(PlainButtonStyle()) // Remove button styling to keep the pin appearance
    }
}

