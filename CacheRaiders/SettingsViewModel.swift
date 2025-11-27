import Foundation
import Combine
import CoreLocation
import SystemConfiguration

// MARK: - Settings View Model
@MainActor
class SettingsViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var showAlert: Bool = false
    @Published var alertMessage: String = ""
    @Published var alertTitle: String = ""
    @Published var databaseObjects: [APIObject] = []
    @Published var isLoadingDatabase: Bool = false
    @Published var apiURL: String = ""
    @Published var selectedObjectId: String? = nil
    @Published var userName: String = ""
    @Published var leaderboard: [TopFinder] = []
    @Published var isLoadingLeaderboard: Bool = false
    @Published var playerNameCache: [String: String] = [:]
    
    private let locationManager: LootBoxLocationManager
    private let userLocationManager: UserLocationManager
    
    init(locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
    }
    
    // MARK: - API URL Management
    
    func loadAPIURL() {
        if let savedURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !savedURL.isEmpty {
            apiURL = savedURL
        } else {
            if let suggested = NetworkHelper.getSuggestedLocalIP() {
                let suggestedURL = "http://\(suggested):5001"
                apiURL = suggestedURL
                UserDefaults.standard.set(suggestedURL, forKey: "apiBaseURL")
                print("✅ Auto-configured API URL to: \(suggestedURL)")
            } else {
                let fallbackURL = "http://10.0.0.1:5001"
                apiURL = fallbackURL
                UserDefaults.standard.set(fallbackURL, forKey: "apiBaseURL")
                print("⚠️ Using fallback API URL: \(fallbackURL)")
            }
        }
    }
    
    func saveAPIURL() -> Bool {
        let trimmedURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedURL.isEmpty else {
            displayAlert(title: "No URL Entered", message: "Please enter a URL before saving (e.g., 192.168.1.100:5001 or http://192.168.1.100:5001)")
            return false
        }
        
        var urlString = trimmedURL
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "http://\(urlString)"
        }
        
        guard URL(string: urlString) != nil else {
            displayAlert(title: "Invalid URL", message: "Please enter a valid URL (e.g., 192.168.1.100:5001 or http://192.168.1.100:5001)")
            return false
        }
        
        UserDefaults.standard.set(urlString, forKey: "apiBaseURL")
        
        // Force APIService to reload the baseURL by accessing it
        let updatedURL = APIService.shared.baseURL
        print("✅ API URL saved: \(urlString), APIService now using: \(updatedURL)")
        
        // Always try to reconnect WebSocket if API sync is enabled
        if locationManager.useAPISync {
            // Disconnect immediately
            WebSocketService.shared.disconnect()

            // Reconnect after a short delay to ensure disconnect completes
            Task(priority: .userInitiated) { [weak self] in
                // Wait 500ms for disconnect to complete
                try? await Task.sleep(nanoseconds: 500_000_000)

                await MainActor.run {
                    let currentURL = APIService.shared.baseURL
                    print("🔌 Reconnecting WebSocket after URL update to: \(currentURL)")
                    WebSocketService.shared.connect()
                }

                // Load database objects after reconnecting (on main actor)
                await MainActor.run {
                    self?.loadDatabaseObjects()
                }
            }
            
            displayAlert(title: "URL Saved", message: "API URL updated to: \(urlString)\n\nReconnecting WebSocket to new server...")
        } else {
            // Even if API sync is not enabled, we should still try to connect
            // in case the user enables it later - but don't force it
            print("ℹ️ API sync not enabled, WebSocket will connect when API sync is enabled")
            displayAlert(title: "URL Saved", message: "API URL updated to: \(urlString)\n\nEnable 'API Sync' to connect to the server.")
        }

        return true
    }
    
    func resetAPIURL() {
        apiURL = ""
        UserDefaults.standard.removeObject(forKey: "apiBaseURL")
        displayAlert(title: "URL Reset", message: "Using default API URL: \(APIService.shared.baseURL)")

        if locationManager.useAPISync {
            // Disconnect immediately
            WebSocketService.shared.disconnect()

            // Reconnect on background thread with proper async/await
            Task(priority: .userInitiated) {
                // Wait 500ms for disconnect to complete
                try? await Task.sleep(nanoseconds: 500_000_000)

                await MainActor.run {
                    WebSocketService.shared.connect()
                }
            }
        }
    }
    
    func getSuggestedURLPlaceholder() -> String {
        let currentURL = APIService.shared.baseURL
        if !currentURL.contains("localhost") {
            return currentURL
        }
        if let suggested = NetworkHelper.getSuggestedLocalIP() {
            return "http://\(suggested):5001"
        }
        return "http://192.168.1.1:5001"
    }
    
    // MARK: - User Name Management
    
    func loadUserName() {
        userName = APIService.shared.currentUserName
        if userName == APIService.shared.currentUserID {
            userName = ""
        }
        
        if locationManager.useAPISync {
            Task {
                do {
                    if let serverName = try await APIService.shared.getPlayerNameFromServer() {
                        if !serverName.isEmpty {
                            userName = serverName
                            APIService.shared.setUserName(serverName)
                        }
                    }
                } catch {
                    print("⚠️ Failed to load player name from server: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func saveUserName() {
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        APIService.shared.setUserName(trimmedName)
        
        if trimmedName.isEmpty {
            displayAlert(title: "Name Saved", message: "Name cleared. Device ID will be used instead.")
        } else {
            displayAlert(title: "Name Saved", message: "Your name '\(trimmedName)' has been saved. It will appear on the leaderboard when you find objects.")
        }
    }
    
    // MARK: - Leaderboard Management
    
    func loadLeaderboard() {
        guard locationManager.useAPISync else { return }
        
        isLoadingLeaderboard = true
        Task {
            do {
                let stats = try await APIService.shared.getStats()
                leaderboard = stats.top_finders
                isLoadingLeaderboard = false
            } catch {
                leaderboard = []
                isLoadingLeaderboard = false
            }
        }
    }
    
    func refreshStats() {
        loadLeaderboard()
    }
    
    // MARK: - Database Objects Management
    
    func loadDatabaseObjects() {
        guard locationManager.useAPISync else { return }

        isLoadingDatabase = true

        // Run asynchronously; heavy work will hop off the main actor as needed
        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let isHealthy = try await APIService.shared.checkHealth()
                guard isHealthy else {
                    let currentURL = APIService.shared.baseURL
                    await MainActor.run {
                        self.databaseObjects = []
                        self.isLoadingDatabase = false
                        if currentURL.contains("localhost") {
                            self.displayAlert(title: "API Unavailable", message: "Cannot connect to \(currentURL).\n\nTo connect to your local network server:\n1. Find your computer's IP (ifconfig on Mac, ipconfig on Windows)\n2. Enter it in the 'API Server URL' field above (e.g., http://192.168.1.100:5001)\n3. Tap 'Save URL'\n4. Make sure your server is running and accessible on your network")
                        } else {
                            self.displayAlert(title: "API Unavailable", message: "Cannot connect to API server at \(currentURL).\n\nMake sure:\n• The server is running\n• The URL is correct\n• Your device is on the same network\n• Firewall allows connections on port 5001")
                        }
                    }
                    return
                }
                
                let apiObjects: [APIObject]
                if let userLocation = userLocationManager.currentLocation {
                    apiObjects = try await APIService.shared.getObjects(
                        latitude: userLocation.coordinate.latitude,
                        longitude: userLocation.coordinate.longitude,
                        radius: 10000.0,
                        includeFound: true
                    )
                } else {
                    apiObjects = try await APIService.shared.getObjects(includeFound: true)
                }
                
                let sortedObjects = apiObjects.sorted { obj1, obj2 in
                    if obj1.collected != obj2.collected {
                        return !obj1.collected
                    }
                    return obj1.name < obj2.name
                }

                await MainActor.run {
                    self.databaseObjects = sortedObjects
                    self.isLoadingDatabase = false
                }
            } catch {
                await MainActor.run {
                    self.databaseObjects = []
                    self.isLoadingDatabase = false
                    self.displayAlert(title: "Error", message: "Failed to load database objects: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func toggleCollectedStatus(for obj: APIObject) {
        guard let index = databaseObjects.firstIndex(where: { $0.id == obj.id }) else { return }
        
        if obj.collected {
            Task {
                do {
                    try await APIService.shared.unmarkFound(objectId: obj.id)
                    // Update the object's collected status directly
                    databaseObjects[index].collected = false
                    databaseObjects[index].found_by = nil
                    databaseObjects[index].found_at = nil
                    locationManager.unmarkCollected(obj.id)
                    loadDatabaseObjects()
                    refreshStats()
                } catch {
                    displayAlert(title: "Error", message: "Failed to unmark as collected: \(error.localizedDescription)")
                }
            }
        } else {
            Task {
                do {
                    try await APIService.shared.markFound(objectId: obj.id, foundBy: APIService.shared.currentUserID)
                    // Update the object's collected status directly
                    databaseObjects[index].collected = true
                    databaseObjects[index].found_by = APIService.shared.currentUserID
                    locationManager.markCollected(obj.id)
                    loadDatabaseObjects()
                    refreshStats()
                } catch {
                    displayAlert(title: "Error", message: "Failed to mark as collected: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func setSelectedObjectId(_ id: String?) {
        selectedObjectId = id
        locationManager.setSelectedDatabaseObjectId(id)
    }
    
    // MARK: - Helper Methods
    
    func displayAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
    
    func fetchPlayerNameIfNeeded(deviceUUID: String) {
        guard playerNameCache[deviceUUID] == nil else { return }
        
        Task {
            do {
                if let playerName = try await APIService.shared.getPlayerName(deviceUUID: deviceUUID) {
                    playerNameCache[deviceUUID] = playerName
                }
            } catch {
                print("⚠️ Failed to fetch player name for \(deviceUUID): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Network Helper
struct NetworkHelper {
    static func getSuggestedLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if name == "en0" {
                        break
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        
        if let deviceIP = address {
            let components = deviceIP.split(separator: ".")
            if components.count == 4 {
                return "\(components[0]).\(components[1]).\(components[2]).1"
            }
        }
        
        return nil
    }
}

