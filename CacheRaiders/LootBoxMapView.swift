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
    @State private var position = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    ))
    
    // Combine user location and loot boxes into a single annotation array
    private var allAnnotations: [MapAnnotationItem] {
        var annotations: [MapAnnotationItem] = []
        
        // Add user location pin
        if let userLocation = userLocationManager.currentLocation {
            annotations.append(MapAnnotationItem(
                id: "user_location",
                coordinate: userLocation.coordinate,
                isUserLocation: true,
                lootBoxLocation: nil
            ))
        }
        
        // Add all loot box locations
        annotations.append(contentsOf: locationManager.locations.map { location in
            print("📍 Map showing location: \(location.name) at (\(location.latitude), \(location.longitude)) - collected: \(location.collected)")
            return MapAnnotationItem(
                id: location.id,
                coordinate: location.coordinate,
                isUserLocation: false,
                lootBoxLocation: location
            )
        })
        
        return annotations
    }
    
    var body: some View {
        Map(position: $position) {
            ForEach(allAnnotations, id: \.id) { annotation in
                if annotation.isUserLocation {
                    // User location pin
                    Annotation("", coordinate: annotation.coordinate) {
                        VStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.blue)
                                .font(.title2)
                                .background(Circle().fill(.white))
                                .shadow(radius: 3)

                            Text("You")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(4)
                        }
                    }
                } else if let location = annotation.lootBoxLocation {
                    // Loot box pin
                    Annotation(location.name, coordinate: annotation.coordinate) {
                        VStack(spacing: 4) {
                            Image(systemName: location.collected ? "checkmark.circle.fill" : "mappin.circle.fill")
                                .foregroundColor(location.collected ? .green : .red)
                                .font(.title)
                                .background(Circle().fill(.white))
                                .shadow(radius: 3)

                            Text(location.name)
                                .font(.caption)
                                .padding(4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .onAppear {
            updateRegion()
        }
        .onChange(of: locationManager.locations) {
            updateRegion()
        }
        .onChange(of: userLocationManager.currentLocation) {
            updateRegion()
        }
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
}

