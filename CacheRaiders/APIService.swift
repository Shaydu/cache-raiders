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

struct Landmark: Codable, Equatable {
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
    var multifindable: Bool?
}

struct NPCResponse: Codable {
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
                print("🔗 [APIService] Using saved baseURL: \(savedURL)")
                return savedURL
            } else {
                print("🔗 [APIService] Using default baseURL: http://localhost:5001")
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

    func createNPC(id: String, name: String, npcType: String, latitude: Double, longitude: Double, arOriginLatitude: Double? = nil, arOriginLongitude: Double? = nil, arOffsetX: Double? = nil, arOffsetY: Double? = nil, arOffsetZ: Double? = nil) async throws -> NPCResponse {
        let url = URL(string: "\(baseURL)/api/npcs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "id": id,
            "name": name,
            "npc_type": npcType,
            "latitude": latitude,
            "longitude": longitude,
            "created_by": currentUserID
        ]

        // Add optional AR positioning data
        if let arOriginLatitude = arOriginLatitude {
            body["ar_origin_latitude"] = arOriginLatitude
        }
        if let arOriginLongitude = arOriginLongitude {
            body["ar_origin_longitude"] = arOriginLongitude
        }
        if let arOffsetX = arOffsetX {
            body["ar_offset_x"] = arOffsetX
        }
        if let arOffsetY = arOffsetY {
            body["ar_offset_y"] = arOffsetY
        }
        if let arOffsetZ = arOffsetZ {
            body["ar_offset_z"] = arOffsetZ
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(NPCResponse.self, from: data)
        } catch {
            throw APIError.decodingError("Failed to decode NPC creation response: \(error.localizedDescription)")
        }
    }

    // MARK: - Health Check
    func checkHealth() async throws -> Bool {
        let url = URL(string: "\(baseURL)/health")!
        print("🏥 [APIService] Checking health at: \(url.absoluteString)")
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ [APIService] Health check failed: Invalid response type")
            return false
        }

        print("📡 [APIService] Health check HTTP status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ [APIService] Health check failed: HTTP \(httpResponse.statusCode)")
            print("   Response data: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
            return false
        }

        do {
            let healthResponse = try decoder.decode(HealthResponse.self, from: data)
            print("✅ [APIService] Health check successful: \(healthResponse.status)")
            return healthResponse.status == "healthy"
        } catch {
            print("❌ [APIService] Health check JSON decode failed: \(error)")
            print("   Raw response: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
            throw error
        }
    }


    // MARK: - Objects
    func getObjects(includeFound: Bool = false) async throws -> [APIObject] {
        var urlString = "\(baseURL)/api/objects?user_id=\(currentUserID)"
        if includeFound {
            urlString += "&include_found=true"
        }

        let url = URL(string: urlString)!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode([APIObject].self, from: data)
    }

    func getObjects(latitude: Double, longitude: Double, radius: Double, includeFound: Bool = false) async throws -> [APIObject] {
        var urlString = "\(baseURL)/api/objects?latitude=\(latitude)&longitude=\(longitude)&radius=\(radius)&user_id=\(currentUserID)"
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

    // NFC-aware object lookup that can handle chip UIDs
    func getObjectByNFCId(_ nfcId: String) async throws -> APIObject {
        // Try the NFC details endpoint first (handles chip UID pattern matching)
        let nfcUrl = URL(string: "\(baseURL)/api/nfc/\(nfcId)")!
        do {
            let (data, _) = try await session.data(from: nfcUrl)
            return try decoder.decode(APIObject.self, from: data)
        } catch {
            // If NFC endpoint fails, try regular object endpoint
            print("⚠️ NFC endpoint failed for '\(nfcId)', trying regular object lookup")
            return try await getObject(id: nfcId)
        }
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

    func updateObjectLocation(objectId: String, latitude: Double, longitude: Double) async throws {
        let url = URL(string: "\(baseURL)/api/objects/\(objectId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw APIError.httpError(httpResponse.statusCode)
        }
    }

    // Helper method to convert APIObject to LootBoxLocation
    func convertToLootBoxLocation(_ apiObject: APIObject) -> LootBoxLocation? {
        guard let lootBoxType = LootBoxType(rawValue: apiObject.type) else {
            print("⚠️ Unknown loot box type: \(apiObject.type)")
            return nil
        }

        // Parse AR placement timestamp if present
        var arPlacementTimestamp: Date? = nil
        if let timestampString = apiObject.ar_placement_timestamp {
            let isoFormatter = ISO8601DateFormatter()
            arPlacementTimestamp = isoFormatter.date(from: timestampString)
        }

        // Parse created_at timestamp for last_modified field
        // Use created_at as the last_modified date since API provides creation time
        var lastModified: Date? = nil
        if let createdAtString = apiObject.created_at {
            let isoFormatter = ISO8601DateFormatter()
            lastModified = isoFormatter.date(from: createdAtString)
        }

        // Determine source: if object has AR coordinates, treat as AR-placed (use .map for persistence)
        // Use .map instead of .arManual so it persists to Core Data and syncs to API
        let hasARCoordinates = apiObject.ar_origin_latitude != nil &&
                               apiObject.ar_origin_longitude != nil &&
                               apiObject.ar_offset_x != nil &&
                               apiObject.ar_offset_y != nil &&
                               apiObject.ar_offset_z != nil
        let source: ItemSource = hasARCoordinates ? .map : .api

        let location = LootBoxLocation(
            id: apiObject.id,
            name: apiObject.name,
            type: lootBoxType,
            latitude: apiObject.latitude,
            longitude: apiObject.longitude,
            radius: apiObject.radius,
            collected: apiObject.collected,
            grounding_height: apiObject.grounding_height,
            source: source, // Use .map for AR-placed objects (persists + syncs), .api for GPS-only
            created_by: apiObject.created_by,
            last_modified: lastModified, // Use created_at as last_modified for display
            ar_origin_latitude: apiObject.ar_origin_latitude,
            ar_origin_longitude: apiObject.ar_origin_longitude,
            ar_offset_x: apiObject.ar_offset_x,
            ar_offset_y: apiObject.ar_offset_y,
            ar_offset_z: apiObject.ar_offset_z,
            ar_placement_timestamp: arPlacementTimestamp,
            multifindable: apiObject.multifindable
        )

        return location
    }

    /// Extract AR positioning data from JSON dictionary using ARPositioningService
    private func extractARPositioningData(from data: [String: Any]) -> (origin: ARPositioningService.AROrigin?, offsets: ARPositioningService.AROffsets?, anchorTransform: String?, placementTimestamp: Date?) {
        // Extract AR coordinate fields
        let arOriginLatitude = data["ar_origin_latitude"] as? Double
        let arOriginLongitude = data["ar_origin_longitude"] as? Double
        let arOffsetX = data["ar_offset_x"] as? Double
        let arOffsetY = data["ar_offset_y"] as? Double
        let arOffsetZ = data["ar_offset_z"] as? Double
        let arAnchorTransform = data["ar_anchor_transform"] as? String

        // Convert timestamp string to Date if present
        var arPlacementTimestamp: Date? = nil
        if let timestampString = data["ar_placement_timestamp"] as? String {
            // Try to parse as ISO 8601 format (what the server likely sends)
            let isoFormatter = ISO8601DateFormatter()
            arPlacementTimestamp = isoFormatter.date(from: timestampString)
        }

        // Create AR positioning structures
        var origin: ARPositioningService.AROrigin? = nil
        if let lat = arOriginLatitude, let lng = arOriginLongitude {
            origin = ARPositioningService.AROrigin(latitude: lat, longitude: lng)
        }

        var offsets: ARPositioningService.AROffsets? = nil
        if let x = arOffsetX, let y = arOffsetY, let z = arOffsetZ {
            offsets = ARPositioningService.AROffsets(x: x, y: y, z: z)
        }

        return (origin, offsets, arAnchorTransform, arPlacementTimestamp)
    }

    /// Convert WebSocket object creation data to LootBoxLocation
    func convertWebSocketDataToLootBoxLocation(_ data: [String: Any]) -> LootBoxLocation? {
        guard let id = data["id"] as? String,
              let name = data["name"] as? String,
              let typeString = data["type"] as? String,
              let latitude = data["latitude"] as? Double,
              let longitude = data["longitude"] as? Double,
              let radius = data["radius"] as? Double else {
            print("⚠️ WebSocket data missing required fields: \(data)")
            return nil
        }

        guard let lootBoxType = LootBoxType(rawValue: typeString) else {
            print("⚠️ Unknown loot box type in WebSocket data: \(typeString)")
            return nil
        }

        // Extract optional fields
        let collected = data["collected"] as? Bool ?? false
        let groundingHeight = data["grounding_height"] as? Double
        let createdBy = data["created_by"] as? String
        let multifindable = data["multifindable"] as? Bool

        // Extract AR positioning data using ARPositioningService helper
        let arData = extractARPositioningData(from: data)

        let location = LootBoxLocation(
            id: id,
            name: name,
            type: lootBoxType,
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            collected: collected,
            grounding_height: groundingHeight,
            source: .api, // WebSocket objects come from the API
            created_by: createdBy,
            ar_origin_latitude: arData.origin?.latitude,
            ar_origin_longitude: arData.origin?.longitude,
            ar_offset_x: arData.offsets?.x,
            ar_offset_y: arData.offsets?.y,
            ar_offset_z: arData.offsets?.z,
            ar_placement_timestamp: arData.placementTimestamp,
            ar_anchor_transform: arData.anchorTransform,
            multifindable: multifindable
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
        print("🌐 [APIService] Creating object via API: \(location.name) (ID: \(location.id))")
        let url = URL(string: "\(baseURL)/api/objects")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "id": location.id,
            "name": location.name,
            "type": location.type.rawValue,
            "latitude": location.latitude,
            "longitude": location.longitude,
            "radius": location.radius,
            "created_by": currentUserID,
            "grounding_height": location.grounding_height
        ]

        // Set multifindable flag
        // Use explicit setting if provided, otherwise use defaults based on placement type
        var multifindableValue: Int
        if let multifindable = location.multifindable {
            multifindableValue = multifindable ? 1 : 0
        } else {
            // Default behavior: NFC-placed items are multifindable, others are not
            let isNFCPlaced = location.nfc_tag_id != nil && !location.nfc_tag_id!.isEmpty
            multifindableValue = isNFCPlaced ? 1 : 0
        }
        body["multifindable"] = multifindableValue

        // Add NFC tag ID if present
        if let nfcTagId = location.nfc_tag_id {
            body["nfc_tag_id"] = nfcTagId
        }

        // CRITICAL: Add AR offset coordinates for <10cm accuracy if available
        if let arOffsetX = location.ar_offset_x,
           let arOffsetY = location.ar_offset_y,
           let arOffsetZ = location.ar_offset_z,
           let arOriginLat = location.ar_origin_latitude,
           let arOriginLon = location.ar_origin_longitude {
            body["ar_offset_x"] = arOffsetX
            body["ar_offset_y"] = arOffsetY
            body["ar_offset_z"] = arOffsetZ
            body["ar_origin_latitude"] = arOriginLat
            body["ar_origin_longitude"] = arOriginLon
            if let arPlacementTimestamp = location.ar_placement_timestamp {
                body["ar_placement_timestamp"] = ISO8601DateFormatter().string(from: arPlacementTimestamp)
            }
            print("✅ [APIService] Sending AR offset coordinates for <10cm accuracy placement")
            print("   AR Origin: (\(String(format: "%.8f", arOriginLat)), \(String(format: "%.8f", arOriginLon)))")
            print("   AR Offsets: X=\(String(format: "%.4f", arOffsetX))m, Y=\(String(format: "%.4f", arOffsetY))m, Z=\(String(format: "%.4f", arOffsetZ))m")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            throw APIError.httpError(httpResponse.statusCode)
        }

        let createdObject = try decoder.decode(APIObject.self, from: data)
        print("✅ [APIService] Successfully created object: \(createdObject.name) (ID: \(createdObject.id))")
        return createdObject
    }

    // MARK: - Game Mode
    func getGameMode() async throws -> String {
        let url = URL(string: "\(baseURL)/api/settings/game-mode")!
        print("🔄 [APIService] Fetching game mode from: \(url.absoluteString)")
        let (data, response) = try await session.data(from: url)

        if let httpResponse = response as? HTTPURLResponse {
            print("📡 [APIService] Game mode HTTP status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                print("❌ [APIService] Non-200 response, data: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
            }
        }

        // Debug: Log raw response data
        let rawResponse = String(data: data, encoding: .utf8) ?? "unable to decode"
        print("🔍 [APIService] Raw game mode response: '\(rawResponse)'")
        print("🔍 [APIService] Response data length: \(data.count) bytes")

        // Check if data is empty
        if data.isEmpty {
            print("❌ [APIService] Response data is EMPTY!")
            throw APIError.decodingError("Server returned empty response for game mode")
        }

        do {
            let decodedResponse = try decoder.decode(GameModeResponse.self, from: data)
            print("✅ [APIService] Decoded game mode: \(decodedResponse.gameMode)")
            return decodedResponse.gameMode
        } catch let decodingError as DecodingError {
            print("❌ [APIService] JSON DecodingError: \(decodingError)")
            print("❌ [APIService] Error details: \(decodingError.localizedDescription)")

            // Handle specific decoding errors
            switch decodingError {
            case .keyNotFound(let key, _):
                print("❌ [APIService] Missing key: \(key.stringValue)")
            case .valueNotFound(_, let context):
                print("❌ [APIService] Missing value at: \(context.codingPath)")
            case .typeMismatch(_, let context):
                print("❌ [APIService] Type mismatch at: \(context.codingPath)")
            case .dataCorrupted(let context):
                print("❌ [APIService] Data corrupted at: \(context.codingPath)")
                if context.codingPath.isEmpty {
                    print("❌ [APIService] Root level data corruption - data may be empty or invalid")
                }
            @unknown default:
                print("❌ [APIService] Unknown decoding error")
            }

            // Try to decode as generic JSON to see what we actually got
            if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                print("🔍 [APIService] Actual JSON received: \(jsonObject)")
                print("🔍 [APIService] JSON keys: \(jsonObject.keys.sorted())")
            } else {
                print("🔍 [APIService] Could not parse as JSON at all")
                print("🔍 [APIService] Raw data length: \(data.count) bytes")
                if let rawString = String(data: data, encoding: .utf8) {
                    print("🔍 [APIService] Raw data as string: '\(rawString)'")
                } else {
                    print("🔍 [APIService] Raw data is not valid UTF-8")
                }
            }
            throw decodingError
        } catch {
            print("❌ [APIService] Non-decoding error: \(error)")
            throw error
        }
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
        print("🗺️ [APIService] getMapPiece called for npcId: \(npcId), location: (\(targetLocation.coordinate.latitude), \(targetLocation.coordinate.longitude))")
        let result = try await interactWithNPC(
            npcId: npcId,
            message: "Give me the treasure map!",
            npcName: "Captain Bones",
            npcType: "skeleton",
            isSkeleton: true,
            includeMapPiece: true
        )
        print("✅ [APIService] getMapPiece completed successfully")
        return result
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

    // MARK: - Cloud Geo Anchors

    /// Stores a geo anchor on the server for multi-user synchronization
    func storeGeoAnchor(_ anchorData: CloudGeoAnchorData) async throws {
        let url = URL(string: "\(baseURL)/api/geo-anchors")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "object_id": anchorData.objectId,
            "latitude": anchorData.coordinate.latitude,
            "longitude": anchorData.coordinate.longitude,
            "altitude": anchorData.altitude,
            "device_id": anchorData.deviceId,
            "created_at": ISO8601DateFormatter().string(from: anchorData.createdAt)
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        // Parse response to confirm storage
        struct GeoAnchorResponse: Codable {
            let success: Bool
            let message: String
            let anchor_id: String?
        }

        let anchorResponse = try decoder.decode(GeoAnchorResponse.self, from: data)
        if !anchorResponse.success {
            throw APIError.serverError(anchorResponse.message)
        }
    }

    /// Retrieves all geo anchors from the server
    func fetchGeoAnchors() async throws -> [CloudGeoAnchorData] {
        let url = URL(string: "\(baseURL)/api/geo-anchors")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        struct GeoAnchorsResponse: Codable {
            let success: Bool
            let anchors: [GeoAnchorData]
        }

        struct GeoAnchorData: Codable {
            let object_id: String
            let latitude: Double
            let longitude: Double
            let altitude: Double
            let device_id: String
            let created_at: String
        }

        let anchorsResponse = try decoder.decode(GeoAnchorsResponse.self, from: data)

        return anchorsResponse.anchors.map { anchor in
            CloudGeoAnchorData(
                objectId: anchor.object_id,
                coordinate: CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude),
                altitude: anchor.altitude,
                createdAt: ISO8601DateFormatter().date(from: anchor.created_at) ?? Date(),
                deviceId: anchor.device_id
            )
        }
    }

    /// Shares a geo anchor with other users via WebSocket
    func shareGeoAnchor(_ anchorData: CloudGeoAnchorData) async throws {
        let url = URL(string: "\(baseURL)/api/geo-anchors/share")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "object_id": anchorData.objectId,
            "latitude": anchorData.coordinate.latitude,
            "longitude": anchorData.coordinate.longitude,
            "altitude": anchorData.altitude,
            "device_id": anchorData.deviceId,
            "created_at": ISO8601DateFormatter().string(from: anchorData.createdAt)
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        struct ShareResponse: Codable {
            let success: Bool
            let message: String
            let shared_with: Int
        }

        let shareResponse = try decoder.decode(ShareResponse.self, from: data)
        if !shareResponse.success {
            throw APIError.serverError(shareResponse.message)
        }

        print("📤 Shared geo anchor with \(shareResponse.shared_with) other users")
    }

    /// Deletes a geo anchor from the server
    func deleteGeoAnchor(objectId: String) async throws {
        let url = URL(string: "\(baseURL)/api/geo-anchors/\(objectId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        struct DeleteResponse: Codable {
            let success: Bool
            let message: String
        }

        let deleteResponse = try decoder.decode(DeleteResponse.self, from: data)
        if !deleteResponse.success {
            throw APIError.serverError(deleteResponse.message)
        }
    }

    // MARK: - Inventory Management

    func getInventory() async throws -> [[String: Any]] {
        let url = URL(string: "\(baseURL)/api/inventory/\(currentUserID)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to get inventory")
        }

        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.decodingError("Invalid inventory response")
        }

        return jsonArray
    }

    func addInventoryItem(_ item: InventoryItem) async throws {
        let url = URL(string: "\(baseURL)/api/inventory/\(currentUserID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Convert item to server format
        var itemData: [String: Any] = [
            "id": item.id,
            "type": item.type.rawValue,
            "name": item.name,
            "description": item.description,
            "icon": item.icon,
            "obtained_date": ISO8601DateFormatter().string(from: item.obtainedDate)
        ]

        if let sourceNPC = item.sourceNPC {
            itemData["source_npc"] = sourceNPC
        }

        if let mapData = item.mapPieceData {
            itemData["map_piece_data"] = [
                "piece_number": mapData.pieceNumber,
                "total_pieces": mapData.totalPieces,
                "npc_name": mapData.npcName,
                "hint": mapData.hint,
                "approximate_latitude": mapData.approximateLatitude,
                "approximate_longitude": mapData.approximateLongitude,
                "is_first_half": mapData.isFirstHalf,
                "clue": mapData.clue,
                "landmarks": mapData.landmarks
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: itemData)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            throw APIError.serverError("Failed to add inventory item")
        }
    }

    func deleteInventoryItem(itemId: String) async throws {
        let url = URL(string: "\(baseURL)/api/inventory/\(currentUserID)/\(itemId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to delete inventory item")
        }
    }

    func resetPlayerInventory() async throws {
        let url = URL(string: "\(baseURL)/api/inventory/\(currentUserID)/reset")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to reset inventory")
        }
    }
}