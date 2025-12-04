import SwiftUI

// MARK: - NFC Tokens List View
struct NFCTokensListView: View {
    @StateObject private var tokenService = NFCTokenService()
    @State private var tokens: [NFCToken] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedToken: NFCToken?
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading NFC tokens...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error loading tokens")
                            .font(.headline)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Try Again") {
                            loadTokens()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tokens.isEmpty {
                    VStack {
                        Image(systemName: "nfc")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No NFC Tokens Found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Scan or create NFC tokens to see them here.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(tokens) { token in
                        NavigationLink(destination: NFCTokenDetailView(token: token)) {
                            NFCTokenRow(token: token)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("NFC Tokens")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: loadTokens) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                loadTokens()
            }
        }
    }
    
    private func loadTokens() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let fetchedTokens = try await tokenService.getAllTokens()
                await MainActor.run {
                    self.tokens = fetchedTokens
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - NFC Token Row
struct NFCTokenRow: View {
    let token: NFCToken
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon based on token type
            Image(systemName: iconName(for: token.type))
                .font(.title3)
                .foregroundColor(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(token.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Placed by \(token.createdBy)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text(formattedDate(token.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }
    
    private func iconName(for type: LootBoxType) -> String {
        switch type {
        case .chalice: return "cup.and.saucer"
        case .templeRelic: return "building.columns"
        case .treasureChest: return "shippingbox"
        case .lootChest: return "shippingbox.fill"
        case .lootCart: return "cart"
        case .sphere: return "circle"
        case .cube: return "cube"
        case .turkey: return "bird"
        }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview
struct NFCTokensListView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleTokens = [
            NFCToken(
                id: "nfc-1",
                name: "Ancient Chalice",
                type: .chalice,
                latitude: 37.7749,
                longitude: -122.4194,
                createdBy: "adventure_seeker",
                createdAt: Date().addingTimeInterval(-86400), // 1 day ago
                nfcTagId: "NFC-ABC123",
                message: "Found near the temple"
            ),
            NFCToken(
                id: "nfc-2",
                name: "Temple Relic",
                type: .templeRelic,
                latitude: 37.7750,
                longitude: -122.4195,
                createdBy: "treasure_hunter",
                createdAt: Date().addingTimeInterval(-172800), // 2 days ago
                nfcTagId: "NFC-DEF456",
                message: "Ancient artifact"
            )
        ]
        
        // Mock service for preview
        let mockService = NFCTokenService()
        
        return NFCTokensListView()
    }
}
