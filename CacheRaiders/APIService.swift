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

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
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
        // Try to get a suggested local network IP (default port is 5001)
        if let suggestedIP = getSuggestedLocalIP() {
            return "http://\(suggestedIP):5001"
        }
        return "http://localhost:5001"
    }
    
    /// Get a suggested local network IP address based on the device's network
    private func getSuggestedLocalIP() -> String? {
        // Try to get the device's local IP to suggest a server IP in the same range
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
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
        
        freeifaddrs(ifaddr)
        
        // If we found the device IP, suggest a server IP in the same subnet
        // Try .1 first (often the router/server), then .100
        if let deviceIP = address {
            let components = deviceIP.split(separator: ".")
            if components.count == 4 {
                // Try .1 first (common for router/server)
                return "\(components[0]).\(components[1]).\(components[2]).1"
            }
        }
        
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
    
    private init() {}
    
    // MARK: - Helper Methods
    
    private func makeRequest<T: Decodable>(
        url: URL,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        print("🔍 [API Request] \(method) \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
            // Enhanced error logging
            print("❌ [API Request] Request failed: \(error.localizedDescription)")
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
            
            throw error
        }
    }
    
    // MARK: - API Methods
    
    /// Check if API is available, with automatic server discovery on failure
    func checkHealth() async throws -> Bool {
        return try await checkHealthWithDiscovery()
    }
    
    /// Check health with automatic server discovery as fallback
    private func checkHealthWithDiscovery(attemptDiscovery: Bool = true) async throws -> Bool {
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
            
            // Try automatic server discovery if this was the first attempt
            if attemptDiscovery {
                print("🔍 [API Health Check] Attempting automatic server discovery...")
                do {
                    return try await discoverAndConnect()
                } catch {
                    print("❌ [API Health Check] Server discovery also failed: \(error.localizedDescription)")
                    // Return false to allow graceful fallback
                    return false
                }
            }
            
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

