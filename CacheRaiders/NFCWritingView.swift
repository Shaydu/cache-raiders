import SwiftUI
import CoreNFC
import ARKit
import RealityKit
import CoreLocation
import AudioToolbox
import UIKit
import Combine


// MARK: - NFC Writing View
/// Allows users to select a loot box type and write it to an NFC token
struct NFCWritingView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
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
    @State private var showARPlacement = false
    @State private var showNFCDiagnostics = false

    enum WritingStep {
        case selecting      // User selecting loot type
        case positioning    // Capturing AR position with coordinates
        case writing        // Writing complete data to NFC token
        case creating       // Creating object via API
        case success        // Object created successfully
        case error          // Error occurred
    }

    private var stepDescription: String {
        switch currentStep {
        case .selecting:
            return "Select the loot type to place"
        case .positioning:
            return "Capturing precise AR position..."
        case .writing:
            return "Writing complete data to NFC tag..."
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
        case .positioning: return .purple
        case .writing: return .orange
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
                        case .positioning:
                            positioningView
                        case .writing:
                            writingView
                        case .creating:
                            creatingView
                        case .success:
                            successView
                        case .error:
                            errorView
                        }
                    }

                    // NFC Diagnostics Button (always visible)
                    Button(action: { showNFCDiagnostics = true }) {
                        HStack {
                            Image(systemName: "wave.3.right.circle")
                            Text("Check NFC Status")
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .padding(.top, 20)

                    Spacer()

                    // Action buttons
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
                    } else if currentStep == .success {
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
            .sheet(isPresented: $showNFCDiagnostics) {
                NFCDiagnosticsSheet(diagnostics: nfcService.getNFCDiagnostics())
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

            Text("Writing complete data...")
                .font(.headline)
                .foregroundColor(.orange)

            if let type = selectedLootType {
                Text("Writing: \(type.displayName) with coordinates")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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

                    Text("NFC Loot Created!")
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

                    Text("NFC tag contains a unique object ID. Complete data including coordinates, timestamps, and creator info is stored securely in the database. Other players can now find this loot!")
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
        // Location will be accessed directly from userLocationManager when needed
        print("📍 Location manager ready: \(userLocationManager.currentLocation != nil ? "✓" : "waiting...")")
    }

    private func handlePrimaryAction() {
        print("🎯 NFCWritingView.handlePrimaryAction: currentStep = \(currentStep)")
        if currentStep == .error {
            resetToSelecting()
        }
    }

    private func startWriting() {
        guard let lootType = selectedLootType else { return }

        // Skip initial NFC writing - go directly to AR positioning first
        print("🎯 Starting AR positioning first, then NFC writing with complete data")
        startPositioning()
    }

    private func startPositioning() {
        currentStep = .positioning

        // Get current user location from the existing location manager
        if let location = userLocationManager.currentLocation {
            print("📍 Got fresh location: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)")
        } else {
            print("⚠️ Location manager has no location yet")
        }

        // Ensure we have a location
        guard let location = userLocationManager.currentLocation else {
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

    private func createLootMessage(for lootType: LootBoxType, with location: CLLocation? = nil, arAnchorData: Data? = nil) -> String {
        guard let location = location else { return "{}" }

        // Create a compact object ID that will be stored on the NFC tag
        // All detailed data (coordinates, timestamps, user info) is stored only in the database
        let objectId = UUID().uuidString.prefix(8)

        // Create a minimal URL that just contains the object ID
        // The full data will be fetched from the server when the tag is read
        let baseURL = APIService.shared.baseURL
        let compactURL = "\(baseURL)/nfc/\(objectId)"

        print("🎯 Creating compact NFC message")
        print("   Object ID: \(objectId)")
        print("   Compact URL: \(compactURL)")
        print("   URL length: \(compactURL.count) characters")
        print("   Detailed data stored in database only")

        // Return the compact URL string - this will be written as an NDEF URI record
        return compactURL
    }

    private func captureARPosition() async throws {
        guard let userLocation = userLocationManager.currentLocation,
              let objectType = selectedLootType else {
            print("❌ Missing required data for AR position capture")
            print("   userLocation: \(userLocationManager.currentLocation != nil ? "✓" : "✗")")
            print("   objectType: \(selectedLootType != nil ? "✓" : "✗")")
            throw NSError(domain: "NFCWriting", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Missing location or loot type"])
        }

        // Note: objectId will be created after NFC writing succeeds
        print("📍 Starting AR position capture for \(objectType.displayName)")

        // CRITICAL IMPROVEMENT: Use GPS with higher precision than before
        // When NFC tag is tapped, we know user is AT that exact location
        // Use the phone's GPS as the placement location with best available accuracy
        let latitude = userLocation.coordinate.latitude
        let longitude = userLocation.coordinate.longitude
        let altitude = userLocation.altitude
        let gpsAccuracy = userLocation.horizontalAccuracy

        print("📍 NFC tap location (GPS):")
        print("   Latitude: \(String(format: "%.8f", latitude))")
        print("   Longitude: \(String(format: "%.8f", longitude))")
        print("   Altitude: \(String(format: "%.2f", altitude))m")
        print("   GPS Accuracy: \(String(format: "%.2f", gpsAccuracy))m")

        // CRITICAL: Try to capture AR camera transform from the active AR session
        // This allows us to store AR offset coordinates for centimeter-level precision
        var arOffsetX: Double? = nil
        var arOffsetY: Double? = nil
        var arOffsetZ: Double? = nil
        var arOriginLat: Double? = nil
        var arOriginLon: Double? = nil

        // Check if we have an active AR session via the integration service
        if let arSession = arIntegrationService.getCurrentARSession(),
           let frame = arSession.currentFrame {
            let cameraTransform = frame.camera.transform
            let cameraPos = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )

            // Store AR position offsets (relative to AR origin)
            arOffsetX = Double(cameraPos.x)
            arOffsetY = Double(cameraPos.y)
            arOffsetZ = Double(cameraPos.z)

            // Store AR origin location (for validating AR coordinates later)
            arOriginLat = latitude  // AR origin is at tap location
            arOriginLon = longitude

            print("✅ Captured AR position offsets for PRECISION placement:")
            print("   AR Offset X: \(String(format: "%.4f", arOffsetX!))m")
            print("   AR Offset Y: \(String(format: "%.4f", arOffsetY!))m")
            print("   AR Offset Z: \(String(format: "%.4f", arOffsetZ!))m")
            print("   💎 This provides centimeter-level accuracy when users are nearby!")
        } else {
            print("ℹ️ No active AR session - using GPS-only positioning")
            print("   For centimeter accuracy, tap NFC while viewing AR mode")
            print("   GPS accuracy: ~\(String(format: "%.1f", gpsAccuracy))m")
        }

        print("📤 Position capture complete. Now writing NFC tag...")

        // Create location object for NFC message
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: gpsAccuracy,
            verticalAccuracy: userLocation.verticalAccuracy,
            timestamp: Date()
        )

        // Write NFC tag with complete data including coordinates and AR offsets
        await writeNFCWithCompleteData(
            for: objectType,
            location: location,
            arOffsetX: arOffsetX,
            arOffsetY: arOffsetY,
            arOffsetZ: arOffsetZ,
            arOriginLat: arOriginLat,
            arOriginLon: arOriginLon
        )
    }

    private func writeNFCWithCompleteData(
        for lootType: LootBoxType,
        location: CLLocation,
        arOffsetX: Double?,
        arOffsetY: Double?,
        arOffsetZ: Double?,
        arOriginLat: Double?,
        arOriginLon: Double?
    ) async {
        currentStep = .writing
        isWriting = true
        errorMessage = nil

        // Create the compact message with just the object ID
        // All detailed data (coordinates, timestamps, user info) is stored only in the database
        let compactMessage = createLootMessage(for: lootType, with: location, arAnchorData: nil)

        print("🔧 Writing compact NFC tag for \(lootType.displayName)")
        print("   Message contains only object ID (detailed data in database)")
        print("   Message length: \(compactMessage.count) characters")

        nfcService.writeNFC(message: compactMessage) { result in
            DispatchQueue.main.async {
                self.isWriting = false

                switch result {
                case .success(let nfcResult):
                    print("✅ NFC write successful - compact object ID stored on tag")
                    self.writeResult = nfcResult

                    // Now create the database object with ALL the detailed data
                    // The NFC tag contains only the minimal identifier
                    Task {
                        await self.createObjectWithCompleteData(
                            type: lootType,
                            location: location,
                            arOffsetX: arOffsetX,
                            arOffsetY: arOffsetY,
                            arOffsetZ: arOffsetZ,
                            arOriginLat: arOriginLat,
                            arOriginLon: arOriginLon,
                            nfcResult: nfcResult,
                            compactMessage: compactMessage
                        )
                    }

                case .failure(let error):
                    print("❌ NFC write failed: \(error)")
                    self.errorMessage = error.localizedDescription
                    self.currentStep = .error
                }
            }
        }
    }

    private func createObjectWithCompleteData(
        type: LootBoxType,
        location: CLLocation,
        arOffsetX: Double?,
        arOffsetY: Double?,
        arOffsetZ: Double?,
        arOriginLat: Double?,
        arOriginLon: Double?,
        nfcResult: NFCService.NFCResult,
        compactMessage: String
    ) async {
        currentStep = .creating

        do {
            // Get current user device ID or username
            let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            let username = UserDefaults.standard.string(forKey: "username") ?? "Player"

            // CRITICAL FIX: Extract the object ID from the compact message URL
            // The compactMessage is in format: "baseURL/nfc/<objectId>"
            // We need to use the SAME objectId that was written to the NFC tag
            let objectId: String
            if let url = URL(string: compactMessage),
               let lastComponent = url.pathComponents.last {
                objectId = lastComponent
                print("✅ Extracted object ID from NFC URL: \(objectId)")
            } else {
                // Fallback to old method if URL parsing fails
                objectId = "nfc_\(nfcResult.tagId)_\(Int(Date().timeIntervalSince1970))"
                print("⚠️ Failed to extract ID from URL, using fallback: \(objectId)")
            }

            // COMPREHENSIVE database object - store all metadata here
            // This matches what was previously written to NFC but now lives in DB
            var objectData: [String: Any] = [
                "id": objectId,
                "name": "\(type.displayName)",
                "type": type.rawValue,
                // GPS coordinates
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                // Object properties
                "radius": 3.0,  // Smaller radius for NFC objects since they're precise
                "grounding_height": 0.0,
                // Creator information
                "created_by": username
            ]

            // CRITICAL: Add AR offset coordinates if captured from active AR session
            // This enables centimeter-level precision when users are nearby
            if let arX = arOffsetX, let arY = arOffsetY, let arZ = arOffsetZ,
               let originLat = arOriginLat, let originLon = arOriginLon {
                objectData["ar_offset_x"] = arX
                objectData["ar_offset_y"] = arY
                objectData["ar_offset_z"] = arZ
                objectData["ar_origin_latitude"] = originLat
                objectData["ar_origin_longitude"] = originLon
                objectData["ar_placement_timestamp"] = ISO8601DateFormatter().string(from: Date())

                print("✅ Including AR offset coordinates for PRECISION placement:")
                print("   AR Origin: (\(String(format: "%.8f", originLat)), \(String(format: "%.8f", originLon)))")
                print("   AR Offsets: X=\(String(format: "%.4f", arX))m, Y=\(String(format: "%.4f", arY))m, Z=\(String(format: "%.4f", arZ))m")
                print("   💎 Objects will appear at EXACT placement location (cm accuracy)!")
            } else {
                print("ℹ️ No AR offsets - using GPS-only positioning (~\(String(format: "%.1f", location.horizontalAccuracy))m accuracy)")
            }

            print("📤 Creating comprehensive database object for NFC loot")
            print("   NFC tag contains: \(compactMessage)")
            print("   Database contains: Full coordinates, timestamps, user info, AR offsets")

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
                // CRITICAL: Object is created with collected: false
                // This means the PLACER does NOT get credit for finding it
                // Other players must scan it using "Scan NFC Token" to register a find
                let object = LootBoxLocation(
                    id: objectId,
                    name: "\(type.displayName)",
                    type: type,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radius: 3.0,  // Match the reduced radius
                    collected: false,  // NOT collected by placer - must be scanned to find
                    source: .map
                )

                DispatchQueue.main.async {
                    self.createdObject = object
                    self.currentStep = .success

                    // CRITICAL: Do NOT add to locationManager here - it will be loaded from API on next refresh
                    // Adding it here causes potential race conditions and duplicate placement
                    // The AR view auto-refreshes from API when entering (ARLootBoxView.swift:184)
                    print("✅ Object saved to database: \(object.name) at (\(object.latitude), \(object.longitude))")
                    print("   Will appear in AR on next API refresh")

                    // Notify other parts of the app to refresh
                    NotificationCenter.default.post(
                        name: NSNotification.Name("NFCObjectCreated"),
                        object: object
                    )

                    // Play success feedback
                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                    impactFeedback.impactOccurred()
                    AudioServicesPlaySystemSound(1103)

                    print("✅ NFC loot object created successfully")
                    print("   NFC tag: Compact object ID only")
                    print("   Database: Full coordinates, timestamps, user info, AR anchors")

                    // Dismiss after short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.dismiss()
                    }
                }
            } else {
                throw NSError(domain: "NFCWriting", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Server error: \(httpResponse.statusCode)"])
            }

        } catch {
            print("❌ Failed to create object: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create object: \(error.localizedDescription)"
                self.currentStep = .error
                self.showARPlacement = false
            }
        }
    }

    private func cleanup() {
        nfcService.stopScanning()
        arView?.session.pause()
        arView = nil
    }
}

// MARK: - NFC Diagnostics Sheet
struct NFCDiagnosticsSheet: View {
    @Environment(\.dismiss) var dismiss
    let diagnostics: NFCService.NFCDiagnostics

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: diagnostics.readingAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(diagnostics.readingAvailable ? .green : .red)
                                .font(.title)
                            Text("NFC Diagnostics")
                                .font(.title)
                                .fontWeight(.bold)
                        }

                        Text(diagnostics.summary)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)

                    // Device Info
                    GroupBox(label: Text("Device Information")) {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Model", value: diagnostics.deviceModel)
                            InfoRow(label: "iOS Version", value: String(format: "%.1f", diagnostics.iosVersion))
                            InfoRow(label: "Likely NFC Device", value: diagnostics.isLikelyNFCDevice ? "Yes" : "No")
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    // NFC Capabilities
                    GroupBox(label: Text("NFC Capabilities")) {
                        VStack(alignment: .leading, spacing: 8) {
                            StatusRow(label: "NFC Reading Available", status: diagnostics.readingAvailable)
                            StatusRow(label: "NDEF Reading Available", status: diagnostics.ndefReadingAvailable)
                            StatusRow(label: "NFC Writing Supported", status: diagnostics.supportsNFCWriting)
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    // Troubleshooting
                    GroupBox(label: Text("Troubleshooting Tips")) {
                        VStack(alignment: .leading, spacing: 12) {
                            if !diagnostics.readingAvailable {
                                Text("• This device doesn't support NFC reading/writing")
                                    .foregroundColor(.red)
                            }

                            if !diagnostics.isLikelyNFCDevice {
                                Text("• Older iPhone models (iPhone 6 and earlier) don't support NFC")
                                    .foregroundColor(.orange)
                            }

                            if !diagnostics.supportsNFCWriting {
                                Text("• NFC writing requires iOS 13.0 or later")
                                    .foregroundColor(.orange)
                            }

                            Text("• Make sure NFC is enabled in Settings > Control Center")
                            Text("• Hold your iPhone steady near the NFC tag")
                            Text("• Clean the NFC area on both the phone and tag")
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
        }
    }
}

// MARK: - Status Row
struct StatusRow: View {
    let label: String
    let status: Bool

    var body: some View {
        HStack {
            Image(systemName: status ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(status ? .green : .red)
            Text(label)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.vertical, 4)
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
        NFCWritingView(locationManager: LootBoxLocationManager(), userLocationManager: UserLocationManager())
    }
}

