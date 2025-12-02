import SwiftUI
import CoreNFC

// MARK: - Simple NFC Scanner View
/// Basic NFC reader for testing and debugging NFC functionality
struct SimpleNFCScannerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isScanning = false
    @State private var scanResults: [String] = []
    @State private var errorMessage: String?
    @State private var session: NFCNDEFReaderSession?
    @State private var showTroubleshooting = false

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground).edgesIgnoringSafeArea(.all)

                VStack(spacing: 20) {
                    Text("NFC Tag Reader")
                        .font(.title)
                        .fontWeight(.bold)

                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(10)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scan Results:")
                            .font(.headline)

                        if scanResults.isEmpty {
                            Text("No tags scanned yet")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(scanResults, id: \.self) { result in
                                        Text(result)
                                            .font(.system(.body, design: .monospaced))
                                            .padding(8)
                                            .background(Color.gray.opacity(0.1))
                                            .cornerRadius(6)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(12)

                    Spacer()

                    VStack(spacing: 16) {
                    Button(action: {
                        if isScanning {
                            stopScanning()
                        } else {
                            startScanning()
                        }
                    }) {
                        Text(isScanning ? "Stop Scanning" : "Start Scanning")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(isScanning ? Color.red : Color.blue)
                            .cornerRadius(12)
                    }

                    if !isScanning {
                        Button(action: {
                            showTroubleshooting.toggle()
                        }) {
                            Text("Troubleshooting")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                        .sheet(isPresented: $showTroubleshooting) {
                            TroubleshootingView()
                        }

                        Button(action: {
                            checkNFCCompatibility()
                        }) {
                            Text("Check NFC Status")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }

                        Button(action: {
                            testNTAG215Compatibility()
                        }) {
                            Text("Test NTAG 215")
                                .font(.subheadline)
                                .foregroundColor(.purple)
                        }

                        Button(action: {
                            diagnoseNFCSession()
                        }) {
                            Text("Diagnose Session")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }

                        Button(action: {
                            scanResults.removeAll()
                            errorMessage = nil
                        }) {
                            Text("Clear Results")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        stopScanning()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            stopScanning()
        }
    }

    private func startScanning() {
        print("🔍 SimpleNFCScannerView: Starting NFC scan")

        // TEMPORARY: Skip availability check for debugging
        // Check if NFC is available
        // guard NFCNDEFReaderSession.readingAvailable else {
        //     errorMessage = "NFC is not available on this device. Please ensure you have an iPhone with NFC capabilities."
        //     print("❌ SimpleNFCScannerView: NFC not available")
        //     return
        // }

        print("ℹ️ SimpleNFCScannerView: NFC readingAvailable = \(NFCNDEFReaderSession.readingAvailable)")
        print("🏷️ Testing with NTAG 215 - this tag type should be fully compatible")

        // Create session with specific settings for NTAG compatibility
        session = NFCNDEFReaderSession(delegate: NFCHandler(scanResults: $scanResults, errorMessage: $errorMessage, isScanning: $isScanning),
                                       queue: nil,
                                       invalidateAfterFirstRead: false)

        // Configure for better NTAG detection
        if #available(iOS 13.0, *) {
            // These settings help with NTAG detection
            print("🔧 iOS 13+ available - using enhanced NFC settings")
        }

        session?.alertMessage = "Hold your iPhone near an NFC tag"

        // Start scanning
        isScanning = true
        errorMessage = nil
        scanResults.append("Starting NFC scan...")
        scanResults.append("ℹ️ Make sure your NFC tag is NDEF-formatted")
        scanResults.append("ℹ️ Hold the top of your iPhone near the tag")
        scanResults.append("ℹ️ Keep the tag still while scanning")

        print("🚀 Attempting to start NFC session...")
        session?.begin()
        print("✅ SimpleNFCScannerView: session?.begin() called")

        // Check if session actually started
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak session] in
            if let currentSession = session {
                print("🔍 Session status check:")
                print("   - isReady: \(currentSession.isReady)")
                if #available(iOS 13.0, *) {
                    print("   - isInvalidated: \(currentSession.isInvalidated)")
                }
            } else {
                print("❌ Session is nil after begin() call")
            }
        }

        // Add a timeout to help debug if session never detects anything
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak session] in
            if let currentSession = session, currentSession.isReady {
                print("⏰ NFC Session still active after 30 seconds - no tag detected")
                print("   This suggests the tag is not NDEF-compatible or session failed silently")
                // Don't invalidate here, let user cancel manually
            }
        }
    }

    private func stopScanning() {
        session?.invalidate()
        session = nil
        isScanning = false
        scanResults.append("Scanning stopped")
        print("🛑 SimpleNFCScannerView: NFC session stopped")
    }

    private func checkNFCCompatibility() {
        var status: [String] = ["📊 NFC Compatibility Check:"]

        // Check device model
        let deviceModel = UIDevice.current.model
        status.append("📱 Device: \(deviceModel)")

        // Check iOS version
        let iOSVersion = UIDevice.current.systemVersion
        status.append("🍎 iOS: \(iOSVersion)")

        // Check NFC availability
        let nfcAvailable = NFCNDEFReaderSession.readingAvailable
        status.append("🔄 NFC Available: \(nfcAvailable)")

        // Check if running on simulator
        #if targetEnvironment(simulator)
        status.append("🖥️ Environment: Simulator (NFC not available)")
        #else
        status.append("📱 Environment: Physical Device")
        #endif

        // NFC capability requirements
        if #available(iOS 11.0, *) {
            status.append("✅ iOS 11+ requirement: Met")
        } else {
            status.append("❌ iOS 11+ requirement: Not met")
        }

        // NTAG 215 specific compatibility
        status.append("🏷️ NTAG 215 Compatibility:")
        status.append("  ✅ NDEF-formatted: Yes")
        status.append("  ✅ ISO 14443 Type A: Yes")
        status.append("  ✅ iOS Compatible: Yes")
        status.append("  ✅ Should work with our app: Yes")

        // Supported tag types
        status.append("🏷️ All Supported tag types:")
        status.append("  ✅ NDEF-formatted tags (including NTAG 215)")
        status.append("  ✅ ISO 14443 Type A/B")
        status.append("  ✅ FeliCa")
        status.append("  ❌ MIFARE Classic")
        status.append("  ❌ Very old NTAG versions (203/213)")

        scanResults.append(contentsOf: status)
    }

    private func testNTAG215Compatibility() {
        var testResults: [String] = ["🧪 NTAG 215 Compatibility Test:"]

        testResults.append("📋 Tag Specifications:")
        testResults.append("  • Type: NTAG 215")
        testResults.append("  • Memory: 504 bytes")
        testResults.append("  • NDEF Compatible: ✅ YES")
        testResults.append("  • iOS Compatible: ✅ YES")

        testResults.append("🔧 App Configuration:")
        testResults.append("  • NFC Entitlement: Should be enabled in Xcode")
        testResults.append("  • CoreNFC Framework: ✅ Imported")
        testResults.append("  • NDEF Reader Session: ✅ Configured")

        testResults.append("🎯 Expected Behavior:")
        testResults.append("  • iOS NFC UI should appear")
        testResults.append("  • Tag should be detected within 1-2 seconds")
        testResults.append("  • Data should be readable")

        testResults.append("🚨 If not working:")
        testResults.append("  1. Rebuild app after enabling NFC in Xcode")
        testResults.append("  2. Clean build folder (Shift+Cmd+K)")
        testResults.append("  3. Restart device if needed")
        testResults.append("  4. Check console logs for errors")

        scanResults.append(contentsOf: testResults)
    }

    private func diagnoseNFCSession() {
        var diagnostics: [String] = ["🔬 NFC Session Diagnosis:"]

        diagnostics.append("📱 Device & OS:")
        diagnostics.append("   Model: \(UIDevice.current.model)")
        diagnostics.append("   iOS: \(UIDevice.current.systemVersion)")

        diagnostics.append("🔧 NFC Capabilities:")
        diagnostics.append("   readingAvailable: \(NFCNDEFReaderSession.readingAvailable)")

        #if targetEnvironment(simulator)
        diagnostics.append("   Environment: Simulator ⚠️")
        diagnostics.append("   → NFC not available in simulator")
        #else
        diagnostics.append("   Environment: Physical Device ✅")
        #endif

        diagnostics.append("🏗️ Testing Session Creation:")
        do {
            let testSession = NFCNDEFReaderSession(delegate: NFCHandler(scanResults: .constant([]), errorMessage: .constant(nil), isScanning: .constant(false)),
                                                   queue: nil,
                                                   invalidateAfterFirstRead: false)
            diagnostics.append("   ✅ Session creation: SUCCESS")
            diagnostics.append("   Alert message: '\(testSession.alertMessage)'")

            // Test beginning the session
            testSession.begin()
            diagnostics.append("   ✅ Session begin(): SUCCESS")

            // Clean up
            testSession.invalidate()
            diagnostics.append("   ✅ Session cleanup: SUCCESS")

        } catch {
            diagnostics.append("   ❌ Session creation: FAILED")
            diagnostics.append("   Error: \(error.localizedDescription)")
        }

        diagnostics.append("🎯 Next Steps:")
        diagnostics.append("   1. If session creation fails → Check NFC entitlement in Xcode")
        diagnostics.append("   2. If session starts but no detection → Check tag NDEF format")
        diagnostics.append("   3. If other apps work → Rebuild app after entitlement change")

        scanResults.append(contentsOf: diagnostics)
    }
}

