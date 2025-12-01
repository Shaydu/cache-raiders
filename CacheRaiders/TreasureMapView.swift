import SwiftUI
import MapKit
import CoreLocation

// MARK: - Treasure Map Data Model
struct TreasureMapData {
    let mapName: String
    let xMarksTheSpot: CLLocationCoordinate2D // Where the treasure is buried
    let landmarks: [LandmarkAnnotation] // Landmarks from OpenStreetMap (water, trees, buildings, etc.)
    let clueCoordinates: [CLLocationCoordinate2D] // Coordinates extracted from LLM clues (shown as red X marks)
    let npcLocation: CLLocationCoordinate2D? // Captain Bones location (if available)
}

// MARK: - Landmark Annotation
struct LandmarkAnnotation: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let name: String
    let type: LandmarkType
    let iconName: String
}

enum LandmarkType {
    case water
    case tree
    case building
    case mountain
    case path
    case park
    case bridge
    case placeOfWorship
    
    var iconName: String {
        switch self {
        case .water: return "drop.fill"
        case .tree: return "tree.fill"
        case .building: return "building.2.fill"
        case .mountain: return "mountain.2.fill"
        case .path: return "map.fill"
        case .park: return "leaf.fill"
        case .bridge: return "arrow.left.arrow.right"
        case .placeOfWorship: return "building.columns.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .water: return .blue
        case .tree: return .green
        case .building: return .brown
        case .mountain: return .gray
        case .path: return .orange
        case .park: return .green
        case .bridge: return .cyan
        case .placeOfWorship: return .purple
        }
    }
}

