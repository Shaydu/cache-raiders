import Foundation
import CoreLocation
import UIKit

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

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // Configure your API base URL here
    // For local development: "http://localhost:5000"
    // For production: "https://your-api-domain.com"
    var baseURL: String {
        // Check UserDefaults for custom URL, otherwise use default
        if let customURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !customURL.isEmpty {
            return customURL
        }
        return "http://localhost:5000"
    }
    
    // User identifier - in production, this should be a proper user ID
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
            print("⚠️ API health check failed: \(error)")
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
        
        let request = MarkFoundRequest(found_by: foundBy ?? currentUserID)
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

