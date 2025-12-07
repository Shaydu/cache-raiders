import SwiftUI
import CoreLocation

// MARK: - Sheet Content View

// MARK: - Sheet Content View
struct SheetContentView: View {
    let sheetType: SheetType
    let locationManager: LootBoxLocationManager
    let userLocationManager: UserLocationManager
    let treasureHuntService: TreasureHuntService
    let gridTreasureMapService: GridTreasureMapService
    let inventoryService: InventoryService
    let dismiss: () -> Void

    var body: some View {
        switch sheetType {
        case .locationConfig:
            LocationConfigView(locationManager: locationManager)
        case .arPlacement:
            ARPlacementView(locationManager: locationManager, userLocationManager: userLocationManager)
        case .nfcScanner:
            NFCScanOnlyView(locationManager: locationManager)
        case .nfcWriting:
            NFCWritingView(locationManager: locationManager, userLocationManager: userLocationManager)
        case .simpleNFCScanner:
            SimpleNFCScannerView()
        case .inventory:
            NavigationView {
                InventoryView(inventoryService: inventoryService)
                    .navigationTitle("Inventory")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
            }
        case .settings:
            NavigationView {
                SettingsView(locationManager: locationManager, userLocationManager: userLocationManager, dismissAction: dismiss)
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .leaderboard:
            NavigationView {
                LeaderboardView()
                    .navigationTitle("Leaderboard")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .skeletonConversation(let npcId, let npcName):
            SkeletonConversationView(
                npcName: npcName,
                npcId: npcId,
                treasureHuntService: treasureHuntService,
                userLocationManager: userLocationManager
            )
        case .treasureMap:
            treasureMapSheetContent
        case .mapView:
            NavigationView {
                LootBoxMapView(
                    locationManager: locationManager,
                    userLocationManager: userLocationManager,
                    onObjectTap: { location in
                        // Create object detail using the existing service
                        let objectDetail = ARObjectDetailService.shared.extractObjectDetails(
                            location: location,
                            anchor: nil // Map objects don't have AR anchors
                        )
                        // Post notification to show object detail sheet
                        NotificationCenter.default.post(
                            name: NSNotification.Name("ShowObjectDetailSheet"),
                            object: objectDetail
                        )
                    }
                )
                    .navigationTitle("Map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
            }
        case .objectDetail(let detail):
            ARObjectDetailView(objectDetail: detail)
        case .foundItems:
            NavigationView {
                FoundItemsView(
                    locationManager: locationManager,
                    userLocationManager: userLocationManager,
                    onToggleCollected: { locationId in
                        locationManager.toggleCollected(locationId)
                    },
                    onDeleteLocation: { locationId in
                        locationManager.deleteLocation(byId: locationId)
                    }
                )
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
            }
        case .gpsDetails:
            GPSDetailsView(userLocationManager: userLocationManager, dismiss: dismiss)
        }
    }

    @ViewBuilder
    private var treasureMapSheetContent: some View {
        if let mapPiece = treasureHuntService.mapPiece,
           let treasureLocation = treasureHuntService.treasureLocation {
            // Create treasure map data from map piece
            let landmarks: [LandmarkAnnotation] = (mapPiece.landmarks ?? []).map { landmarkData in
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
                clueCoordinates: [], // Clues can be added here if needed
                npcLocation: nil
            )

            TreasureMapView(mapData: mapData, userLocationManager: userLocationManager)
                .environmentObject(userLocationManager)
        } else {
            // Fallback: Show general treasure map with all loot boxes
            generalTreasureMapContent
        }
    }

    @ViewBuilder
    private var generalTreasureMapContent: some View {
        // Create treasure map data showing all loot boxes
        let landmarks: [LandmarkAnnotation] = [] // Could add OSM landmarks here if needed

        // Find all loot box locations (excluding NPCs for now)
        let lootBoxLocations = locationManager.locations.filter { location in
            // Include all valid loot boxes that should show on map
            guard !(location.latitude == 0 && location.longitude == 0) else { return false }
            return location.shouldShowOnMap && !location.id.hasPrefix("npc_")
        }

        // Find Captain Bones location if available
        let npcLocations = locationManager.locations.filter { location in
            location.id == "npc_skeleton-1" ||
            (location.id.hasPrefix("npc_") && location.id.contains("skeleton-1"))
        }
        let npcLocation = npcLocations.first?.coordinate

        // Use the first loot box as "treasure" or user's location as center
        let treasureLocation = lootBoxLocations.first?.coordinate ?? userLocationManager.currentLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)

        let mapData = TreasureMapData(
            mapName: "Treasure Map",
            xMarksTheSpot: treasureLocation,
            landmarks: landmarks,
            clueCoordinates: lootBoxLocations.map { $0.coordinate }, // Show all loot boxes as red X marks
            npcLocation: npcLocation
        )

        TreasureMapView(mapData: mapData, userLocationManager: userLocationManager)
            .environmentObject(userLocationManager)
    }
}

// MARK: - GPS Details View
public struct GPSDetailsView: View {
    let userLocationManager: UserLocationManager
    let dismiss: () -> Void

    init(userLocationManager: UserLocationManager, dismiss: @escaping () -> Void) {
        self.userLocationManager = userLocationManager
        self.dismiss = dismiss
    }

    private var formatDistanceInFeetInches: (Double) -> String = { meters in
        let totalInches = meters * 39.3701 // Convert meters to inches
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))

        if feet > 0 {
            return "\(feet)'\(inches)\""
        } else {
            return "\(inches)\""
        }
    }

    public var body: some View {
        List {
            // GPS Status Section
            Section("GPS Status") {
                HStack {
                    Image(systemName: userLocationManager.currentLocation != nil ? "location.fill" : "location.slash")
                        .foregroundColor(userLocationManager.currentLocation != nil ? .green : .red)
                    Text(userLocationManager.currentLocation != nil ? "Connected" : "Disconnected")
                }

                if let location = userLocationManager.currentLocation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Coordinates:")
                            .font(.subheadline)
                        Text("Lat: \(location.coordinate.latitude, specifier: "%.8f")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Lon: \(location.coordinate.longitude, specifier: "%.8f")")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Accuracy: \(formatDistanceInFeetInches(location.horizontalAccuracy))")
                            .font(.subheadline)

                        Text("Altitude: \(location.altitude, specifier: "%.1f")m")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }

            // AR Status Section
            Section("AR Status") {
                HStack {
                    Image(systemName: "camera.fill")
                        .foregroundColor(.blue)
                    Text("AR Session Active")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Session Info:")
                        .font(.subheadline)

                    Text("AR tracking available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // Location Services Section
            Section("Location Services") {
                HStack {
                    Image(systemName: userLocationManager.authorizationStatus == .authorizedWhenInUse || userLocationManager.authorizationStatus == .authorizedAlways ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(userLocationManager.authorizationStatus == .authorizedWhenInUse || userLocationManager.authorizationStatus == .authorizedAlways ? .green : .red)
                    Text("Permission: \(userLocationManager.authorizationStatus.rawValue)")
                }

                HStack {
                    Image(systemName: userLocationManager.isSendingLocation ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .foregroundColor(userLocationManager.isSendingLocation ? .green : .gray)
                    Text("Sending to Server: \(userLocationManager.isSendingLocation ? "Yes" : "No")")
                }

                if let lastSent = userLocationManager.lastLocationSentSuccessfully {
                    Text("Last Sent: \(lastSent.formatted())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("GPS & AR Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

