//
//  FindDataService.swift
//  CacheRaiders
//
//  Created for offline storage of find records using Core Data
//

import Foundation
import CoreData

// MARK: - Find Record Struct
/// Represents a find record (who found what when)
struct FindRecord {
    let id: String
    let objectId: String
    let foundBy: String
    let foundAt: Date
    let needsSync: Bool
    let createdAt: Date?
    let lastSyncedAt: Date?

    init(id: String, objectId: String, foundBy: String, foundAt: Date, needsSync: Bool = true, createdAt: Date? = nil, lastSyncedAt: Date? = nil) {
        self.id = id
        self.objectId = objectId
        self.foundBy = foundBy
        self.foundAt = foundAt
        self.needsSync = needsSync
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
    }

    /// Convert Find entity to FindRecord
    init?(from findEntity: Find) {
        guard let id = findEntity.id,
              let objectId = findEntity.object_id,
              let foundBy = findEntity.found_by,
              let foundAt = findEntity.found_at else {
            print("⚠️ Failed to convert Find entity to FindRecord: missing required fields")
            return nil
        }

        self.id = id
        self.objectId = objectId
        self.foundBy = foundBy
        self.foundAt = foundAt
        self.needsSync = findEntity.needs_sync
        self.createdAt = findEntity.created_at
        self.lastSyncedAt = findEntity.last_synced_at
    }
}

// MARK: - Find Data Service
/// Service for managing find records in Core Data (SQLite) for offline storage
class FindDataService {
    static let shared = FindDataService()

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

    // MARK: - Convert FindRecord to Find Entity

    private func createFindEntity(from record: FindRecord, in context: NSManagedObjectContext) -> Find {
        let findEntity = Find(context: context)
        findEntity.id = record.id
        findEntity.object_id = record.objectId
        findEntity.found_by = record.foundBy
        findEntity.found_at = record.foundAt
        findEntity.needs_sync = record.needsSync
        findEntity.created_at = record.createdAt ?? Date()
        findEntity.last_synced_at = record.lastSyncedAt
        return findEntity
    }

    // MARK: - CRUD Operations

    /// Save a new find record
    func saveFindRecord(_ record: FindRecord) throws {
        let context = viewContext

        // Check if record already exists
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id)

        if let existingRecord = try? context.fetch(fetchRequest).first {
            // Update existing record
            existingRecord.object_id = record.objectId
            existingRecord.found_by = record.foundBy
            existingRecord.found_at = record.foundAt
            existingRecord.needs_sync = record.needsSync
            existingRecord.created_at = record.createdAt ?? Date()
            existingRecord.last_synced_at = record.lastSyncedAt
        } else {
            // Create new record
            let findEntity = createFindEntity(from: record, in: context)
            findEntity.created_at = Date()
        }

        try saveContext(context)
    }

    /// Save multiple find records (batch operation on background thread)
    func saveFindRecords(_ records: [FindRecord]) async throws {
        let context = newBackgroundContext()

        return try await context.perform {
            // Fetch all existing records to update
            let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
            let existingRecords = try context.fetch(fetchRequest)
            let existingRecordsDict = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.id ?? "", $0) })

            for record in records {
                if let existingEntity = existingRecordsDict[record.id] {
                    // Update existing
                    existingEntity.object_id = record.objectId
                    existingEntity.found_by = record.foundBy
                    existingEntity.found_at = record.foundAt
                    existingEntity.needs_sync = record.needsSync
                    existingEntity.created_at = record.createdAt ?? Date()
                    existingEntity.last_synced_at = record.lastSyncedAt
                } else {
                    // Create new
                    let findEntity = self.createFindEntity(from: record, in: context)
                    findEntity.created_at = Date()
                }
            }

            try self.saveContext(context)
        }
    }

    /// Load all find records
    func loadAllFindRecords() throws -> [FindRecord] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "found_at", ascending: false)]

        let findEntities = try context.fetch(fetchRequest)
        return findEntities.compactMap { FindRecord(from: $0) }
    }

    /// Load all find records (async, runs on background thread)
    func loadAllFindRecordsAsync() async throws -> [FindRecord] {
        let context = newBackgroundContext()

        return try await context.perform {
            let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "found_at", ascending: false)]

            let findEntities = try context.fetch(fetchRequest)
            return findEntities.compactMap { FindRecord(from: $0) }
        }
    }

    /// Get find records that need syncing to API
    func getFindRecordsNeedingSync() throws -> [FindRecord] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "needs_sync == YES")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "created_at", ascending: true)]

        let findEntities = try context.fetch(fetchRequest)
        return findEntities.compactMap { FindRecord(from: $0) }
    }

    /// Get find records for a specific object
    func getFindRecords(forObjectId objectId: String) throws -> [FindRecord] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "object_id == %@", objectId)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "found_at", ascending: true)]

        let findEntities = try context.fetch(fetchRequest)
        return findEntities.compactMap { FindRecord(from: $0) }
    }

    /// Get find records by a specific user
    func getFindRecords(byUser userId: String) throws -> [FindRecord] {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "found_by == %@", userId)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "found_at", ascending: false)]

        let findEntities = try context.fetch(fetchRequest)
        return findEntities.compactMap { FindRecord(from: $0) }
    }

    /// Mark find record as synced
    func markAsSynced(findId: String) throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", findId)

        if let findEntity = try context.fetch(fetchRequest).first {
            findEntity.needs_sync = false
            findEntity.last_synced_at = Date()
            try saveContext(context)
        }
    }

    /// Delete a find record
    func deleteFindRecord(byId id: String) throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id)

        if let findEntity = try context.fetch(fetchRequest).first {
            context.delete(findEntity)
            try saveContext(context)
        }
    }

    /// Delete all find records
    func deleteAllFindRecords() throws {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest as! NSFetchRequest<NSFetchRequestResult>)

        try context.execute(batchDeleteRequest)
        try saveContext(context)
    }

    /// Get count of all find records
    func getFindRecordCount() throws -> Int {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        return try context.count(for: fetchRequest)
    }

    /// Get count of find records needing sync
    func getPendingSyncCount() throws -> Int {
        let context = viewContext
        let fetchRequest: NSFetchRequest<Find> = Find.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "needs_sync == YES")
        return try context.count(for: fetchRequest)
    }
}

