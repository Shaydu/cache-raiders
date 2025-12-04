import SwiftUI
import RealityKit
import ARKit
import Combine

// MARK: - NFCToken Detail View
struct NFCTokenDetailView: View {
    let token: NFCToken
    @State private var rotationAngle: Double = 0
    @State private var timer: Timer?
    @Environment(\ .dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 3D Model with rotation
                    ZStack {
                        RealityView { content in
                            // Load the 3D model based on token type
                            if let modelEntity = loadModelEntity(for: token.type) {
                                // Center the model
                                modelEntity.position = [0, 0, 0]
                                
                                // Add rotation component
                                var transform = modelEntity.transform
                                transform.rotation = simd_quatf(angle: Float(rotationAngle * .pi / 180), 
                                                              axis: [0, 1, 0])
                                modelEntity.transform = transform
                                
                                content.add(modelEntity)
                            }
                        }
                        .frame(height: 300)
                        .padding()
                        
                        // Rotation indicator
                        Circle()
                            .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                            .frame(width: 280, height: 280)
                    }
                    
                    // Token Metadata
                    VStack(alignment: .leading, spacing: 12) {
                        Text(token.name)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        HStack {
                            Image(systemName: "cube")
                            Text(token.type.displayName)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "person")
                            Text("Placed by: \(token.createdBy)")
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "calendar")
                            Text("Placed: \(formattedDate(token.createdAt))")
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "mappin")
                            Text("Location: \(String(format: "%.6f", token.latitude)), \(String(format: "%.6f", token.longitude))")
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        
                        if let message = token.message, !message.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Message:")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(message)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    .padding(.horizontal)
                    
                    // NFC Tag Info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NFC Tag ID:")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(token.nfcTagId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("NFC Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                startRotation()
            }
            .onDisappear {
                stopRotation()
            }
        }
    }
    
    // MARK: - 3D Model Loading
    private func loadModelEntity(for type: LootBoxType) -> ModelEntity? {
        // This would load the appropriate 3D model based on the token type
        // For now, we'll create a simple placeholder model
        let mesh = MeshResource.generateBox(size: 0.1)
        let material = SimpleMaterial(color: .blue, roughness: 0.5, isMetallic: true)
        let modelEntity = ModelEntity(mesh: mesh, materials: [material])
        
        return modelEntity
    }
    
    // MARK: - Rotation Animation
    private func startRotation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            withAnimation(.linear(duration: 0.016)) {
                rotationAngle += 1
                if rotationAngle >= 360 {
                    rotationAngle = 0
                }
            }
        }
    }
    
    private func stopRotation() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Date Formatting
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview
struct NFCTokenDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleToken = NFCToken(
            id: "test-nfc-123",
            name: "Ancient Chalice",
            type: .chalice,
            latitude: 37.7749,
            longitude: -122.4194,
            createdBy: "adventure_seeker",
            createdAt: Date(),
            nfcTagId: "NFC-ABC123DEF456",
            message: "This ancient chalice was discovered near the old temple ruins."
        )
        
        return NFCTokenDetailView(token: sampleToken)
    }
}
