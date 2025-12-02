import SwiftUI

// MARK: - Inventory View
struct InventoryView: View {
    @ObservedObject var inventoryService: InventoryService
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("🎒 Inventory")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)

                // Content
                ScrollView {
                    VStack(spacing: 16) {
                        // Map Pieces Section
                        if !inventoryService.getMapPieces().isEmpty {
                            InventorySectionView(
                                title: "🗺️ Treasure Maps",
                                items: inventoryService.getMapPieces(),
                                inventoryService: inventoryService
                            )
                        }

                        // Other Items Section
                        let otherItems = inventoryService.items.filter { $0.type != .mapPiece }
                        if !otherItems.isEmpty {
                            InventorySectionView(
                                title: "📦 Other Items",
                                items: otherItems,
                                inventoryService: inventoryService
                            )
                        }

                        // Empty State
                        if inventoryService.items.isEmpty {
                            VStack(spacing: 16) {
                                Text("🎒")
                                    .font(.system(size: 64))
                                Text("Your inventory is empty")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Text("Collect treasure maps and items during your adventures!")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            .padding(.top, 50)
                        }
                    }
                    .padding()
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            inventoryService.clearNewItemsFlag()
        }
    }
}

// MARK: - Inventory Section View
struct InventorySectionView: View {
    let title: String
    let items: [InventoryItem]
    let inventoryService: InventoryService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            ForEach(items) { item in
                InventoryItemView(item: item, inventoryService: inventoryService)
            }
        }
    }
}

// MARK: - Inventory Item View
struct InventoryItemView: View {
    let item: InventoryItem
    let inventoryService: InventoryService

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 12) {
                Text(item.icon)
                    .font(.title)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(item.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()

                // Expand/collapse button
                if shouldShowDetails {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Expanded details
            if isExpanded && shouldShowDetails {
                VStack(alignment: .leading, spacing: 8) {
                    if let mapData = item.mapPieceData {
                        MapPieceDetailsView(mapPieceData: mapData)
                    }

                    if let sourceNPC = item.sourceNPC {
                        Text("Obtained from: \(sourceNPC)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Obtained: \(item.obtainedDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 44) // Align with text
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if shouldShowDetails {
                isExpanded.toggle()
            }
        }
    }

    private var shouldShowDetails: Bool {
        return item.mapPieceData != nil || item.sourceNPC != nil
    }
}

// MARK: - Map Piece Details View
struct MapPieceDetailsView: View {
    let mapPieceData: MapPieceData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Piece \(mapPieceData.pieceNumber)/\(mapPieceData.totalPieces)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if mapPieceData.isFirstHalf {
                    Text("First Half")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            Text("Clue: \(mapPieceData.clue)")
                .font(.subheadline)
                .foregroundColor(.primary)

            if let landmarks = mapPieceData.landmarks, !landmarks.isEmpty {
                Text("Landmarks:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                ForEach(landmarks, id: \.name) { landmark in
                    Text("• \(landmark.name) (\(landmark.type))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Approximate Location:")
                    .font(.caption)
                Text(String(format: "%.4f, %.4f", mapPieceData.approximateLatitude, mapPieceData.approximateLongitude))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospaced()
            }
        }
    }
}

// MARK: - Preview
struct InventoryView_Previews: PreviewProvider {
    static var previews: some View {
        let inventoryService = InventoryService()

        // Add some sample items for preview
        let mockMapPiece = MapPiece(
            piece_number: 1,
            total_pieces: 3,
            npc_name: "Captain Bones",
            hint: "Arr, this map shows the path to me treasure! Look for the big rock and the old tree.",
            approximate_latitude: 40.1234,
            approximate_longitude: -105.5678,
            landmarks: [
                Landmark(name: "Big Rock", type: "landmark", latitude: 40.1234, longitude: -105.5678),
                Landmark(name: "Old Tree", type: "tree", latitude: 40.1235, longitude: -105.5679)
            ],
            is_first_half: true,
            clue: "X marks the spot where the treasure be buried!"
        )

        let sampleMapPiece = InventoryItem(
            id: "sample_map_1",
            type: .mapPiece,
            name: "Map Piece 1/3",
            description: "Arr, this map shows the path to me treasure! Look for the big rock and the old tree.",
            icon: "🗺️",
            sourceNPC: "Captain Bones",
            mapPieceData: MapPieceData(from: mockMapPiece)
        )

        inventoryService.addItem(sampleMapPiece)

        return InventoryView(inventoryService: inventoryService)
    }
}
