// MARK: - Sheet Type Enum
enum SheetType: Identifiable, Equatable {
    case locationConfig
    case arPlacement
    case nfcScanner
    case nfcWriting
    case simpleNFCScanner
    case inventory
    case settings
    case leaderboard
    case skeletonConversation(npcId: String, npcName: String)
    case treasureMap
    case mapView

    var id: String {
        switch self {
        case .locationConfig: return "locationConfig"
        case .arPlacement: return "arPlacement"
        case .nfcScanner: return "nfcScanner"
        case .nfcWriting: return "nfcWriting"
        case .simpleNFCScanner: return "simpleNFCScanner"
        case .inventory: return "inventory"
        case .settings: return "settings"
        case .leaderboard: return "leaderboard"
        case .skeletonConversation(let npcId, _): return "skeletonConversation_\(npcId)"
        case .treasureMap: return "treasureMap"
        case .mapView: return "mapView"
        }
    }
}

