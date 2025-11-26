import SwiftUI
import ARKit

// MARK: - AR Lens Selector
/// A compact lens selector UI component for the AR view
struct ARLensSelector: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @State private var showLensPicker = false
    @State private var availableLenses: [ARLensHelper.LensOption] = []
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Lens button
            Button(action: {
                showLensPicker.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .font(.caption)
                    if let selectedLens = getSelectedLens() {
                        // Truncate long names for compact button display
                        let displayName = selectedLens.name.count > 20 
                            ? String(selectedLens.name.prefix(17)) + "..."
                            : selectedLens.name
                        Text(displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    } else {
                        Text("Ultra Wide")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(10)
            }
            
            // Lens picker menu
            if showLensPicker && !availableLenses.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(availableLenses) { lens in
                        Button(action: {
                            print("📷 User selected lens: \(lens.name) (ID: \(lens.id))")
                            locationManager.setSelectedARLens(lens.id)
                            showLensPicker = false
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lens.name)
                                        .font(.caption)
                                        .foregroundColor(.white)
                                    if !lens.fovDescription.isEmpty {
                                        Text(lens.fovDescription)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                                Spacer()
                                if isLensSelected(lens) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isLensSelected(lens) ? Color.blue.opacity(0.3) : Color.clear)
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .frame(minWidth: 180, maxWidth: 250)
            }
        }
        .task {
            // Use task instead of onAppear for async operations
            // This ensures state modifications happen outside the view update cycle
            await loadAvailableLenses()
        }
    }
    
    @State private var hasInitialized = false
    
    private func loadAvailableLenses() async {
        // Prevent multiple initializations
        guard !hasInitialized else { return }
        
        // Load available lenses on background thread
        let lenses = ARLensHelper.getAvailableLenses()
        
        // Update UI state on main thread, but outside view update cycle
        await MainActor.run {
            availableLenses = lenses
            hasInitialized = true
            
            // If no lens is selected and we have available lenses, select the default
            // This happens asynchronously, outside the view update cycle
            // Only set default if no lens is currently selected (don't override user choice)
            if locationManager.selectedARLens == nil, let defaultLens = ARLensHelper.getDefaultLens() {
                locationManager.setSelectedARLens(defaultLens.id)
            }
        }
    }
    
    private func getSelectedLens() -> ARLensHelper.LensOption? {
        guard let selectedId = locationManager.selectedARLens else {
            return ARLensHelper.getDefaultLens()
        }
        return availableLenses.first { $0.id == selectedId }
    }
    
    private func isLensSelected(_ lens: ARLensHelper.LensOption) -> Bool {
        // If a lens is explicitly selected, check by ID
        if let selectedId = locationManager.selectedARLens {
            return lens.id == selectedId
        }
        // If no lens selected, check if this is the default (ultraWide - widest)
        // Check both exact match and prefix match for different ID formats
        if lens.id == "ultraWide" || lens.id.starts(with: "ultraWide") {
            // If there are multiple ultra wide options, prefer the highest quality one
            if let defaultLens = ARLensHelper.getDefaultLens() {
                return lens.id == defaultLens.id
            }
            return true
        }
        // Fallback to wide if ultraWide not available
        if lens.id == "wide" || lens.id.starts(with: "wide") {
            if let defaultLens = ARLensHelper.getDefaultLens() {
                return lens.id == defaultLens.id
            }
            return true
        }
        return false
    }
}

