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

// MARK: - GPS Indicator View (Bottom Right Corner)
struct GPSIndicatorView: View {
    let isGPSConnected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "location.fill")
                .font(.title2)
                .foregroundColor(isGPSConnected ? .green : .red)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                .padding(.trailing, 6)
                .padding(.bottom, 16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Top Overlay View (Main Container)
struct TopOverlayView: View {
    @Binding var showPlusMenu: Bool
    @Binding var showGridTreasureMap: Bool
    @Binding var presentedSheet: SheetType?
    let collectionNotification: String?
    let temperatureStatus: String?
    let directionIndicatorView: AnyView
    let locationManager: LootBoxLocationManager
    let userLocationManager: UserLocationManager

    var body: some View {
        VStack {
            TopToolbarView(showPlusMenu: $showPlusMenu, showGridTreasureMap: $showGridTreasureMap, presentedSheet: $presentedSheet, directionIndicatorView: directionIndicatorView, locationManager: locationManager, userLocationManager: userLocationManager)

            Spacer()

            NotificationsView(collectionNotification: collectionNotification, temperatureStatus: temperatureStatus)
        }
    }
}
