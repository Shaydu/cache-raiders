import Foundation
import ARKit

// MARK: - AR Lens Helper
/// Helper for managing AR camera lens selection
struct ARLensHelper {
    /// Represents an available AR camera lens
    struct LensOption: Identifiable, Hashable {
        let id: String // Camera type identifier (e.g., "wide", "ultraWide", "telephoto")
        let name: String // Display name
        let videoFormat: ARConfiguration.VideoFormat
        
        static func == (lhs: LensOption, rhs: LensOption) -> Bool {
            lhs.id == rhs.id
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
    
    /// Camera type enum for grouping
    private enum CameraType: String, CaseIterable {
        case ultraWide = "ultraWide"
        case wide = "wide"
        case telephoto = "telephoto"
        
        var displayName: String {
            switch self {
            case .ultraWide: return "Ultra Wide"
            case .wide: return "Wide"
            case .telephoto: return "Telephoto"
            }
        }
        
        var sortOrder: Int {
            switch self {
            case .ultraWide: return 0
            case .wide: return 1
            case .telephoto: return 2
            }
        }
    }
    
    /// Identify camera type from video format
    private static func identifyCameraType(from format: ARConfiguration.VideoFormat) -> CameraType {
        let resolution = format.imageResolution
        let width = resolution.width
        let height = resolution.height
        let totalPixels = width * height
        let aspectRatio = Double(width) / Double(height)
        
        // Improved heuristics based on resolution, aspect ratio, and frame rate
        // ARKit typically provides formats from different physical cameras
        
        // Ultra-wide cameras typically have:
        // - Lower pixel count (< 2.5M pixels) OR
        // - Very wide aspect ratio (> 2.0) OR
        // - Lower frame rates (30fps or less) with lower resolution
        if totalPixels < 2_500_000 || aspectRatio > 2.0 || (format.framesPerSecond <= 30 && totalPixels < 4_000_000) {
            return .ultraWide
        }
        
        // Telephoto cameras typically have:
        // - Very high pixel count (> 10M pixels) OR
        // - 4K resolution (3840x2160 or similar) OR
        // - High resolution with high frame rate
        if totalPixels > 10_000_000 || width >= 3840 || (totalPixels > 6_000_000 && format.framesPerSecond >= 60) {
            return .telephoto
        }
        
        // Default to wide (most common for AR)
        // Wide cameras typically have:
        // - Medium to high resolution (2.5M - 10M pixels)
        // - Standard aspect ratios (1.3 - 1.8)
        // - Often support 60fps
        return .wide
    }
    
    /// Get all available lens options for the current device (one per camera type)
    static func getAvailableLenses() -> [LensOption] {
        guard ARWorldTrackingConfiguration.isSupported else {
            print("⚠️ AR World Tracking not supported on this device")
            return []
        }
        
        let supportedFormats = ARWorldTrackingConfiguration.supportedVideoFormats
        print("📷 Found \(supportedFormats.count) supported AR video formats")
        
        // Log all available formats for debugging
        for (index, format) in supportedFormats.enumerated() {
            let resolution = format.imageResolution
            let totalPixels = resolution.width * resolution.height
            let aspectRatio = Double(resolution.width) / Double(resolution.height)
            let cameraType = identifyCameraType(from: format)
            print("   [\(index)] \(cameraType.displayName): \(resolution.width)x\(resolution.height) (\(String(format: "%.1f", Double(totalPixels)/1_000_000))M pixels), \(format.framesPerSecond)fps, aspect: \(String(format: "%.2f", aspectRatio))")
        }
        
        // Group formats by camera type and pick the best one from each group
        var bestFormatsByType: [CameraType: ARConfiguration.VideoFormat] = [:]
        
        for format in supportedFormats {
            let cameraType = identifyCameraType(from: format)
            let resolution = format.imageResolution
            let totalPixels = resolution.width * resolution.height
            let fps = format.framesPerSecond
            
            // If we don't have a format for this camera type yet, or this one is better
            if let existingFormat = bestFormatsByType[cameraType] {
                let existingResolution = existingFormat.imageResolution
                let existingPixels = existingResolution.width * existingResolution.height
                let existingFps = existingFormat.framesPerSecond
                
                // Prefer higher resolution, then higher fps
                if totalPixels > existingPixels || 
                   (totalPixels == existingPixels && fps > existingFps) {
                    bestFormatsByType[cameraType] = format
                }
            } else {
                bestFormatsByType[cameraType] = format
            }
        }
        
        print("📷 Detected \(bestFormatsByType.count) camera type(s): \(bestFormatsByType.keys.map { $0.displayName }.joined(separator: ", "))")
        
        // Convert to lens options, sorted by camera type order
        var lenses: [LensOption] = []
        for cameraType in CameraType.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let format = bestFormatsByType[cameraType] {
                let resolution = format.imageResolution
                lenses.append(LensOption(
                    id: cameraType.rawValue,
                    name: cameraType.displayName,
                    videoFormat: format
                ))
                print("✅ Added lens option: \(cameraType.displayName) (\(resolution.width)x\(resolution.height) @ \(format.framesPerSecond)fps)")
            }
        }
        
        // If we only detected one camera type, it might be that the device only supports one
        // or our heuristics need improvement. Show all formats as separate options as fallback.
        if lenses.count == 1 && supportedFormats.count > 1 {
            print("⚠️ Only one camera type detected but multiple formats available. Showing all formats as options.")
            // Create separate options for each format with resolution info
            var fallbackLenses: [LensOption] = []
            for (index, format) in supportedFormats.enumerated() {
                let resolution = format.imageResolution
                let cameraType = identifyCameraType(from: format)
                fallbackLenses.append(LensOption(
                    id: "\(cameraType.rawValue)_\(index)",
                    name: "\(cameraType.displayName) (\(resolution.width)x\(resolution.height))",
                    videoFormat: format
                ))
            }
            return fallbackLenses
        }
        
        return lenses
    }
    
    /// Get the video format for a given lens identifier
    static func getVideoFormat(for lensId: String?) -> ARConfiguration.VideoFormat? {
        guard let lensId = lensId else {
            return nil // Use default
        }
        
        guard ARWorldTrackingConfiguration.isSupported else {
            return nil
        }
        
        // Find the lens option with this ID
        let availableLenses = getAvailableLenses()
        return availableLenses.first { $0.id == lensId }?.videoFormat
    }
    
    /// Get the default lens option (wide angle, if available)
    static func getDefaultLens() -> LensOption? {
        let lenses = getAvailableLenses()
        // Prefer "Wide" lens, fallback to first available
        return lenses.first { $0.id == "wide" } ?? lenses.first
    }
}
