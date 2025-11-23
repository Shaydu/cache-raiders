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
    let collected: Bool
    let found_by: String?
    let found_at: String?
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

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // Configure your API base URL here
    // For local development: "http://localhost:5001"
    // For production: "https://your-api-domain.com"
    var baseURL: String {
        // Check UserDefaults for custom URL, otherwise use default
        if let customURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !customURL.isEmpty {
            return customURL
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
        Task {
            do {
                try await updatePlayerNameOnServer(trimmedName)
            } catch {
                // Silently fail - local storage is primary, server is secondary
                print("⚠️ Failed to sync player name to server: \(error.localizedDescription)")
            }
        }
    }
    
    private init() {}
    
    // MARK: - Helper Methods
    
    private func makeRequest<T: Decodable>(
        url: URL,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let body = body {
            request.httpBody = body
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorData = try? JSONDecoder().decode([String: String].self, from: data),
               let errorMessage = errorData["error"] {
                throw APIError.serverError(errorMessage)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
    
    // MARK: - API Methods
    
    /// Check if API is available
    func checkHealth() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else {
            throw APIError.invalidURL
        }
        
        do {
            let _: [String: String] = try await makeRequest(url: url)
            return true
        } catch {
            // Suppress detailed error logging - just return false
            // The calling code will handle the fallback
            return false
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
    
    /// Convert APIObject to LootBoxLocation
    func convertToLootBoxLocation(_ apiObject: APIObject) -> LootBoxLocation? {
        guard let type = LootBoxType(rawValue: apiObject.type) else {
            print("⚠️ Unknown loot box type: \(apiObject.type)")
            return nil
        }
        
        return LootBoxLocation(
            id: apiObject.id,
            name: apiObject.name,
            type: type,
            latitude: apiObject.latitude,
            longitude: apiObject.longitude,
            radius: apiObject.radius,
            collected: apiObject.collected
        )
    }
}

// MARK: - API Errors
enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case serverError(String)
    case decodingError
    
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
        }
    }
}

