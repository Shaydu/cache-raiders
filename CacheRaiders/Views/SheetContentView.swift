import SwiftUI
import CoreLocation

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
            NFCScanOnlyView()
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
            SettingsView(locationManager: locationManager, userLocationManager: userLocationManager, dismissAction: dismiss)
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
                LootBoxMapView(locationManager: locationManager, userLocationManager: userLocationManager)
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
