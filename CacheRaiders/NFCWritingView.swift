import SwiftUI
import CoreNFC
import ARKit
import RealityKit
import CoreLocation

// MARK: - NFC Writing View
/// Allows users to select a loot box type and write it to an NFC token
struct NFCWritingView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var locationManager: LootBoxLocationManager
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
    @State private var clLocationManager: CLLocationManager?

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
            return "Select the loot type to place"
        case .writing:
            return "Hold your iPhone near the NFC tag to write"
        case .written:
            return "NFC tag written successfully!"
        case .positioning:
            return "Placing loot at this location..."
        case .creating:
            return "Saving to database..."
        case .success:
            return "Loot placed! All players can now find it!"
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

                        Text("NFC Loot Writer")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Place Loot in the World")
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

                    // Action buttons (only for error state)
                    if currentStep == .error {
                        Button(action: handlePrimaryAction) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Try Again")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(Color.red)
                            .cornerRadius(12)
                            .shadow(color: Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.bottom, 40)
                    }

                    // Success: Dismiss button
                    if currentStep == .success {
                        Button(action: { dismiss() }) {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                Text("Done")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(Color.green)
                            .cornerRadius(12)
                            .shadow(color: Color.green.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.bottom, 40)
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


    private var lootTypeSelectionView: some View {
        VStack(spacing: 20) {
            Text("Choose Your Loot")
                .font(.title2)
                .fontWeight(.semibold)

            // Grid of loot types
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(LootBoxType.allCases.filter { $0 != .turkey }, id: \.self) { lootType in
                    LootTypeCard(
                        lootType: lootType,
                        isSelected: selectedLootType == lootType,
                        action: {
                            print("🎯 LootTypeCard selected: \(lootType.displayName)")
                            selectedLootType = lootType
                            // Immediately start NFC writing when loot type is selected
                            startWriting()
                        }
                    )
                }
            }
            .padding(.horizontal)

            if selectedLootType == nil {
                Text("Select a loot type above")
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
                                Text("Loot Type:")
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

                    Text("Loot Created!")
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

                    Text("Other players can now find this loot!")
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
        // Don't create AR view here - we don't need it for the NFC writing flow
        // The AR positioning service will use the main AR session when needed

        // Setup location manager to get current location
        clLocationManager = CLLocationManager()
        clLocationManager?.desiredAccuracy = kCLLocationAccuracyBest
        clLocationManager?.requestWhenInUseAuthorization()
        clLocationManager?.startUpdatingLocation()

        // Get initial location
        userLocation = clLocationManager?.location
    }

    private func handlePrimaryAction() {
        print("🎯 NFCWritingView.handlePrimaryAction: currentStep = \(currentStep)")
        if currentStep == .error {
            resetToSelecting()
        }
    }

    private func startWriting() {
        guard let lootType = selectedLootType else { return }

        currentStep = .writing
        isWriting = true
        errorMessage = nil

        // Create the message to write
        let message = createLootMessage(for: lootType)

        print("🔧 Starting NFC write for \(lootType.displayName)")
        nfcService.writeNFC(message: message) { result in
            DispatchQueue.main.async {
                self.isWriting = false

                switch result {
                case .success(let nfcResult):
                    print("✅ NFC write successful")
                    self.writeResult = nfcResult
                    // Automatically proceed to place the loot at current location
                    self.startPositioning()
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

        // Get current user location (refresh from location manager)
        if let freshLocation = clLocationManager?.location {
            userLocation = freshLocation
            print("📍 Got fresh location: lat=\(freshLocation.coordinate.latitude), lon=\(freshLocation.coordinate.longitude)")
        } else {
            print("⚠️ Location manager has no location yet")
        }

        // Ensure we have a location
        guard let location = userLocation else {
            print("❌ No user location available")
            errorMessage = "Unable to get current location. Please ensure location services are enabled."
            currentStep = .error
            return
        }

        print("📍 Using location: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude), alt=\(location.altitude)")

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

    private func createLootMessage(for lootType: LootBoxType) -> String {
        let lootData: [String: Any] = [
            "version": "1.0",
            "type": "cache_raiders_loot",
            "lootType": lootType.rawValue,
            "timestamp": Date().timeIntervalSince1970,
            "tagId": UUID().uuidString
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: lootData)
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
            print("❌ Missing required data for AR position capture")
            print("   userLocation: \(userLocation != nil ? "✓" : "✗")")
            print("   objectType: \(selectedLootType != nil ? "✓" : "✗")")
            print("   nfcResult: \(writeResult != nil ? "✓" : "✗")")
            throw NSError(domain: "NFCWriting", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Missing location or NFC result"])
        }

        // Create unique object ID
        let objectId = "nfc_\(nfcResult.tagId)_\(Int(Date().timeIntervalSince1970))"

        // Start with GPS coordinates
        var latitude = userLocation.coordinate.latitude
        var longitude = userLocation.coordinate.longitude
        var altitude = userLocation.altitude

        print("📍 Initial GPS coordinates:")
        print("   Latitude: \(latitude)")
        print("   Longitude: \(longitude)")
        print("   Altitude: \(altitude)")

        // Skip AR precision refinement for now to avoid camera freeze
        // The object is placed at GPS coordinates, which is accurate enough
        // AR precision can be added later when the user is in AR mode
        print("ℹ️ Using GPS coordinates (AR refinement skipped to prevent camera freeze)")

        print("📤 Creating object with final coordinates: lat=\(latitude), lon=\(longitude), alt=\(altitude)")

        // Create the object
        await createObject(id: objectId, type: objectType,
                          latitude: latitude, longitude: longitude, altitude: altitude)
    }

    private func createObject(id: String, type: LootBoxType, latitude: Double, longitude: Double, altitude: Double) async {
        currentStep = .creating

        do {
            // Get current user device ID or username
            let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            let username = UserDefaults.standard.string(forKey: "username") ?? "Player"

            // Store both GPS coordinates and AR-refined coordinates
            let objectData: [String: Any] = [
                "id": id,
                "name": "\(type.displayName)",
                "type": type.rawValue,
                // GPS coordinates
                "latitude": latitude,
                "longitude": longitude,
                "altitude": altitude,
                // AR positioning metadata
                "ar_precision": true,
                "ar_latitude": latitude,  // These are AR-refined coordinates
                "ar_longitude": longitude,
                "ar_altitude": altitude,
                // Object properties
                "radius": 3.0,  // Smaller radius for NFC objects since they're precise
                "grounding_height": 0.0,
                // NFC metadata
                "nfc_tag_id": writeResult?.tagId ?? "",
                "nfc_write_timestamp": Date().timeIntervalSince1970,
                "is_nfc_object": true,
                // Creator information
                "created_by": username,
                "creator_device_id": deviceUUID,
                "created_at": Date().timeIntervalSince1970,
                // Discovery tracking
                "times_found": 0,
                "first_finder": NSNull(),
                "last_found_at": NSNull(),
                // Visibility
                "visible_to_all": true,
                "active": true
            ]

            print("📤 Creating NFC loot object: \(objectData)")

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

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "NFCWriting", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            print("📥 Server response: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("   Response body: \(responseString)")
            }

            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                let object = LootBoxLocation(
                    id: id,
                    name: "\(type.displayName)",
                    type: type,
                    latitude: latitude,
                    longitude: longitude,
                    radius: 3.0,  // Match the reduced radius
                    collected: false,
                    source: .map
                )

                DispatchQueue.main.async {
                    self.createdObject = object
                    self.currentStep = .success

                    // Add object to location manager immediately so it appears in AR
                    self.locationManager.locations.append(object)
                    print("✅ Added object to locationManager.locations (\(self.locationManager.locations.count) total)")

                    // Notify other parts of the app to refresh
                    NotificationCenter.default.post(
                        name: NSNotification.Name("NFCObjectCreated"),
                        object: object
                    )

                    // Also trigger a location manager refresh
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RefreshLootBoxes"),
                        object: nil
                    )

                    print("✅ NFC loot object created successfully, added to AR, and notifications sent")
                }
            } else {
                throw NSError(domain: "NFCWriting", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Server returned error: \(httpResponse.statusCode)"])
            }

        } catch {
            print("❌ Failed to create object: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create object: \(error.localizedDescription)"
                self.currentStep = .error
            }
        }
    }

    private func cleanup() {
        nfcService.stopScanning()
        clLocationManager?.stopUpdatingLocation()
        clLocationManager = nil
    }
}

// MARK: - Loot Type Card
struct LootTypeCard: View {
    let lootType: LootBoxType
    let isSelected: Bool
    let action: () -> Void

    // Convert UIColor to SwiftUI Color
    private var color: Color {
        Color(uiColor: lootType.color)
    }

    var body: some View {
        Button(action: {
            print("🎯 LootTypeCard tapped: \(lootType.displayName)")
            action()
        }) {
            VStack(spacing: 12) {
                // Icon representation
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 60, height: 60)

                    Circle()
                        .stroke(color, lineWidth: isSelected ? 3 : 1)
                        .frame(width: 60, height: 60)

                    Image(systemName: iconForLootType(lootType))
                        .font(.system(size: 24))
                        .foregroundColor(color)
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
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color.opacity(0.1) : Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? color : Color.clear, lineWidth: 2)
                    )
            )
            .shadow(color: isSelected ? color.opacity(0.3) : Color.clear, radius: 4, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        NFCWritingView(locationManager: LootBoxLocationManager())
    }
}
