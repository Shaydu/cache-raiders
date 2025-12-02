import SwiftUI
import CoreNFC
import ARKit
import RealityKit
import CoreLocation

// MARK: - NFC Writing View
/// Allows users to select a loot box type and write it to an NFC token
struct NFCWritingView: View {
    @Environment(\.dismiss) var dismiss
    private let nfcService = NFCService.shared
    @StateObject private var precisePositioning = PreciseARPositioningService.shared
    @StateObject private var arIntegrationService = NFCARIntegrationService.shared

    @State private var selectedLootType: LootBoxType? = nil
    @State private var isWriting = false
    @State private var writeResult: NFCService.NFCResult?
    @State private var isPositioning = false
    @State private var createdObject: LootBoxLocation?
    @State private var errorMessage: String?
    @State private var currentStep: WritingStep = .selecting
    @State private var arView: ARView?
    @State private var userLocation: CLLocation?

    enum WritingStep {
        case selecting      // User selecting loot type
        case writing        // Writing to NFC token
        case written        // Successfully written, showing result
        case positioning    // Capturing AR position
        case creating       // Creating object via API
        case success        // Object created successfully
        case error          // Error occurred
    }

    private var stepDescription: String {
        switch currentStep {
        case .selecting:
            return "Select the treasure type to write to your NFC token"
        case .writing:
            return "Hold your iPhone near the NFC tag to write treasure data"
        case .written:
            return "Successfully wrote treasure data to NFC tag!"
        case .positioning:
            return "Capturing precise AR coordinates for your treasure..."
        case .creating:
            return "Creating your treasure object..."
        case .success:
            return "Treasure object created! Other players can now find it!"
        case .error:
            return "An error occurred"
        }
    }

