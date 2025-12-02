import SwiftUI
import ARKit
import RealityKit
import CoreLocation
import CoreNFC

// MARK: - Open Game NFC Scanner View
/// Handles NFC scanning in open game mode to create new objects with high-precision AR coordinates
struct OpenGameNFCScannerView: View {
    @Environment(\.dismiss) var dismiss
    private let nfcService = NFCService.shared
    @StateObject private var precisePositioning = PreciseARPositioningService.shared
    @StateObject private var arIntegrationService = NFCARIntegrationService.shared

    @State private var isScanning = false
    @State private var scanResult: NFCService.NFCResult?
    @State private var assignedObjectType: LootBoxType?
    @State private var isCreatingObject = false
    @State private var createdObject: LootBoxLocation?
    @State private var errorMessage: String?
    @State private var currentStep: ScanningStep = .ready
    @State private var arView: ARView?
    @State private var userLocation: CLLocation?

    enum ScanningStep {
        case ready          // Ready to scan
        case scanning       // NFC scanning in progress
        case analyzing      // Analyzing NFC data and assigning type
        case positioning    // Capturing AR position
        case creating       // Creating object via API
        case success        // Object created successfully
        case error          // Error occurred
    }

    private var stepDescription: String {
        switch currentStep {
        case .ready:
            return "Tap to start scanning an NFC token"
        case .scanning:
            return "Hold your iPhone near an NFC tag to read it"
        case .analyzing:
            return "Analyzing token data and assigning object type..."
        case .positioning:
            return "Capturing precise AR coordinates..."
        case .creating:
            return "Creating new treasure object..."
        case .success:
            return "Treasure object created successfully!"
        case .error:
            return "An error occurred"
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

                        Text("NFC Treasure Scanner")
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

                    // Scanning animation or results
                    ZStack {
                        switch currentStep {
                        case .ready:
                            readyView
                        case .scanning:
                            scanningView
                        case .analyzing:
                            analyzingView
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

                    // Action button
                    if currentStep == .ready || currentStep == .error {
                        Button(action: startScanning) {
                            HStack {
                                Image(systemName: "wave.3.right")
                                Text(currentStep == .ready ? "Start Scanning" : "Try Again")
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
                    }
                }
                .padding(.horizontal, 20)
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
            .onAppear {
                setupARView()
                checkNFCAvailability()
            }
            .onDisappear {
                cleanup()
            }
        }
    }

    private var stepColor: Color {
        switch currentStep {
        case .ready: return .blue
        case .scanning: return .blue
        case .analyzing: return .orange
        case .positioning: return .purple
        case .creating: return .green
        case .success: return .green
        case .error: return .red
        }
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 80))
                .foregroundColor(.blue.opacity(0.5))

            Text("Ready to scan NFC tokens and create new treasures!")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 4)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(Color.blue, lineWidth: 4)
                    .frame(width: 120, height: 120)
                    .scaleEffect(1.2)
                    .opacity(0.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(), value: isScanning)

                Image(systemName: "wave.3.right")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
            }

