import SwiftUI
import CoreNFC

// MARK: - NFC Scanner View
struct NFCScannerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isScanning = false
    @State private var isWriting = false
    @State private var scanResult: NFCService.NFCResult?
    @State private var writeResult: String?
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var mode: Mode = .read

    enum Mode {
        case read, write
    }

    var onTagScanned: ((NFCService.NFCResult) -> Void)? = nil
    var onTagWritten: ((String) -> Void)? = nil

    private var buttonText: String {
        if isScanning || isWriting {
            return "Stop"
        }
        return mode == .read ? "Start Reading" : "Start Writing"
    }

    private var buttonColor: Color {
        if isScanning || isWriting {
            return .red
        }
        return mode == .read ? .blue : .green
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    // Mode Picker
                    Picker("Mode", selection: $mode) {
                        Text("Read Tag").tag(Mode.read)
                        Text("Write Tag").tag(Mode.write)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .disabled(isScanning || isWriting)

                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: mode == .read ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                            .font(.system(size: 60))
                            .foregroundColor(mode == .read ? .blue : .green)

                        Text(mode == .read ? "NFC Reader" : "NFC Writer")
                            .font(.title)
                            .fontWeight(.bold)

                        Text(mode == .read ?
                             "Hold your iPhone near an NFC tag to read it" :
                             "Hold your iPhone near an NFC tag to write to it")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    Spacer()

                    // Scanning/Writing animation
                    if isScanning || isWriting {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .stroke((isScanning ? Color.blue : Color.green).opacity(0.3), lineWidth: 4)
                                    .frame(width: 120, height: 120)

                                Circle()
                                    .stroke(isScanning ? Color.blue : Color.green, lineWidth: 4)
                                    .frame(width: 120, height: 120)
                                    .scaleEffect((isScanning || isWriting) ? 1.2 : 1.0)
                                    .opacity((isScanning || isWriting) ? 0.0 : 1.0)
                                    .animation(.easeInOut(duration: 1.5).repeatForever(), value: isScanning || isWriting)

                                Image(systemName: "wave.3.right")
                                    .font(.system(size: 40))
                                    .foregroundColor(isScanning ? .blue : .green)
                            }

                            Text(isScanning ? "Reading..." : "Writing...")
                                .font(.headline)
                                .foregroundColor(isScanning ? .blue : .green)
                        }
                    }

                    // Results
                    if let result = scanResult {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.green)

                            Text("Tag Read Successfully!")
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

                    if let writeResult = writeResult {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.green)

                            Text("Tag Written Successfully!")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)

                            Text(writeResult)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                        }
                        .padding(.horizontal)
                        .transition(.scale.combined(with: .opacity))
                    }

                    // Error message
                    if let error = errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)

                            Text("Scan Failed")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)

                            Text(error)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    Spacer()

                    // Action button
                    Button(action: startAction) {
                        HStack {
                            Image(systemName: (isScanning || isWriting) ? "stop.fill" : (mode == .read ? "wave.3.right" : "pencil"))
                            Text(buttonText)
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(buttonColor)
                        .cornerRadius(12)
                        .shadow(color: buttonColor.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .disabled(showSuccess)
                    .padding(.bottom, 40)
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
                // Check NFC availability
                if !NFCNDEFReaderSession.readingAvailable {
                    errorMessage = "NFC is not available on this device. NFC requires an iPhone 7 or later."
                }
            }
            .alert("NFC Tag Scanned!", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                if let result = scanResult {
                    Text("Successfully read NFC tag with ID: \(result.tagId)")
                }
            }
        }
    }

    private func startAction() {
        if isScanning || isWriting {
            // Stop current operation
            NFCService.shared.stopScanning()
            isScanning = false
            isWriting = false
            errorMessage = nil
        } else if mode == .read {
            startReading()
        } else {
            startWriting()
        }
    }

    private func startReading() {
        isScanning = true
        errorMessage = nil
        scanResult = nil
        writeResult = nil

        NFCService.shared.scanNFC { result in
            DispatchQueue.main.async {
                self.isScanning = false

                switch result {
                case .success(let nfcResult):
                    self.scanResult = nfcResult
                    self.errorMessage = nil
                    self.showSuccess = true

                    // Call the callback if provided
                    self.onTagScanned?(nfcResult)

                    // Vibrate for success
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()

                case .failure(let error):
                    self.scanResult = nil
                    self.errorMessage = error.localizedDescription

                    // Vibrate for error
                    let impact = UIImpactFeedbackGenerator(style: .heavy)
                    impact.impactOccurred()
                }
            }
        }
    }

    private func startWriting() {
        isWriting = true
        errorMessage = nil
        scanResult = nil
        writeResult = nil

        NFCService.shared.writeNFC(message: "CacheRaiders Treasure") { result in
            DispatchQueue.main.async {
                self.isWriting = false

                switch result {
                case .success(let message):
                    self.writeResult = message
                    self.errorMessage = nil
                    self.showSuccess = true

                    // Call the callback if provided
                    self.onTagWritten?(message)

                    // Vibrate for success
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()

                case .failure(let error):
                    self.writeResult = nil
                    self.errorMessage = error.localizedDescription

                    // Vibrate for error
                    let impact = UIImpactFeedbackGenerator(style: .heavy)
                    impact.impactOccurred()
                }
            }
        }
    }
}

// MARK: - Preview
struct NFCScannerView_Previews: PreviewProvider {
    static var previews: some View {
        NFCScannerView()
    }
}
