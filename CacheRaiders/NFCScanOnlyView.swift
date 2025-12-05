import SwiftUI
import CoreNFC

// MARK: - NFC Scan Only View
/// Simple view for scanning NFC tokens and logging finds
struct NFCScanOnlyView: View {
    @Environment(\.dismiss) var dismiss
    private let nfcService = NFCService.shared
    private let apiService = APIService.shared
    private let findDataService = FindDataService.shared

    @State private var isScanning = false
    @State private var statusMessage = "Ready to scan"
    @State private var showSuccess = false
    @State private var foundObject: APIObject? = nil
    @State private var showRetryButton = false
    @State private var lastErrorMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("Loot Scanner")
                    .font(.title)
                    .fontWeight(.bold)

                Text(statusMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if showRetryButton {
                    Button(action: {
                        showRetryButton = false
                        startScanning()
                    }) {
                        Text("Try Again")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.top, 40)

            if showSuccess, let object = foundObject {
                // Object details card
                VStack(spacing: 16) {
                    // 3D Model
                    RotatingModelView(
                        modelName: modelName(for: object.type),
                        size: 0.3
                    )

                    // Object name
                    Text(object.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    // Date placed
                    if let createdAt = object.created_at {
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(.secondary)
                            Text(formatDate(createdAt))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Success message
                    Text("Find logged successfully!")
                        .font(.headline)
                        .foregroundColor(.green)
                        .padding(.top, 8)

                    // Dismiss button
                    Button(action: {
                        dismiss()
                    }) {
                        Text("Continue")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .shadow(radius: 8)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .onAppear {
            startScanning()
        }
        .onDisappear {
            nfcService.stopScanning()
        }
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        return dateString // Fallback to original string if parsing fails
    }

    private func modelName(for objectType: String) -> String {
        // Map API object types to 3D model names
        switch objectType.lowercased() {
        case "chalice":
            return "Chalice"
        case "treasure chest", "treasure_chest":
            return "Treasure_Chest"
        case "loot chest":
            return "Stylised_Treasure_Chest"
        case "loot cart":
            return "Mine_Cart_Gold"
        case "temple relic":
            return "Stylized_Container"
        case "mysterious sphere", "sphere":
            return "sphere" // Will use fallback cube
        case "mysterious cube", "cube":
            return "cube" // Will use fallback cube
        case "turkey":
            return "Dancing_Turkey"
        default:
            return "Chalice" // Default fallback
        }
    }

    private func startScanning() {
        // TEMPORARY WORKAROUND: Skip availability check for debugging
        // guard NFCNDEFReaderSession.readingAvailable else {
        //     statusMessage = "NFC not available on this device"
        //     return
        // }

        statusMessage = "Preparing to scan..."
        isScanning = true
        showRetryButton = false

        // Small delay to ensure UI updates and user sees the scanning state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.statusMessage = "Scanning for NFC token..."
            // Use AR-enhanced NFC scanning for precise positioning
            NFCARIntegrationService.shared.scanNFCWithARPositioning { result in
                DispatchQueue.main.async {
                    self.isScanning = false

                    switch result {
                    case .success(let nfcResult):
                        self.handleNFCSuccess(nfcResult)
                    case .failure(let error):
                        self.isScanning = false
                        self.showRetryButton = true
                        self.lastErrorMessage = error.localizedDescription

                        // Provide more specific error messages based on the error
                        if error.localizedDescription.contains("Tag connection lost") {
                            self.statusMessage = "Tag moved too quickly. Hold your device steady over the NFC tag and try again."
                        } else if error.localizedDescription.contains("retry exceeded") {
                            self.statusMessage = "Tag reading failed. Make sure the NFC tag is positioned correctly and try again."
                        } else {
                            self.statusMessage = "Scan failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func handleNFCSuccess(_ nfcResult: NFCService.NFCResult) {
        statusMessage = "Token found! Logging scan..."

        // Extract object ID from NFC records
        // New format: Record 1 = URL, Record 2 = Object ID
        let objectId = extractObjectIdFromNFCResult(nfcResult)

        guard let objectId = objectId, !objectId.isEmpty else {
            statusMessage = "No valid object ID found in token"
            return
        }

        // Try to mark found with the extracted object ID
        tryMarkFoundWithIds([objectId])
    }

    private func extractObjectIdFromNFCResult(_ nfcResult: NFCService.NFCResult) -> String? {
        print("🔍 Extracting object ID from NFC result")
        print("   Tag ID: '\(nfcResult.tagId)'")
        print("   Payload: '\(nfcResult.payload ?? "nil")'")

        guard let ndefMessage = nfcResult.ndefMessage else {
            print("   ❌ No NDEF message found")
            return nil
        }

        print("   NDEF message has \(ndefMessage.records.count) record(s)")

        // New format: Record 1 = URI (URL), Record 2 = Text (Object ID)
        if ndefMessage.records.count >= 2 {
            let secondRecord = ndefMessage.records[1] // Second record (index 1)
            print("   Second record type: '\(String(data: secondRecord.type, encoding: .utf8) ?? "unknown")'")

            // Try to extract text from the second record (should be the object ID)
            let objectId = extractTextFromRecord(secondRecord)
            if let objectId = objectId, !objectId.isEmpty {
                print("   ✅ Found object ID in second record: '\(objectId)'")
                return objectId
            }
        }

        // Fallback: Try old strategies for backward compatibility
        print("   ⚠️ No object ID found in second record, trying fallback strategies")
        let fallbackIds = extractPotentialObjectIds(from: nfcResult.payload ?? "", tagId: nfcResult.tagId)
        return fallbackIds.first
    }

    private func extractPotentialObjectIds(from payload: String, tagId: String) -> [String] {
        var ids = [String]()

        print("🔍 Fallback: Extracting object IDs from:")
        print("   Payload: '\(payload)'")
        print("   Tag ID: '\(tagId)'")

        // Strategy 1: Use payload directly if it looks like an object ID
        if !payload.isEmpty && payload.count > 5 {
            ids.append(payload)
            print("   Strategy 1: Added payload directly: '\(payload)'")
        }

        // Strategy 2: Extract from URL format (e.g., "http://localhost:5001/nfc/12345678")
        if let url = URL(string: payload), let pathComponents = url.pathComponents.last, pathComponents != "/" {
            let extractedId = pathComponents
            if extractedId.count > 3 {
                ids.append(extractedId)
                print("   Strategy 2: Extracted from URL: '\(extractedId)'")
            }
        }

        // Strategy 3: Look for objects with NFC chip UID pattern
        // Extract potential chip UID from tagId or payload
        let chipUid = extractChipUid(from: payload) ?? extractChipUid(from: tagId)
        if let uid = chipUid {
            // Add pattern for database lookup - the API will handle this
            ids.append(uid)
            print("   Strategy 3: Found chip UID: '\(uid)'")
        }

        print("   Final IDs to try: \(ids)")
        return ids
    }

    private func extractChipUid(from text: String) -> String? {
        // Look for hex patterns that might be NFC chip UIDs (typically 8-16 hex chars)
        let hexPattern = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{8,16}", options: [])
        if let match = hexPattern?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.count)),
           let range = Range(match.range, in: text) {
            return String(text[range])
        }
        return nil
    }

    private func extractTextFromRecord(_ record: NFCNDEFPayload) -> String? {
        // NDEF Text record format: [status byte][language code][text]
        // Status byte: bit 7 = UTF-16 (0 for UTF-8), bits 5-0 = language code length
        guard record.payload.count >= 1 else { return nil }

        let statusByte = record.payload[0]
        let isUTF16 = (statusByte & 0x80) != 0
        let languageCodeLength = Int(statusByte & 0x3F)

        guard record.payload.count >= (1 + languageCodeLength) else { return nil }

        let textStartIndex = 1 + languageCodeLength
        let textData = record.payload[textStartIndex...]

        if isUTF16 {
            return String(data: textData, encoding: .utf16)
        } else {
            return String(data: textData, encoding: .utf8)
        }
    }

    private func tryMarkFoundWithIds(_ objectIds: [String]) {
        // For local-first approach, we'll try to find the object locally first
        // This helps validate the ID and provides better user feedback
        Task {
            var validObjectId: String? = nil

            // Try to validate each potential object ID by checking if object exists
            for objectId in objectIds {
                print("🔍 Validating object ID: '\(objectId)'")
                do {
                    // Try to get object info from API using NFC-aware lookup
                    let object = try await apiService.getObjectByNFCId(objectId)
                    validObjectId = object.id // Use the actual object ID from the response
                    foundObject = object // Store the object details
                    print("✅ Found valid object: \(object.name) (\(object.id))")
                    break // Found a valid object ID
                } catch {
                    print("❌ Object ID '\(objectId)' not found in database: \(error.localizedDescription)")
                    continue
                }
            }

            guard let objectId = validObjectId else {
                DispatchQueue.main.async {
                    self.statusMessage = "No valid object found for scanned token"
                }
                return
            }

            // Create find record and save locally first
            do {
                let findId = "\(objectId)_\(apiService.currentUserID)_\(Date().timeIntervalSince1970)"
                let findRecord = FindRecord(
                    id: findId,
                    objectId: objectId,
                    foundBy: apiService.currentUserID,
                    foundAt: Date(),
                    needsSync: true
                )

                // Save to local Core Data first
                try findDataService.saveFindRecord(findRecord)
                print("✅ Find saved locally: \(findId)")

                // Try to sync to server immediately if online
                if !OfflineModeManager.shared.isOfflineMode {
                    do {
                        try await apiService.markFound(objectId: objectId)
                        // Mark as synced in local database
                        try findDataService.markAsSynced(findId: findId)
                        print("✅ Find synced to server successfully")
                    } catch {
                        print("⚠️ Failed to sync find to server (will retry later): \(error.localizedDescription)")
                        // Keep needs_sync = true for later retry
                    }
                } else {
                    print("📴 Offline mode - find saved locally, will sync when online")
                }

                DispatchQueue.main.async {
                    self.statusMessage = "Find logged successfully!"
                    self.showSuccess = true

                    // Auto-dismiss after a longer delay to show the 3D model
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        self.dismiss()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to log find: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Preview
struct NFCScanOnlyView_Previews: PreviewProvider {
    static var previews: some View {
        NFCScanOnlyView()
    }
}