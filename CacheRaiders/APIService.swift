import Foundation
import CoreLocation
import UIKit
import SystemConfiguration

// MARK: - API Response Models
struct APIObject: Codable {
    let id: String
    let name: String
    let type: String
    let latitude: Double
    let longitude: Double
    let radius: Double
    let created_at: String?
    let created_by: String?
    let grounding_height: Double?
    let ar_origin_latitude: Double?
    let ar_origin_longitude: Double?
    let ar_offset_x: Double?
    let ar_offset_y: Double?
    let ar_offset_z: Double?
    let ar_placement_timestamp: String?
    var collected: Bool  // Mutable: state that changes when objects are found/unfound
    var found_by: String?  // Mutable: state that changes when objects are found/unfound
    var found_at: String?  // Mutable: state that changes when objects are found/unfound
}

struct CreateObjectRequest: Codable {
    let id: String
    let name: String
    let type: String
    let latitude: Double
    let longitude: Double
    let radius: Double
    let created_by: String?
}

struct MarkFoundRequest: Codable {
    let found_by: String
}

struct APIStats: Codable {
    let total_objects: Int
    let found_objects: Int
    let unfound_objects: Int
    let total_finds: Int
    let top_finders: [TopFinder]
}

struct TopFinder: Codable {
    let user: String
    let count: Int
}

struct ResetFindsResponse: Codable {
    let message: String
    let finds_removed: Int
}

struct HealthResponse: Codable {
    let status: String
    let timestamp: String
    let server_ip: String
}

