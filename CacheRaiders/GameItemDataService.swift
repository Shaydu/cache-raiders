//
//  GameItemDataService.swift
//  CacheRaiders
//
//  Created for offline storage using Core Data
//

import Foundation
import CoreData
import CoreLocation

// MARK: - Game Item Data Service
/// Service for managing game items in Core Data (SQLite) for offline storage
class GameItemDataService {
    static let shared = GameItemDataService()
    
    private let persistenceController = PersistenceController.shared
    
    private init() {}
    
    // MARK: - Core Data Context Helpers
    
    /// Main context for UI operations (runs on main thread)
    private var viewContext: NSManagedObjectContext {
        return persistenceController.container.viewContext
    }
    
    /// Background context for heavy operations (runs on background thread)
    private func newBackgroundContext() -> NSManagedObjectContext {
        return persistenceController.container.newBackgroundContext()
    }
    
    // MARK: - Save Context
    
    private func saveContext(_ context: NSManagedObjectContext) throws {
        if context.hasChanges {
            try context.save()
        }
    }
    
    // MARK: - Convert LootBoxLocation to GameItem
    
    private func createGameItem(from location: LootBoxLocation, in context: NSManagedObjectContext) -> GameItem {
        let gameItem = GameItem(context: context)
        gameItem.id = location.id
        gameItem.name = location.name
        gameItem.type = location.type.rawValue
        gameItem.latitude = location.latitude
        gameItem.longitude = location.longitude
        gameItem.radius = location.radius
        gameItem.collected = location.collected
        gameItem.grounding_height = location.grounding_height ?? 0.0
        gameItem.source = location.source.rawValue
        gameItem.ar_origin_latitude = location.ar_origin_latitude ?? 0.0
        gameItem.ar_origin_longitude = location.ar_origin_longitude ?? 0.0
        gameItem.ar_offset_x = location.ar_offset_x ?? 0.0
        gameItem.ar_offset_y = location.ar_offset_y ?? 0.0
        gameItem.ar_offset_z = location.ar_offset_z ?? 0.0
        gameItem.ar_placement_timestamp = location.ar_placement_timestamp
        gameItem.ar_anchor_transform = location.ar_anchor_transform // Add AR anchor transform support
        gameItem.created_at = Date()
        gameItem.updated_at = Date()
        gameItem.needs_sync = false // Will be set to true when modified offline
        return gameItem
    }
    
    private func updateGameItem(_ gameItem: GameItem, with location: LootBoxLocation) {
        gameItem.name = location.name
        gameItem.type = location.type.rawValue
        gameItem.latitude = location.latitude
        gameItem.longitude = location.longitude
        gameItem.radius = location.radius
        gameItem.collected = location.collected
        gameItem.grounding_height = location.grounding_height ?? 0.0
        gameItem.source = location.source.rawValue
        gameItem.ar_origin_latitude = location.ar_origin_latitude ?? 0.0
        gameItem.ar_origin_longitude = location.ar_origin_longitude ?? 0.0
        gameItem.ar_offset_x = location.ar_offset_x ?? 0.0
        gameItem.ar_offset_y = location.ar_offset_y ?? 0.0
        gameItem.ar_offset_z = location.ar_offset_z ?? 0.0
        gameItem.ar_placement_timestamp = location.ar_placement_timestamp
        gameItem.ar_anchor_transform = location.ar_anchor_transform // Add AR anchor transform support
        gameItem.updated_at = Date()
    }
    
    // MARK: - Convert GameItem to LootBoxLocation
    
    private func convertToLootBoxLocation(_ gameItem: GameItem) -> LootBoxLocation? {
        guard let id = gameItem.id,
              let name = gameItem.name,
              let typeString = gameItem.type,
              let type = LootBoxType(rawValue: typeString),
              let sourceString = gameItem.source,
              let source = ItemSource(rawValue: sourceString) else {
            print("⚠️ Failed to convert GameItem to LootBoxLocation: missing required fields")
            return nil
        }
        
        // Core Data stores optional Double as non-optional Double (0.0 for nil)
        // Convert back to optional: if value is 0.0, treat as nil (0.0 is unlikely for these AR values)
        let groundingHeight: Double? = gameItem.grounding_height != 0.0 ? gameItem.grounding_height : nil
        
        var location = LootBoxLocation(
            id: id,
            name: name,
            type: type,
            latitude: gameItem.latitude,
            longitude: gameItem.longitude,
            radius: gameItem.radius,
            collected: gameItem.collected,
            grounding_height: groundingHeight,
            source: source
        )
        
        // Set optional AR offset fields
        // Convert non-zero values back to optional Double
        if gameItem.ar_origin_latitude != 0.0 {
            location.ar_origin_latitude = gameItem.ar_origin_latitude
        }
        if gameItem.ar_origin_longitude != 0.0 {
            location.ar_origin_longitude = gameItem.ar_origin_longitude
        }
        
        if gameItem.ar_offset_x != 0.0 {
            location.ar_offset_x = gameItem.ar_offset_x
        }
        if gameItem.ar_offset_y != 0.0 {
            location.ar_offset_y = gameItem.ar_offset_y
        }
        if gameItem.ar_offset_z != 0.0 {
            location.ar_offset_z = gameItem.ar_offset_z
        }
        
        location.ar_placement_timestamp = gameItem.ar_placement_timestamp
        
        // Set AR anchor transform if available
        location.ar_anchor_transform = gameItem.ar_anchor_transform
        
        return location
    }
    
