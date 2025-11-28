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
    @StateObject private var gridTreasureMapService = GridTreasureMapService()
    
    // Grid treasure map modal state (separate from sheets)
    @State private var showGridTreasureMap = false
    
    // QR Scanner state for automatic connection failure handling
    @State private var showQRScanner = false
    @State private var scannedURL: String?
    @State private var hasCheckedHealth = false
    
    // Use enum-based sheet state to prevent multiple sheets being presented simultaneously
    enum SheetType: Identifiable {
        case locationConfig
        case arPlacement
        case settings
        case leaderboard
        case skeletonConversation(npcId: String, npcName: String)
        case treasureMap
        
        var id: String {
            switch self {
            case .locationConfig: return "locationConfig"
            case .arPlacement: return "arPlacement"
            case .settings: return "settings"
            case .leaderboard: return "leaderboard"
            case .skeletonConversation(let npcId, _): return "skeletonConversation_\(npcId)"
            case .treasureMap: return "treasureMap"
            }
        }
    }
    
    @State private var presentedSheet: SheetType? = nil
    @State private var conversationNPC: ConversationNPC? = nil
    @State private var nearbyLocations: [LootBoxLocation] = []
    @State private var distanceToNearest: Double?
    @State private var temperatureStatus: String?
    @State private var collectionNotification: String?
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

    // Helper function to convert meters to feet and inches
    private func formatDistanceInFeetInches(_ meters: Double) -> String {
        let totalInches = meters * 39.3701 // Convert meters to inches
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        
        if feet > 0 {
            return "\(feet)'\(inches)\""
        } else {
            return "\(inches)\""
        }
    }
    
    // Computed property to determine GPS connection status
    private var isGPSConnected: Bool {
        guard let location = userLocationManager.currentLocation else {
            return false
        }
        // GPS is connected if we have a valid location with good accuracy
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100
    }
    
    // MARK: - View Components
    
    private var topOverlayView: some View {
        VStack {
            topToolbarView
            
            locationDisplayView
            
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
                Button(action: {
                    // Toggle grid treasure map (only available after skeleton gives map)
                    if treasureHuntService.hasMap,
                       let treasureLocation = treasureHuntService.treasureLocation,
                       let mapPiece = treasureHuntService.mapPiece {
                        // Update grid map service with current data
                        let landmarks = mapPiece.landmarks.map { landmarkData in
                            let landmarkType: LandmarkType
                            switch landmarkData.type.lowercased() {
                            case "water": landmarkType = .water
                            case "tree": landmarkType = .tree
                            case "building": landmarkType = .building
                            case "mountain": landmarkType = .mountain
                            case "path": landmarkType = .path
                            default: landmarkType = .building
                            }
                            
                            return LandmarkAnnotation(
                                id: UUID().uuidString,
                                coordinate: CLLocationCoordinate2D(latitude: landmarkData.latitude, longitude: landmarkData.longitude),
                                name: landmarkData.name,
                                type: landmarkType,
                                iconName: landmarkType.iconName
                            )
                        }
                        
                        gridTreasureMapService.updateMapData(
                            treasureLocation: treasureLocation.coordinate,
                            landmarks: landmarks,
                            userLocation: userLocationManager.currentLocation?.coordinate
                        )
                        showGridTreasureMap = true
                    } else {
                        // Manually send location to server (also sent automatically every 5 seconds)
                        userLocationManager.sendCurrentLocationToServer()
                    }
                }) {
                    VStack(alignment: .center, spacing: 4) {
                        directionArrowView
                        
                        if let temperature = temperatureStatus {
                            Text(temperature)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        
                        Text(formatDistanceInFeetInches(distance))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .overlay(directionIndicatorBorder)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top)
            }
        }
    }
    
    private var directionArrowView: some View {
        Group {
            if let direction = nearestObjectDirection {
                Image(systemName: "location.north.line.fill")
                    .font(.caption)
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(direction))
            } else {
                Image(systemName: "location.north.line.fill")
                    .font(.caption)
                    .foregroundColor(.white)
            }
        }
    }
    
    private var directionIndicatorBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(directionIndicatorBorderColor, lineWidth: 2)
    }
    
    private var directionIndicatorBorderColor: Color {
        if userLocationManager.isSendingLocation || isRecentlySent {
            return .blue
        }
        return isGPSConnected ? .green : .red
    }
    
    private var isRecentlySent: Bool {
        guard let lastSent = userLocationManager.lastLocationSentSuccessfully else {
            return false
        }
        return Date().timeIntervalSince(lastSent) < 2.0
    }
    
    private var rightButtonsView: some View {
        HStack(spacing: 8) {
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
    
    private var locationDisplayView: some View {
        Group {
            if let currentLocation = userLocationManager.currentLocation {
                Text("📍 Location: \(currentLocation.coordinate.latitude, specifier: "%.8f"), \(currentLocation.coordinate.longitude, specifier: "%.8f")")
                    .font(.caption)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(.top)
            }
        }
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
    
    var body: some View {
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
        }
        .fullScreenCover(isPresented: $showGridTreasureMap) {
            GridTreasureMapView(mapService: gridTreasureMapService)
        }
        .sheet(item: $presentedSheet) { sheetType in
            Group {
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
                            // Close conversation and open treasure map
                            presentedSheet = nil
                            // Small delay to allow conversation to close smoothly
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                presentedSheet = .treasureMap
                            }
                        },
                        treasureHuntService: treasureHuntService,
                        userLocationManager: userLocationManager
                    )
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.clear)
                case .treasureMap:
                    // Show treasure map if we have map data
                    if let mapPiece = treasureHuntService.mapPiece,
                       let treasureLocation = treasureHuntService.treasureLocation {
                        // Create treasure map data from map piece
                        let landmarks = mapPiece.landmarks.map { landmarkData in
                            let landmarkType: LandmarkType
                            switch landmarkData.type.lowercased() {
                            case "water": landmarkType = .water
                            case "tree": landmarkType = .tree
                            case "building": landmarkType = .building
                            case "mountain": landmarkType = .mountain
                            case "path": landmarkType = .path
                            default: landmarkType = .building
                            }
                            
                            return LandmarkAnnotation(
                                id: UUID().uuidString,
                                coordinate: CLLocationCoordinate2D(latitude: landmarkData.latitude, longitude: landmarkData.longitude),
                                name: landmarkData.name,
                                type: landmarkType,
                                iconName: landmarkType.iconName
                            )
                        }
                        
                        let mapData = TreasureMapData(
                            mapName: "Captain Bones' Treasure Map",
                            xMarksTheSpot: treasureLocation.coordinate,
                            landmarks: landmarks,
                            clueCoordinates: []
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
            }
            .onAppear {
                // Notify AR coordinator that dialog is open
                NotificationCenter.default.post(name: NSNotification.Name("DialogOpened"), object: nil)
            }
            .onDisappear {
                // Notify AR coordinator that dialog is closed
                NotificationCenter.default.post(name: NSNotification.Name("DialogClosed"), object: nil)
            }
        }
        .onChange(of: conversationNPC) { _, newNPC in
            if let npc = newNPC {
                presentedSheet = .skeletonConversation(npcId: npc.id, npcName: npc.name)
            }
        }
        .onAppear {
            userLocationManager.requestLocationPermission()

            // Auto-connect WebSocket on app start
            WebSocketService.shared.connect()
            
            // Sync saved user name to server on app startup
            // This ensures the name persists between sessions
            APIService.shared.syncSavedUserNameToServer()
            
            // Check API health on startup and show QR scanner if connection fails
            if !hasCheckedHealth {
                hasCheckedHealth = true
                Task {
                    do {
                        let isHealthy = try await APIService.shared.checkHealth()
                        if !isHealthy {
                            // Connection failed - show QR scanner automatically
                            await MainActor.run {
                                showQRScanner = true
                            }
                        }
                    } catch {
                        // Connection error - show QR scanner automatically
                        await MainActor.run {
                            showQRScanner = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerView(scannedURL: $scannedURL)
        }
        .onChange(of: scannedURL) { oldURL, newURL in
            guard let url = newURL, url != oldURL else { return }
            
            // Update API URL with scanned QR code
            DispatchQueue.main.async {
                // Save the scanned URL
                UserDefaults.standard.set(url, forKey: "apiBaseURL")
                
                // Reset scannedURL after processing to allow scanning again
                self.scannedURL = nil
                
                // Try to reconnect
                WebSocketService.shared.disconnect()
                WebSocketService.shared.connect()
                
                // Verify connection
                Task {
                    do {
                        let isHealthy = try await APIService.shared.checkHealth()
                        if isHealthy {
                            // Connection successful - close QR scanner
                            await MainActor.run {
                                self.showQRScanner = false
                            }
                        }
                    } catch {
                        // Still failed - keep QR scanner open
                        print("⚠️ Connection still failed after scanning QR code")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("APIConnectionFailed"))) { _ in
            // Show QR scanner when API connection fails
            if !showQRScanner {
                showQRScanner = true
            }
        }
        .onChange(of: userLocationManager.currentLocation) { _, newLocation in
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
        // Counter is now a computed property, so no onChange handlers needed
        // It will automatically update when locationManager.locations or locationManager.databaseStats change
        // No automatic GPS box creation - user must add items manually via map
        // .onChange(of: userLocationManager.currentLocation) { _, newLocation in
        //     // When we get a GPS fix, check if we need to create/regenerate locations
        //     if let location = newLocation {
        //         // Check if we have a valid GPS fix
        //         guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else {
        //             return
        //         }
        //
        //         // If no locations, or if we need to check/regenerate, reload with user location
        //         if locationManager.locations.isEmpty {
        //             locationManager.loadLocations(userLocation: location)
        //         } else {
        //             // Check if existing locations are too far away
        //             locationManager.loadLocations(userLocation: location)
        //         }
        //     }
        // }
    }
}

