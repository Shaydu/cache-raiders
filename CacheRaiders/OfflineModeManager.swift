import Foundation
import Combine
import CoreLocation

/// Offline Mode Manager - Manages offline mode state (user-controlled toggle)
class OfflineModeManager: ObservableObject {
    static let shared = OfflineModeManager()

    @Published var isOfflineMode: Bool = false {
        didSet {
            // Save to UserDefaults
            UserDefaults.standard.set(isOfflineMode, forKey: "offlineModeEnabled")

            // Handle mode change
            handleModeChange()
        }
    }

    @Published var pendingSyncCount: Int = 0

    private let offlineModeKey = "offlineModeEnabled"

    private weak var locationManager: LootBoxLocationManager?
    private var cancellables = Set<AnyCancellable>()

    // Services for sync operations
    private let findDataService = FindDataService.shared
    private let gameItemDataService = GameItemDataService.shared
    private let apiService = APIService.shared
    
    private init() {
        // Load saved offline mode preference (defaults to false/online)
        isOfflineMode = UserDefaults.standard.bool(forKey: offlineModeKey)
        
        // Setup observers for pending sync count
        setupObservers()
    }
    
    /// Set location manager reference (for sync count and sync operations)
    func setLocationManager(_ manager: LootBoxLocationManager) {
        self.locationManager = manager
    }
    
    // MARK: - Mode Change Handler
    
    /// Handle mode change between offline and online
    private func handleModeChange() {
        if isOfflineMode {
            // Going offline: disconnect WebSocket, use local Core Data
            print("📴 Offline mode enabled - using local SQLite database")
            WebSocketService.shared.disconnect()
            
            NotificationCenter.default.post(
                name: NSNotification.Name("OfflineModeEnabled"),
                object: nil,
                userInfo: ["message": "Using local database"]
            )
        } else {
            // Going online: connect WebSocket, sync with server, reload from API
            print("📡 Online mode enabled - connecting to server and WebSocket")

            // Connect WebSocket
            if let locationManager = locationManager, locationManager.useAPISync {
                WebSocketService.shared.connect()

                // Reload locations from API (replaces local Core Data with server data)
                Task {
                    // Load all locations from API (no user location filter needed)
                    await locationManager.loadLocationsFromAPI(userLocation: nil)

                    // Then sync any pending changes
                    await locationManager.syncPendingChangesToAPI()

                    // Also sync any pending finds
                    await syncPendingFinds()
                }
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("OfflineModeDisabled"),
                object: nil,
                userInfo: ["message": "Connected to server"]
            )
        }
    }
    
    // MARK: - Observers
    
    private func setupObservers() {
        // Update pending sync count periodically
        Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updatePendingSyncCount()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Helper Methods
    
    /// Sync pending finds to the server
    private func syncPendingFinds() async {
        do {
            let pendingFinds = try findDataService.getFindRecordsNeedingSync()
            print("🔄 Syncing \(pendingFinds.count) pending finds to server...")

            var syncedCount = 0
            var failedCount = 0

            for find in pendingFinds {
                do {
                    try await apiService.markFound(objectId: find.objectId)
                    try findDataService.markAsSynced(findId: find.id)
                    syncedCount += 1
                    print("✅ Synced find: \(find.id)")
                } catch {
                    failedCount += 1
                    print("❌ Failed to sync find \(find.id): \(error.localizedDescription)")
                }
            }

            print("🔄 Find sync complete: \(syncedCount) synced, \(failedCount) failed")

            // Update pending sync count after syncing
            await updatePendingSyncCountAsync()

        } catch {
            print("⚠️ Error syncing pending finds: \(error)")
        }
    }

    /// Update pending sync count from Core Data (includes both game items and finds)
    private func updatePendingSyncCountAsync() async {
        do {
            let gameItemsNeedingSync = try gameItemDataService.getItemsNeedingSync()
            let findsNeedingSync = try findDataService.getFindRecordsNeedingSync()
            let totalPending = gameItemsNeedingSync.count + findsNeedingSync.count

            await MainActor.run {
                self.pendingSyncCount = totalPending
            }
        } catch {
            print("⚠️ Error getting pending sync count: \(error)")
        }
    }

    /// Synchronous wrapper for updating pending sync count (for timer)
    private func updatePendingSyncCount() {
        Task {
            await updatePendingSyncCountAsync()
        }
    }
    
    /// Get status message for display
    var statusMessage: String {
        if isOfflineMode {
            return "Offline Mode - Using local database"
        } else {
            return "Online Mode - Connected to server"
        }
    }
}