    // MARK: - CRUD Operations
    
    /// Save or update a game item
    func saveLocation(_ location: LootBoxLocation) throws {
        let context = viewContext
        
        // Check if item already exists
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", location.id)
        
        if let existingItem = try? context.fetch(fetchRequest).first {
            // Update existing item
            updateGameItem(existingItem, with: location)
            existingItem.updated_at = Date()
        } else {
            // Create new item
            let gameItem = createGameItem(from: location, in: context)
            gameItem.needs_sync = location.shouldSyncToAPI
        }
        
        try saveContext(context)
    }
    
    /// Save multiple locations (batch operation on background thread)
    func saveLocations(_ locations: [LootBoxLocation]) async throws {
        let context = newBackgroundContext()
        
        return try await context.perform {
            // Fetch all existing items to update
            let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
            let existingItems = try context.fetch(fetchRequest)
            let existingItemsDict = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id ?? "", $0) })
            
            for location in locations {
                if let existingItem = existingItemsDict[location.id] {
                    // Update existing
                    self.updateGameItem(existingItem, with: location)
                    existingItem.updated_at = Date()
                } else {
                    // Create new
                    let gameItem = self.createGameItem(from: location, in: context)
                    gameItem.needs_sync = location.shouldSyncToAPI
                }
            }
            
            try self.saveContext(context)
        }
    }
    
    /// Load all game items
    func loadAllLocations() throws -> [LootBoxLocation] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        
        let gameItems = try context.fetch(fetchRequest)
        return gameItems.compactMap { convertToLootBoxLocation($0) }
    }
    
    /// Load all game items (async, runs on background thread)
    func loadAllLocationsAsync() async throws -> [LootBoxLocation] {
        let context = newBackgroundContext()
        
        return try await context.perform {
            let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            
            let gameItems = try context.fetch(fetchRequest)
            return gameItems.compactMap { self.convertToLootBoxLocation($0) }
        }
    }
    
    /// Get a single location by ID
    func getLocation(byId id: String) throws -> LootBoxLocation? {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        fetchRequest.fetchLimit = 1
        
        if let gameItem = try context.fetch(fetchRequest).first {
            return convertToLootBoxLocation(gameItem)
        }
        return nil
    }
    
    /// Delete a location
    func deleteLocation(byId id: String) throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)
        
        if let gameItem = try context.fetch(fetchRequest).first {
            context.delete(gameItem)
            try saveContext(context)
        }
    }
    
    /// Delete all locations
    func deleteAllLocations() throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest as! NSFetchRequest<NSFetchRequestResult>)
        
        try context.execute(batchDeleteRequest)
        try saveContext(context)
    }
    
    /// Mark location as collected
    func markCollected(_ locationId: String) throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", locationId)
        
        if let gameItem = try context.fetch(fetchRequest).first {
            gameItem.collected = true
            gameItem.updated_at = Date()
            gameItem.needs_sync = true
            try saveContext(context)
        }
    }
    
    /// Mark location as uncollected
    func markUncollected(_ locationId: String) throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", locationId)
        
        if let gameItem = try context.fetch(fetchRequest).first {
            gameItem.collected = false
            gameItem.updated_at = Date()
            gameItem.needs_sync = true
            try saveContext(context)
        }
    }
    
    /// Get items that need syncing to API
    func getItemsNeedingSync() throws -> [LootBoxLocation] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "needs_sync == YES")
        
        let gameItems = try context.fetch(fetchRequest)
        return gameItems.compactMap { convertToLootBoxLocation($0) }
    }
    
    /// Mark item as synced
    func markAsSynced(_ locationId: String) throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", locationId)
        
        if let gameItem = try context.fetch(fetchRequest).first {
            gameItem.needs_sync = false
            gameItem.last_synced_at = Date()
            try saveContext(context)
        }
    }
    
    /// Get nearby locations within radius
    func getNearbyLocations(userLocation: CLLocation, maxDistance: Double) throws -> [LootBoxLocation] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        
        let allItems = try context.fetch(fetchRequest)
        let allLocations = allItems.compactMap { convertToLootBoxLocation($0) }
        
        // Filter by distance
        return allLocations.filter { location in
            let locationCLLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            return userLocation.distance(from: locationCLLocation) <= maxDistance
        }
    }
    
    /// Count of all items
    func getItemCount() throws -> Int {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        return try context.count(for: fetchRequest)
    }
    
    /// Count of collected items
    func getCollectedCount() throws -> Int {
        let context = viewContext
        let fetchRequest: NSFetchRequest<GameItem> = GameItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "collected == YES")
        return try context.count(for: fetchRequest)
    }
}

