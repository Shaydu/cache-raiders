import SwiftUI
import CoreNFC

// MARK: - NFC Scan Only View
/// View for scanning existing NFC tokens and registering them as finds
/// This is different from OpenGameNFCScannerView which creates NEW objects
/// This view ONLY scans existing tokens and marks them as found
struct NFCScanOnlyView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    private let nfcService = NFCService.shared

    @State private var isScanning = false
    @State private var scanResult: NFCService.NFCResult?
    @State private var errorMessage: String?
    @State private var currentStep: ScanningStep = .ready
    @State private var foundObject: LootBoxLocation?

    enum ScanningStep {
        case ready          // Ready to scan
        case scanning       // NFC scanning in progress
        case processing     // Processing scanned NFC data
        case success        // Object found successfully
        case notFound       // NFC tag scanned but no matching object in database
        case error          // Error occurred
    }

    private var stepDescription: String {
        switch currentStep {
        case .ready:
            return "Tap to scan an NFC token and register your find"
        case .scanning:
            return "Hold your iPhone near an NFC token"
        case .processing:
            return "Looking up NFC token in database..."
        case .success:
            return "Treasure found!"
        case .notFound:
            return "NFC token not found in database"
        case .error:
            return "An error occurred"
        }
    }

    private var stepColor: Color {
        switch currentStep {
        case .ready: return .blue
        case .scanning: return .blue
        case .processing: return .orange
        case .success: return .green
        case .notFound: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "wave.3.right.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(stepColor)

                        Text("Scan NFC Token")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Find Existing Treasures")
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
                        case .ready:
                            readyView
                        case .scanning:
                            scanningView
                        case .processing:
                            processingView
                        case .success:
                            successView
                        case .notFound:
                            notFoundView
                        case .error:
                            errorView
                        }
                    }

                    Spacer()

                    // Action buttons
                    if currentStep == .ready || currentStep == .error || currentStep == .notFound {
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
        }
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 80))
                .foregroundColor(.blue.opacity(0.5))

            Text("Scan NFC tokens placed by other players to find treasures!")
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

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Looking up token...")
                .font(.headline)
                .foregroundColor(.orange)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            if let object = foundObject {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)

                    Text("Treasure Found!")
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

                    Text("This find has been registered to your account!")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var notFoundView: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Token Not Found")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.orange)

            if let result = scanResult {
                Text("NFC token scanned successfully, but no matching treasure was found in the database.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tag ID:")
                            .fontWeight(.semibold)
                        Text(result.tagId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            }
        }
        .padding(.horizontal)
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

    private func startScanning() {
        currentStep = .scanning
        errorMessage = nil
        scanResult = nil
        foundObject = nil

        print("🎯 NFCScanOnlyView: Starting NFC scan to find existing token")

        nfcService.scanNFC { result in
            DispatchQueue.main.async {
                self.isScanning = false

                switch result {
                case .success(let nfcResult):
                    print("✅ NFCScanOnlyView: NFC scan successful")
                    self.handleNFCSuccess(nfcResult)
                case .failure(let error):
                    print("❌ NFCScanOnlyView: NFC scan failed with error: \(error)")
                    self.handleNFCError(error)
                }
            }
        }
    }

    private func handleNFCSuccess(_ nfcResult: NFCService.NFCResult) {
        scanResult = nfcResult
        currentStep = .processing

        print("🔍 Looking up NFC token in database: \(nfcResult.tagId)")

        // Extract object ID from NFC payload
        // The payload should be a URL like: "baseURL/nfc/<objectId>"
        var objectId: String? = nil

        if let payload = nfcResult.payload,
           let url = URL(string: payload),
           let lastComponent = url.pathComponents.last {
            objectId = lastComponent
            print("✅ Extracted object ID from NFC URL: \(objectId!)")
        } else if let payload = nfcResult.payload {
            // Fallback: try to use payload directly as object ID
            objectId = payload
            print("⚠️ Using payload directly as object ID: \(objectId!)")
        }

        guard let objId = objectId else {
            print("❌ Could not extract object ID from NFC payload")
            errorMessage = "Invalid NFC token format"
            currentStep = .error
            return
        }

        // Look up object in location manager
        if let object = locationManager.locations.first(where: { $0.id == objId }) {
            print("✅ Found object in database: \(object.name)")

            // Check if already collected by this user
            if object.collected {
                print("ℹ️ Object already collected by current user")
                foundObject = object
                currentStep = .success
                return
            }

            // Mark as found
            Task {
                do {
                    try await APIService.shared.markFound(objectId: objId)

                    await MainActor.run {
                        // Update local state
                        locationManager.markCollected(objId)
                        foundObject = object
                        currentStep = .success

                        print("✅ Object marked as found successfully")

                        // Play success sound/haptic
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()

                        // Auto-dismiss after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            dismiss()
                        }
                    }
                } catch {
                    await MainActor.run {
                        print("❌ Failed to mark object as found: \(error)")
                        errorMessage = "Failed to register find: \(error.localizedDescription)"
                        currentStep = .error
                    }
                }
            }
        } else {
            print("❌ Object not found in database: \(objId)")
            currentStep = .notFound
        }
    }

    private func handleNFCError(_ error: NFCService.NFCError) {
        errorMessage = error.localizedDescription
        currentStep = .error
    }
}

// MARK: - Preview
struct NFCScanOnlyView_Previews: PreviewProvider {
    static var previews: some View {
        NFCScanOnlyView(
            locationManager: LootBoxLocationManager(),
            userLocationManager: UserLocationManager()
        )
    }
}
