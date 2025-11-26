import Foundation
import ARKit

// MARK: - AR Lens Helper
/// Helper for managing AR camera lens selection
struct ARLensHelper {
    // Cache for available lenses to avoid re-scanning and re-logging
    private static var cachedLenses: [LensOption]?
    private static var cachedLensesAllFormats: [LensOption]? // Separate cache for all formats mode
    private static var hasLoggedFormats = false
    /// Represents an available AR camera lens
    struct LensOption: Identifiable, Hashable {
        let id: String // Camera type identifier (e.g., "wide", "ultraWide", "telephoto")
        let name: String // Display name
        let videoFormat: ARConfiguration.VideoFormat
        let fovDescription: String // Field of view description
        
        static func == (lhs: LensOption, rhs: LensOption) -> Bool {
            lhs.id == rhs.id
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        /// Get a detailed description including resolution and frame rate
        var detailedDescription: String {
            let resolution = videoFormat.imageResolution
            let fps = videoFormat.framesPerSecond
            return "\(resolution.width)x\(resolution.height) @ \(fps)fps"
        }
        
        /// Get FOV category for sorting (lower = wider FOV)
        var fovOrder: Int {
            if id.starts(with: "ultraWide") { return 0 } // Widest
            if id.starts(with: "wide") { return 1 }      // Medium
            if id.starts(with: "telephoto") { return 2 } // Narrowest
            return 1
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
    
    /// Mode for lens selection: simplified (one per type), keyVariants, or all formats
    enum LensMode {
        case simplified  // Show one format per camera type (best quality)
        case keyVariants // Show highest, lowest resolution, and best 60fps per camera type
        case allFormats  // Show all available formats
    }
    
    /// Get all available lens options for the current device
    /// - Parameter mode: .simplified shows one per camera type, .keyVariants shows key variants, .allFormats shows all formats
    static func getAvailableLenses(mode: LensMode = .keyVariants) -> [LensOption] {
        // Return cached result if available (check appropriate cache based on mode)
        if mode == .allFormats {
            if let cached = cachedLensesAllFormats {
                return cached
            }
        } else {
            if let cached = cachedLenses {
                return cached
            }
        }
        
        guard ARWorldTrackingConfiguration.isSupported else {
            print("⚠️ AR World Tracking not supported on this device")
            return []
        }
        
        let supportedFormats = ARWorldTrackingConfiguration.supportedVideoFormats
        
        // Only log formats once (first time)
        let shouldLog = !hasLoggedFormats
        if shouldLog {
            print("📷 Found \(supportedFormats.count) supported AR video formats")
            
            // Log all available formats for debugging (only once)
            for (index, format) in supportedFormats.enumerated() {
                let resolution = format.imageResolution
                let totalPixels = resolution.width * resolution.height
                let aspectRatio = Double(resolution.width) / Double(resolution.height)
                let cameraType = identifyCameraType(from: format)
                print("   [\(index)] \(cameraType.displayName): \(resolution.width)x\(resolution.height) (\(String(format: "%.1f", Double(totalPixels)/1_000_000))M pixels), \(format.framesPerSecond)fps, aspect: \(String(format: "%.2f", aspectRatio))")
            }
        }
        
        // Helper to get FOV description
        func getFOVDescription(cameraType: CameraType) -> String {
            switch cameraType {
            case .ultraWide: return "Widest FOV (shows most area)"
            case .wide: return "Standard FOV"
            case .telephoto: return "Narrow FOV (zoomed in)"
            }
        }
        
        // Helper to create lens option
        func createLensOption(id: String, name: String, format: ARConfiguration.VideoFormat, cameraType: CameraType) -> LensOption {
            LensOption(
                id: id,
                name: name,
                videoFormat: format,
                fovDescription: getFOVDescription(cameraType: cameraType)
            )
        }
        
        // Mode: show all formats
        if mode == .allFormats {
            var allLenses: [LensOption] = []
            
            // Group formats by camera type for organization
            var formatsByType: [CameraType: [(index: Int, format: ARConfiguration.VideoFormat)]] = [:]
            
            for (index, format) in supportedFormats.enumerated() {
                let cameraType = identifyCameraType(from: format)
                if formatsByType[cameraType] == nil {
                    formatsByType[cameraType] = []
                }
                formatsByType[cameraType]?.append((index: index, format: format))
            }
            
            // Create lens options for each format, grouped by camera type
            for cameraType in CameraType.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                if let formats = formatsByType[cameraType] {
                    for (index, format) in formats {
                        let resolution = format.imageResolution
                        let fps = format.framesPerSecond
                        let totalPixels = resolution.width * resolution.height
                        
                        // Create descriptive name with resolution and fps
                        let name: String
                        if formats.count == 1 {
                            // Only one format for this camera type, use simple name
                            name = cameraType.displayName
                        } else {
                            // Multiple formats, include resolution and fps in name
                            let pixelStr = totalPixels >= 1_000_000 
                                ? String(format: "%.1fM", Double(totalPixels) / 1_000_000)
                                : "\(Int(totalPixels / 1_000))K"
                            name = "\(cameraType.displayName) - \(Int(resolution.width))x\(Int(resolution.height)) @ \(fps)fps"
                        }
                        
                        let lensId = formats.count == 1 
                            ? cameraType.rawValue 
                            : "\(cameraType.rawValue)_\(index)"
                        
                        allLenses.append(createLensOption(
                            id: lensId,
                            name: name,
                            format: format,
                            cameraType: cameraType
                        ))
                    }
                }
            }
            
            // Sort by FOV (ultra wide first), then by resolution (higher first), then fps (higher first)
            allLenses.sort { lhs, rhs in
                if lhs.fovOrder != rhs.fovOrder {
                    return lhs.fovOrder < rhs.fovOrder
                }
                let lhsPixels = lhs.videoFormat.imageResolution.width * lhs.videoFormat.imageResolution.height
                let rhsPixels = rhs.videoFormat.imageResolution.width * rhs.videoFormat.imageResolution.height
                if lhsPixels != rhsPixels {
                    return lhsPixels > rhsPixels
                }
                return lhs.videoFormat.framesPerSecond > rhs.videoFormat.framesPerSecond
            }
            
            if shouldLog {
                print("📷 Showing all \(allLenses.count) formats as lens options")
            }
            
            // Cache the result
            cachedLensesAllFormats = allLenses
            hasLoggedFormats = true
            return allLenses
        }
        
        // Mode: keyVariants - show highest, lowest resolution, and best 60fps per camera type
        if mode == .keyVariants {
            var keyLenses: [LensOption] = []
            
            // Group formats by camera type
            var formatsByType: [CameraType: [ARConfiguration.VideoFormat]] = [:]
            for format in supportedFormats {
                let cameraType = identifyCameraType(from: format)
                if formatsByType[cameraType] == nil {
                    formatsByType[cameraType] = []
                }
                formatsByType[cameraType]?.append(format)
            }
            
            // For each camera type, select key variants
            for cameraType in CameraType.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard let formats = formatsByType[cameraType], !formats.isEmpty else { continue }
                
                // Calculate pixel counts and find key formats
                let formatsWithInfo = formats.map { format -> (format: ARConfiguration.VideoFormat, pixels: Int, fps: Int) in
                    let resolution = format.imageResolution
                    let pixels = resolution.width * resolution.height
                    return (format: format, pixels: pixels, fps: format.framesPerSecond)
                }
                
                // Find highest resolution
                let highestRes = formatsWithInfo.max { $0.pixels < $1.pixels }!
                
                // Find lowest resolution
                let lowestRes = formatsWithInfo.min { $0.pixels < $1.pixels }!
                
                // Find best 60fps format (highest resolution at 60fps)
                let formats60fps = formatsWithInfo.filter { $0.fps == 60 }
                let best60fps = formats60fps.max { $0.pixels < $1.pixels }
                
                // Helper to create lens name with resolution and fps
                func formatName(format: ARConfiguration.VideoFormat, suffix: String? = nil) -> String {
                    let resolution = format.imageResolution
                    let fps = format.framesPerSecond
                    let baseName = cameraType.displayName
                    let resStr = "\(Int(resolution.width))x\(Int(resolution.height))"
                    
                    if let suffix = suffix {
                        return "\(baseName) - \(suffix) (\(resStr) @ \(fps)fps)"
                    } else {
                        // Only add fps if not 30 (most common)
                        if fps == 60 {
                            return "\(baseName) (\(resStr) @ \(fps)fps)"
                        } else if formats.count > 1 {
                            return "\(baseName) (\(resStr))"
                        } else {
                            return baseName
                        }
                    }
                }
                
                // Helper to create unique ID
                func formatId(format: ARConfiguration.VideoFormat, suffix: String) -> String {
                    let resolution = format.imageResolution
                    return "\(cameraType.rawValue)_\(suffix)_\(Int(resolution.width))x\(Int(resolution.height))_\(format.framesPerSecond)fps"
                }
                
                // Add highest resolution format
                let highestResName = highestRes.pixels == lowestRes.pixels && formats.count == 1
                    ? cameraType.displayName
                    : formatName(format: highestRes.format, suffix: formats.count > 1 ? "High" : nil)
                keyLenses.append(createLensOption(
                    id: formats.count == 1 ? cameraType.rawValue : formatId(format: highestRes.format, suffix: "high"),
                    name: highestResName,
                    format: highestRes.format,
                    cameraType: cameraType
                ))
                
                // Add lowest resolution format (if different from highest)
                if highestRes.pixels != lowestRes.pixels {
                    keyLenses.append(createLensOption(
                        id: formatId(format: lowestRes.format, suffix: "low"),
                        name: formatName(format: lowestRes.format, suffix: "Low"),
                        format: lowestRes.format,
                        cameraType: cameraType
                    ))
                }
                
                // Add best 60fps format (if available and different from above)
                if let best60fps = best60fps,
                   best60fps.format != highestRes.format && best60fps.format != lowestRes.format {
                    keyLenses.append(createLensOption(
                        id: formatId(format: best60fps.format, suffix: "60fps"),
                        name: formatName(format: best60fps.format, suffix: "60fps"),
                        format: best60fps.format,
                        cameraType: cameraType
                    ))
                }
            }
            
            // Sort by FOV order, then by resolution (highest first)
            keyLenses.sort { lhs, rhs in
                if lhs.fovOrder != rhs.fovOrder {
                    return lhs.fovOrder < rhs.fovOrder
                }
                let lhsPixels = lhs.videoFormat.imageResolution.width * lhs.videoFormat.imageResolution.height
                let rhsPixels = rhs.videoFormat.imageResolution.width * rhs.videoFormat.imageResolution.height
                return lhsPixels > rhsPixels
            }
            
            if shouldLog {
                print("📷 Showing \(keyLenses.count) key variant formats (highest/lowest resolution + 60fps options per camera type)")
            }
            
            cachedLenses = keyLenses
            hasLoggedFormats = true
            return keyLenses
        }
        
        // Mode: simplified (one per camera type) - pick best quality
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
        
        // Only log detection once
        if shouldLog {
            print("📷 Detected \(bestFormatsByType.count) camera type(s): \(bestFormatsByType.keys.map { $0.displayName }.joined(separator: ", "))")
        }
        
        // Convert to lens options, sorted by camera type order
        var lenses: [LensOption] = []
        for cameraType in CameraType.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let format = bestFormatsByType[cameraType] {
                let resolution = format.imageResolution
                lenses.append(createLensOption(
                    id: cameraType.rawValue,
                    name: cameraType.displayName,
                    format: format,
                    cameraType: cameraType
                ))
                // Only log lens options once
                if shouldLog {
                    print("✅ Added lens option: \(cameraType.displayName) (\(resolution.width)x\(resolution.height) @ \(format.framesPerSecond)fps)")
                }
            }
        }
        
