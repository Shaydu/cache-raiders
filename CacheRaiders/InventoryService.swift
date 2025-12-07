import Foundation
import Combine

// MARK: - Inventory Item Types
enum InventoryItemType: String, Codable {
    case mapPiece = "map_piece"
    case treasureMap = "treasure_map"
    case clue = "clue"
    case key = "key"
    case other = "other"
}

// MARK: - Inventory Sync Service
class InventorySyncService {
    static let shared = InventorySyncService()

    private init() {
        setupWebSocketListeners()
    }

    private func setupWebSocketListeners() {
        // Listen for inventory synchronization events
        WebSocketService.shared.onInventoryItemAdded = { [weak self] itemData in
            self?.handleInventoryItemAdded(itemData)
        }

        WebSocketService.shared.onInventoryItemDeleted = { [weak self] deleteData in
            self?.handleInventoryItemDeleted(deleteData)
        }

        WebSocketService.shared.onInventoryReset = { [weak self] resetData in
            self?.handleInventoryReset(resetData)
        }
    }

    private func handleInventoryItemAdded(_ itemData: [String: Any]) {
        guard let deviceUUID = itemData["device_uuid"] as? String,
              let item = itemData["item"] as? [String: Any],
              deviceUUID == APIService.shared.currentUserID else {
            return // Not for this device
        }

        // Convert server item data to InventoryItem
        if let inventoryItem = InventoryItem.fromServerData(item) {
            InventoryService.shared.addItem(inventoryItem)
            print("📦 [InventorySync] Item added via WebSocket: \(inventoryItem.name)")
        }
    }

    private func handleInventoryItemDeleted(_ deleteData: [String: Any]) {
        guard let deviceUUID = deleteData["device_uuid"] as? String,
              let itemId = deleteData["item_id"] as? String,
              deviceUUID == APIService.shared.currentUserID else {
            return // Not for this device
        }

        InventoryService.shared.removeItem(withId: itemId)
        print("🗑️ [InventorySync] Item deleted via WebSocket: \(itemId)")
    }

    private func handleInventoryReset(_ resetData: [String: Any]) {
        guard let deviceUUID = resetData["device_uuid"] as? String,
              deviceUUID == APIService.shared.currentUserID else {
            return // Not for this device
        }

        InventoryService.shared.reset()
        print("🔄 [InventorySync] Inventory reset via WebSocket")
    }
}

// MARK: - Inventory Item
struct InventoryItem: Identifiable, Codable, Equatable {
    let id: String
    let type: InventoryItemType
    let name: String
    let description: String
    let icon: String // Emoji or icon name
    let obtainedDate: Date
    let sourceNPC: String? // Which NPC gave this item

    // Map piece specific data
    let mapPieceData: MapPieceData?

    init(id: String, type: InventoryItemType, name: String, description: String, icon: String, sourceNPC: String? = nil, mapPieceData: MapPieceData? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.description = description
        self.icon = icon
        self.obtainedDate = Date()
        self.sourceNPC = sourceNPC
        self.mapPieceData = mapPieceData
    }

    // MARK: - Server Data Conversion
    static func fromServerData(_ data: [String: Any]) -> InventoryItem? {
        guard let id = data["id"] as? String,
              let typeString = data["type"] as? String,
              let type = InventoryItemType(rawValue: typeString),
              let name = data["name"] as? String,
              let description = data["description"] as? String,
              let icon = data["icon"] as? String else {
            return nil
        }

        let sourceNPC = data["source_npc"] as? String

        // Parse map piece data if present
        var mapPieceData: MapPieceData? = nil
        if let mapData = data["map_piece_data"] as? [String: Any] {
            mapPieceData = MapPieceData.fromServerData(mapData)
        }

        // Parse obtained date
        var obtainedDate = Date()
        if let dateString = data["obtained_date"] as? String,
           let date = ISO8601DateFormatter().date(from: dateString) {
            obtainedDate = date
        }

        return InventoryItem(
            id: id,
            type: type,
            name: name,
            description: description,
            icon: icon,
            sourceNPC: sourceNPC,
            mapPieceData: mapPieceData
        )
    }

