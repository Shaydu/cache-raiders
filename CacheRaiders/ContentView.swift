import SwiftUI
import CoreLocation

// MARK: - NPC Info
struct ConversationNPC: Equatable {
    let id: String
    let name: String
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var locationManager = LootBoxLocationManager()
    @StateObject private var userLocationManager = UserLocationManager()
    @StateObject private var treasureHuntService = TreasureHuntService()
    @StateObject private var inventoryService = InventoryService()
    
    // Use enum-based sheet state to prevent multiple sheets being presented simultaneously
    enum SheetType: Identifiable, Equatable {
        case locationConfig
        case arPlacement
        case settings
        case leaderboard
        case skeletonConversation(npcId: String, npcName: String)
        case treasureMap
        case clueDrawer
        case inventory
        case nfcScanner

        var id: String {
            switch self {
            case .locationConfig: return "locationConfig"
            case .arPlacement: return "arPlacement"
            case .settings: return "settings"
            case .leaderboard: return "leaderboard"
            case .skeletonConversation(let npcId, _): return "skeletonConversation_\(npcId)"
            case .treasureMap: return "treasureMap"
            case .clueDrawer: return "clueDrawer"
            case .inventory: return "inventory"
            case .nfcScanner: return "nfcScanner"
            }
        }
    }
    
    @State private var presentedSheet: SheetType? = nil
    @State private var conversationNPC: ConversationNPC? = nil
    @State private var nearbyLocations: [LootBoxLocation] = []
    @State private var distanceToNearest: Double?
    @State private var temperatureStatus: String?
    @State private var collectionNotification: String?
    @State private var inventoryNotification: String?
    @State private var nearestObjectDirection: Double?
    
    // PERFORMANCE: Task for debouncing location updates to prevent excessive API calls
    @State private var locationUpdateTask: Task<Void, Never>?
    
    // Computed property for loot box counter - counts ALL locations from database (not just nearby)
    // This matches the admin panel which shows all objects, not just nearby ones
    private var lootBoxCounter: (found: Int, total: Int) {
        // Use locationManager.locations to get ALL objects from the database
        // Filter out temporary AR-only items (they're not in the database)
        let allLocations = locationManager.locations.filter { location in
            // Include all API/map objects (they're in the database)
            // Exclude temporary AR-only items (they're not persisted)
            return location.shouldPersist || location.shouldSyncToAPI
        }
        
        let foundCount = allLocations.filter { $0.collected }.count
        let totalCount = allLocations.count
        return (found: foundCount, total: totalCount)
    }

    // Helper function to format distance in meters
    private func formatDistance(_ meters: Double) -> String {
        if meters < 1.0 {
            // Show centimeters for very close distances
            return String(format: "%.0fcm", meters * 100)
        } else if meters < 100 {
            // Show one decimal place for distances under 100m
            return String(format: "%.1fm", meters)
        } else {
            // Show whole meters for larger distances
            return String(format: "%.0fm", meters)
        }
    }

    // Helper function to convert bearing to compass direction
    private func bearingToCompassDirection(_ bearing: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((bearing + 22.5) / 45.0) % 8
        return directions[index]
    }
    
    // GPS connection quality levels
    private enum GPSQuality {
        case disconnected  // No location at all
        case degraded      // Location available but poor accuracy (> 50m)
        case good          // Good accuracy (≤ 50m)
    }

    // Computed property to determine GPS connection quality
    private var gpsQuality: GPSQuality {
        guard let location = userLocationManager.currentLocation else {
            return .disconnected
        }
        // Check horizontal accuracy to determine quality
        if location.horizontalAccuracy < 0 {
            return .disconnected  // Invalid accuracy means disconnected
        } else if location.horizontalAccuracy <= 50 {
            return .good  // ≤ 50m is good accuracy
        } else {
            return .degraded  // > 50m is degraded accuracy
        }
    }

    // Legacy property for backward compatibility
    private var isGPSConnected: Bool {
        return gpsQuality != .disconnected
    }
    
    // MARK: - View Components
    
    private var topOverlayView: some View {
        VStack {
            topToolbarView
            
            // Location coordinates removed for cleaner UI
            // locationDisplayView
            
            Spacer()
            
            notificationsView
        }
    }
    
    private var topToolbarView: some View {
        HStack {
            leftButtonsView
            
            Spacer()
            
            directionIndicatorView
            
            Spacer()
            
            rightButtonsView
        }
    }
    
