import Foundation
import Combine

/// Offline Mode Manager - Manages offline mode state and user notifications
class OfflineModeManager: ObservableObject {
    static let shared = OfflineModeManager()
    
    @Published var isOfflineMode: Bool = false
    @Published var offlineReason: OfflineReason = .unknown
    @Published var lastOfflineNotificationTime: Date?
    @Published var lastOnlineNotificationTime: Date?
    @Published var pendingSyncCount: Int = 0
    
    enum OfflineReason: String {
        case noNetwork = "No network connection"
        case apiUnreachable = "Server unreachable"
        case apiTimeout = "Server timeout"
        case apiError = "Server error"
        case unknown = "Unknown"
        
        var displayName: String {
            return self.rawValue
        }
    }
    
    private let networkMonitor = NetworkMonitorService.shared
    private weak var locationManager: LootBoxLocationManager?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupObservers()
        
        // Perform initial check
        Task {
            await checkOfflineStatus()
        }
    }
    
    /// Set location manager reference (for sync count and sync operations)
    func setLocationManager(_ manager: LootBoxLocationManager) {
        self.locationManager = manager
    }
    
    // MARK: - Observers
    
    private func setupObservers() {
        // Observe network monitor changes
        networkMonitor.$isNetworkAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkOfflineStatus()
                }
            }
            .store(in: &cancellables)
        
        networkMonitor.$isAPIReachable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkOfflineStatus()
                }
            }
            .store(in: &cancellables)
        
        // Observe API online/offline notifications
        NotificationCenter.default.publisher(for: NSNotification.Name("APIOffline"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkOfflineStatus()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSNotification.Name("APIOnline"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkOfflineStatus()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Offline Status Checking
    
    /// Check and update offline status
    @MainActor
    func checkOfflineStatus() async {
        let wasOffline = isOfflineMode
        let previousReason = offlineReason
        
        // Determine if we're offline and why
        if !networkMonitor.isNetworkAvailable {
            isOfflineMode = true
            offlineReason = .noNetwork
        } else if !networkMonitor.isAPIReachable {
            isOfflineMode = true
            
            // Determine specific reason
            if let error = networkMonitor.lastAPIError {
                if error.contains("timeout") || error.contains("timed out") {
                    offlineReason = .apiTimeout
                } else {
                    offlineReason = .apiError
                }
            } else {
                offlineReason = .apiUnreachable
            }
        } else {
            isOfflineMode = false
            offlineReason = .unknown
        }
        
        // Notify user if status changed
        if wasOffline != isOfflineMode {
            if isOfflineMode {
                await notifyWentOffline(reason: offlineReason)
            } else {
                await notifyWentOnline()
            }
        } else if isOfflineMode && previousReason != offlineReason {
            // Reason changed while still offline
            await notifyOfflineReasonChanged(to: offlineReason)
        }
        
        // Update pending sync count (if we have location manager access)
        updatePendingSyncCount()
    }
    
    // MARK: - User Notifications
    
    /// Notify user that we went offline
    @MainActor
    private func notifyWentOffline(reason: OfflineReason) async {
        let now = Date()
        
        // Throttle notifications - only show once per minute
        if let lastNotification = lastOfflineNotificationTime,
           now.timeIntervalSince(lastNotification) < 60 {
            return
        }
        
        lastOfflineNotificationTime = now
        
        let message = "Offline Mode: \(reason.displayName). Using cached data."
        print("📴 \(message)")
        
        // Post notification for UI to display
        NotificationCenter.default.post(
            name: NSNotification.Name("OfflineModeEnabled"),
            object: nil,
            userInfo: ["reason": reason.rawValue, "message": message]
        )
    }
    
    /// Notify user that we came back online
    @MainActor
    private func notifyWentOnline() async {
        let now = Date()
        
        // Throttle notifications - only show once per minute
        if let lastNotification = lastOnlineNotificationTime,
           now.timeIntervalSince(lastNotification) < 60 {
            return
        }
        
        lastOnlineNotificationTime = now
        
        let message = "Back online! Syncing with server..."
        print("📡 \(message)")
        
        // Post notification for UI to display
        NotificationCenter.default.post(
            name: NSNotification.Name("OfflineModeDisabled"),
            object: nil,
            userInfo: ["message": message]
        )
        
        // Trigger sync of pending changes
        locationManager?.syncPendingChangesToAPI()
    }
    
    /// Notify user that offline reason changed
    @MainActor
    private func notifyOfflineReasonChanged(to reason: OfflineReason) async {
        let message = "Connection issue: \(reason.displayName)"
        print("⚠️ \(message)")
        
        NotificationCenter.default.post(
            name: NSNotification.Name("OfflineReasonChanged"),
            object: nil,
            userInfo: ["reason": reason.rawValue, "message": message]
        )
    }
    
    // MARK: - Helper Methods
    
    /// Update pending sync count from Core Data
    private func updatePendingSyncCount() {
        // This will be called to update the count of items needing sync
        // We'll use a notification or delegate pattern to get this from LootBoxLocationManager
        Task.detached {
            do {
                let dataService = GameItemDataService.shared
                let itemsNeedingSync = try await dataService.getItemsNeedingSync()
                
                await MainActor.run {
                    self.pendingSyncCount = itemsNeedingSync.count
                }
            } catch {
                print("⚠️ Error getting pending sync count: \(error)")
            }
        }
    }
    
    /// Get status message for display
    var statusMessage: String {
        if isOfflineMode {
            return "Offline: \(offlineReason.displayName)"
        } else {
            return "Online"
        }
    }
}

