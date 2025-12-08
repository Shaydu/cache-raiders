import SwiftUI
import CoreLocation

// MARK: - Clue Drawer View
/// A drawer view shown in Story Mode that displays collected clues and the treasure map
struct ClueDrawerView: View {
    @ObservedObject var treasureHuntService: TreasureHuntService
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @Environment(\.dismiss) var dismiss
    
    // Callback when user wants to view the full treasure map
    var onShowTreasureMap: (() -> Void)?
    
    @State private var isMapExpanded = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection
                    
                    // Treasure Map Section
                    if treasureHuntService.hasMap {
                        treasureMapSection
                    } else {
                        noMapSection
                    }
                    
                    // Collected Items Section
                    collectedItemsSection
                    
                    Spacer(minLength: 40)
                }
                .padding()
            }
            .background(drawerBackground)
            .navigationTitle("Clue Drawer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.orange)
                }
            }
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .yellow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("Your Discoveries")
                .font(.system(.title2, design: .serif, weight: .bold))
                .foregroundColor(.white)
            
            Text("Items and clues collected on your adventure")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
    
    // MARK: - Treasure Map Section
    private var treasureMapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "map.fill")
                    .foregroundColor(.orange)
                Text("Treasure Map")
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                // Map status badge
                Text("COLLECTED")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.3))
                    .foregroundColor(.green)
                    .cornerRadius(4)
            }
            
            // Tappable map preview
            Button(action: {
                onShowTreasureMap?()
                dismiss()
            }) {
                ZStack {
                    // Map preview background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.82, green: 0.71, blue: 0.55),
                                    Color(red: 0.72, green: 0.61, blue: 0.45)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 160)
                    
                    // Aged paper texture overlay
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.brown.opacity(0.1))
                        .frame(height: 160)
                    
                    // Map content
                    VStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.red.opacity(0.8))
                        
                        Text("X Marks the Spot")
                            .font(.system(.subheadline, design: .serif, weight: .semibold))
                            .foregroundColor(.brown)
                        
                        if let distance = getDistanceToTreasure() {
                            Text("\(formatDistance(distance)) away")
                                .font(.caption)
                                .foregroundColor(.brown.opacity(0.8))
                        }
                    }
                    
                    // Tap hint
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "hand.tap.fill")
                                Text("Tap to view")
                            }
                            .font(.caption2)
                            .foregroundColor(.brown.opacity(0.7))
                            .padding(8)
                        }
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            // Map clue text from skeleton
            if let mapPiece = treasureHuntService.mapPiece {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Captain Bones says:")
                        .font(.caption)
                        .foregroundColor(.orange)
                    
                    Text("\"\(mapPiece.hint)\"")
                        .font(.system(.caption, design: .serif))
                        .foregroundColor(.gray)
                        .italic()
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    // MARK: - No Map Section
    private var noMapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "map")
                    .foregroundColor(.gray)
                Text("Treasure Map")
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("NOT FOUND")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.gray)
                    .cornerRadius(4)
            }
            
            // Empty map placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 120)
                
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.gray.opacity(0.5))
                    
                    Text("Find Captain Bones to get the map")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Collected Items Section
    private var collectedItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "archivebox.fill")
                    .foregroundColor(.yellow)
                Text("Collected Items")
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("\(collectedStoryItems.count)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.2))
                    .foregroundColor(.yellow)
                    .cornerRadius(4)
            }
            
            if collectedStoryItems.isEmpty {
                // Empty state
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 100)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundColor(.gray.opacity(0.5))
                        
                        Text("No items collected yet")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            } else {
                // Items grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(collectedStoryItems) { item in
                        CollectedItemCell(item: item)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Background
    private var drawerBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.06, blue: 0.12),
                Color(red: 0.12, green: 0.08, blue: 0.16),
                Color(red: 0.06, green: 0.04, blue: 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    // MARK: - Helper Methods
    
    /// Get items collected in story mode
    private var collectedStoryItems: [LootBoxLocation] {
        // In story mode, filter for collected items that are story-relevant
        // For now, return collected items - this can be expanded later
        return locationManager.locations.filter { $0.collected }
    }
    
    /// Get distance to treasure
    private func getDistanceToTreasure() -> Double? {
        guard let userLocation = userLocationManager.currentLocation else { return nil }
        return treasureHuntService.getDistanceToTreasure(from: userLocation)
    }
    
    /// Format distance for display
    private func formatDistance(_ meters: Double) -> String {
        let totalInches = meters * 39.3701
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        
        if feet > 0 {
            return "\(feet)'\(inches)\""
        } else {
            return "\(inches)\""
        }
    }
}

// MARK: - Collected Item Cell
struct CollectedItemCell: View {
    let item: LootBoxLocation
    
    var body: some View {
        VStack(spacing: 6) {
            // Item icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [itemColor.opacity(0.3), itemColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                
                Image(systemName: itemIcon)
                    .font(.system(size: 22))
                    .foregroundColor(itemColor)
            }
            
            // Item name
            Text(item.name)
                .font(.caption2)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
    
    private var itemIcon: String {
        return item.type.factory.iconName
    }
    
    private var itemColor: Color {
        return Color(uiColor: item.type.factory.color)
    }
}

// MARK: - Preview
#Preview {
    ClueDrawerView(
        treasureHuntService: TreasureHuntService(),
        locationManager: LootBoxLocationManager(),
        userLocationManager: UserLocationManager()
    )
}