    private var stepColor: Color {
        switch currentStep {
        case .selecting: return .blue
        case .writing: return .orange
        case .written: return .green
        case .positioning: return .purple
        case .creating: return .green
        case .success: return .green
        case .error: return .red
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "wave.3.right.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(stepColor)

                        Text("NFC Treasure Writer")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Open Game Mode")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // Step indicator
                    VStack(spacing: 16) {
                        Text(stepDescription)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.primary)
                            .padding(.horizontal)
                    }

                    Spacer()

                    // Main content based on current step
                    ZStack {
                        switch currentStep {
                        case .selecting:
                            lootTypeSelectionView
                        case .writing:
                            writingView
                        case .written:
                            writtenView
                        case .positioning:
                            positioningView
                        case .creating:
                            creatingView
                        case .success:
                            successView
                        case .error:
                            errorView
                        }
                    }

                    Spacer()

                    // Action buttons
                    if currentStep == .selecting || currentStep == .written || currentStep == .error {
                        Button(action: handlePrimaryAction) {
                            HStack {
                                Image(systemName: primaryButtonIcon)
                                Text(primaryButtonText)
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(stepColor)
                            .cornerRadius(12)
                            .shadow(color: stepColor.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.bottom, 40)
                        .disabled(currentStep == .selecting && selectedLootType == nil)
                    }
                }
                .padding(.horizontal, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
            .onAppear {
                setupARView()
            }
            .onDisappear {
                cleanup()
            }
        }
    }

    private var primaryButtonText: String {
        switch currentStep {
        case .selecting: return "Write to NFC Token"
        case .written: return "Place Treasure"
        case .error: return "Try Again"
        default: return ""
        }
    }

    private var primaryButtonIcon: String {
        switch currentStep {
        case .selecting: return "wave.3.right"
        case .written: return "arkit"
        case .error: return "arrow.clockwise"
        default: return ""
        }
    }

    private var lootTypeSelectionView: some View {
        VStack(spacing: 20) {
            Text("Choose Your Treasure")
                .font(.title2)
                .fontWeight(.semibold)

            // Grid of loot types
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(LootBoxType.allCases.filter { $0 != .turkey }, id: \.self) { lootType in
                    LootTypeCard(
                        lootType: lootType,
                        isSelected: selectedLootType == lootType,
                        action: { selectedLootType = lootType }
                    )
                }
            }
            .padding(.horizontal)

            if selectedLootType == nil {
                Text("Select a treasure type above")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    private var writingView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(Color.orange, lineWidth: 4)
                    .frame(width: 120, height: 120)
                    .scaleEffect(1.2)
                    .opacity(0.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(), value: isWriting)

                Image(systemName: "wave.3.right")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
            }

            Text("Writing...")
                .font(.headline)
                .foregroundColor(.orange)

            if let type = selectedLootType {
                Text("Writing: \(type.displayName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var writtenView: some View {
        VStack(spacing: 16) {
            if let result = writeResult {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)

                    Text("NFC Tag Written!")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tag ID:")
                                .fontWeight(.semibold)
                            Text(result.tagId.prefix(12) + "...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if let type = selectedLootType {
                            HStack {
                                Text("Treasure:")
                                    .fontWeight(.semibold)
                                Text(type.displayName)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var positioningView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.purple.opacity(0.3), lineWidth: 4)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(Color.purple, lineWidth: 4)
                    .frame(width: 120, height: 120)
                    .scaleEffect(1.2)
                    .opacity(0.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(), value: currentStep == .positioning)

                Image(systemName: "arkit")
                    .font(.system(size: 40))
                    .foregroundColor(.purple)
            }

            Text("Capturing AR position...")
                .font(.headline)
                .foregroundColor(.purple)

            if let type = selectedLootType {
                Text("Creating: \(type.displayName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var creatingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Creating treasure object...")
                .font(.headline)
                .foregroundColor(.green)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            if let object = createdObject {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)

                    Text("Treasure Created!")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Type:")
                                .fontWeight(.semibold)
                            Text(object.type.displayName)
                                .foregroundColor(.primary)
                        }

                        HStack {
                            Text("Location:")
                                .fontWeight(.semibold)
                            Text(String(format: "%.6f, %.6f",
                                      object.latitude, object.longitude))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity)

                    Text("Other players can now find this treasure!")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Write Failed")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.red)

            if let error = errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal)
    }

    private func setupARView() {
        arView = ARView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        if let arView = arView {
            arIntegrationService.setup(with: arView)
            precisePositioning.setup(with: arView)
        }
    }

    private func handlePrimaryAction() {
        switch currentStep {
        case .selecting:
            startWriting()
        case .written:
            startPositioning()
        case .error:
            resetToSelecting()
        default:
            break
        }
    }

    private func startWriting() {
        guard let lootType = selectedLootType else { return }

        currentStep = .writing
        isWriting = true
        errorMessage = nil

        // Create the message to write
        let message = createTreasureMessage(for: lootType)

        print("🔧 Starting NFC write for \(lootType.displayName)")
        nfcService.writeNFC(message: message) { result in
            DispatchQueue.main.async {
                self.isWriting = false

                switch result {
                case .success(let nfcResult):
                    print("✅ NFC write successful")
                    self.writeResult = nfcResult
                    self.currentStep = .written
                case .failure(let error):
                    print("❌ NFC write failed: \(error)")
                    self.errorMessage = error.localizedDescription
                    self.currentStep = .error
                }
            }
        }
    }

    private func startPositioning() {
        currentStep = .positioning

        // Get current user location
        userLocation = CLLocationManager().location

        // Start AR positioning
        Task {
            do {
                try await captureARPosition()
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to capture AR position: \(error.localizedDescription)"
                    self.currentStep = .error
                }
            }
        }
    }

    private func resetToSelecting() {
        currentStep = .selecting
        selectedLootType = nil
        writeResult = nil
        errorMessage = nil
    }

    private func createTreasureMessage(for lootType: LootBoxType) -> String {
        let treasureData: [String: Any] = [
            "version": "1.0",
            "type": "cache_raiders_treasure",
            "lootType": lootType.rawValue,
            "timestamp": Date().timeIntervalSince1970,
            "tagId": UUID().uuidString
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: treasureData)
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            print("❌ Failed to create JSON message: \(error)")
            return "{}"
        }
    }

    private func captureARPosition() async throws {
        guard let userLocation = userLocation,
              let objectType = selectedLootType,
              let nfcResult = writeResult else {
            throw NSError(domain: "NFCWriting", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Missing location or NFC result"])
        }

        // Create unique object ID
        let objectId = "nfc_\(nfcResult.tagId)_\(Int(Date().timeIntervalSince1970))"

        // Start with GPS coordinates
        var latitude = userLocation.coordinate.latitude
        var longitude = userLocation.coordinate.longitude
        var altitude = userLocation.altitude

        // Try AR precision refinement
        do {
            let positioningService = PreciseARPositioningService.shared
            let preciseCoords = try await positioningService.getSubCentimeterPosition(
                for: nfcResult.tagId,
                objectId: objectId,
                initialLocation: userLocation
            )

            latitude = preciseCoords.latitude
            longitude = preciseCoords.longitude
            altitude = preciseCoords.altitude

            print("🎯 Achieved sub-centimeter precision: \(latitude), \(longitude)")
        } catch {
            print("⚠️ AR precision failed, using GPS coordinates: \(error)")
        }

        // Create the object
        await createObject(id: objectId, type: objectType,
                          latitude: latitude, longitude: longitude, altitude: altitude)
    }

    private func createObject(id: String, type: LootBoxType, latitude: Double, longitude: Double, altitude: Double) async {
        currentStep = .creating

        do {
            let objectData: [String: Any] = [
                "id": id,
                "name": "\(type.displayName) (NFC)",
                "type": type.rawValue,
                "latitude": latitude,
                "longitude": longitude,
                "altitude": altitude,
                "radius": 10.0,
                "created_by": "nfc_writer",
                "grounding_height": 0.0,
                "nfc_tag_id": writeResult?.tagId ?? "",
                "nfc_write_timestamp": Date().timeIntervalSince1970
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: objectData)

            let baseURL = APIService.shared.baseURL
            guard let url = URL(string: "\(baseURL)/api/objects") else {
                throw NSError(domain: "NFCWriting", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "NFCWriting", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            if httpResponse.statusCode == 200 {
                let object = LootBoxLocation(
                    id: id,
                    name: "\(type.displayName) (NFC)",
                    type: type,
                    latitude: latitude,
                    longitude: longitude,
                    radius: 10.0,
                    collected: false,
                    source: .map
                )

                DispatchQueue.main.async {
                    self.createdObject = object
                    self.currentStep = .success

                    // Notify other parts of the app
                    NotificationCenter.default.post(
                        name: NSNotification.Name("NFCObjectCreated"),
                        object: object
                    )
                }
            } else {
                throw NSError(domain: "NFCWriting", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Server returned error: \(httpResponse.statusCode)"])
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create object: \(error.localizedDescription)"
                self.currentStep = .error
            }
        }
    }

    private func cleanup() {
        nfcService.stopScanning()
        arView?.session.pause()
        arView = nil
    }
}

// MARK: - Loot Type Card
struct LootTypeCard: View {
    let lootType: LootBoxType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Icon representation
                ZStack {
                    Circle()
                        .fill(Color(lootType.color).opacity(0.2))
                        .frame(width: 60, height: 60)

                    Circle()
                        .stroke(Color(lootType.color), lineWidth: isSelected ? 3 : 1)
                        .frame(width: 60, height: 60)

                    Image(systemName: iconForLootType(lootType))
                        .font(.system(size: 24))
                        .foregroundColor(Color(lootType.color))
                }

                Text(lootType.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color(lootType.color).opacity(0.1) : Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color(lootType.color) : Color.clear, lineWidth: 2)
                    )
            )
            .shadow(color: isSelected ? Color(lootType.color).opacity(0.3) : Color.clear, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func iconForLootType(_ type: LootBoxType) -> String {
        switch type {
        case .chalice: return "cup.and.saucer.fill"
        case .templeRelic: return "building.columns.fill"
        case .treasureChest: return "shippingbox.fill"
        case .lootChest: return "archivebox.fill"
        case .lootCart: return "cart.fill"
        case .sphere: return "circle.fill"
        case .cube: return "square.fill"
        case .turkey: return "bird.fill"
        }
    }
}

// MARK: - Preview
struct NFCWritingView_Previews: PreviewProvider {
    static var previews: some View {
        NFCWritingView()
    }
}
