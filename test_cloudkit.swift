#!/usr/bin/env swift

import Foundation
import CloudKit

// Simple CloudKit connectivity test
let container = CKContainer(identifier: "iCloud.com.shaydu.CacheRaiders")
let database = container.privateCloudDatabase

print("🧪 Testing CloudKit connectivity...")

// Test account status
container.accountStatus { status, error in
    DispatchQueue.main.async {
        switch status {
        case .available:
            print("✅ iCloud account available")

            // Test basic database operation
            let testRecord = CKRecord(recordType: "TestRecord")
            testRecord["message"] = "Hello from CacheRaiders CloudKit test!" as CKRecordValue
            testRecord["timestamp"] = Date() as CKRecordValue

            database.save(testRecord) { savedRecord, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("❌ Failed to save test record: \(error.localizedDescription)")
                    } else {
                        print("✅ Successfully saved test record to CloudKit")

                        // Clean up the test record
                        if let recordID = savedRecord?.recordID {
                            database.deleteRecord(withID: recordID) { deletedRecordID, error in
                                DispatchQueue.main.async {
                                    if let error = error {
                                        print("⚠️ Failed to clean up test record: \(error.localizedDescription)")
                                    } else {
                                        print("✅ Test record cleaned up")
                                    }
                                    exit(0)
                                }
                            }
                        } else {
                            exit(0)
                        }
                    }
                }
            }

        case .noAccount:
            print("❌ No iCloud account configured")
            exit(1)
        case .restricted:
            print("❌ iCloud access restricted")
            exit(1)
        case .couldNotDetermine:
            print("❌ Could not determine iCloud status")
            exit(1)
        @unknown default:
            print("❌ Unknown iCloud status")
            exit(1)
        }
    }
}

// Keep the script running until async operations complete
RunLoop.main.run()