    // Convenience initializer for map pieces
    init(from mapPiece: MapPiece, sourceNPC: String) {
        self.id = "map_piece_\(mapPiece.piece_number)"
        self.type = .mapPiece
        self.name = "Map Piece \(mapPiece.piece_number)/\(mapPiece.total_pieces)"
        self.description = mapPiece.hint
        self.icon = "🗺️"
        self.obtainedDate = Date()
        self.sourceNPC = sourceNPC
        self.mapPieceData = MapPieceData(from: mapPiece)
    }
}

// MARK: - Map Piece Data
struct MapPieceData: Codable, Equatable {
    static func == (lhs: MapPieceData, rhs: MapPieceData) -> Bool {
        return lhs.pieceNumber == rhs.pieceNumber &&
               lhs.totalPieces == rhs.totalPieces &&
               lhs.npcName == rhs.npcName &&
               lhs.hint == rhs.hint &&
               lhs.approximateLatitude == rhs.approximateLatitude &&
               lhs.approximateLongitude == rhs.approximateLongitude &&
               lhs.isFirstHalf == rhs.isFirstHalf &&
               lhs.clue == rhs.clue &&
               lhs.landmarks == rhs.landmarks
    }

    let pieceNumber: Int
    let totalPieces: Int
    let npcName: String
    let hint: String
    let approximateLatitude: Double
    let approximateLongitude: Double
    let landmarks: [Landmark]?
    let isFirstHalf: Bool
    let clue: String

    init(pieceNumber: Int, totalPieces: Int, npcName: String, hint: String,
         approximateLatitude: Double, approximateLongitude: Double,
         landmarks: [Landmark]?, isFirstHalf: Bool, clue: String) {
        self.pieceNumber = pieceNumber
        self.totalPieces = totalPieces
        self.npcName = npcName
        self.hint = hint
        self.approximateLatitude = approximateLatitude
        self.approximateLongitude = approximateLongitude
        self.landmarks = landmarks
        self.isFirstHalf = isFirstHalf
        self.clue = clue
    }

    init(from mapPiece: MapPiece) {
        self.pieceNumber = mapPiece.piece_number
        self.totalPieces = mapPiece.total_pieces
        self.npcName = mapPiece.npc_name
        self.hint = mapPiece.hint
        self.approximateLatitude = mapPiece.approximate_latitude
        self.approximateLongitude = mapPiece.approximate_longitude
        self.landmarks = mapPiece.landmarks
        self.isFirstHalf = mapPiece.is_first_half
        self.clue = mapPiece.clue
    }

    static func fromServerData(_ data: [String: Any]) -> MapPieceData? {
        guard let pieceNumber = data["piece_number"] as? Int,
              let totalPieces = data["total_pieces"] as? Int,
              let npcName = data["npc_name"] as? String,
              let hint = data["hint"] as? String,
              let latitude = data["approximate_latitude"] as? Double,
              let longitude = data["approximate_longitude"] as? Double,
              let isFirstHalf = data["is_first_half"] as? Bool,
              let clue = data["clue"] as? String else {
            return nil
        }

        let landmarks = data["landmarks"] as? [Landmark]

        return MapPieceData(
            pieceNumber: pieceNumber,
            totalPieces: totalPieces,
            npcName: npcName,
            hint: hint,
            approximateLatitude: latitude,
            approximateLongitude: longitude,
            landmarks: landmarks,
            isFirstHalf: isFirstHalf,
            clue: clue
        )
    }
}

// MARK: - Inventory Service
class InventoryService: ObservableObject {
    static let shared = InventoryService()

    @Published var items: [InventoryItem] = []
    @Published var hasNewItems: Bool = false

    private let inventoryKey = "inventory_items"
    private var isInitialized = false

    private init() {
        loadInventory()
        // Initialize sync service
        _ = InventorySyncService.shared
    }

