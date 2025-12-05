import Foundation

// MARK: - NPC Types
/// Shared enum for NPC types used across the AR system
enum NPCType: String, CaseIterable {
    case skeleton = "skeleton"
    case corgi = "corgi"

    var modelName: String {
        switch self {
        case .skeleton: return "Curious_skeleton"
        case .corgi: return "Corgi_Traveller"
        }
    }

    var npcId: String {
        switch self {
        case .skeleton: return "skeleton-1"
        case .corgi: return "corgi-1"
        }
    }

    var defaultName: String {
        switch self {
        case .skeleton: return "Captain Bones"
        case .corgi: return "Corgi Traveller"
        }
    }

    var npcType: String {
        switch self {
        case .skeleton: return "skeleton"
        case .corgi: return "traveller"
        }
    }

    var isSkeleton: Bool {
        return self == .skeleton
    }
}









