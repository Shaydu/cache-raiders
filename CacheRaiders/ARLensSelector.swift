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
                        Text(selectedLens.name)
                            .font(.caption)
                            .fontWeight(.medium)
                    } else {
                        Text("Wide")
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
                            locationManager.setSelectedARLens(lens.id)
                            showLensPicker = false
                        }) {
                            HStack {
                                Text(lens.name)
                                    .font(.caption)
                                    .foregroundColor(.white)
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
                .frame(width: 140)
            }
        }
        .onAppear {
            loadAvailableLenses()
        }
    }
    
    private func loadAvailableLenses() {
        availableLenses = ARLensHelper.getAvailableLenses()
        // If no lens is selected and we have available lenses, select the default
        // Defer state modification to avoid "Modifying state during view update" warning
        if locationManager.selectedARLens == nil, let defaultLens = ARLensHelper.getDefaultLens() {
            DispatchQueue.main.async {
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
        // If no lens selected, check if this is the default (wide)
        // Only show one as selected - the default wide lens
        if lens.id == "wide" {
            return true
        }
        return false
    }
}