// MARK: - Treasure Map View
struct TreasureMapView: View {
    let mapData: TreasureMapData
    @ObservedObject var userLocationManager: UserLocationManager
    @Environment(\.dismiss) var dismiss
    @State private var position = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    ))
    @State private var hasInitialized = false
    
    /// Calculate distance from user to treasure
    private var distanceToTreasure: String {
        guard let userLocation = userLocationManager.currentLocation else {
            return "Unknown"
        }
        
        let treasureLocation = CLLocation(
            latitude: mapData.xMarksTheSpot.latitude,
            longitude: mapData.xMarksTheSpot.longitude
        )
        
        let distanceMeters = userLocation.distance(from: treasureLocation)
        
        if distanceMeters < 1000 {
            return String(format: "%.0fm", distanceMeters)
        } else {
            return String(format: "%.1fkm", distanceMeters / 1000)
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Parchment background overlay (subtle, doesn't block map)
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.90).opacity(0.3),
                        Color(red: 0.95, green: 0.92, blue: 0.85).opacity(0.2)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                MapReader { proxy in
                    Map(position: $position) {
                        // User location
                        if let userLocation = userLocationManager.currentLocation {
                            Annotation("You", coordinate: userLocation.coordinate) {
                                VStack(spacing: 4) {
                                    Image(systemName: "location.north.line.fill")
                                        .foregroundColor(.blue)
                                        .font(.title2)
                                        .background(Circle().fill(.white))
                                        .shadow(radius: 3)
                                        .rotationEffect(.degrees(userLocationManager.heading ?? 0))
                                    
                                    Text("You")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .padding(4)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                }
                            }
                        }
                        
                        // Landmarks from OpenStreetMap
                        ForEach(mapData.landmarks) { landmark in
                            Annotation(landmark.name, coordinate: landmark.coordinate) {
                                VStack(spacing: 2) {
                                    Image(systemName: landmark.iconName)
                                        .foregroundColor(landmark.type.color)
                                        .font(.title3)
                                        .background(Circle().fill(.white).opacity(0.9))
                                        .shadow(radius: 2)
                                    
                                    Text(landmark.name)
                                        .font(.caption2)
                                        .padding(2)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                        .lineLimit(1)
                                }
                            }
                        }
                        
                        // Clue coordinates (from LLM clues) - shown as red X marks
                        ForEach(Array(mapData.clueCoordinates.enumerated()), id: \.offset) { index, coordinate in
                            Annotation("Clue \(index + 1)", coordinate: coordinate) {
                                ZStack {
                                    // Red circle background
                                    Circle()
                                        .fill(Color.red.opacity(0.3))
                                        .frame(width: 50, height: 50)
                                    
                                    // Red X mark
                                    Text("✕")
                                        .font(.system(size: 30, weight: .bold))
                                        .foregroundColor(.red)
                                        .rotationEffect(.degrees(45))
                                    
                                    // Outer ring
                                    Circle()
                                        .stroke(Color.red, lineWidth: 2)
                                        .frame(width: 50, height: 50)
                                }
                                .shadow(radius: 3)
                            }
                        }
                        
                        // Captain Bones (NPC) location
                        if let npcLocation = mapData.npcLocation {
                            Annotation("💀 Captain Bones", coordinate: npcLocation) {
                                VStack(spacing: 2) {
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.yellow)
                                        .font(.title3)
                                        .background(Circle().fill(Color(red: 1.0, green: 0.843, blue: 0.0).opacity(0.9)))
                                        .shadow(radius: 2)
                                    
                                    Text("💀 Captain Bones")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(2)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                        .lineLimit(1)
                                }
                            }
                        }
                        
                        // X Marks The Spot - Red X marker at treasure location
                        Annotation("X Marks The Spot", coordinate: mapData.xMarksTheSpot) {
                            ZStack {
                                // Red circle background
                                Circle()
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: 60, height: 60)
                                
                                // Red X mark
                                Text("✕")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundColor(.red)
                                    .rotationEffect(.degrees(45))
                                
                                // Outer ring
                                Circle()
                                    .stroke(Color.red, lineWidth: 3)
                                    .frame(width: 60, height: 60)
                            }
                            .shadow(radius: 5)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .overlay(
                        // Compass rose (top right)
                        VStack {
                            HStack {
                                Spacer()
                                VStack(spacing: 2) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundColor(.brown)
                                        .font(.title2)
                                    Text("N")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.brown)
                                }
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(.trailing, 16)
                                .padding(.top, 16)
                            }
                            Spacer()
                        }
                    )
                }
                
                // Title overlay (top)
                VStack {
                    VStack(spacing: 8) {
                        Text(mapData.mapName)
                            .font(.custom("Copperplate", size: 24))
                            .fontWeight(.bold)
                            .foregroundColor(.brown)
                        
                        Text("X Marks The Spot")
                            .font(.custom("Copperplate", size: 16))
                            .foregroundColor(.red)
                        
                        // Distance to treasure
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.blue)
                            Text("Distance: \(distanceToTreasure)")
                                .font(.custom("Copperplate", size: 18))
                                .fontWeight(.semibold)
                                .foregroundColor(.brown)
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding(.top, 16)
                    
                    Spacer()
                    
                    // Legend (bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Legend")
                            .font(.headline)
                            .foregroundColor(.brown)
                        
                        HStack(spacing: 16) {
                            LegendItem(icon: "drop.fill", color: .blue, label: "Water")
                            LegendItem(icon: "tree.fill", color: .green, label: "Tree")
                            LegendItem(icon: "building.2.fill", color: .brown, label: "Building")
                            LegendItem(icon: "map.fill", color: .orange, label: "Road")
                        }
                        
                        HStack(spacing: 16) {
                            LegendItem(icon: "mountain.2.fill", color: .gray, label: "Mountain")
                            LegendItem(icon: "leaf.fill", color: .green, label: "Park")
                            LegendItem(icon: "arrow.left.arrow.right", color: .cyan, label: "Bridge")
                            LegendItem(icon: "building.columns.fill", color: .purple, label: "Place of Worship")
                        }
                        
                        HStack(spacing: 16) {
                            LegendItem(icon: "person.fill", color: .yellow, label: "Captain Bones")
                            LegendItem(icon: "location.fill", color: .blue, label: "You")
                            LegendItem(icon: "xmark", color: .red, label: "Treasure")
                        }
                        
                        HStack(spacing: 16) {
                            LegendItem(icon: "xmark", color: .red, label: "Clue (Red X)")
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Treasure Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Center map to show all important points: treasure, landmarks, NPC, and clues
                var allCoords: [CLLocationCoordinate2D] = [mapData.xMarksTheSpot]
                allCoords.append(contentsOf: mapData.landmarks.map { $0.coordinate })
                allCoords.append(contentsOf: mapData.clueCoordinates)
                if let npcLoc = mapData.npcLocation {
                    allCoords.append(npcLoc)
                }
                
                // Calculate bounding box
                let minLat = allCoords.map { $0.latitude }.min() ?? mapData.xMarksTheSpot.latitude
                let maxLat = allCoords.map { $0.latitude }.max() ?? mapData.xMarksTheSpot.latitude
                let minLon = allCoords.map { $0.longitude }.min() ?? mapData.xMarksTheSpot.longitude
                let maxLon = allCoords.map { $0.longitude }.max() ?? mapData.xMarksTheSpot.longitude
                
                let center = CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2
                )
                
                // Add padding to span
                let latDelta = max((maxLat - minLat) * 1.5, 0.005) // At least 500m
                let lonDelta = max((maxLon - minLon) * 1.5, 0.005)
                
                let region = MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
                )
                position = .region(region)
                hasInitialized = true
            }
        }
    }
}

