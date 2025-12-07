import SwiftUI
import CoreLocation

// MARK: - Found Items View
struct FoundItemsView: View {
    let locationManager: LootBoxLocationManager
    let userLocationManager: UserLocationManager
    let onToggleCollected: (String) -> Void
    let onDeleteLocation: (String) -> Void

    // Get all unfound items (not collected locations that are persisted)
    private var unfoundItems: [LootBoxLocation] {
        locationManager.locations.filter { location in
            // Include uncollected items that are persisted (not temporary AR-only items)
            return !location.collected && location.shouldPersist
        }
    }

    // Get all found items (collected locations that are persisted)
    private var foundItems: [LootBoxLocation] {
        locationManager.locations.filter { location in
            // Include collected items that are persisted (not temporary AR-only items)
            return location.collected && location.shouldPersist
        }
    }

    // Helper function to convert meters to feet and inches
    private func formatDistanceInFeetInches(_ meters: Double) -> String {
        let totalInches = meters * 39.3701 // Convert meters to inches
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))

        if feet > 0 {
            return "\(feet)'\(inches)\""
        } else {
            return "\(inches)\""
        }
    }

    // Calculate distance from user to item
    private func distanceToItem(_ item: LootBoxLocation) -> Double? {
        guard let userLocation = userLocationManager.currentLocation else { return nil }
        let itemLocation = CLLocation(latitude: item.latitude, longitude: item.longitude)
        return userLocation.distance(from: itemLocation)
    }

    // Get placer name for an item (similar to ARObjectDetailService logic)
    private func placerName(for item: LootBoxLocation) -> String {
        if let createdBy = item.created_by {
            let currentUserId = APIService.shared.currentUserID
            if createdBy == currentUserId {
                return "Your"
            } else if createdBy == "admin-web-ui" {
                return "Admin"
            } else {
                return "Another user's"
            }
        } else {
            return item.source == .api ? "Admin" : "Unknown"
        }
    }

    // Helper function to create item row (used for both found and unfound items)
    @ViewBuilder
    private func itemRow(for item: LootBoxLocation, isFound: Bool) -> some View {
        HStack(spacing: 12) {
            // Item Icon
            Image(systemName: item.type.factory.iconName)
                .font(.title2)
                .foregroundColor(Color(item.type.color))
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                // Item Name
                Text(item.name)
                    .font(.headline)
                    .foregroundColor(.white)

                // Placer Name and Distance
                HStack {
                    Text("\(placerName(for: item)) item")
                        .font(.caption)
                        .foregroundColor(.gray)

                    if let distance = distanceToItem(item) {
                        Text("• \(formatDistanceInFeetInches(distance)) away")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }

            Spacer()

            // Collection indicator
            if isFound {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.gray)
                    .font(.title3)
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.black.opacity(0.2))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Toggle found/unfound action
            Button {
                onToggleCollected(item.id)
            } label: {
                Label(isFound ? "Mark Unfound" : "Mark Found",
                      systemImage: isFound ? "circle" : "checkmark.circle.fill")
            }
            .tint(isFound ? .orange : .green)

            // Delete action
            Button(role: .destructive) {
                onDeleteLocation(item.id)
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                // Unfound Items Section
                if !unfoundItems.isEmpty {
                    Section(header: Text("Unfound Items (\(unfoundItems.count))")
                        .foregroundColor(.white)
                        .font(.headline)) {
                        ForEach(unfoundItems) { item in
                            itemRow(for: item, isFound: false)
                        }
                    }
                }

                // Found Items Section
                if !foundItems.isEmpty {
                    Section(header: Text("Found Items (\(foundItems.count))")
                        .foregroundColor(.white)
                        .font(.headline)) {
                        ForEach(foundItems) { item in
                            itemRow(for: item, isFound: true)
                        }
                    }
                }

                // Empty state when both lists are empty
                if unfoundItems.isEmpty && foundItems.isEmpty {
                    Text("No items available!")
                        .foregroundColor(.gray)
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.grouped)
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .navigationTitle("Items (\(unfoundItems.count + foundItems.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