// MARK: - Network Request Queue
/// Limits concurrent network requests to prevent freezes from too many simultaneous requests
actor NetworkRequestQueue {
    private var activeCount = 0
    private let maxConcurrent = 3 // Max 3 concurrent requests
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    func waitForSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func releaseSlot() {
        activeCount -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            activeCount += 1
            next.resume()
        }
    }
}

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // Network request queue to limit concurrent requests and prevent freezes
    private static let requestQueue = NetworkRequestQueue()
    
    // Track last error message to suppress repeated identical errors
    private var lastErrorLogTime: Date?
    private var lastErrorMessage: String = ""
    private let errorLogThrottleInterval: TimeInterval = 30.0 // Only log same error every 30 seconds
    
    // Configure your API base URL here
    // For local development: "http://localhost:5001"
    // For production: "https://your-api-domain.com"
    var baseURL: String {
        // Check UserDefaults for custom URL, otherwise use default
        if let customURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !customURL.isEmpty {
            // Validate the stored URL - ensure it's properly formatted
            var validatedURL = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // If it doesn't start with http:// or https://, add http://
            if !validatedURL.hasPrefix("http://") && !validatedURL.hasPrefix("https://") {
                validatedURL = "http://\(validatedURL)"
            }
            
            // Validate it's a proper URL
            if URL(string: validatedURL) != nil {
                // CRITICAL: Check if IP ends in .1 (router IP) and warn user
                if validatedURL.contains(".1:") || validatedURL.contains(".1/") {
                    print("⚠️ WARNING: IP ends in .1 - this is usually the ROUTER, not your computer!")
                    if let deviceIP = ServerDiscoveryService.shared.getDeviceLocalIP() {
                        // Extract the IP part and replace .1 with the device's last octet
                        let deviceIPParts = deviceIP.split(separator: ".")
                        if deviceIPParts.count == 4, let lastOctet = deviceIPParts.last {
                            // Replace .1:port with .{lastOctet}:port
                            let suggestedURL = validatedURL.replacingOccurrences(of: ".1:", with: ".\(lastOctet):")
                                .replacingOccurrences(of: ".1/", with: ".\(lastOctet)/")
                            print("   💡 Your computer's IP appears to be: \(deviceIP)")
                            print("   💡 Try updating Settings → API Server URL to: \(suggestedURL)")
                        } else {
                            print("   💡 Your computer's IP appears to be: \(deviceIP)")
                            print("   💡 Update Settings → API Server URL to use: http://\(deviceIP):5001")
                        }
                    } else {
                        print("   💡 Your computer's IP is likely 192.168.68.53 (not .1)")
                        print("   💡 Update Settings → API Server URL to use your computer's IP")
                    }
                }
                
                // If validation passed and URL changed, save the corrected version
                if validatedURL != customURL {
                    UserDefaults.standard.set(validatedURL, forKey: "apiBaseURL")
                }
                return validatedURL
            } else {
                // Invalid URL stored - remove it and fall back to default
                print("⚠️ Invalid API URL stored in UserDefaults: '\(customURL)', falling back to default")
                UserDefaults.standard.removeObject(forKey: "apiBaseURL")
            }
        }
        // No QR code URL set - user needs to scan QR code or enter URL manually
        // Don't guess IPs - only use what's explicitly set
        print("⚠️ No API URL configured. Please:")
        print("   1. Open Settings (gear icon in top right)")
        print("   2. Go to 'API Server URL' section")
        print("   3. Scan QR code from server admin panel OR")
        print("   4. Manually enter server IP (e.g., 192.168.68.53:5001)")
        print("   💡 Find your server IP: Mac: 'ifconfig | grep inet', Windows: 'ipconfig'")
        
        // Try to get device IP as a suggestion (but don't auto-use it)
        if let deviceIP = ServerDiscoveryService.shared.getDeviceLocalIP() {
            let suggestedURL = "http://\(deviceIP):5001"
            print("   💡 Suggested IP based on your network: \(suggestedURL)")
        }
        
        return "http://localhost:5001" // Fallback, but won't work on physical device - user must configure URL
    }
    
    /// Get a suggested local network IP address based on the device's network
    /// Returns nil to force server discovery instead of guessing (which often picks the router IP)
    private func getSuggestedLocalIP() -> String? {
        // Don't suggest an IP - let server discovery handle it
        // The old logic always suggested .1 (router IP) which is usually wrong
        // Server discovery will try multiple IPs and find the correct server
        return nil
    }
    
    // User identifier - device UUID for tracking
    var currentUserID: String {
        // Use device identifier or user account ID
        if let userID = UserDefaults.standard.string(forKey: "userID"), !userID.isEmpty {
            return userID
        }
        // Generate and store a unique user ID
        let userID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(userID, forKey: "userID")
        return userID
    }
    
    // User display name - for leaderboard and display purposes
    var currentUserName: String {
        if let userName = UserDefaults.standard.string(forKey: "userName"), !userName.isEmpty {
            return userName
        }
        // Default to UUID if no name is set
        return currentUserID
    }
    
    // Set user name (maps to UUID in database)
    func setUserName(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "userName")
        } else {
            UserDefaults.standard.removeObject(forKey: "userName")
        }
        
        // Sync to server if API is available
        // Note: Server requires non-empty player_name, so only sync if name is not empty
        if !trimmedName.isEmpty {
            Task {
                do {
                    try await updatePlayerNameOnServer(trimmedName)
                    print("✅ Player name synced to server: \(trimmedName)")
                } catch {
                    // Log error but don't fail - local storage is primary, server is secondary
                    print("⚠️ Failed to sync player name to server: \(error.localizedDescription)")
                }
            }
        } else {
            print("ℹ️ Player name is empty - not syncing to server (server requires non-empty name)")
        }
    }
    
    /// Sync saved user name to server on app startup
    /// This ensures the name persists between sessions and is synced to the server
    func syncSavedUserNameToServer() {
        // Get saved name from UserDefaults
        if let savedName = UserDefaults.standard.string(forKey: "userName"), !savedName.isEmpty {
            // Sync to server in background (don't block app startup)
            Task {
                do {
                    try await updatePlayerNameOnServer(savedName)
                    print("✅ Synced saved player name to server on startup: \(savedName)")
                } catch {
                    // Log error but don't fail - this is a background sync
                    print("⚠️ Failed to sync saved player name to server on startup: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private init() {}
    
    // MARK: - Error Logging Helpers
    
    /// Determine if an error should be logged (throttles repeated identical errors)
    private func shouldLogError(message: String, isLocalhostError: Bool) -> Bool {
        let now = Date()
        
        // Always log if it's a different error
        if message != lastErrorMessage {
            return true
        }
        
        // For localhost errors, only log once per throttle interval
        if isLocalhostError {
            if let lastTime = lastErrorLogTime {
                return now.timeIntervalSince(lastTime) >= errorLogThrottleInterval
            }
            return true
        }
        
        // For other errors, log if enough time has passed
        if let lastTime = lastErrorLogTime {
            return now.timeIntervalSince(lastTime) >= errorLogThrottleInterval
        }
        
        return true
    }
    
    // MARK: - Helper Methods
    
    private func makeRequest<T: Decodable>(
        url: URL,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        print("🔍 [API Request] \(method) \(url.absoluteString)")
        
        // PERFORMANCE: Wait for available slot in request queue to prevent too many concurrent requests
        await Self.requestQueue.waitForSlot()
        defer { 
            Task {
                await Self.requestQueue.releaseSlot()
            }
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // PERFORMANCE: Add timeout to prevent hanging requests
        request.timeoutInterval = 10.0 // 10 second timeout
        
        if let body = body {
            request.httpBody = body
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ [API Request] Invalid response type: \(type(of: response))")
                throw APIError.invalidResponse
            }
            
            print("📡 [API Request] Response status: \(httpResponse.statusCode)")
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unable to decode error body"
                print("❌ [API Request] HTTP error \(httpResponse.statusCode)")
                print("   Response body: \(errorBody)")
                
                if let errorData = try? JSONDecoder().decode([String: String].self, from: data),
                   let errorMessage = errorData["error"] {
                    throw APIError.serverError(errorMessage)
                }
                throw APIError.httpError(httpResponse.statusCode)
            }
            
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            // Check if this is a localhost connection error on a physical device
            let isLocalhostError = url.host == "localhost" || url.host == "127.0.0.1"
            let isConnectionError = (error as? URLError)?.code == .cannotConnectToHost || 
                                   (error as? URLError)?.code == .timedOut
            
            // Create error message
            let errorMessage = error.localizedDescription
            let shouldLog = shouldLogError(message: errorMessage, isLocalhostError: isLocalhostError && isConnectionError)
            
            if shouldLog {
                if isLocalhostError && isConnectionError {
                    // Special handling for localhost connection errors
                    print("❌ [API Request] Cannot connect to localhost:5001")
                    print("   💡 This won't work on a physical device!")
                    print("   📱 To fix: Open Settings → API Server URL")
                    print("   📱 Enter your computer's IP (e.g., 192.168.1.100:5001)")
                    print("   📱 Or scan the QR code from the server admin page")
                    print("   💻 Find your IP: Mac: 'ifconfig | grep inet', Windows: 'ipconfig'")
                } else {
                    // Enhanced error logging for other errors
                    print("❌ [API Request] Request failed: \(errorMessage)")
                    print("   Error type: \(type(of: error))")
                    print("   URL: \(url.absoluteString)")
                    print("   Method: \(method)")
                    
                    if let urlError = error as? URLError {
                        print("   URLError code: \(urlError.code.rawValue) (\(urlError.code))")
                        print("   Failed URL: \(urlError.failureURLString ?? "unknown")")
                        let nsError = error as NSError
                        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                            print("   Underlying error: \(underlyingError)")
                        }
                    } else if let nsError = error as NSError? {
                        print("   NSError domain: \(nsError.domain)")
                        print("   NSError code: \(nsError.code)")
                        print("   User info: \(nsError.userInfo)")
                    }
                }
                
                // Update last error tracking
                lastErrorLogTime = Date()
                lastErrorMessage = errorMessage
            }
            
            throw error
        }
    }
    
    // MARK: - API Methods
    
    /// Check if API is available using the configured URL (from QR code or manual entry)
    func checkHealth() async throws -> Bool {
        return try await checkHealthWithDiscovery()
    }
    
    /// Check health - only uses the URL set via QR code or manual entry, no automatic discovery
    private func checkHealthWithDiscovery(attemptDiscovery: Bool = false) async throws -> Bool {
        let healthURL = "\(baseURL)/health"
        print("🔍 [API Health Check] Attempting to connect to: \(healthURL)")
        
        guard let url = URL(string: healthURL) else {
            print("❌ [API Health Check] Invalid URL: \(healthURL)")
            print("   Base URL: \(baseURL)")
            
            // Try discovery if URL is invalid
            if attemptDiscovery {
                return try await discoverAndConnect()
            }
            throw APIError.invalidURL
        }
        
        do {
            // Use proper HealthResponse struct for better type safety
            let healthResponse: HealthResponse = try await makeRequest(url: url)
            print("✅ [API Health Check] Successfully connected to \(healthURL)")
            print("   Server status: \(healthResponse.status)")
            print("   Server IP: \(healthResponse.server_ip)")
            
            // Save the working URL
            UserDefaults.standard.set(baseURL, forKey: "apiBaseURL")
            return healthResponse.status.lowercased() == "healthy"
        } catch {
            // Enhanced error logging for root cause analysis
            print("❌ [API Health Check] Failed to connect to \(healthURL)")
            print("   Error: \(error.localizedDescription)")
            print("   Error type: \(type(of: error))")
            
            if let apiError = error as? APIError {
                print("   API Error: \(apiError)")
            } else if let urlError = error as? URLError {
                print("   URLError code: \(urlError.code.rawValue) (\(urlError.code))")
                print("   Failed URL: \(urlError.failureURLString ?? "unknown")")
                
                // Provide specific guidance based on error code
                switch urlError.code {
                case .cannotConnectToHost:
                    print("   → Cannot connect to host - check:")
                    print("      • Server is running")
                    print("      • IP address is correct: \(baseURL)")
                    
                    // Check if IP looks like router (ends in .1)
                    if baseURL.contains(".1:") || baseURL.contains(".1/") {
                        print("      ⚠️ CRITICAL: IP ends in .1 - this is the ROUTER, not your computer!")
                        print("      → Your computer IP is likely 192.168.68.53 (not .1)")
                        print("      → Update Settings → API Server URL to: http://192.168.68.53:5001")
                    }
                    
                    print("      • Device and server are on same network")
                    print("      • Firewall allows connections")
                case .timedOut:
                    print("   → Connection timed out - server may be slow or unreachable")
                case .networkConnectionLost:
                    print("   → Network connection lost - check Wi-Fi")
                case .notConnectedToInternet:
                    print("   → No internet connection")
                default:
                    break
                }
                
                let nsError = error as NSError
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                    print("   Underlying error: \(underlyingError)")
                }
            } else if let decodingError = error as? DecodingError {
                print("   Decoding Error: \(decodingError)")
                // If decoding fails, the server responded but with wrong format
                // This might still indicate the server is reachable
                print("   → Server responded but with unexpected format")
                print("   → This might indicate server version mismatch")
            } else if let nsError = error as NSError? {
                print("   NSError domain: \(nsError.domain)")
                print("   NSError code: \(nsError.code)")
                print("   User info: \(nsError.userInfo)")
            }
            
            print("   Base URL: \(baseURL)")
            print("   Full health URL: \(healthURL)")
            
            // Don't try automatic discovery - only use the URL set via QR code or manual entry
            // If connection fails, user should scan QR code again or check the server URL in Settings
            print("💡 [API Health Check] Connection failed. Please:")
            print("   • Scan the QR code from the server admin panel")
            print("   • Or manually enter the server URL in Settings")
            print("   • Make sure the server is running and accessible")
            
            // Return false instead of throwing to allow graceful fallback
            return false
        }
    }
    
    /// Discover server automatically and update baseURL
    private func discoverAndConnect() async throws -> Bool {
        print("🔍 [Server Discovery] Starting automatic server discovery...")
        
        if let discoveredURL = await ServerDiscoveryService.shared.discoverServerAsync() {
            print("✅ [Server Discovery] Found server at: \(discoveredURL)")
            
            // Update the stored URL
            UserDefaults.standard.set(discoveredURL, forKey: "apiBaseURL")
            
            // Force refresh by synchronizing
            UserDefaults.standard.synchronize()
            
            // Try health check with discovered URL
            let healthURL = "\(discoveredURL)/health"
            guard let url = URL(string: healthURL) else {
                print("❌ [Server Discovery] Invalid discovered URL: \(discoveredURL)")
                throw APIError.invalidURL
            }
            
            do {
                let healthResponse: HealthResponse = try await makeRequest(url: url)
                print("✅ [Server Discovery] Successfully connected to discovered server")
                print("   Server status: \(healthResponse.status)")
                print("   Server IP: \(healthResponse.server_ip)")
                return healthResponse.status.lowercased() == "healthy"
            } catch {
                print("❌ [Server Discovery] Failed to connect to discovered server: \(error.localizedDescription)")
                throw error
            }
        } else {
            print("❌ [Server Discovery] Could not find server on local network")
            print("   → Make sure the server is running")
            print("   → Check that device and server are on the same network")
            print("   → Try manually setting the server URL in Settings")
            throw APIError.serverUnreachable
        }
    }
    
    /// Get all objects, optionally filtered by location
    func getObjects(
        latitude: Double? = nil,
        longitude: Double? = nil,
        radius: Double = 10000.0,
        includeFound: Bool = false
    ) async throws -> [APIObject] {
        var components = URLComponents(string: "\(baseURL)/api/objects")
        var queryItems: [URLQueryItem] = []
        
        if let lat = latitude {
            queryItems.append(URLQueryItem(name: "latitude", value: String(lat)))
        }
        if let lon = longitude {
            queryItems.append(URLQueryItem(name: "longitude", value: String(lon)))
        }
        queryItems.append(URLQueryItem(name: "radius", value: String(radius)))
        queryItems.append(URLQueryItem(name: "include_found", value: includeFound ? "true" : "false"))
        
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw APIError.invalidURL
        }
        
        return try await makeRequest(url: url)
    }
    
    /// Get a specific object by ID
    func getObject(id: String) async throws -> APIObject {
        guard let url = URL(string: "\(baseURL)/api/objects/\(id)") else {
            throw APIError.invalidURL
        }
        
        return try await makeRequest(url: url)
    }
    
    /// Create a new object
    func createObject(_ location: LootBoxLocation) async throws -> APIObject {
        guard let url = URL(string: "\(baseURL)/api/objects") else {
            throw APIError.invalidURL
        }
        
        let request = CreateObjectRequest(
            id: location.id,
            name: location.name,
            type: location.type.rawValue,
            latitude: location.latitude,
            longitude: location.longitude,
            radius: location.radius,
            created_by: currentUserID
        )
        
        let encoder = JSONEncoder()
        let body = try encoder.encode(request)
        
        return try await makeRequest(url: url, method: "POST", body: body)
    }
    
    /// Mark an object as found
    func markFound(objectId: String, foundBy: String? = nil) async throws {
        guard let url = URL(string: "\(baseURL)/api/objects/\(objectId)/found") else {
            throw APIError.invalidURL
        }
        
        // Always use device UUID as the unique identifier for finds
        // The server will look up the player name from the players table for display
        let foundByUUID = foundBy ?? currentUserID
        let request = MarkFoundRequest(found_by: foundByUUID)
        let encoder = JSONEncoder()
        let body = try encoder.encode(request)
        
        let _: [String: String] = try await makeRequest(url: url, method: "POST", body: body)
    }
    
    /// Unmark an object as found (for testing)
    func unmarkFound(objectId: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/objects/\(objectId)/found") else {
            throw APIError.invalidURL
        }
        
        let _: [String: String] = try await makeRequest(url: url, method: "DELETE")
    }
    
    /// Get all objects found by a specific user
    func getUserFinds(userId: String? = nil) async throws -> [APIObject] {
        let userId = userId ?? currentUserID
        guard let url = URL(string: "\(baseURL)/api/users/\(userId)/finds") else {
            throw APIError.invalidURL
        }
        
        return try await makeRequest(url: url)
    }
    
    /// Get statistics
    func getStats() async throws -> APIStats {
        guard let url = URL(string: "\(baseURL)/api/stats") else {
            throw APIError.invalidURL
        }
        
        return try await makeRequest(url: url)
    }
    
    /// Reset all finds (make all objects unfound)
    func resetAllFinds() async throws -> ResetFindsResponse {
        guard let url = URL(string: "\(baseURL)/api/finds/reset") else {
            throw APIError.invalidURL
        }
        
        return try await makeRequest(url: url, method: "POST")
    }
    
    /// Get player name from server
    func getPlayerNameFromServer() async throws -> String? {
        guard let url = URL(string: "\(baseURL)/api/players/\(currentUserID)") else {
            throw APIError.invalidURL
        }
        
        do {
            let response: [String: String] = try await makeRequest(url: url)
            return response["player_name"]
        } catch {
            // If player doesn't exist on server, return nil
            if case APIError.httpError(let code) = error, code == 404 {
                return nil
            }
            throw error
        }
    }
    
    /// Get player name by device UUID
    func getPlayerName(deviceUUID: String) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/api/players/\(deviceUUID)") else {
            throw APIError.invalidURL
        }
        
        do {
            let response: [String: String] = try await makeRequest(url: url)
            return response["player_name"]
        } catch {
            // If player doesn't exist on server, return nil
            if case APIError.httpError(let code) = error, code == 404 {
                return nil
            }
            throw error
        }
    }
    
    /// Update player name on server
    func updatePlayerNameOnServer(_ name: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/players/\(currentUserID)") else {
            throw APIError.invalidURL
        }
        
        let body = ["player_name": name]
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)
        
        let _: [String: String] = try await makeRequest(url: url, method: "POST", body: bodyData)
    }
    
    /// Update grounding height for an object
    func updateGroundingHeight(objectId: String, height: Double) async throws {
        guard let url = URL(string: "\(baseURL)/api/objects/\(objectId)/grounding") else {
            throw APIError.invalidURL
        }
        
        struct GroundingUpdate: Codable {
            let grounding_height: Double
        }

        struct GroundingResponse: Codable {
            let success: Bool?
        }

        let body = GroundingUpdate(grounding_height: height)
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)

        // Response not needed for this operation - just ignore the result
        let _: GroundingResponse = try await makeRequest(url: url, method: "PUT", body: bodyData)
    }
    
    /// Update object location (latitude/longitude)
    func updateObjectLocation(objectId: String, latitude: Double, longitude: Double) async throws {
        guard let url = URL(string: "\(baseURL)/api/objects/\(objectId)") else {
            throw APIError.invalidURL
        }

        struct LocationUpdate: Codable {
            let latitude: Double
            let longitude: Double
        }

        struct UpdateResponse: Codable {
            let success: Bool?
        }

        let body = LocationUpdate(latitude: latitude, longitude: longitude)
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)

        let _: UpdateResponse = try await makeRequest(url: url, method: "PUT", body: bodyData)
    }

    /// Update AR coordinates for mm-precision positioning (alias for updateAROffset)
    func updateARCoordinates(
        objectId: String,
        arOriginLatitude: Double,
        arOriginLongitude: Double,
        arOffsetX: Double,
        arOffsetY: Double,
        arOffsetZ: Double
    ) async throws {
        try await updateAROffset(
            objectId: objectId,
            arOriginLatitude: arOriginLatitude,
            arOriginLongitude: arOriginLongitude,
            offsetX: arOffsetX,
            offsetY: arOffsetY,
            offsetZ: arOffsetZ
        )
    }
    
    /// Update user's current location (for web map display)
    /// Get the location update interval from the server
    func getLocationUpdateInterval() async throws -> Double {
        guard let url = URL(string: "\(baseURL)/api/settings/location-update-interval") else {
            throw APIError.invalidURL
        }
        
        struct IntervalResponse: Codable {
            let interval_ms: Int
            let interval_seconds: Double
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.serverUnreachable
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(httpResponse.statusCode)
        }
        
        let intervalResponse = try JSONDecoder().decode(IntervalResponse.self, from: data)
        return intervalResponse.interval_seconds
    }
    
    func updateUserLocation(latitude: Double, longitude: Double, accuracy: Double? = nil, heading: Double? = nil, arOffsetX: Double? = nil, arOffsetY: Double? = nil, arOffsetZ: Double? = nil) async throws {
        guard let url = URL(string: "\(baseURL)/api/users/\(currentUserID)/location") else {
            throw APIError.invalidURL
        }
        
        struct LocationUpdate: Codable {
            let latitude: Double
            let longitude: Double
            let accuracy: Double?
            let heading: Double?
            let ar_offset_x: Double?
            let ar_offset_y: Double?
            let ar_offset_z: Double?
        }
        
        struct UpdateResponse: Codable {
            let message: String?
        }
        
        let body = LocationUpdate(
            latitude: latitude,
            longitude: longitude,
            accuracy: accuracy,
            heading: heading,
            ar_offset_x: arOffsetX,
            ar_offset_y: arOffsetY,
            ar_offset_z: arOffsetZ
        )
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)
        
        // Fire and forget - don't wait for response
        let _: UpdateResponse = try await makeRequest(url: url, method: "POST", body: bodyData)
    }
    
    /// Update AR offset positioning data for centimeter-level accuracy
    func updateAROffset(
        objectId: String,
        arOriginLatitude: Double,
        arOriginLongitude: Double,
        offsetX: Double,
        offsetY: Double,
        offsetZ: Double
    ) async throws {
        guard let url = URL(string: "\(baseURL)/api/objects/\(objectId)/ar-offset") else {
            throw APIError.invalidURL
        }

        struct AROffsetUpdate: Codable {
            let ar_origin_latitude: Double
            let ar_origin_longitude: Double
            let ar_offset_x: Double
            let ar_offset_y: Double
            let ar_offset_z: Double
            let ar_placement_timestamp: String
        }

        struct UpdateResponse: Codable {
            let success: Bool?
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let body = AROffsetUpdate(
            ar_origin_latitude: arOriginLatitude,
            ar_origin_longitude: arOriginLongitude,
            ar_offset_x: offsetX,
            ar_offset_y: offsetY,
            ar_offset_z: offsetZ,
            ar_placement_timestamp: timestamp
        )
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)

        let _: UpdateResponse = try await makeRequest(url: url, method: "PUT", body: bodyData)
    }
    
    // MARK: - NPC Management
    
    /// NPC data structure
    struct APINPC: Codable {
        let id: String
        let name: String
        let npc_type: String
        let latitude: Double
        let longitude: Double
        let created_at: String?
        let created_by: String?
        let ar_origin_latitude: Double?
        let ar_origin_longitude: Double?
        let ar_offset_x: Double?
        let ar_offset_y: Double?
        let ar_offset_z: Double?
        let ar_placement_timestamp: String?
    }
    
    struct CreateNPCRequest: Codable {
        let id: String
        let name: String
        let npc_type: String
        let latitude: Double
        let longitude: Double
        let created_by: String?
        let ar_origin_latitude: Double?
        let ar_origin_longitude: Double?
        let ar_offset_x: Double?
        let ar_offset_y: Double?
        let ar_offset_z: Double?
        let ar_placement_timestamp: String?
    }
    
    /// Get all NPCs
    func getNPCs() async throws -> [APINPC] {
        guard let url = URL(string: "\(baseURL)/api/npcs") else {
            throw APIError.invalidURL
        }
        return try await makeRequest(url: url, method: "GET")
    }
    
    /// Get a specific NPC by ID
    func getNPC(id: String) async throws -> APINPC {
        guard let url = URL(string: "\(baseURL)/api/npcs/\(id)") else {
            throw APIError.invalidURL
        }
        return try await makeRequest(url: url, method: "GET")
    }
    
    /// Create a new NPC
    func createNPC(
        id: String,
        name: String,
        npcType: String,
        latitude: Double,
        longitude: Double,
        arOriginLatitude: Double? = nil,
        arOriginLongitude: Double? = nil,
        arOffsetX: Double? = nil,
        arOffsetY: Double? = nil,
        arOffsetZ: Double? = nil
    ) async throws -> APINPC {
        guard let url = URL(string: "\(baseURL)/api/npcs") else {
            throw APIError.invalidURL
        }
        
        let request = CreateNPCRequest(
            id: id,
            name: name,
            npc_type: npcType,
            latitude: latitude,
            longitude: longitude,
            created_by: currentUserID,
            ar_origin_latitude: arOriginLatitude,
            ar_origin_longitude: arOriginLongitude,
            ar_offset_x: arOffsetX,
            ar_offset_y: arOffsetY,
            ar_offset_z: arOffsetZ,
            ar_placement_timestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(request)
        
        struct CreateResponse: Codable {
            let id: String
            let message: String?
        }
        
        let response: CreateResponse = try await makeRequest(url: url, method: "POST", body: bodyData)
        return try await getNPC(id: response.id)
    }
    
    /// Update an NPC
    func updateNPC(
        id: String,
        name: String? = nil,
        npcType: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        arOriginLatitude: Double? = nil,
        arOriginLongitude: Double? = nil,
        arOffsetX: Double? = nil,
        arOffsetY: Double? = nil,
        arOffsetZ: Double? = nil
    ) async throws -> APINPC {
        guard let url = URL(string: "\(baseURL)/api/npcs/\(id)") else {
            throw APIError.invalidURL
        }
        
        struct UpdateRequest: Codable {
            let name: String?
            let npc_type: String?
            let latitude: Double?
            let longitude: Double?
            let ar_origin_latitude: Double?
            let ar_origin_longitude: Double?
            let ar_offset_x: Double?
            let ar_offset_y: Double?
            let ar_offset_z: Double?
            let ar_placement_timestamp: String?
        }
        
        let request = UpdateRequest(
            name: name,
            npc_type: npcType,
            latitude: latitude,
            longitude: longitude,
            ar_origin_latitude: arOriginLatitude,
            ar_origin_longitude: arOriginLongitude,
            ar_offset_x: arOffsetX,
            ar_offset_y: arOffsetY,
            ar_offset_z: arOffsetZ,
            ar_placement_timestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(request)
        
        struct UpdateResponse: Codable {
            let id: String
            let message: String?
        }
        
        let _: UpdateResponse = try await makeRequest(url: url, method: "PUT", body: bodyData)
        return try await getNPC(id: id)
    }
    
    /// Delete an NPC
    func deleteNPC(id: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/npcs/\(id)") else {
            throw APIError.invalidURL
        }
        
        struct DeleteResponse: Codable {
            let npc_id: String
            let message: String?
        }
        
        let _: DeleteResponse = try await makeRequest(url: url, method: "DELETE")
    }
    
    /// Convert APIObject to LootBoxLocation
    func convertToLootBoxLocation(_ apiObject: APIObject) -> LootBoxLocation? {
        guard let type = LootBoxType(rawValue: apiObject.type) else {
            print("⚠️ Unknown loot box type: \(apiObject.type)")
            return nil
        }
        
        var location = LootBoxLocation(
            id: apiObject.id,
            name: apiObject.name,
            type: type,
            latitude: apiObject.latitude,
            longitude: apiObject.longitude,
            radius: apiObject.radius,
            collected: apiObject.collected,
            source: .api  // Explicitly set source to .api so items show on map
        )
        
        // Set AR coordinates if available (for cm-level precision indoor placement)
        location.grounding_height = apiObject.grounding_height
        location.ar_origin_latitude = apiObject.ar_origin_latitude
        location.ar_origin_longitude = apiObject.ar_origin_longitude
        location.ar_offset_x = apiObject.ar_offset_x
        location.ar_offset_y = apiObject.ar_offset_y
        location.ar_offset_z = apiObject.ar_offset_z
        
        // Parse AR placement timestamp if available
        if let timestampString = apiObject.ar_placement_timestamp {
            let formatter = ISO8601DateFormatter()
            location.ar_placement_timestamp = formatter.date(from: timestampString)
        }
        
        return location
    }
    
    // MARK: - Story Mode API Methods
    
    /// Interact with an NPC (skeleton) via LLM conversation
    func interactWithNPC(npcId: String, message: String, npcName: String = "Captain Bones", npcType: String = "skeleton", isSkeleton: Bool = true) async throws -> (npcName: String, response: String) {
        guard let url = URL(string: "\(baseURL)/api/npcs/\(npcId)/interact") else {
            throw APIError.invalidURL
        }
        
        struct NPCInteractionRequest: Codable {
            let device_uuid: String
            let message: String
            let npc_name: String
            let npc_type: String
            let is_skeleton: Bool
        }
        
        struct NPCInteractionResponse: Codable {
            let npc_id: String
            let npc_name: String
            let response: String
        }
        
        let request = NPCInteractionRequest(
            device_uuid: currentUserID,
            message: message,
            npc_name: npcName,
            npc_type: npcType,
            is_skeleton: isSkeleton
        )
        
        let encoder = JSONEncoder()
        let body = try encoder.encode(request)
        
        let response: NPCInteractionResponse = try await makeRequest(url: url, method: "POST", body: body)
        return (response.npc_name, response.response)
    }
    
    /// Generate a pirate riddle clue based on location and map features
    func generateClue(targetLocation: CLLocation, mapFeatures: [String]? = nil, fetchRealFeatures: Bool = true) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/llm/generate-clue") else {
            throw APIError.invalidURL
        }
        
        struct ClueRequest: Codable {
            let target_location: TargetLocation
            let map_features: [String]?
            let fetch_real_features: Bool
            
            struct TargetLocation: Codable {
                let latitude: Double
                let longitude: Double
            }
        }
        
        struct ClueResponse: Codable {
            let clue: String
            let target_location: ClueRequest.TargetLocation
            let used_real_map_data: Bool
        }
        
        let request = ClueRequest(
            target_location: ClueRequest.TargetLocation(
                latitude: targetLocation.coordinate.latitude,
                longitude: targetLocation.coordinate.longitude
            ),
            map_features: mapFeatures,
            fetch_real_features: fetchRealFeatures
        )
        
        let encoder = JSONEncoder()
        let body = try encoder.encode(request)
        
        let response: ClueResponse = try await makeRequest(url: url, method: "POST", body: body)
        return response.clue
    }
    
    // MARK: - Map Pieces
    
    // MARK: - Map Piece Types
    
    struct LandmarkData: Codable {
        let name: String
        let type: String
        let latitude: Double
        let longitude: Double
    }
    
    struct MapPiece: Codable {
        let piece_number: Int
        let hint: String
        let approximate_latitude: Double?
        let approximate_longitude: Double?
        let exact_latitude: Double?
        let exact_longitude: Double?
        let landmarks: [LandmarkData]  // Now includes coordinates
        let is_first_half: Bool?
        let is_second_half: Bool?
        
        // Custom decoder to handle both old format (strings) and new format (dicts)
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            piece_number = try container.decode(Int.self, forKey: .piece_number)
            hint = try container.decode(String.self, forKey: .hint)
            approximate_latitude = try container.decodeIfPresent(Double.self, forKey: .approximate_latitude)
            approximate_longitude = try container.decodeIfPresent(Double.self, forKey: .approximate_longitude)
            exact_latitude = try container.decodeIfPresent(Double.self, forKey: .exact_latitude)
            exact_longitude = try container.decodeIfPresent(Double.self, forKey: .exact_longitude)
            is_first_half = try container.decodeIfPresent(Bool.self, forKey: .is_first_half)
            is_second_half = try container.decodeIfPresent(Bool.self, forKey: .is_second_half)
            
            // Try to decode as array of LandmarkData first (new format)
            if let landmarkData = try? container.decode([LandmarkData].self, forKey: .landmarks) {
                landmarks = landmarkData
            } else if (try? container.decode([String].self, forKey: .landmarks)) != nil {
                // Fallback to old format (strings) - convert to empty array since we don't have coordinates
                landmarks = []
            } else {
                landmarks = []
            }
        }
    }
    
    struct MapPieceResponse: Codable {
        let npc_id: String
        let npc_type: String
        let map_piece: MapPiece
        let message: String
    }
    
    struct CombinedMapResponse: Codable {
        let complete_map: CompleteMap
        let message: String
        
        struct CompleteMap: Codable {
            let map_name: String
            let x_marks_the_spot: XMarksTheSpot
            let landmarks: [String]
            let combined_from_pieces: [Int]
            
            struct XMarksTheSpot: Codable {
                let latitude: Double
                let longitude: Double
            }
        }
    }
    
    /// Get a treasure map piece from an NPC
    /// - Parameters:
    ///   - npcId: The ID of the NPC (skeleton-1 or corgi-1)
    ///   - targetLocation: Optional target location for the treasure (if not provided, uses default)
    /// - Returns: Map piece data with coordinates and landmarks
    func getMapPiece(npcId: String, targetLocation: CLLocation? = nil) async throws -> MapPieceResponse {
        let urlString = "\(baseURL)/api/npcs/\(npcId)/map-piece"
        
        struct MapPieceRequest: Codable {
            let target_location: TargetLocation?
            
            struct TargetLocation: Codable {
                let latitude: Double
                let longitude: Double
            }
        }
        
        var requestBody: Data?
        if let targetLocation = targetLocation {
            let request = MapPieceRequest(
                target_location: MapPieceRequest.TargetLocation(
                    latitude: targetLocation.coordinate.latitude,
                    longitude: targetLocation.coordinate.longitude
                )
            )
            let encoder = JSONEncoder()
            requestBody = try encoder.encode(request)
        }
        
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }
        
        let response: MapPieceResponse = try await makeRequest(url: url, method: "GET", body: requestBody)
        return response
    }
    
    /// Combine two map pieces into a complete treasure map
    /// - Parameters:
    ///   - piece1: First map piece (from skeleton)
    ///   - piece2: Second map piece (from corgi)
    /// - Returns: Complete treasure map with X marks the spot location
    func combineMapPieces(piece1: MapPiece, piece2: MapPiece) async throws -> CombinedMapResponse {
        guard let url = URL(string: "\(baseURL)/api/map-pieces/combine") else {
            throw APIError.invalidURL
        }
        
        struct CombineRequest: Codable {
            let piece1: MapPiece
            let piece2: MapPiece
        }
        
        let request = CombineRequest(piece1: piece1, piece2: piece2)
        let encoder = JSONEncoder()
        let body = try encoder.encode(request)
        
        let response: CombinedMapResponse = try await makeRequest(url: url, method: "POST", body: body)
        return response
    }
}

// MARK: - API Errors
enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case serverError(String)
    case decodingError
    case serverUnreachable
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .decodingError:
            return "Failed to decode response"
        case .serverUnreachable:
            return "Server is unreachable. Make sure the server is running and on the same network."
        }
    }
}

