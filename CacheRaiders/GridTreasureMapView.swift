import SwiftUI
import CoreLocation

// MARK: - Grid Treasure Map View
/// A grid-based treasure map showing landmarks and treasure location
struct GridTreasureMapView: View {
    @ObservedObject var mapService: GridTreasureMapService
    @Environment(\.dismiss) var dismiss
    
    // Grid configuration
    private let gridSize: Int = 20 // 20x20 grid
    private let cellSize: CGFloat = 15 // Size of each grid cell in points
    
    var body: some View {
        NavigationView {
            mapContent
                .navigationTitle("Treasure Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
        }
    }
    
    private var mapContent: some View {
        GeometryReader { geometry in
            ZStack {
                // Parchment background
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.90),
                        Color(red: 0.95, green: 0.92, blue: 0.85)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Grid and content
                if let treasureLocation = mapService.treasureLocation {
                    let gridData = calculateGridPositions(
                        treasureLocation: treasureLocation,
                        landmarks: mapService.landmarks,
                        userLocation: mapService.userLocation,
                        gridSize: gridSize,
                        viewSize: geometry.size
                    )
                    
                    // Draw grid
                    GridCanvas(
                        gridSize: gridSize,
                        cellSize: cellSize,
                        gridData: gridData,
                        viewSize: geometry.size
                    )
                } else {
                    VStack {
                        Text("No treasure map data available")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Legend overlay (bottom)
                VStack {
                    Spacer()
                    
                    LegendView()
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding()
                }
            }
        }
    }
    
    /// Calculate grid positions for all points
    private func calculateGridPositions(
        treasureLocation: CLLocationCoordinate2D,
        landmarks: [GridLandmark],
        userLocation: CLLocationCoordinate2D?,
        gridSize: Int,
        viewSize: CGSize
    ) -> GridMapData {
        // Find bounds of all coordinates
        var allCoords: [CLLocationCoordinate2D] = [treasureLocation]
        allCoords.append(contentsOf: landmarks.map { $0.coordinate })
        if let userLoc = userLocation {
            allCoords.append(userLoc)
        }
        
        let minLat = allCoords.map { $0.latitude }.min() ?? treasureLocation.latitude
        let maxLat = allCoords.map { $0.latitude }.max() ?? treasureLocation.latitude
        let minLon = allCoords.map { $0.longitude }.min() ?? treasureLocation.longitude
        let maxLon = allCoords.map { $0.longitude }.max() ?? treasureLocation.longitude
        
        // Add padding
        let latPadding = (maxLat - minLat) * 0.2
        let lonPadding = (maxLon - minLon) * 0.2
        
        let bounds = CoordinateBounds(
            minLat: minLat - latPadding,
            maxLat: maxLat + latPadding,
            minLon: minLon - lonPadding,
            maxLon: maxLon + lonPadding
        )
        
        // Convert coordinates to grid positions
        let treasureGridPos = coordinateToGrid(
            coordinate: treasureLocation,
            bounds: bounds,
            gridSize: gridSize
        )
        
        let landmarkGridPositions = landmarks.map { landmark in
            GridPositionedLandmark(
                landmark: landmark,
                gridPosition: coordinateToGrid(
                    coordinate: landmark.coordinate,
                    bounds: bounds,
                    gridSize: gridSize
                )
            )
        }
        
        let userGridPos = userLocation.map { coord in
            coordinateToGrid(
                coordinate: coord,
                bounds: bounds,
                gridSize: gridSize
            )
        }
        
        return GridMapData(
            treasurePosition: treasureGridPos,
            landmarks: landmarkGridPositions,
            userPosition: userGridPos,
            bounds: bounds
        )
    }
    
    /// Convert a coordinate to grid position (0 to gridSize-1)
    private func coordinateToGrid(
        coordinate: CLLocationCoordinate2D,
        bounds: CoordinateBounds,
        gridSize: Int
    ) -> GridPosition {
        let latRatio = (coordinate.latitude - bounds.minLat) / (bounds.maxLat - bounds.minLat)
        let lonRatio = (coordinate.longitude - bounds.minLon) / (bounds.maxLon - bounds.minLon)
        
        let x = Int(lonRatio * Double(gridSize - 1))
        let y = Int((1.0 - latRatio) * Double(gridSize - 1)) // Flip Y axis (north is up)
        
        return GridPosition(
            x: max(0, min(gridSize - 1, x)),
            y: max(0, min(gridSize - 1, y))
        )
    }
}

// MARK: - Grid Map Data
struct GridMapData {
    let treasurePosition: GridPosition
    let landmarks: [GridPositionedLandmark]
    let userPosition: GridPosition?
    let bounds: CoordinateBounds
}

struct CoordinateBounds {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
}

struct GridPosition: Equatable {
    let x: Int
    let y: Int
}

struct GridPositionedLandmark {
    let landmark: GridLandmark
    let gridPosition: GridPosition
}

// MARK: - Grid Canvas
struct GridCanvas: View {
    let gridSize: Int
    let cellSize: CGFloat
    let gridData: GridMapData
    let viewSize: CGSize
    
    var body: some View {
        Canvas { context, size in
            // Calculate grid dimensions
            let gridWidth = CGFloat(gridSize) * cellSize
            let gridHeight = CGFloat(gridSize) * cellSize
            let offsetX = (size.width - gridWidth) / 2
            let offsetY = (size.height - gridHeight) / 2
            
            // Draw grid lines
            context.stroke(
                Path { path in
                    // Vertical lines
                    for i in 0...gridSize {
                        let x = offsetX + CGFloat(i) * cellSize
                        path.move(to: CGPoint(x: x, y: offsetY))
                        path.addLine(to: CGPoint(x: x, y: offsetY + gridHeight))
                    }
                    // Horizontal lines
                    for i in 0...gridSize {
                        let y = offsetY + CGFloat(i) * cellSize
                        path.move(to: CGPoint(x: offsetX, y: y))
                        path.addLine(to: CGPoint(x: offsetX + gridWidth, y: y))
                    }
                },
                with: .color(.brown.opacity(0.3)),
                lineWidth: 1
            )
            
            // Draw landmarks
            for positionedLandmark in gridData.landmarks {
                let pos = positionedLandmark.gridPosition
                let x = offsetX + CGFloat(pos.x) * cellSize + cellSize / 2
                let y = offsetY + CGFloat(pos.y) * cellSize + cellSize / 2
                
                // Draw landmark icon
                let color = positionedLandmark.landmark.type.color
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - cellSize / 3,
                        y: y - cellSize / 3,
                        width: cellSize * 2/3,
                        height: cellSize * 2/3
                    )),
                    with: .color(color)
                )
            }
            
            // Draw user position
            if let userPos = gridData.userPosition {
                let x = offsetX + CGFloat(userPos.x) * cellSize + cellSize / 2
                let y = offsetY + CGFloat(userPos.y) * cellSize + cellSize / 2
                
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - cellSize / 4,
                        y: y - cellSize / 4,
                        width: cellSize / 2,
                        height: cellSize / 2
                    )),
                    with: .color(.blue)
                )
            }
            
            // Draw treasure (X marks the spot)
            let treasureX = offsetX + CGFloat(gridData.treasurePosition.x) * cellSize + cellSize / 2
            let treasureY = offsetY + CGFloat(gridData.treasurePosition.y) * cellSize + cellSize / 2
            
            // Red circle
            context.fill(
                Path(ellipseIn: CGRect(
                    x: treasureX - cellSize / 2,
                    y: treasureY - cellSize / 2,
                    width: cellSize,
                    height: cellSize
                )),
                with: .color(.red.opacity(0.3))
            )
            
            // Red X
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: treasureX - cellSize / 3, y: treasureY - cellSize / 3))
                    path.addLine(to: CGPoint(x: treasureX + cellSize / 3, y: treasureY + cellSize / 3))
                    path.move(to: CGPoint(x: treasureX + cellSize / 3, y: treasureY - cellSize / 3))
                    path.addLine(to: CGPoint(x: treasureX - cellSize / 3, y: treasureY + cellSize / 3))
                },
                with: .color(.red),
                lineWidth: 3
            )
        }
    }
}

// MARK: - Legend View
struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legend")
                .font(.headline)
                .foregroundColor(.brown)
            
            HStack(spacing: 16) {
                LegendItem(icon: "location.fill", color: .blue, label: "You")
                LegendItem(icon: "tree.fill", color: .green, label: "Tree")
                LegendItem(icon: "drop.fill", color: .blue, label: "Water")
                LegendItem(icon: "building.2.fill", color: .brown, label: "Building")
            }
            
            HStack(spacing: 16) {
                LegendItem(icon: "xmark", color: .red, label: "Treasure")
            }
        }
    }
}

