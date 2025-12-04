import SwiftUI
import CoreLocation

// MARK: - Sheet Content View
struct SheetContentView: View {
    let sheetType: SheetType
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @ObservedObject var treasureHuntService: TreasureHuntService
    @ObservedObject var gridTreasureMapService: GridTreasureMapService
    @ObservedObject var inventoryService: InventoryService
    @Binding var showQRScanner: Bool
    @Binding var scannedURL: String?
    
    var body: some View {
        switch sheetType {
        case .nfcWriting:
            NFCWritingView(locationManager: locationManager, userLocationManager: userLocationManager)
        case .nfcScanner:
            NFCScannerView()
        case .simpleNFCScanner:
            SimpleNFCScannerView()
        case .openGameNFCScanner:
            OpenGameNFCScannerView()
        case .qrCodeScanner:
            QRCodeScannerView(scannedURL: $scannedURL)
        case .settings:
            SettingsView(locationManager: locationManager, userLocationManager: userLocationManager)
        case .inventory:
            InventoryView(inventoryService: inventoryService)
        case .leaderboard:
            LeaderboardView()
        case .treasureMap:
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
            } else {
                // Fallback when no treasure map data is available
                EmptyView()
            }
        case .gridTreasureMap:
            GridTreasureMapView(mapService: gridTreasureMapService)
        case .nfcTokensList:
            NFCTokensListView()
        case .nfcTokenDetail(let token):
            NFCTokenDetailView(token: token)
        default:
            // Handle other cases that might not be implemented here
            EmptyView()
        }
    }
}

