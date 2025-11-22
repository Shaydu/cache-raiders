import SwiftUI
import MapKit

// MARK: - Loot Box Map View
struct LootBoxMapView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var showDistanceWarning = false
    @State private var distanceMessage = ""
    
    var body: some View {
        Map(coordinateRegion: $region, annotationItems: locationManager.locations) { location in
            MapAnnotation(coordinate: location.coordinate) {
                VStack(spacing: 4) {
                    Image(systemName: location.collected ? "checkmark.circle.fill" : "mappin.circle.fill")
                        .foregroundColor(location.collected ? .green : .red)
                        .font(.title)
                        .background(Circle().fill(.white))
                    
                    Text(location.name)
                        .font(.caption)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                }
            }
        }
        .onAppear {
            updateRegion()
        }
        .onChange(of: locationManager.locations) { _ in
            updateRegion()
        }
        .onChange(of: userLocationManager.currentLocation) { _ in
            updateRegion()
        }
    }
    
    private func updateRegion() {
        var coordinates: [CLLocationCoordinate2D] = []
        
        // Add user location if available
        if let userLocation = userLocationManager.currentLocation {
            coordinates.append(userLocation.coordinate)
        }
        
        // Add all loot box locations
        coordinates.append(contentsOf: locationManager.locations.map { $0.coordinate })
        
        guard !coordinates.isEmpty else { return }
        
        // Calculate bounding box
        let latitudes = coordinates.map { $0.latitude }
        let longitudes = coordinates.map { $0.longitude }
        
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        
        // Add padding
        let latDelta = max((maxLat - minLat) * 1.5, 0.01)
        let lonDelta = max((maxLon - minLon) * 1.5, 0.01)
        
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}