// MARK: - Legend Item
struct LegendItem: View {
    let icon: String
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text(label)
                .font(.caption2)
        }
    }
}

// MARK: - Helper: Extract Coordinates from LLM Clues
/// Extracts coordinates from LLM-generated clues
/// The LLM provides clues with coordinates in the format:
/// - "dig where the river meets the oak at 37.7749, -122.4194"
/// - Or coordinates are provided separately via API
func extractCoordinatesFromClues(clues: [String]) -> [CLLocationCoordinate2D] {
    var coordinates: [CLLocationCoordinate2D] = []
    
    // Pattern to match coordinates: "latitude, longitude" or "(lat, lon)"
    let coordinatePattern = #"(-?\d+\.\d+),\s*(-?\d+\.\d+)"#
    let regex = try? NSRegularExpression(pattern: coordinatePattern, options: [])
    
    for clue in clues {
        let nsString = clue as NSString
        let matches = regex?.matches(in: clue, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for match in matches ?? [] {
            if match.numberOfRanges == 3 {
                let latRange = match.range(at: 1)
                let lonRange = match.range(at: 2)
                
                if let latString = latRange.location != NSNotFound ? nsString.substring(with: latRange) : nil,
                   let lonString = lonRange.location != NSNotFound ? nsString.substring(with: lonRange) : nil,
                   let lat = Double(latString),
                   let lon = Double(lonString) {
                    coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
        }
    }
    
    return coordinates
}

// MARK: - Helper: Convert OpenStreetMap Features to Landmarks
/// Converts OpenStreetMap feature data to landmark annotations
/// The LLM service already fetches features with coordinates
func convertOSMFeaturesToLandmarks(features: [(name: String, type: String, latitude: Double, longitude: Double)]) -> [LandmarkAnnotation] {
    return features.map { feature in
        let landmarkType: LandmarkType
        switch feature.type.lowercased() {
        case "water": landmarkType = .water
        case "tree": landmarkType = .tree
        case "building": landmarkType = .building
        case "mountain": landmarkType = .mountain
        case "path": landmarkType = .path
        case "park": landmarkType = .park
        case "bridge": landmarkType = .bridge
        case "place_of_worship": landmarkType = .placeOfWorship
        default: landmarkType = .building
        }
        
        return LandmarkAnnotation(
            id: UUID().uuidString,
            coordinate: CLLocationCoordinate2D(latitude: feature.latitude, longitude: feature.longitude),
            name: feature.name,
            type: landmarkType,
            iconName: landmarkType.iconName
        )
    }
}


