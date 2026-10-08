import Foundation
import CloudKit

/// Utility class for testing CloudKit functionality
class CloudKitTestUtility {

    private let container: CKContainer
    private let privateDatabase: CKDatabase

    init(containerIdentifier: String = "iCloud.com.shaydu.CacheRaiders") {
        self.container = CKContainer(identifier: containerIdentifier)
        self.privateDatabase = container.privateCloudDatabase
    }

    /// Test basic CloudKit connectivity
    func testCloudKitConnectivity() async -> Bool {
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                print("✅ CloudKit: iCloud account available")
                return true
            case .noAccount:
                print("❌ CloudKit: No iCloud account configured")
                return false
            case .restricted:
                print("❌ CloudKit: iCloud access restricted")
                return false
            case .couldNotDetermine:
                print("❌ CloudKit: Could not determine account status")
                return false
            @unknown default:
                print("❌ CloudKit: Unknown account status")
                return false
            }
        } catch {
            print("❌ CloudKit connectivity test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Test basic database operations
    func testDatabaseOperations() async -> Bool {
        do {
            // Create a test record
            let testRecord = CKRecord(recordType: "TestRecord")
            testRecord["testData"] = "Hello CloudKit!" as CKRecordValue
            testRecord["timestamp"] = Date() as CKRecordValue

            // Save the record
            let savedRecord = try await privateDatabase.save(testRecord)
            print("✅ CloudKit: Test record saved successfully")

            // Fetch the record back
            let fetchedRecord = try await privateDatabase.record(for: savedRecord.recordID)
            if let testData = fetchedRecord["testData"] as? String, testData == "Hello CloudKit!" {
                print("✅ CloudKit: Test record fetched successfully")

                // Delete the test record
                try await privateDatabase.deleteRecord(withID: savedRecord.recordID)
                print("✅ CloudKit: Test record deleted successfully")

                return true
            } else {
                print("❌ CloudKit: Test record data mismatch")
                return false
            }
        } catch {
            print("❌ CloudKit database test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Run comprehensive CloudKit tests
    func runAllTests() async -> Bool {
        print("🧪 Starting CloudKit comprehensive tests...")

        let connectivityOK = await testCloudKitConnectivity()
        if !connectivityOK {
            print("❌ CloudKit tests failed - no connectivity")
            return false
        }

        let databaseOK = await testDatabaseOperations()
        if !databaseOK {
            print("❌ CloudKit tests failed - database operations failed")
            return false
        }

        print("✅ All CloudKit tests passed!")
        return true
    }

    /// Get CloudKit diagnostic information
    func getDiagnostics() -> [String: Any] {
        return [
            "containerIdentifier": container.containerIdentifier ?? "unknown",
            "hasContainer": true,
            "privateDatabaseAvailable": true,
            "publicDatabaseAvailable": true
        ]
    }
}
