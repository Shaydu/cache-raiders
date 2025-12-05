import SwiftUI
import CoreNFC

// MARK: - NFC Scan Only View
/// Simple view for scanning NFC tokens and logging finds
struct NFCScanOnlyView: View {
    @Environment(\.dismiss) var dismiss
    private let nfcService = NFCService.shared
    private let apiService = APIService.shared

    @State private var isScanning = false
    @State private var statusMessage = "Ready to scan"
    @State private var showSuccess = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("NFC Scanner")
                    .font(.title)
                    .fontWeight(.bold)

                Text(statusMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 40)

            if showSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
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

    private func startScanning() {
        // TEMPORARY WORKAROUND: Skip availability check for debugging
        // guard NFCNDEFReaderSession.readingAvailable else {
        //     statusMessage = "NFC not available on this device"
        //     return
        // }

        statusMessage = "Scanning for NFC token..."
        isScanning = true

        nfcService.scanNFC { result in
            DispatchQueue.main.async {
                self.isScanning = false

                switch result {
                case .success(let nfcResult):
                    self.handleNFCSuccess(nfcResult)
                case .failure(let error):
                    self.statusMessage = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleNFCSuccess(_ nfcResult: NFCService.NFCResult) {
        statusMessage = "Token found! Logging scan..."

        // Try to extract object ID from NFC payload
        // For now, we'll assume the payload contains the object ID
        // In a real implementation, you might need to map NFC tag IDs to object IDs
        guard let objectId = nfcResult.payload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !objectId.isEmpty else {
            statusMessage = "No valid object ID found in token"
            return
        }

        // Log the find
        Task {
            do {
                try await apiService.markFound(objectId: objectId)
                DispatchQueue.main.async {
                    self.statusMessage = "Find logged successfully!"
                    self.showSuccess = true

                    // Auto-dismiss after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
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