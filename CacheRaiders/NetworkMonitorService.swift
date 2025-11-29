import Foundation
import Network
import Combine

/// Network Monitor Service - Monitors network connectivity and API availability
class NetworkMonitorService: ObservableObject {
    static let shared = NetworkMonitorService()
    
    @Published var isNetworkAvailable: Bool = true
    @Published var isAPIReachable: Bool = false
    @Published var connectionType: ConnectionType = .unknown
    @Published var lastAPICheckTime: Date?
    @Published var lastAPIError: String?
    
    enum ConnectionType: String {
        case wifi = "Wi-Fi"
        case cellular = "Cellular"
        case ethernet = "Ethernet"
        case loopback = "Loopback"
        case other = "Other"
        case unavailable = "Unavailable"
        case unknown = "Unknown"
        
        var displayName: String {
            return self.rawValue
        }
    }
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var cancellables = Set<AnyCancellable>()
    
    // API health check properties
    private var apiHealthCheckTimer: Timer?
    private let apiHealthCheckInterval: TimeInterval = 30.0 // Check every 30 seconds
    private var isCheckingAPI: Bool = false
    
    private init() {
        startMonitoring()
        startAPIHealthChecks()
    }
    
    deinit {
        stopMonitoring()
        stopAPIHealthChecks()
    }
    
    // MARK: - Network Path Monitoring
    
    /// Start monitoring network connectivity
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                
                // Determine connection type
                if path.status == .satisfied {
                    if path.usesInterfaceType(.wifi) {
                        self.connectionType = .wifi
                    } else if path.usesInterfaceType(.cellular) {
                        self.connectionType = .cellular
                    } else if path.usesInterfaceType(.wiredEthernet) {
                        self.connectionType = .ethernet
                    } else if path.usesInterfaceType(.loopback) {
                        self.connectionType = .loopback
                    } else {
                        self.connectionType = .other
                    }
                } else {
                    self.connectionType = .unavailable
                    // If network becomes unavailable, API is also unreachable
                    self.isAPIReachable = false
                }
                
                // Notify if network status changed
                if wasAvailable != self.isNetworkAvailable {
                    print("🌐 Network status changed: \(self.isNetworkAvailable ? "Available" : "Unavailable") (\(self.connectionType.displayName))")
                    
                    // If network came back, check API immediately
                    if self.isNetworkAvailable {
                        Task {
                            await self.checkAPIHealth()
                        }
                    }
                }
            }
        }
        
        monitor.start(queue: queue)
        print("✅ Started network monitoring")
    }
    
    /// Stop monitoring network connectivity
    private func stopMonitoring() {
        monitor.cancel()
        print("⏹️ Stopped network monitoring")
    }
    
    // MARK: - API Health Checks
    
    /// Start periodic API health checks
    private func startAPIHealthChecks() {
        stopAPIHealthChecks() // Stop any existing timer
        
        // Perform initial check
        Task {
            await checkAPIHealth()
        }
        
        // Schedule periodic checks
        apiHealthCheckTimer = Timer.scheduledTimer(withTimeInterval: apiHealthCheckInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.checkAPIHealth()
            }
        }
        
        if let timer = apiHealthCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        print("✅ Started API health checks (every \(Int(apiHealthCheckInterval))s)")
    }
    
    /// Stop API health checks
    private func stopAPIHealthChecks() {
        apiHealthCheckTimer?.invalidate()
        apiHealthCheckTimer = nil
    }
    
    /// Check if API endpoint is reachable
    @MainActor
    func checkAPIHealth() async {
        // Don't check if already checking or if network is unavailable
        guard !isCheckingAPI else {
            return
        }
        
        guard isNetworkAvailable else {
            isAPIReachable = false
            lastAPIError = "Network unavailable"
            print("⚠️ Skipping API health check - network unavailable")
            return
        }
        
        isCheckingAPI = true
        defer {
            isCheckingAPI = false
        }
        
        do {
            let wasReachable = isAPIReachable
            let startTime = Date()
            
            // Use APIService's health check
            let isHealthy = try await APIService.shared.checkHealth()
            
            DispatchQueue.main.async {
                self.lastAPICheckTime = Date()
                self.isAPIReachable = isHealthy
                
                if !isHealthy {
                    self.lastAPIError = "Server health check failed"
                } else {
                    self.lastAPIError = nil
                }
                
                let latency = Date().timeIntervalSince(startTime) * 1000
                
                // Notify if API reachability changed
                if wasReachable != isHealthy {
                    if isHealthy {
                        print("✅ API is now reachable (latency: \(String(format: "%.0f", latency))ms)")
                        NotificationCenter.default.post(
                            name: NSNotification.Name("APIOnline"),
                            object: nil
                        )
                    } else {
                        print("⚠️ API is now unreachable")
                        NotificationCenter.default.post(
                            name: NSNotification.Name("APIOffline"),
                            object: nil
                        )
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.lastAPICheckTime = Date()
                let wasReachable = self.isAPIReachable
                self.isAPIReachable = false
                
                let errorMessage = error.localizedDescription
                self.lastAPIError = errorMessage
                
                // Only notify if status changed to avoid spam
                if wasReachable {
                    print("⚠️ API became unreachable: \(errorMessage)")
                    NotificationCenter.default.post(
                        name: NSNotification.Name("APIOffline"),
                        object: nil
                    )
                }
            }
        }
    }
    
    /// Manually trigger an API health check
    func testAPIConnection() async {
        await checkAPIHealth()
    }
    
    /// Check if we're in offline mode (network available but API unreachable, or network unavailable)
    var isOfflineMode: Bool {
        return !isAPIReachable || !isNetworkAvailable
    }
    
    /// Get a human-readable status message
    var statusMessage: String {
        if !isNetworkAvailable {
            return "No network connection"
        } else if !isAPIReachable {
            return "Server unreachable"
        } else {
            return "Connected"
        }
    }
}

