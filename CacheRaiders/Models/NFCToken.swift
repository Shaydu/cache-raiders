import Foundation
import CoreLocation
import Combine

// MARK: - NFCToken Model
struct NFCToken: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let type: LootBoxType
    let latitude: Double
    let longitude: Double
    let createdBy: String
    let createdAt: Date
    let nfcTagId: String
    let message: String?
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
    
    // MARK: - Coding Keys
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case latitude
        case longitude
        case createdBy = "created_by"
        case createdAt = "created_at"
        case nfcTagId = "nfc_tag_id"
        case message
    }
    
    // MARK: - Initializers
    init(id: String, name: String, type: LootBoxType, latitude: Double, longitude: Double, 
         createdBy: String, createdAt: Date, nfcTagId: String, message: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.nfcTagId = nfcTagId
        self.message = message
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(LootBoxType.self, forKey: .type)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        
        // Handle date decoding from string
        let dateString = try container.decode(String.self, forKey: .createdAt)
        if let date = ISO8601DateFormatter().date(from: dateString) {
            createdAt = date
        } else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, 
                in: container, 
                debugDescription: "Date string does not match format expected by formatter.")
        }
        
        nfcTagId = try container.decode(String.self, forKey: .nfcTagId)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(ISO8601DateFormatter().string(from: createdAt), forKey: .createdAt)
        try container.encode(nfcTagId, forKey: .nfcTagId)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

// MARK: - NFCToken Response
struct NFCTokenResponse: Codable {
    let tokens: [NFCToken]
}

// MARK: - NFCToken Service
class NFCTokenService: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    init() {}

    static let shared = NFCTokenService()
    
    private let apiService = APIService.shared
    
    func getAllTokens() async throws -> [NFCToken] {
        // This would call a new API endpoint to get all NFC tokens
        // For now, we'll return an empty array as a placeholder
        return []
    }
    
    func getToken(byId id: String) async throws -> NFCToken? {
        // This would call a new API endpoint to get a specific NFC token
        // For now, return nil as a placeholder
        return nil
    }
    
    func getTokens(byUser userId: String) async throws -> [NFCToken] {
        // This would call a new API endpoint to get tokens by user
        // For now, return empty array as a placeholder
        return []
    }
}
