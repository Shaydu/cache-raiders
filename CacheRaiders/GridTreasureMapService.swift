import Foundation
import CoreLocation
import SwiftUI
import Combine

// MARK: - Grid Treasure Map Service
/// Service for managing grid-based treasure map display
class GridTreasureMapService: ObservableObject {
    @Published var isMapVisible: Bool = false
    @Published var treasureLocation: CLLocationCoordinate2D?
    @Published var landmarks: [GridLandmark] = []
    @Published var userLocation: CLLocationCoordinate2D?

    private var userLocationManager: UserLocationManager?
    private var cancellables = Set<AnyCancellable>()
    
    /// Toggle map visibility
    func toggleMap() {
        isMapVisible.toggle()
    }
    
    /// Show the map
    func showMap() {
        isMapVisible = true
    }
    
    /// Hide the map
    func hideMap() {
        isMapVisible = false
    }
    
    /// Update map data with treasure location and landmarks
    func updateMapData(treasureLocation: CLLocationCoordinate2D, landmarks: [LandmarkAnnotation], userLocation: CLLocationCoordinate2D?, userLocationManager: UserLocationManager) {
        self.treasureLocation = treasureLocation
        self.userLocation = userLocation

        // Set up location manager reference and start observing location changes
        self.userLocationManager = userLocationManager
        setupLocationObservation()

        self.landmarks = landmarks.map { landmark in
            GridLandmark(
                name: landmark.name,
                coordinate: landmark.coordinate,
                type: landmark.type
            )
        }
    }

    /// Set up observation of user location changes
    private func setupLocationObservation() {
        guard let userLocationManager = userLocationManager else { return }

        // Cancel any existing observations
        cancellables.removeAll()

        // Observe location changes and update userLocation
        userLocationManager.$currentLocation
            .compactMap { $0?.coordinate }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coordinate in
                self?.userLocation = coordinate
            }
            .store(in: &cancellables)
    }
}

// MARK: - Grid Landmark
struct GridLandmark: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let type: LandmarkType
}

