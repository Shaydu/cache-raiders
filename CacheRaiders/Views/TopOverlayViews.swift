import SwiftUI
import CoreLocation

// MARK: - Top Toolbar View
struct TopToolbarView: View {
    @Binding var showPlusMenu: Bool
    @Binding var showGridTreasureMap: Bool
    @Binding var presentedSheet: SheetType?
    let directionIndicatorView: AnyView
    let locationManager: LootBoxLocationManager
    let userLocationManager: UserLocationManager

    var body: some View {
        HStack {
            LeftButtonsView(showGridTreasureMap: $showGridTreasureMap, presentedSheet: $presentedSheet, locationManager: locationManager, userLocationManager: userLocationManager)

            Spacer()

            directionIndicatorView

            Spacer()

            RightButtonsView(showPlusMenu: $showPlusMenu, presentedSheet: $presentedSheet)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - Left Buttons View
struct LeftButtonsView: View {
    @Binding var showGridTreasureMap: Bool
    @Binding var presentedSheet: SheetType?
    let locationManager: LootBoxLocationManager
    let userLocationManager: UserLocationManager

    var body: some View {
        HStack(spacing: 12) {
            // Map Button - Show different map views based on game mode
            Button(action: {
                // Use async to avoid modifying state during view update
                Task { @MainActor in
                    // Show different map views based on game mode
                    if locationManager.gameMode == .deadMensSecrets {
                        presentedSheet = .treasureMap
                    } else {
                        presentedSheet = .mapView
                    }
                }
            }) {
                Image(systemName: "map")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }

            // Settings Button
            Button(action: {
                // Use async to avoid modifying state during view update
                Task { @MainActor in
                    presentedSheet = .settings
                }
            }) {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }
        }
    }
}

// MARK: - Right Buttons View
struct RightButtonsView: View {
    @Binding var showPlusMenu: Bool
    @Binding var presentedSheet: SheetType?

    var body: some View {
        HStack(spacing: 12) {
            // Plus Menu Button
            Button(action: {
                showPlusMenu.toggle()
            }) {
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }
            .actionSheet(isPresented: $showPlusMenu) {
                ActionSheet(
                    title: Text("Create"),
                    message: Text("Choose what to create"),
                    buttons: [
                        .default(Text("Place AR Object")) {
                            Task { @MainActor in
                                presentedSheet = .arPlacement
                            }
                        },
                        .default(Text("Place NFC Token")) {
                            Task { @MainActor in
                                presentedSheet = .nfcWriting
                            }
                        },
                        .default(Text("Scan NFC Token")) {
                            Task { @MainActor in
                                presentedSheet = .nfcScanner
                            }
                        },
                        .cancel()
                    ]
                )
            }
        }
    }
}

// MARK: - Location Display View
struct LocationDisplayView: View {
    let isGPSConnected: Bool
    let formatDistanceInFeetInches: (Double) -> String

    var body: some View {
        VStack(spacing: 4) {
            if isGPSConnected {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(.green)
                    Text("GPS Connected")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else {
                HStack {
                    Image(systemName: "location.slash")
                        .foregroundColor(.red)
                    Text("GPS Disconnected")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if let distance = UserLocationManager().currentLocation?.horizontalAccuracy {
                Text("Accuracy: \(formatDistanceInFeetInches(distance))")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

// MARK: - Notifications View
struct NotificationsView: View {
    let collectionNotification: String?
    let temperatureStatus: String?

    var body: some View {
        VStack(spacing: 8) {
            if let notification = collectionNotification {
                Text(notification)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9))
                    .cornerRadius(8)
                    .transition(.slide)
            }

            if let tempStatus = temperatureStatus {
                Text(tempStatus)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Top Overlay View (Main Container)
struct TopOverlayView: View {
    @Binding var showPlusMenu: Bool
    @Binding var showGridTreasureMap: Bool
    @Binding var presentedSheet: SheetType?
    let isGPSConnected: Bool
    let formatDistanceInFeetInches: (Double) -> String
    let collectionNotification: String?
    let temperatureStatus: String?
    let directionIndicatorView: AnyView
    let locationManager: LootBoxLocationManager
    let userLocationManager: UserLocationManager

    var body: some View {
        VStack {
            TopToolbarView(showPlusMenu: $showPlusMenu, showGridTreasureMap: $showGridTreasureMap, presentedSheet: $presentedSheet, directionIndicatorView: directionIndicatorView, locationManager: locationManager, userLocationManager: userLocationManager)

            LocationDisplayView(isGPSConnected: isGPSConnected, formatDistanceInFeetInches: formatDistanceInFeetInches)

            Spacer()

            NotificationsView(collectionNotification: collectionNotification, temperatureStatus: temperatureStatus)
        }
    }
}