            Text("Scanning...")
                .font(.headline)
                .foregroundColor(.blue)
        }
    }

    private var analyzingView: some View {
        VStack(spacing: 16) {
            if let result = scanResult {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)

                    Text("NFC Tag Read!")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tag ID:")
                                .fontWeight(.semibold)
                            Text(result.tagId)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if let payload = result.payload {
                            HStack(alignment: .top) {
                                Text("Data:")
                                    .fontWeight(.semibold)
                                Text(payload)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(nil)
                            }
                        } else {
                            Text("No data found - will assign random object type")
                                .font(.body)
                                .foregroundColor(.orange)
                                .italic()
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .transition(.scale.combined(with: .opacity))
            } else {
                ProgressView()
                    .scaleEffect(1.5)
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

            if let objectType = assignedObjectType {
                Text("Creating: \(objectType.displayName)")
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

            Text("Scan Failed")
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

    private func checkNFCAvailability() {
        print("🔍 NFC Availability Debug:")
        print("   - NFCNDEFReaderSession.readingAvailable: \(NFCNDEFReaderSession.readingAvailable)")

        // Check device capabilities
        #if targetEnvironment(simulator)
        print("   - Running on simulator: true")
        #else
        print("   - Running on simulator: false")
        #endif

        // Check iOS version
        let iOSVersion = UIDevice.current.systemVersion
        print("   - iOS Version: \(iOSVersion)")

        // Check device model
        let deviceModel = UIDevice.current.model
        let deviceName = UIDevice.current.name
        print("   - Device Model: \(deviceModel)")
        print("   - Device Name: \(deviceName)")

        if !NFCNDEFReaderSession.readingAvailable {
            var errorDetails = "NFC is not available on this device."

            #if targetEnvironment(simulator)
            errorDetails += " (Running on Simulator - NFC not available in simulator)"
            #else
            if #available(iOS 11.0, *) {
                errorDetails += " (Device should support NFC - iOS 11+ required)"
            } else {
                errorDetails += " (iOS 11+ required for NFC)"
            }
            #endif

            errorMessage = errorDetails
            currentStep = .error
            print("❌ NFC not available: \(errorDetails)")
        } else {
            print("✅ NFC is available on this device")
        }
    }

    private func startScanning() {
        // TEMPORARY WORKAROUND: Skip availability check for debugging
        // guard NFCNDEFReaderSession.readingAvailable else {
        //     errorMessage = "NFC is not available on this device"
        //     currentStep = .error
        //     return
        // }

        // For debugging: Log availability status
        print("🚀 Starting NFC scan - readingAvailable: \(NFCNDEFReaderSession.readingAvailable)")

        currentStep = .scanning
        errorMessage = nil
        scanResult = nil
        assignedObjectType = nil
        createdObject = nil

        nfcService.scanNFC { result in
            DispatchQueue.main.async {
                self.isScanning = false

                switch result {
                case .success(let nfcResult):
                    self.handleNFCSuccess(nfcResult)
                case .failure(let error):
                    self.handleNFCError(error)
                }
            }
        }
    }

    private func handleNFCSuccess(_ nfcResult: NFCService.NFCResult) {
        scanResult = nfcResult
        currentStep = .analyzing

        // Analyze NFC data and assign object type
        assignedObjectType = assignObjectType(from: nfcResult)

        // Move to positioning after a brief delay to show the analysis
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.startPositioning()
        }
    }

    private func handleNFCError(_ error: NFCService.NFCError) {
        errorMessage = error.localizedDescription
        currentStep = .error
    }

    private func assignObjectType(from nfcResult: NFCService.NFCResult) -> LootBoxType {
        // Check if NFC token contains pre-programmed object type
        if let payload = nfcResult.payload?.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Try to parse object type from payload
            if let type = LootBoxType(rawValue: payload) {
                return type
            }

            // Check for common variations or abbreviations
            let lowerPayload = payload.lowercased()
            for type in LootBoxType.allCases {
                if lowerPayload.contains(type.rawValue.lowercased()) ||
                   lowerPayload.contains(type.rawValue.lowercased().replacingOccurrences(of: " ", with: "")) {
                    return type
                }
            }
        }

        // If no pre-programmed type or invalid, assign random type from available types
        // Exclude turkey as it's seasonal and less common for random assignment
        let availableTypes: [LootBoxType] = [.chalice, .templeRelic, .treasureChest, .lootChest, .lootCart, .sphere, .cube]
        return availableTypes.randomElement() ?? .treasureChest
    }

    private func startPositioning() {
        currentStep = .positioning

        // Get current user location for initial GPS coordinates
        userLocation = CLLocationManager().location

        // Start AR positioning to get high-precision coordinates
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

    private func captureARPosition() async throws {
        guard let userLocation = userLocation,
              let objectType = assignedObjectType,
              let nfcResult = scanResult else {
            throw NSError(domain: "OpenGameNFCScanner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing location, object type, or NFC result"])
        }

        // Create a unique object ID based on NFC tag and timestamp
        let objectId = "nfc_\(nfcResult.tagId)_\(Int(Date().timeIntervalSince1970))"

        // Start with GPS coordinates as fallback
        var latitude = userLocation.coordinate.latitude
        var longitude = userLocation.coordinate.longitude

        // Try to get high-precision AR coordinates
        do {
            // Create a temporary NFCTaggedObject for AR positioning
            let tempObject = PreciseARPositioningService.NFCTaggedObject(
                tagID: nfcResult.tagId,
                objectID: objectId,
                worldTransform: matrix_identity_float4x4,
                latitude: latitude,
                longitude: longitude,
                altitude: userLocation.altitude,
                createdAt: Date(),
                refinedTransform: nil,
                visualAnchorData: nil
            )

            // Attempt to place with AR precision (this may take a few seconds)
            try await precisePositioning.placePreciseARObject(object: tempObject)

            // If successful, get the refined coordinates from AR anchor
            if let anchor = precisePositioning.getActiveAnchor(for: objectId),
               let geoAnchor = anchor as? ARGeoAnchor {
                // Use AR-refined coordinates
                latitude = geoAnchor.coordinate.latitude
                longitude = geoAnchor.coordinate.longitude

                print("🎯 Used AR-refined coordinates: \(latitude), \(longitude)")
            } else {
                print("📍 Using GPS coordinates (AR refinement not available)")
            }
        } catch {
            print("⚠️ AR positioning failed, using GPS coordinates: \(error)")
            // Continue with GPS coordinates
        }

        // Create the object via API
        await createObject(id: objectId, type: objectType, latitude: latitude, longitude: longitude)
    }

    private func createObject(id: String, type: LootBoxType, latitude: Double, longitude: Double) async {
        currentStep = .creating

        do {
            // Create the object data
            let objectData: [String: Any] = [
                "id": id,
                "name": "\(type.displayName) (NFC)",
                "type": type.rawValue,
                "latitude": latitude,
                "longitude": longitude,
                "radius": 10.0, // 10 meter radius
                "created_by": "nfc_scanner",
                "grounding_height": 0.0
            ]

            // Convert to JSON
            let jsonData = try JSONSerialization.data(withJSONObject: objectData)

            // Create URL request
            let baseURL = APIService.shared.baseURL
            guard let url = URL(string: "\(baseURL)/api/objects") else {
                throw NSError(domain: "OpenGameNFCScanner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            // Send request
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "OpenGameNFCScanner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            if httpResponse.statusCode == 200 {
                // Success - create local object representation
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

                    // Notify other parts of the app that a new NFC object was created
                    NotificationCenter.default.post(
                        name: NSNotification.Name("NFCObjectCreated"),
                        object: object
                    )
                }
            } else {
                throw NSError(domain: "OpenGameNFCScanner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned error: \(httpResponse.statusCode)"])
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

// MARK: - Preview
struct OpenGameNFCScannerView_Previews: PreviewProvider {
    static var previews: some View {
        OpenGameNFCScannerView()
    }
}
