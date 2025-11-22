import SwiftUI

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Search Distance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Search Distance: \(Int(locationManager.maxSearchDistance))m")
                            .font(.headline)
                        
                        Slider(
                            value: Binding(
                                get: { locationManager.maxSearchDistance },
                                set: { newValue in
                                    locationManager.maxSearchDistance = newValue
                                    locationManager.saveMaxDistance()
                                }
                            ),
                            in: 10...10000,
                            step: 10
                        )
                        
                        HStack {
                            Text("10m")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("10,000m")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Loot boxes within this distance will appear in AR")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("About") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cache Raiders")
                            .font(.headline)
                        Text("An AR treasure hunting game")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

