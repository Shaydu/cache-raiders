import SwiftUI
import MapKit
import CoreLocation

// MARK: - Grid Treasure Map View
struct GridTreasureMapView: View {
    @ObservedObject var mapService: GridTreasureMapService
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        ZStack {
            // Background
            Color.black.edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .font(.title2)
                            .padding()
                    }

                    Spacer()

                    Text("Treasure Map")
                        .font(.title)
                        .foregroundColor(.white)
                        .fontWeight(.bold)

                    Spacer()

                    // Invisible button for balance
                    Image(systemName: "xmark")
                        .foregroundColor(.clear)
                        .font(.title2)
                        .padding()
                }
                .background(Color.black.opacity(0.8))

                // Map content placeholder - for now just show a message
                ZStack {
                    Color.gray.opacity(0.2)

                    VStack(spacing: 20) {
                        Image(systemName: "map")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.6))

                        Text("Grid Treasure Map")
                            .font(.title)
                            .foregroundColor(.white)

                        Text("Map visualization coming soon...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))

                        if let treasureLocation = mapService.treasureLocation {
                            Text("Treasure at: \(treasureLocation.latitude), \(treasureLocation.longitude)")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }

                        Text("Landmarks: \(mapService.landmarks.count)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
    }
}

#Preview {
    GridTreasureMapView(mapService: GridTreasureMapService())
}