        // If we only detected one camera type, it might be that the device only supports one
        // or our heuristics need improvement. Show all formats as separate options as fallback.
        if lenses.count == 1 && supportedFormats.count > 1 {
            if shouldLog {
                print("⚠️ Only one camera type detected but multiple formats available. Showing all formats as options.")
            }
            // Create separate options for each format with resolution info
            var fallbackLenses: [LensOption] = []
            for (index, format) in supportedFormats.enumerated() {
                let resolution = format.imageResolution
                let cameraType = identifyCameraType(from: format)
                fallbackLenses.append(createLensOption(
                    id: "\(cameraType.rawValue)_\(index)",
                    name: "\(cameraType.displayName) (\(resolution.width)x\(resolution.height))",
                    format: format,
                    cameraType: cameraType
                ))
            }
            cachedLenses = fallbackLenses
            return fallbackLenses
        }
        
        cachedLenses = lenses
        hasLoggedFormats = true // Mark as logged after first run
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
    
    /// Get the default lens option (ultra wide angle - widest, if available)
    static func getDefaultLens() -> LensOption? {
        let lenses = getAvailableLenses()
        
        // Filter for ultra wide lenses (widest FOV)
        let ultraWideLenses = lenses.filter { $0.id.starts(with: "ultraWide") || $0.fovOrder == 0 }
        
        if !ultraWideLenses.isEmpty {
            // Prefer highest resolution ultra wide, or simple "ultraWide" ID if exists
            if let simpleUltraWide = ultraWideLenses.first(where: { $0.id == "ultraWide" }) {
                return simpleUltraWide
            }
            // Otherwise pick highest resolution ultra wide
            return ultraWideLenses.max { lhs, rhs in
                let lhsPixels = lhs.videoFormat.imageResolution.width * lhs.videoFormat.imageResolution.height
                let rhsPixels = rhs.videoFormat.imageResolution.width * rhs.videoFormat.imageResolution.height
                return lhsPixels < rhsPixels
            }
        }
        
        // Fallback to wide lenses
        let wideLenses = lenses.filter { $0.id.starts(with: "wide") || $0.fovOrder == 1 }
        if !wideLenses.isEmpty {
            if let simpleWide = wideLenses.first(where: { $0.id == "wide" }) {
                return simpleWide
            }
            return wideLenses.max { lhs, rhs in
                let lhsPixels = lhs.videoFormat.imageResolution.width * lhs.videoFormat.imageResolution.height
                let rhsPixels = rhs.videoFormat.imageResolution.width * rhs.videoFormat.imageResolution.height
                return lhsPixels < rhsPixels
            }
        }
        
        // Final fallback: first available
        return lenses.first
    }
}
