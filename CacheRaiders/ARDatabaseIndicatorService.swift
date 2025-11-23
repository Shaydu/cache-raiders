import Foundation
import RealityKit
import ARKit

// MARK: - AR Database Indicator Service
/// Handles adding visual indicators (orange icons) above objects that come from the shared database
class ARDatabaseIndicatorService {
    
    /// Add an orange icon above objects that come from the shared database
    /// This helps users distinguish between local-only objects and shared database objects
    func addDatabaseIndicator(to anchor: AnchorEntity, location: LootBoxLocation, in arView: ARView) {
        // Check if this object exists in the API database
        Task {
            do {
                let apiObject = try await APIService.shared.getObject(id: location.id)
                // Object exists in database - add orange indicator
                await MainActor.run {
                    self.createIndicatorEntity(for: location, on: anchor)
                    Swift.print("🟠 Added database indicator above '\(location.name)' (ID: \(location.id))")
                }
            } catch {
                // Object doesn't exist in database or API check failed - no indicator
                // This is expected for local-only objects
            }
        }
    }
    
    /// Remove database indicator for a specific location
    func removeDatabaseIndicator(from anchor: AnchorEntity, locationId: String) {
        // Find and remove the indicator entity
        if let indicator = anchor.children.first(where: { $0.name == "database_indicator_\(locationId)" }) {
            indicator.removeFromParent()
            Swift.print("🟠 Removed database indicator for location ID: \(locationId)")
        }
    }
    
    /// Remove all database indicators from an anchor
    func removeAllDatabaseIndicators(from anchor: AnchorEntity) {
        let indicators = anchor.children.filter { $0.name.hasPrefix("database_indicator_") }
        for indicator in indicators {
            indicator.removeFromParent()
        }
        if !indicators.isEmpty {
            Swift.print("🟠 Removed \(indicators.count) database indicator(s)")
        }
    }
    
    // MARK: - Private Methods
    
    private func createIndicatorEntity(for location: LootBoxLocation, on anchor: AnchorEntity) {
        // Create a small orange sphere above the object
        let indicatorRadius: Float = 0.05 // 5cm sphere
        let indicatorMesh = MeshResource.generateSphere(radius: indicatorRadius)
        var indicatorMaterial = SimpleMaterial()
        indicatorMaterial.color = .init(tint: .orange)
        indicatorMaterial.roughness = 0.2
        indicatorMaterial.metallic = 0.0
        
        let indicator = ModelEntity(mesh: indicatorMesh, materials: [indicatorMaterial])
        indicator.name = "database_indicator_\(location.id)"
        
        // Position indicator 0.3m above the object
        indicator.position = SIMD3<Float>(0, 0.3, 0)
        
        // Add point light to make it more visible
        let light = PointLightComponent(color: .orange, intensity: 100)
        indicator.components.set(light)
        
        anchor.addChild(indicator)
    }
}