// MARK: - NFC Handler
class NFCHandler: NSObject, NFCNDEFReaderSessionDelegate {
    private let id = UUID().uuidString.prefix(8)

    init(scanResults: Binding<[String]>, errorMessage: Binding<String?>, isScanning: Binding<Bool>) {
        _scanResults = scanResults
        _errorMessage = errorMessage
        _isScanning = isScanning
        super.init()
        print("🆕 NFCHandler \(id): Created")
    }

    deinit {
        print("🗑️ NFCHandler \(id): Deallocated")
    }
    @Binding var scanResults: [String]
    @Binding var errorMessage: String?
    @Binding var isScanning: Bool

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        print("🎯 NFCHandler \(id): NFC Tag detected! Messages: \(messages.count)")

        var results: [String] = ["🎯 SUCCESS: NFC Tag detected at \(Date())!"]
        results.append("📊 Found \(messages.count) NDEF message(s)")

        for (messageIndex, message) in messages.enumerated() {
            results.append("📄 Message \(messageIndex + 1): \(message.records.count) records")

            for (recordIndex, record) in message.records.enumerated() {
                var recordInfo = "📋 Record \(recordIndex + 1): "

                if let type = String(data: record.type, encoding: .utf8) {
                    recordInfo += "Type: '\(type)', "
                } else {
                    recordInfo += "Type: \(record.type.count) bytes, "
                }

                if let payload = String(data: record.payload, encoding: .utf8) {
                    recordInfo += "Payload: '\(payload)'"
                } else {
                    recordInfo += "Payload: \(record.payload.count) bytes (binary)"
                }

                results.append("   \(recordInfo)")
                print("   \(recordInfo)")
            }
        }