    private var leftButtonsView: some View {
        HStack(spacing: 8) {
            Button(action: {
                // Use async to avoid modifying state during view update
                Task { @MainActor in
                    presentedSheet = .locationConfig
                }
            }) {
                Image(systemName: "map")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
            }
            
            // In Story Mode: Show clue drawer button instead of + button
            // In Open Mode: Show + button for AR placement
            if locationManager.gameMode == .deadMensSecrets {
                Button(action: {
                    // Open clue drawer in story mode
                    Task { @MainActor in
                        presentedSheet = .clueDrawer
                    }
                }) {
                    Image(systemName: "book.closed.fill")
                        .foregroundColor(.orange)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
            } else {
                Button(action: {
                    // Use async to avoid modifying state during view update
                    Task { @MainActor in
                        presentedSheet = .arPlacement
                    }
                }) {
                    Image(systemName: "plus")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
            }
        }
        .padding(.top)
    }
    
    private var directionIndicatorView: some View {
        Group {
            // In Dead Men's Secrets mode, only show navigation after skeleton gives the map
            let shouldShowNav: Bool = {
                if locationManager.gameMode == .deadMensSecrets {
                    return treasureHuntService.shouldShowNavigation
                } else {
                    // In other modes, show if we have distance data
                    return distanceToNearest != nil
                }
            }()

            if shouldShowNav, let distance = distanceToNearest {
                VStack(spacing: 2) {
                    Button(action: {
                        // Open treasure map (only available after skeleton gives map)
                        if treasureHuntService.hasMap {
                            presentedSheet = .treasureMap
                        } else {
                            // Manually send location to server (also sent automatically every 5 seconds)
                            userLocationManager.sendCurrentLocationToServer()
                        }
                    }) {
                        HStack(spacing: 2) {
                            Image(systemName: "location.north.line.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .rotationEffect(.degrees(nearestObjectDirection ?? 0))

                            Text("GPS")
                                .font(.system(size: 10))
                                .fontWeight(.bold)
                                .foregroundColor(.white)

                            Text(formatDistance(distance))
                                .font(.system(size: 10))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                        .overlay(directionIndicatorBorder)
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Directional clue text below the GPS box
                    if let direction = nearestObjectDirection {
                        Text("Head \(bearingToCompassDirection(direction)) to find the treasure")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
    
    private var directionArrowView: some View {
        Group {
            if let direction = nearestObjectDirection {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(direction))
            } else {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }
        }
    }
    
    private var directionIndicatorBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(directionIndicatorBorderColor, lineWidth: 2)
    }
    
    private var directionIndicatorBorderColor: Color {
        // Show GPS quality via border color (2px border)
        switch gpsQuality {
        case .good:
            return .green      // Green: Full GPS connectivity (≤ 50m accuracy)
        case .degraded:
            return .orange     // Amber: Degraded GPS (> 50m accuracy)
        case .disconnected:
            return .red        // Red: Disconnected (no location)
        }
    }
    
    private var isRecentlySent: Bool {
        guard let lastSent = userLocationManager.lastLocationSentSuccessfully else {
            return false
        }
        return Date().timeIntervalSince(lastSent) < 2.0
    }
    
    private var rightButtonsView: some View {
        HStack(spacing: 8) {
            // Treasure map button removed - users can access it from the discoveries log book (ClueDrawerView)

            // Inventory button
            Button(action: {
                // Use async to avoid modifying state during view update
                Task { @MainActor in
                    presentedSheet = .inventory
                }
            }) {
                ZStack {
                    Image(systemName: "backpack.fill")
                        .foregroundColor(.brown)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)

                    // New items badge
                    if inventoryService.hasNewItems {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 10, y: -10)
                    }
                }
            }

            // Show leaderboard trophy only in Open mode (not in story mode)
            if locationManager.gameMode == .open {
                Button(action: {
                    // Use async to avoid modifying state during view update
                    Task { @MainActor in
                        presentedSheet = .leaderboard
                    }
                }) {
                    Image(systemName: "trophy.fill")
                        .foregroundColor(.yellow)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
            }

            // NFC Scanner button (Open Game Mode)
            if locationManager.gameMode == .open {
                Button(action: {
                    // Use async to avoid modifying state during view update
                    Task { @MainActor in
                        presentedSheet = .nfcScanner
                    }
                }) {
                    Image(systemName: "wave.3.right.circle")
                        .foregroundColor(.blue)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
            }

            Button(action: {
                // Use async to avoid modifying state during view update
                Task { @MainActor in
                    presentedSheet = .settings
                }
            }) {
                Image(systemName: "gearshape")
                    .foregroundColor(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
            }
            .contentShape(Rectangle())
            .allowsHitTesting(true)
        }
        .padding(.top)
    }
    
    // DISABLED: Location coordinates display removed for cleaner UI
    // To re-enable, uncomment the code below and add locationDisplayView back to topOverlayView
    private var locationDisplayView: some View {
        EmptyView()
        // Group {
        //     if let currentLocation = userLocationManager.currentLocation {
        //         Text("📍 Location: \(currentLocation.coordinate.latitude, specifier: "%.8f"), \(currentLocation.coordinate.longitude, specifier: "%.8f")")
        //             .font(.caption)
        //             .padding()
        //             .background(.ultraThinMaterial)
        //             .cornerRadius(10)
        //             .padding(.top)
        //     }
        // }
    }
    
    private var notificationsView: some View {
        VStack(spacing: 8) {
            // Only show "loot boxes nearby" in open mode
            if locationManager.gameMode == .open && !nearbyLocations.isEmpty {
                Text("🎯 \(nearbyLocations.count) loot box\(nearbyLocations.count == 1 ? "" : "es") nearby!")
                    .font(.headline)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .offset(y: -54)
            }

            // Inventory notification
            if let notification = inventoryNotification {
                Text(notification)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(15)
                    .shadow(radius: 10)
                    .onAppear {
                        // Auto-dismiss after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            withAnimation {
                                inventoryNotification = nil
                            }
                        }
                    }
            }

            if let notification = collectionNotification {
                Text(notification)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .offset(y: -80)
                    .transition(.opacity)
                    .animation(.easeInOut, value: collectionNotification)
            }
        }
        .padding()
        .padding(.bottom, -20)
    }
    
    private var bottomCounterView: some View {
        VStack {
            Spacer()
            HStack {
                // Only show "Loot Boxes Found" counter in open mode
                if locationManager.gameMode == .open && !locationManager.locations.isEmpty {
                    Text("Loot Boxes Found: \(lootBoxCounter.found)/\(lootBoxCounter.total)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
                
                Spacer()
            }
        }
    }
    
    // Helper to build sheet content - breaks up complex expression
    @ViewBuilder
    private func sheetContent(for sheetType: SheetType) -> some View {
        switch sheetType {
        case .locationConfig:
            LocationConfigView(locationManager: locationManager)
        case .arPlacement:
            ARPlacementView(locationManager: locationManager, userLocationManager: userLocationManager)
        case .settings:
            SettingsView(locationManager: locationManager, userLocationManager: userLocationManager)
        case .leaderboard:
            NavigationView {
                LeaderboardView()
                    .navigationTitle("Leaderboard")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                presentedSheet = nil
                            }
                        }
                    }
            }
        case .skeletonConversation(let npcId, let npcName):
            SkeletonConversationView(
                npcName: npcName,
                npcId: npcId,
                onMapMentioned: {
                    Swift.print("🗺️ ContentView: onMapMentioned callback triggered - opening treasure map")
                    // Close conversation and open treasure map
                    presentedSheet = nil
                    // Small delay to allow conversation to close smoothly
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        presentedSheet = .treasureMap
                        Swift.print("🗺️ ContentView: Treasure map sheet opened")
                    }
                },
                treasureHuntService: treasureHuntService,
                userLocationManager: userLocationManager,
                inventoryService: inventoryService
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.clear)
            .presentationBackground {
                Color.black.opacity(0.95)
            }
        case .treasureMap:
            treasureMapSheetContent
        case .clueDrawer:
            clueDrawerSheetContent
        case .inventory:
            InventoryView(inventoryService: inventoryService)
        case .nfcScanner:
            OpenGameNFCScannerView()
        }
    }
    
    // Helper for treasure map content - breaks up complex expression
    @ViewBuilder
    private var treasureMapSheetContent: some View {
        if let mapPiece = treasureHuntService.mapPiece,
           let treasureLocation = treasureHuntService.treasureLocation {
            // Create treasure map data from map piece
            let landmarks = (mapPiece.landmarks ?? []).map { landmarkData in
                // Cast to Landmark struct
                guard let landmark = landmarkData as? Landmark else {
                    // Fallback for unknown landmark type
                    return LandmarkAnnotation(
                        id: UUID().uuidString,
                        coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                        name: "Unknown",
                        type: .building,
                        iconName: LandmarkType.building.iconName
                    )
                }

                // Derive landmark type from the landmark.type string
                let landmarkType: LandmarkType
                switch landmark.type.lowercased() {
                case "water": landmarkType = .water
                case "tree": landmarkType = .tree
                case "building": landmarkType = .building
                case "mountain": landmarkType = .mountain
                case "path": landmarkType = .path
                case "park": landmarkType = .park
                case "bridge": landmarkType = .bridge
                case "place_of_worship": landmarkType = .placeOfWorship
                default: landmarkType = .building
                }

                return LandmarkAnnotation(
                    id: UUID().uuidString,
                    coordinate: CLLocationCoordinate2D(latitude: landmark.latitude, longitude: landmark.longitude),
                    name: landmark.name,
                    type: landmarkType,
                    iconName: landmarkType.iconName
                )
            }
            
            // Find Captain Bones location if available
            // Use exact NPC ID to avoid duplicates (skeleton-1 becomes npc_skeleton-1 in locations)
            // Filter to ensure we only get one unique coordinate
            let npcLocations = locationManager.locations.filter { location in
                location.id == "npc_skeleton-1" || 
                (location.id.hasPrefix("npc_") && location.id.contains("skeleton-1"))
            }
            // Get the first unique coordinate (in case there are duplicates with same coordinates)
            let npcLocation = npcLocations.first?.coordinate
            
            let mapData = TreasureMapData(
                mapName: "Captain Bones' Treasure Map",
                xMarksTheSpot: treasureLocation.coordinate,
                landmarks: landmarks,
                clueCoordinates: [], // Clues can be added here if needed
                npcLocation: npcLocation
            )
            
            TreasureMapView(
                mapData: mapData,
                userLocationManager: userLocationManager
            )
        } else {
            // Fallback: show regular map if treasure map not available
            LocationConfigView(locationManager: locationManager)
        }
    }
    
    // Helper for clue drawer content - Story Mode inventory of collected items and map
    @ViewBuilder
    private var clueDrawerSheetContent: some View {
        ClueDrawerView(
            treasureHuntService: treasureHuntService,
            locationManager: locationManager,
            userLocationManager: userLocationManager,
            onShowTreasureMap: {
                // When user taps map in clue drawer, open the detailed treasure map
                presentedSheet = nil
                // Small delay to allow clue drawer to close smoothly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    presentedSheet = .treasureMap
                }
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    var body: some View {
        mainContentView
            .onAppear(perform: handleAppear)
            .onChange(of: presentedSheet) { oldSheet, newSheet in
                handleSheetChange(oldSheet: oldSheet, newSheet: newSheet)
                // Clear conversationNPC when skeleton conversation sheet is dismissed
                if oldSheet != nil, newSheet == nil {
                    // Sheet was dismissed - check if it was a skeleton conversation
                    if case .skeletonConversation = oldSheet {
                        conversationNPC = nil
                    }
                }
            }
            .sheet(item: $presentedSheet) { sheetType in
                sheetContent(for: sheetType)
                    .onAppear {
                        NotificationCenter.default.post(name: NSNotification.Name("DialogOpened"), object: nil)
                    }
                    .onDisappear {
                        NotificationCenter.default.post(name: NSNotification.Name("DialogClosed"), object: nil)
                    }
            }
            .onChange(of: conversationNPC) { oldNPC, newNPC in
                // Only open sheet if there's a new NPC and we don't already have that sheet open
                if let npc = newNPC {
                    // Check if we need to open the sheet (either it's a new NPC or the sheet isn't currently showing)
                    let shouldOpen = oldNPC?.id != npc.id || presentedSheet == nil
                    if shouldOpen {
                        presentedSheet = .skeletonConversation(npcId: npc.id, npcName: npc.name)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TreasureMapMentioned"))) { _ in
                Swift.print("🗺️ ContentView: TreasureMapMentioned notification received - opening treasure map")
                // Close any current sheet and open treasure map (like onMapMentioned callback)
                presentedSheet = nil
                // Small delay to allow sheet to close smoothly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    presentedSheet = .treasureMap
                    Swift.print("🗺️ ContentView: Treasure map sheet opened via notification")
                }
            }
            .onChange(of: userLocationManager.currentLocation) { oldLocation, newLocation in
                handleLocationChange(oldLocation: oldLocation, newLocation: newLocation)
            }
    }
    
    // Break up body into smaller computed properties
    private var mainContentView: some View {
        ZStack {
            ARLootBoxView(
                locationManager: locationManager,
                userLocationManager: userLocationManager,
                nearbyLocations: $nearbyLocations,
                distanceToNearest: $distanceToNearest,
                temperatureStatus: $temperatureStatus,
                collectionNotification: $collectionNotification,
                nearestObjectDirection: $nearestObjectDirection,
                conversationNPC: $conversationNPC,
                treasureHuntService: treasureHuntService
            )
            .ignoresSafeArea()

            topOverlayView

            bottomCounterView

            // Precise positioning overlay (shows GPS → NFC → AR transition)
            PrecisePositioningOverlay()
        }
    }
    
    // Break up onChange handlers into separate functions
    private func handleAppear() {
        // Set location manager reference in user location manager for game mode checks
        userLocationManager.lootBoxLocationManager = locationManager
        userLocationManager.treasureHuntService = treasureHuntService

        userLocationManager.requestLocationPermission()

        // Initialize offline mode manager with location manager reference
        OfflineModeManager.shared.setLocationManager(locationManager)

        // Auto-connect WebSocket on app start (only if not in offline mode)
        if !OfflineModeManager.shared.isOfflineMode {
            WebSocketService.shared.connect()
            
            // CRITICAL: Refresh game mode from server on app appear
            // This ensures we're always in sync with server, even if WebSocket connection fails
            Task {
                // Wait a moment for API to be ready
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                print("🎮 [ContentView] Refreshing game mode on app appear...")
                await locationManager.refreshGameMode()
            }
        } else {
            print("📴 Offline mode enabled - skipping WebSocket connection")
        }
        
        // Sync saved user name to server on app startup (only if not offline)
        if !OfflineModeManager.shared.isOfflineMode {
            APIService.shared.syncSavedUserNameToServer()
        }
        
        // Offline mode is supported for local testing without server connection

        // Set up inventory notification listener
        setupInventoryNotifications()

        // Set up NFC object creation listener
        setupNFCNotifications()
    }

    private func setupInventoryNotifications() {
        // Note: ContentView is a struct, so we can't capture self in notification observers
        // Inventory notifications are handled by the InventoryService ObservableObject
        // and the UI updates automatically through SwiftUI's state management
    }

    private func setupNFCNotifications() {
        // Listen for NFC object creation
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NFCObjectCreated"),
            object: nil,
            queue: .main
        ) { notification in
            if let object = notification.object as? LootBoxLocation {
                // Show success notification
                self.collectionNotification = "🎯 New \(object.type.displayName) created via NFC!"

                // Refresh locations to show the new object on map
                Task {
                    await self.locationManager.loadLocationsFromAPI()
                }

                // Clear notification after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.collectionNotification = nil
                }
            }
        }
    }

    private func handleSheetChange(oldSheet: SheetType?, newSheet: SheetType?) {
        // Notify AR coordinator when sheets are presented/dismissed
        if newSheet != nil && oldSheet == nil {
            // Sheet was presented
            NotificationCenter.default.post(name: NSNotification.Name("SheetPresented"), object: nil)
        } else if newSheet == nil && oldSheet != nil {
            // Sheet was dismissed
            NotificationCenter.default.post(name: NSNotification.Name("SheetDismissed"), object: nil)
        }
    }
    
    
    private func handleLocationChange(oldLocation: CLLocation?, newLocation: CLLocation?) {
        // PERFORMANCE: Debounce location updates to prevent excessive API calls
        // Cancel previous task if still pending
        locationUpdateTask?.cancel()
        
        // When we get a GPS fix, automatically load shared objects from API
        // SKIP in story modes - we only show NPCs, no loot boxes
        guard locationManager.gameMode == .open else {
            Swift.print("📖 Story mode active - skipping API object loading (NPCs only)")
            return
        }

        if let location = newLocation {
            // Check if we have a valid GPS fix
            guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else {
                return
            }

            // PERFORMANCE: Debounce - wait 2 seconds before making API call
            // This prevents rapid-fire API calls when GPS updates frequently
            locationUpdateTask = Task {
                do {
                    // Wait 2 seconds before making the call
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    
                    // Check if task was cancelled
                    guard !Task.isCancelled else { return }
                    
                    // Auto-load shared objects from API on background thread
                    await locationManager.loadLocationsFromAPI(userLocation: location)
                } catch {
                    // Task was cancelled or sleep failed - ignore
                    if !(error is CancellationError) {
                        Swift.print("⚠️ Location update task error: \(error)")
                    }
                }
            }
        }
    }
}

