import Foundation
import Network

/// Service for automatically discovering the CacheRaiders server on the local network
class ServerDiscoveryService {
    static let shared = ServerDiscoveryService()
    
    private let defaultPort = 5001
    private let healthCheckPath = "/health"
    private let discoveryTimeout: TimeInterval = 2.0
    
    private init() {}
    
    /// Discover the server by trying multiple IP addresses in the local network
    /// Returns the first working server URL found, or nil if none found
    func discoverServer(completion: @escaping (String?) -> Void) {
        Task {
            let serverURL = await discoverServerAsync()
            DispatchQueue.main.async {
                completion(serverURL)
            }
        }
    }
    
    /// Async version of server discovery
    func discoverServerAsync() async -> String? {
        // Get candidate IPs to try
        let candidateIPs = getCandidateIPs()
        
        print("🔍 [ServerDiscovery] Trying \(candidateIPs.count) candidate IPs: \(candidateIPs)")
        
        // Try each IP concurrently with timeout
        return await withTaskGroup(of: String?.self) { group in
            for ip in candidateIPs {
                group.addTask {
                    let url = "http://\(ip):\(self.defaultPort)"
                    if await self.testServer(url: url) {
                        print("✅ [ServerDiscovery] Found server at \(url)")
                        return url
                    }
                    return nil
                }
            }
            
            // Return the first successful result
            for await result in group {
                if let url = result {
                    // Cancel remaining tasks since we found a server
                    group.cancelAll()
                    return url
                }
            }
            return nil
        }
    }
    
    /// Test if a server URL is reachable
    private func testServer(url: String) async -> Bool {
        guard let testURL = URL(string: "\(url)\(healthCheckPath)") else {
            return false
        }
        
        var request = URLRequest(url: testURL)
        request.httpMethod = "GET"
        request.timeoutInterval = discoveryTimeout
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Silently fail - this is expected for most IPs
            return false
        }
        
        return false
    }
    
    /// Get candidate IP addresses to try
    private func getCandidateIPs() -> [String] {
        var candidates: [String] = []
        
        // 1. Try the last known working IP (from UserDefaults)
        if let lastKnownURL = UserDefaults.standard.string(forKey: "apiBaseURL"),
           let url = URL(string: lastKnownURL),
           let host = url.host,
           host != "localhost" {
            candidates.append(host)
        }
        
        // 2. Get device's local IP and try common server IPs in the same subnet
        if let deviceIP = getDeviceLocalIP() {
            let components = deviceIP.split(separator: ".")
            if components.count == 4 {
                let subnet = "\(components[0]).\(components[1]).\(components[2])"
                
                // Try common server IPs in order of likelihood
                let commonIPs = [
                    "1",      // Router/server
                    "50",     // Common server IP
                    "53",     // Another common server IP
                    "100",    // Common static IP
                    "101",    // Another common static IP
                    "2",      // Secondary router
                    "254"     // Gateway
                ]
                
                for suffix in commonIPs {
                    let candidate = "\(subnet).\(suffix)"
                    if candidate != deviceIP && !candidates.contains(candidate) {
                        candidates.append(candidate)
                    }
                }
            }
        }
        
        // 3. Try localhost as last resort
        if !candidates.contains("127.0.0.1") {
            candidates.append("127.0.0.1")
        }
        
        return candidates
    }
    
    /// Get the device's local network IP address
    private func getDeviceLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        defer { freeifaddrs(ifaddr) }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // Check for IPv4
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Prefer en0 (WiFi) or en1 (Ethernet)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    // If we found en0 (WiFi), use it; otherwise continue looking
                    if name == "en0" {
                        break
                    }
                }
            }
        }
        
        return address
    }
    
    /// Validate that a server URL is reachable
    func validateServer(url: String) async -> Bool {
        return await testServer(url: url)
    }
}