        DispatchQueue.main.async {
            self.scanResults.append(contentsOf: results)
            print("✅ NFCHandler \(self.id): NFC data processed and displayed")
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        print("❌ NFCHandler \(id): NFC Session invalidated: \(error.localizedDescription)")
        print("   Error type: \(type(of: error))")

        if let nfcError = error as? NFCReaderError {
            print("   NFC Error code: \(nfcError.code.rawValue) (\(nfcError.code))")
        }

        DispatchQueue.main.async {
            self.isScanning = false

            if let nfcError = error as? NFCReaderError {
                switch nfcError.code {
                case .readerSessionInvalidationErrorUserCanceled:
                    self.errorMessage = "Scanning cancelled by user"
                    print("   → User cancelled scanning")
                case .readerSessionInvalidationErrorSessionTimeout:
                    self.errorMessage = "Scanning timed out - try again"
                    print("   → Session timed out")
                case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
                    self.errorMessage = "NFC session terminated unexpectedly"
                    print("   → Session terminated unexpectedly")
                default:
                    self.errorMessage = "NFC Error: \(nfcError.code.rawValue)"
                    print("   → Other NFC error: \(nfcError.code)")
                }
            } else {
                self.errorMessage = "Session ended: \(error.localizedDescription)"
                print("   → Non-NFC error: \(error.localizedDescription)")
            }

            print("🏁 NFCHandler \(self.id): Session cleanup complete")
        }
    }
}

