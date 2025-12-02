import Foundation
import CoreLocation
import UIKit

// MARK: - API Response Models
struct NPCInteractionResponse: Codable {
    let response: String
    let npc_id: String?
    let npc_name: String?
    let npc_type: String?
    let map_piece: MapPiece?
}

struct MapPiece: Codable {
    let piece_number: Int
    let total_pieces: Int
    let npc_name: String
    let hint: String
    let approximate_latitude: Double
    let approximate_longitude: Double
    let landmarks: [Landmark]?
    let is_first_half: Bool
    let clue: String
}

struct Landmark: Codable {
    let name: String
    let type: String
    let latitude: Double
    let longitude: Double
}

struct TreasureHuntResponse: Codable {
    let has_active_hunt: Bool
    let treasure_hunt: TreasureHunt?
}

struct TreasureHunt: Codable {
    let id: Int
    let treasure_latitude: Double
    let treasure_longitude: Double
    let map_piece_1: MapPiece?
    let map_piece_2: MapPiece?
}

struct LocationUpdateIntervalResponse: Codable {
    let interval_ms: Int
    let interval_seconds: Double
}

struct IOUDiscoveryResponse: Codable {
    let success: Bool
    let message: String
    let iou_note: String?
    let stage_2_unlocked: Bool?
    let corgi_location: IOUCorgiLocation?
}

struct IOUCorgiLocation: Codable {
    let latitude: Double
    let longitude: Double
}

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
    var collected: Bool
    var found_by: String?
    var found_at: String?
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
    let user_id: String
    let display_name: String?
    let find_count: Int
}

struct ResetFindsResponse: Codable {
    let message: String
    let finds_removed: Int
}

struct HealthResponse: Codable {
    let status: String
    let version: String?
    let timestamp: String
}



enum APIError: Error {
    case serverError(String)
    case serverUnreachable
    case httpError(Int)
    case decodingError(String)
    case invalidURL
    case networkError(String)
}

// MARK: - APIService Class
class APIService {
    static let shared = APIService()