    // MARK: - Server Synchronization

    func syncWithServer() async throws {
        print("🔄 [InventoryService] Syncing inventory with server...")
        let serverItems = try await APIService.shared.getInventory()

        // Convert server items to InventoryItem objects
        var syncedItems: [InventoryItem] = []
        for itemData in serverItems {
            if let item = InventoryItem.fromServerData(itemData) {
                syncedItems.append(item)
            }
        }

        // Update local inventory
        await MainActor.run {
            self.items = syncedItems
            self.saveInventory()
            self.isInitialized = true
        }

        print("✅ [InventoryService] Synced \(syncedItems.count) items from server")
    }

    // MARK: - Add Items

    func addItem(_ item: InventoryItem) {
        // Check if item already exists
        if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
            // Update existing item
            items[existingIndex] = item
        } else {
            // Add new item
            items.append(item)
            hasNewItems = true

            // Post notification for UI updates
            NotificationCenter.default.post(
                name: NSNotification.Name("InventoryItemAdded"),
                object: nil,
                userInfo: ["item": item]
            )

            // Sync to server if initialized
            if isInitialized {
                Task {
                    do {
                        try await APIService.shared.addInventoryItem(item)
                        print("📤 [InventoryService] Synced item to server: \(item.name)")
                    } catch {
                        print("❌ [InventoryService] Failed to sync item to server: \(error.localizedDescription)")
                    }
                }
            }
        }

        saveInventory()
        print("📦 [InventoryService] Added item: \(item.name) (\(item.type.rawValue))")
    }

    func addMapPiece(_ mapPiece: MapPiece, sourceNPC: String) {
        let item = InventoryItem(from: mapPiece, sourceNPC: sourceNPC)
        addItem(item)
    }

    // MARK: - Query Items

    func hasItem(withId id: String) -> Bool {
        return items.contains(where: { $0.id == id })
    }

    func getItems(ofType type: InventoryItemType) -> [InventoryItem] {
        return items.filter { $0.type == type }
    }

    func getMapPieces() -> [InventoryItem] {
        return getItems(ofType: .mapPiece).sorted { $0.mapPieceData?.pieceNumber ?? 0 < $1.mapPieceData?.pieceNumber ?? 0 }
    }

    var mapPieceCount: Int {
        return getMapPieces().count
    }

    var hasCompleteMap: Bool {
        let mapPieces = getMapPieces()
        guard let firstPiece = mapPieces.first else { return false }
        guard let totalPieces = firstPiece.mapPieceData?.totalPieces else { return false }
        return mapPieces.count >= totalPieces
    }

    // MARK: - Remove Items

    func removeItem(withId id: String) {
        items.removeAll { $0.id == id }
        saveInventory()

        // Sync deletion to server if initialized
        if isInitialized {
            Task {
                do {
                    try await APIService.shared.deleteInventoryItem(itemId: id)
                    print("🗑️ [InventoryService] Synced item deletion to server: \(id)")
                } catch {
                    print("❌ [InventoryService] Failed to sync item deletion to server: \(error.localizedDescription)")
                }
            }
        }
    }

    func clearNewItemsFlag() {
        hasNewItems = false
    }

    // MARK: - Persistence

    private func saveInventory() {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: inventoryKey)
        } catch {
            print("❌ [InventoryService] Failed to save inventory: \(error.localizedDescription)")
        }
    }

    private func loadInventory() {
        guard let data = UserDefaults.standard.data(forKey: inventoryKey) else { return }

        do {
            items = try JSONDecoder().decode([InventoryItem].self, from: data)
            print("✅ [InventoryService] Loaded \(items.count) inventory items")
        } catch {
            print("❌ [InventoryService] Failed to load inventory: \(error.localizedDescription)")
        }
    }

    // MARK: - Reset

    func reset() {
        items = []
        hasNewItems = false
        UserDefaults.standard.removeObject(forKey: inventoryKey)
        print("🗑️ [InventoryService] Inventory reset")
    }
}