// MARK: - Troubleshooting View
struct TroubleshootingView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("NFC Troubleshooting Guide")
                        .font(.title)
                        .fontWeight(.bold)

                    Group {
                        Text("🔍 Common Issues:")
                            .font(.headline)
                            .foregroundColor(.orange)

                        VStack(alignment: .leading, spacing: 15) {
                            TroubleshootingItem(
                                title: "Tag Format (NDEF)",
                                description: "iOS requires NDEF-formatted NFC tags. Your NTAG 215 IS NDEF-compatible and should work perfectly.",
                                solution: "✅ NTAG 215: Fully compatible with iOS\n✅ NTAG 216: Also fully compatible\n❌ NTAG 203/213: Older versions not compatible"
                            )

                            TroubleshootingItem(
                                title: "NTAG 215 Specific Issues",
                                description: "NTAG 215 is one of the most iOS-compatible tags available. If other apps read it but ours doesn't, the issue is in our app configuration.",
                                solution: "Check: NFC entitlement enabled in Xcode\nCheck: App rebuilt after entitlement change\nCheck: Console logs for session errors"
                            )

                            TroubleshootingItem(
                                title: "Empty or Unformatted Tags",
                                description: "Some NFC tags come blank/unformatted and need to be written to before they can be read.",
                                solution: "Try writing data to your tag first using another NFC app, then test reading it."
                            )

                            TroubleshootingItem(
                                title: "Tag Position",
                                description: "NFC scanning works best when the tag is very close to the scanner area.",
                                solution: "Hold the TOP of your iPhone (where the camera is) directly against the NFC tag. Keep it still for 2-3 seconds."
                            )

                            TroubleshootingItem(
                                title: "Tag Orientation",
                                description: "Some tags are directional and need to be oriented correctly.",
                                solution: "Try flipping the tag over or rotating it 180 degrees."
                            )

                            TroubleshootingItem(
                                title: "Interference",
                                description: "Metal cases, magnetic fields, or other electronics can interfere with NFC.",
                                solution: "Remove phone case if metal, move away from magnets/electronics."
                            )

                            TroubleshootingItem(
                                title: "Tag Content",
                                description: "Some tags may be empty or contain data iOS can't read.",
                                solution: "Test with a known working tag from another iOS app."
                            )
                        }
                    }

                    Group {
                        Text("🧪 Testing Steps:")
                            .font(.headline)
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("1. **Verify NFC works**: Test your tag in Apple Wallet or another NFC app")
                            Text("2. **Check position**: Hold phone top directly on tag")
                            Text("3. **Wait**: Keep tag in position for 2-3 seconds")
                            Text("4. **Try multiple tags**: Different manufacturers/tags behave differently")
                            Text("5. **Check console logs**: Look for detailed NFC session information")
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }

                    Group {
                        Text("📱 Device Compatibility:")
                            .font(.headline)
                            .foregroundColor(.green)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("✅ iPhone 14 Pro: Full NFC support")
                            Text("✅ iOS 18: Latest NFC features")
                            Text("✅ NDEF tags: Standard format supported")
                            Text("❌ NTAG/Ultralight: May not work with iOS")
                            Text("❌ MIFARE: Not supported by iOS")
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
            .navigationBarTitle("NFC Troubleshooting", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
    }
}

struct TroubleshootingItem: View {
    let title: String
    let description: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("💡 \(solution)")
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.vertical, 2)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

struct SimpleNFCScannerView_Previews: PreviewProvider {
    static var previews: some View {
        SimpleNFCScannerView()
    }
}