    var baseURL: String {
        get {
            // Load from UserDefaults if available, otherwise use localhost for development
            if let savedURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !savedURL.isEmpty {
                return savedURL
            } else {
                return "http://localhost:5001"
            }
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "apiBaseURL")
        }
    }
    var currentUserID: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown_user"

    var currentUserName: String {
        get {
            UserDefaults.standard.string(forKey: "userName") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "userName")
        }
    }

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 300.0
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: - NPC Interaction
    func interactWithNPC(npcId: String, message: String, npcName: String, npcType: String, isSkeleton: Bool, includeMapPiece: Bool = false) async throws -> NPCInteractionResponse {
        let url = URL(string: "\(baseURL)/api/npcs/\(npcId)/interact")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "device_uuid": currentUserID,
            "message": message,
            "user_location": [
                "latitude": 0.0,
                "longitude": 0.0
            ]
        ]

        // Add include_map_piece parameter if requested
        if includeMapPiece {
            body["include_map_piece"] = true
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 503 {
                throw APIError.serverError("LLM service not available")
            } else {
                throw APIError.httpError(httpResponse.statusCode)
            }
        }

        do {
            return try decoder.decode(NPCInteractionResponse.self, from: data)
        } catch {
            throw APIError.decodingError("Failed to decode NPC response: \(error.localizedDescription)")
        }
    }

    // MARK: - Health Check
    func checkHealth() async throws -> Bool {
        let url = URL(string: "\(baseURL)/health")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return false
        }

        let healthResponse = try decoder.decode(HealthResponse.self, from: data)
        return healthResponse.status == "healthy"
    }


    // MARK: - Objects
    func getObjects(includeFound: Bool = false) async throws -> [APIObject] {
        var urlString = "\(baseURL)/api/objects"
        if includeFound {
            urlString += "?include_found=true"
        }

        let url = URL(string: urlString)!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([APIObject].self, from: data)
    }

    func getObjects(latitude: Double, longitude: Double, radius: Double, includeFound: Bool = false) async throws -> [APIObject] {
        var urlString = "\(baseURL)/api/objects?latitude=\(latitude)&longitude=\(longitude)&radius=\(radius)"
        if includeFound {
            urlString += "&include_found=true"
        }

        let url = URL(string: urlString)!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([APIObject].self, from: data)
    }

    func getObject(id: String) async throws -> APIObject {
        let url = URL(string: "\(baseURL)/api/objects/\(id)")!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(APIObject.self, from: data)
    }

    func markFound(objectId: String) async throws {
        let url = URL(string: "\(baseURL)/api/objects/\(objectId)/mark-found")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = MarkFoundRequest(found_by: currentUserID)
        request.httpBody = try JSONEncoder().encode(body)

        let _ = try await session.data(for: request)
    }

    // Helper method to convert APIObject to LootBoxLocation
    func convertToLootBoxLocation(_ apiObject: APIObject) -> LootBoxLocation? {
        guard let lootBoxType = LootBoxType(rawValue: apiObject.type) else {
            print("⚠️ Unknown loot box type: \(apiObject.type)")
            return nil
        }

        let location = LootBoxLocation(
            id: apiObject.id,
            name: apiObject.name,
            type: lootBoxType,
            latitude: apiObject.latitude,
            longitude: apiObject.longitude,
            radius: apiObject.radius,
            collected: apiObject.collected,
            grounding_height: apiObject.grounding_height,
            source: .api // API objects come from the API
        )

        return location
    }

    func updateObjectLocation(objectId: String, location: CLLocation) async throws {
        let url = URL(string: "\(baseURL)/api/objects/\(objectId)/location")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let _ = try await session.data(for: request)
    }

    func resetAllFinds() async throws -> ResetFindsResponse {
        let url = URL(string: "\(baseURL)/api/finds/reset")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(ResetFindsResponse.self, from: data)
    }

    func unmarkFound(objectId: String) async throws {
        let url = URL(string: "\(baseURL)/api/objects/\(objectId)/unmark-found")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let _ = try await session.data(for: request)
    }

    func getStats() async throws -> APIStats {
        let url = URL(string: "\(baseURL)/api/stats")!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(APIStats.self, from: data)
    }

    func updateAROffset(objectId: String, arOriginLatitude: Double, arOriginLongitude: Double, offsetX: Double, offsetY: Double, offsetZ: Double) async throws {
        let url = URL(string: "\(baseURL)/api/objects/\(objectId)/ar-offset")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "ar_origin_latitude": arOriginLatitude,
            "ar_origin_longitude": arOriginLongitude,
            "ar_offset_x": offsetX,
            "ar_offset_y": offsetY,
            "ar_offset_z": offsetZ
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let _ = try await session.data(for: request)
    }

    func updateGroundingHeight(objectId: String, height: Double) async throws {
        let url = URL(string: "\(baseURL)/api/objects/\(objectId)/grounding-height")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grounding_height": height
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let _ = try await session.data(for: request)
    }

    func createObject(_ location: LootBoxLocation) async throws -> APIObject {
        let url = URL(string: "\(baseURL)/api/objects")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "id": location.id,
            "name": location.name,
            "type": location.type.rawValue,
            "latitude": location.latitude,
            "longitude": location.longitude,
            "radius": location.radius,
            "created_by": currentUserID,
            "grounding_height": location.grounding_height
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw APIError.httpError(httpResponse.statusCode)
        }

        return try decoder.decode(APIObject.self, from: data)
    }

    // MARK: - Game Mode
    func getGameMode() async throws -> String {
        let url = URL(string: "\(baseURL)/api/game-mode")!
        let (data, _) = try await session.data(from: url)
        let response = try decoder.decode(GameModeResponse.self, from: data)
        return response.game_mode
    }

    // MARK: - Treasure Hunt
    func getTreasureHunt() async throws -> TreasureHuntResponse {
        let url = URL(string: "\(baseURL)/api/treasure-hunts/\(currentUserID)")!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(TreasureHuntResponse.self, from: data)
    }

    func resetTreasureHunt() async throws {
        let url = URL(string: "\(baseURL)/api/treasure-hunts/\(currentUserID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let _ = try await session.data(for: request)
    }

    func completeTreasureHunt() async throws {
        let url = URL(string: "\(baseURL)/api/treasure-hunts/\(currentUserID)/complete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let _ = try await session.data(for: request)
    }

    func getMapPiece(npcId: String, targetLocation: CLLocation) async throws -> NPCInteractionResponse {
        return try await interactWithNPC(
            npcId: npcId,
            message: "Give me the treasure map!",
            npcName: "Captain Bones",
            npcType: "skeleton",
            isSkeleton: true,
            includeMapPiece: true
        )
    }

    // MARK: - Location Update Interval
    func getLocationUpdateInterval() async throws -> Double {
        let url = URL(string: "\(baseURL)/api/settings/location-update-interval")!
        let (data, _) = try await session.data(from: url)
        let response = try decoder.decode(LocationUpdateIntervalResponse.self, from: data)
        return response.interval_seconds
    }

    func updateUserLocation(latitude: Double, longitude: Double, accuracy: Double?, heading: Double?, arOffsetX: Double?, arOffsetY: Double?, arOffsetZ: Double?) async throws {
        let url = URL(string: "\(baseURL)/api/users/\(currentUserID)/location")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude
        ]

        if let accuracy = accuracy { body["accuracy"] = accuracy }
        if let heading = heading { body["heading"] = heading }
        if let arOffsetX = arOffsetX { body["ar_offset_x"] = arOffsetX }
        if let arOffsetY = arOffsetY { body["ar_offset_y"] = arOffsetY }
        if let arOffsetZ = arOffsetZ { body["ar_offset_z"] = arOffsetZ }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let _ = try await session.data(for: request)
    }

    // MARK: - Treasure Hunt
    func discoverIOU(deviceUUID: String, currentLatitude: Double, currentLongitude: Double) async throws -> IOUDiscoveryResponse {
        let url = URL(string: "\(baseURL)/api/treasure-hunts/\(deviceUUID)/discover-iou")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "current_latitude": currentLatitude,
            "current_longitude": currentLongitude
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 404 {
                throw APIError.serverError("No active treasure hunt found")
            } else {
                throw APIError.httpError(httpResponse.statusCode)
            }
        }

        do {
            return try decoder.decode(IOUDiscoveryResponse.self, from: data)
        } catch {
            throw APIError.decodingError("Failed to decode IOU discovery response: \(error.localizedDescription)")
        }
    }

    // MARK: - User Management
    func setUserName(_ name: String) {
        currentUserName = name
        // Sync to server in background if not empty
        if !name.isEmpty {
            Task {
                do {
                    try await setPlayerNameOnServer(name)
                } catch {
                    print("⚠️ Failed to sync user name to server: \(error.localizedDescription)")
                }
            }
        }
    }

    func getPlayerNameFromServer(deviceUUID: String? = nil) async throws -> String? {
        let userId = deviceUUID ?? currentUserID
        let url = URL(string: "\(baseURL)/api/players/\(userId)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 404 {
            return nil // Player not found
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        struct PlayerResponse: Codable {
            let device_uuid: String
            let player_name: String
            let created_at: String
            let updated_at: String
        }

        let playerResponse = try decoder.decode(PlayerResponse.self, from: data)
        return playerResponse.player_name
    }

    func getPlayerName(deviceUUID: String? = nil) async throws -> String? {
        let userId = deviceUUID ?? currentUserID
        let url = URL(string: "\(baseURL)/api/players/\(userId)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 404 {
            return nil // Player not found
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        struct PlayerResponse: Codable {
            let device_uuid: String
            let player_name: String
            let created_at: String
            let updated_at: String
        }

        let playerResponse = try decoder.decode(PlayerResponse.self, from: data)
        return playerResponse.player_name
    }

    private func setPlayerNameOnServer(_ name: String) async throws {
        let url = URL(string: "\(baseURL)/api/players/\(currentUserID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["player_name": name]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let _ = try await session.data(for: request)
    }

    func syncSavedUserNameToServer() {
        // Stub implementation
        print("syncSavedUserNameToServer not implemented")
    }
}