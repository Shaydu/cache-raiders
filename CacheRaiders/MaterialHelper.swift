import RealityKit
import UIKit

// MARK: - Material Helper
/// Provides a consistent interface for working with materials across different types
/// Uses UnlitMaterial for emissive-like effects (objects visible regardless of lighting)
class MaterialHelper {
    
    /// Creates a material with emissive-like properties using UnlitMaterial
    /// UnlitMaterial makes objects visible regardless of ambient lighting, simulating emissive behavior
    /// - Parameters:
    ///   - baseMaterial: The original material to base the emissive material on
    ///   - emissiveColor: The color for the emissive glow
    ///   - emissiveIntensity: The intensity of the emissive glow (0.0 to 1.0) - affects color brightness
    /// - Returns: A new material (UnlitMaterial for emissive effect, or SimpleMaterial with brightened color)
    static func createEmissiveMaterial(
        from baseMaterial: Material,
        emissiveColor: UIColor,
        emissiveIntensity: Float
    ) -> Material {
        // Get the base color from the material
        let baseColor = getBaseColor(from: baseMaterial)
        
        // Blend the base color with the emissive color based on intensity
        let blendedColor = blendColor(baseColor, with: emissiveColor, intensity: CGFloat(emissiveIntensity))
        
        // Use UnlitMaterial for true emissive-like effect (always visible regardless of lighting)
        var unlitMaterial = UnlitMaterial()
        unlitMaterial.color = .init(tint: blendedColor)
        
        return unlitMaterial
    }
    
    /// Creates a non-emissive material (converts UnlitMaterial back to SimpleMaterial)
    /// - Parameter baseMaterial: The material to remove emissive properties from
    /// - Returns: A new SimpleMaterial without emissive properties
    static func createNonEmissiveMaterial(from baseMaterial: Material) -> Material {
        // Handle SimpleMaterial - return as-is (already non-emissive)
        if let simpleMaterial = baseMaterial as? SimpleMaterial {
            // Extract the float value from MaterialScalarParameter
            let metallicValue: Float
            switch simpleMaterial.metallic {
            case .float(let value):
                metallicValue = value
            case .texture:
                // For texture-based parameters, default to non-metallic
                metallicValue = 0.0
            }

            let restoredMaterial = SimpleMaterial(
                color: simpleMaterial.color.tint,
                roughness: simpleMaterial.roughness,
                isMetallic: metallicValue > 0.5
            )
            return restoredMaterial
        }
        
        // Handle UnlitMaterial - convert to SimpleMaterial to restore lighting
        if let unlitMaterial = baseMaterial as? UnlitMaterial {
            let simpleMaterial = SimpleMaterial(
                color: unlitMaterial.color.tint,
                roughness: 0.4, // Default roughness
                isMetallic: false
            )
            return simpleMaterial
        }
        
        // For other material types, return as-is
        return baseMaterial
    }
    
    /// Extracts the base color from a material
    static func getBaseColor(from material: Material) -> UIColor {
        if let simpleMaterial = material as? SimpleMaterial {
            return simpleMaterial.color.tint
        }
        if let unlitMaterial = material as? UnlitMaterial {
            return unlitMaterial.color.tint
        }
        return .white // Default fallback
    }
    
    /// Blends two colors together based on intensity
    /// - Parameters:
    ///   - baseColor: The base color
    ///   - blendColor: The color to blend with
    ///   - intensity: The intensity of the blend (0.0 = all base, 1.0 = all blend)
    /// - Returns: The blended color
    private static func blendColor(_ baseColor: UIColor, with blendColor: UIColor, intensity: CGFloat) -> UIColor {
        var baseRed: CGFloat = 0
        var baseGreen: CGFloat = 0
        var baseBlue: CGFloat = 0
        var baseAlpha: CGFloat = 0
        
        var blendRed: CGFloat = 0
        var blendGreen: CGFloat = 0
        var blendBlue: CGFloat = 0
        var blendAlpha: CGFloat = 0
        
        baseColor.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha)
        blendColor.getRed(&blendRed, green: &blendGreen, blue: &blendBlue, alpha: &blendAlpha)
        
        // Blend the colors based on intensity
        let red = baseRed * (1.0 - intensity) + blendRed * intensity
        let green = baseGreen * (1.0 - intensity) + blendGreen * intensity
        let blue = baseBlue * (1.0 - intensity) + blendBlue * intensity
        let alpha = baseAlpha * (1.0 - intensity) + blendAlpha * intensity
        
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

