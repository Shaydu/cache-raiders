import CoreNFC
import UIKit
import ARKit

// MARK: - NFC Service
class NFCService: NSObject, NFCNDEFReaderSessionDelegate, NFCTagReaderSessionDelegate {
    // MARK: - Singleton
    static let shared = NFCService()

    // MARK: - Properties
    private var readerSession: NFCNDEFReaderSession?
    private var writerSession: NFCTagReaderSession?
    private var readCompletion: ((Result<NFCResult, NFCError>) -> Void)?
    private var writeCompletion: ((Result<NFCResult, NFCError>) -> Void)?
    private var writeMessage: String?
    private var writeNDEFMessage: NFCNDEFMessage?
    private var shouldLockTag: Bool = false
    private var arSession: ARSession? // Reference to AR session for position capture

    // MARK: - NFC Message Content
    struct NFCMessageContent {
        let url: String
        let objectId: String
    }

// MARK: - NFC Result
    struct NFCResult {
        let tagId: String
        let ndefMessage: NFCNDEFMessage?
        let payload: String?
        let timestamp: Date
        let arTransform: simd_float4x4? // Exact AR position where NFC was tapped
        let cameraTransform: simd_float4x4? // Camera transform at time of scan
    }

    // MARK: - NFC Error
    enum NFCError: Error {
        case notSupported
        case sessionInvalidated
        case userCancelled
        case timeout
        case tagNotFound
        case readError(String)

        var localizedDescription: String {
            switch self {
            case .notSupported:
                return "NFC is not supported on this device"
            case .sessionInvalidated:
                return "NFC session was invalidated"
            case .userCancelled:
                return "NFC scanning was cancelled"
            case .timeout:
                return "NFC scanning timed out"
            case .tagNotFound:
                return "No NFC tag found"
            case .readError(let message):
                return "Failed to read NFC tag: \(message)"
            }
        }
    }

    // MARK: - Public Methods
    /// Scan NFC without AR positioning (legacy method)
    func scanNFC(completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
        scanNFCWithARPositioning(arSession: nil, completion: completion)
    }

    /// Scan NFC with high-precision AR positioning capture
    func scanNFCWithARPositioning(arSession: ARSession?, completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
        self.readCompletion = completion

        // TEMPORARY WORKAROUND: Skip availability check for debugging
        // Check if NFC is available
        // guard NFCNDEFReaderSession.readingAvailable else {
        //     completion(.failure(.notSupported))
        //     return
        // }

        print("🔧 NFCService.scanNFC: Starting scan (availability check bypassed)")

        // Invalidate any existing sessions
        invalidateSessions()

        // Create new reader session with improved configuration
        print("📱 Creating NFC reader session...")
        readerSession = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        readerSession?.alertMessage = "Hold your iPhone steady near an NFC tag to read it. Keep the tag in place until you see the success message."

        // Check if session was created successfully
        if let session = readerSession {
            print("✅ NFC reader session created successfully")
            print("   - Delegate: \(String(describing: session.delegate))")
            print("   - Alert message: \(session.alertMessage)")

            // Start session
            print("🚀 Starting NFC reader session...")
            session.begin()
            print("📡 NFC reader session begin() called")
        } else {
            print("❌ Failed to create NFC reader session")
            completion(.failure(.sessionInvalidated))
            return
        }
    }

    /// Get current AR camera transform for precise positioning
    private func getCurrentARTransform() -> (arTransform: simd_float4x4?, cameraTransform: simd_float4x4?) {
        guard let arSession = arSession,
              let frame = arSession.currentFrame else {
            print("⚠️ No AR session or frame available for position capture")
            return (nil, nil)
        }

        let cameraTransform = frame.camera.transform
        print("📍 Captured AR camera transform at NFC scan time")

        // Estimate NFC tag position based on camera orientation
        // NFC scanning typically happens when device is ~5-15cm from the tag
        // We'll estimate the position along the camera's forward vector
        let estimatedDistance: Float = 0.1 // 10cm in front of camera
        let forwardDirection = -simd_normalize(SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)) // Negative Z is forward in camera space
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Calculate estimated tag position
        let tagPosition = cameraPosition + (forwardDirection * estimatedDistance)

        // Create transform matrix for the estimated tag position
        // Keep the same orientation as camera for simplicity
        var tagTransform = cameraTransform
        tagTransform.columns.3 = SIMD4<Float>(tagPosition.x, tagPosition.y, tagPosition.z, 1.0)

        print("🎯 Estimated NFC tag position: (\(String(format: "%.3f", tagPosition.x)), \(String(format: "%.3f", tagPosition.y)), \(String(format: "%.3f", tagPosition.z)))")

        return (tagTransform, cameraTransform)
    }

    @available(iOS 13.0, *)
    func writeNFC(message: String, lockTag: Bool = false, completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
        print("🎯 NFCService.writeNFC called with message: \(message)")
        print("   iOS Version: \(UIDevice.current.systemVersion)")
        print("   Device Model: \(UIDevice.current.model)")
        print("   Device Name: \(UIDevice.current.name)")

        // Check if NFC is available for reading (required for writing)
        guard NFCTagReaderSession.readingAvailable else {
            print("❌ NFC not available on this device for reading/writing")
            print("   NFCTagReaderSession.readingAvailable = false")
            completion(.failure(.notSupported))
            return
        }

        print("✅ NFC reading capability confirmed")

        print("🔧 NFCService.writeNFC: Starting write with message: \(message)")

        // Create NDEF message to write BEFORE invalidating sessions
        let content = NFCMessageContent(url: message, objectId: "TEMP_ID") // This should be updated by caller
        guard let ndefMessage = createNDEFMessage(from: content) else {
            print("❌ Failed to create NDEF message")
            completion(.failure(.readError("Failed to create NDEF message")))
            return
        }

        // Invalidate any existing sessions FIRST
        invalidateSessions()

        // NOW set the write data (after invalidate, so it doesn't get cleared)
        self.writeCompletion = completion
        self.writeMessage = message
        self.writeNDEFMessage = ndefMessage
        self.shouldLockTag = lockTag

        // Create new writer session with NFCTagReaderSession to get write access
        writerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        writerSession?.alertMessage = "Hold your iPhone near an NFC tag to write loot data."

        print("🚀 Starting NFC writer session...")
        writerSession?.begin()
        print("📡 NFC writer session begin() called")
    }

    func writeNFC(content: NFCMessageContent, lockTag: Bool = false, completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
        print("🎯 NFCService.writeNFC called with URL + object ID")
        print("   URL: \(content.url)")
        print("   Object ID: \(content.objectId)")
        print("   iOS Version: \(UIDevice.current.systemVersion)")
        print("   Device Model: \(UIDevice.current.model)")
        print("   Device Name: \(UIDevice.current.name)")

        // Check if NFC is available for reading (required for writing)
        guard NFCTagReaderSession.readingAvailable else {
            print("❌ NFC not available on this device for reading/writing")
            print("   NFCTagReaderSession.readingAvailable = false")
            completion(.failure(.notSupported))
            return
        }

        print("✅ NFC reading capability confirmed")

        print("🔧 NFCService.writeNFC: Starting write with URL + object ID")

        // Create NDEF message to write BEFORE invalidating sessions
        guard let ndefMessage = createNDEFMessage(from: content) else {
            print("❌ Failed to create NDEF message")
            completion(.failure(.readError("Failed to create NDEF message")))
            return
        }

        // Invalidate any existing sessions FIRST
        invalidateSessions()

        // NOW set the write data (after invalidate, so it doesn't get cleared)
        self.writeCompletion = completion
        self.writeMessage = "URL: \(content.url), ObjectID: \(content.objectId)"
        self.writeNDEFMessage = ndefMessage
        self.shouldLockTag = lockTag

        // Create new writer session with NFCTagReaderSession to get write access
        writerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        writerSession?.alertMessage = "Hold your iPhone near an NFC tag to write loot data."

        print("🚀 Starting NFC writer session...")
        writerSession?.begin()
        print("📡 NFC writer session begin() called")
    }

    func writeNFC(messages: [String], lockTag: Bool = false, completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
        print("🎯 NFCService.writeNFC called with \(messages.count) message(s): \(messages)")
        print("   iOS Version: \(UIDevice.current.systemVersion)")
        print("   Device Model: \(UIDevice.current.model)")
        print("   Device Name: \(UIDevice.current.name)")

        // Check if NFC is available for reading (required for writing)
        guard NFCTagReaderSession.readingAvailable else {
            print("❌ NFC not available on this device for reading/writing")
            print("   NFCTagReaderSession.readingAvailable = false")
            completion(.failure(.notSupported))
            return
        }

        print("✅ NFC reading capability confirmed")

        print("🔧 NFCService.writeNFC: Starting write with \(messages.count) message(s)")

        // Create NDEF message to write BEFORE invalidating sessions
        let content = NFCMessageContent(url: messages.first ?? "", objectId: messages.last ?? "TEMP_ID") // This should be updated by caller
        guard let ndefMessage = createNDEFMessage(from: content) else {
            print("❌ Failed to create NDEF message")
            completion(.failure(.readError("Failed to create NDEF message")))
            return
        }

        // Invalidate any existing sessions FIRST
        invalidateSessions()

        // NOW set the write data (after invalidate, so it doesn't get cleared)
        self.writeCompletion = completion
        self.writeMessage = messages.joined(separator: ", ")
        self.writeNDEFMessage = ndefMessage
        self.shouldLockTag = lockTag

        // Create new writer session with NFCTagReaderSession to get write access
        writerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        writerSession?.alertMessage = "Hold your iPhone near an NFC tag to write loot data."

        print("🚀 Starting NFC writer session...")
        writerSession?.begin()
        print("📡 NFC writer session begin() called")
    }

    func stopScanning() {
        invalidateSessions()
    }

    /// Check NFC capabilities and return diagnostic information
    func getNFCDiagnostics() -> NFCDiagnostics {
        let readingAvailable = NFCTagReaderSession.readingAvailable
        let ndefReadingAvailable = NFCNDEFReaderSession.readingAvailable

        // Check iOS version for NFC writing support
        let iosVersion = Double(UIDevice.current.systemVersion) ?? 0.0
        let supportsNFCWriting = iosVersion >= 13.0

        // Known NFC-capable devices (not comprehensive, but covers most)
        let deviceModel = UIDevice.current.model
        let isLikelyNFCDevice = deviceModel.contains("iPhone") && !deviceModel.contains("iPhone 6") && !deviceModel.contains("iPhone 5")

        return NFCDiagnostics(
            readingAvailable: readingAvailable,
            ndefReadingAvailable: ndefReadingAvailable,
            supportsNFCWriting: supportsNFCWriting,
            isLikelyNFCDevice: isLikelyNFCDevice,
            iosVersion: iosVersion,
            deviceModel: deviceModel
        )
    }

    struct NFCDiagnostics {
        let readingAvailable: Bool
        let ndefReadingAvailable: Bool
        let supportsNFCWriting: Bool
        let isLikelyNFCDevice: Bool
        let iosVersion: Double
        let deviceModel: String

        var summary: String {
            var issues: [String] = []

            if !readingAvailable {
                issues.append("NFC reading not available on this device")
            }

            if !ndefReadingAvailable {
                issues.append("NDEF reading not available")
            }

            if !supportsNFCWriting {
                issues.append("iOS version \(iosVersion) may not support NFC writing (requires iOS 13.0+)")
            }

            if !isLikelyNFCDevice {
                issues.append("Device model '\(deviceModel)' may not support NFC")
            }

            return issues.isEmpty ? "NFC appears to be fully supported" : "NFC Issues: " + issues.joined(separator: "; ")
        }
    }

    private func invalidateSessions() {
        readerSession?.invalidate()
        writerSession?.invalidate()
        readerSession = nil
        writerSession = nil
        writeNDEFMessage = nil
    }

    // MARK: - NFCNDEFReaderSessionDelegate
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        print("❌ NFC Session invalidated with error: \(error.localizedDescription)")
        print("   - Error type: \(type(of: error))")
        if let readerError = error as? NFCReaderError {
            print("   - Reader error code: \(readerError.code.rawValue)")
        }

        let nfcError: NFCError
        if let readerError = error as? NFCReaderError {
            switch readerError.code {
            case .readerSessionInvalidationErrorUserCanceled:
                nfcError = .userCancelled
            case .readerSessionInvalidationErrorSessionTimeout:
                nfcError = .timeout
            case .readerTransceiveErrorTagConnectionLost:
                // Error code 204 - tag connection lost
                print("   → Tag connection lost (204) - this often happens when the tag moves away too quickly")
                nfcError = .readError("Tag connection lost - try holding the device steadier over the NFC tag")
            case .readerTransceiveErrorRetryExceeded:
                // Error code 203 - retry exceeded
                print("   → Retry exceeded - tag may be faulty or positioned incorrectly")
                nfcError = .readError("Unable to read tag - try repositioning the NFC tag")
            case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
                // Error code 205 - session terminated unexpectedly
                print("   → Session terminated unexpectedly")
                nfcError = .readError("NFC session ended unexpectedly - try again")
            default:
                print("   → Unhandled NFC error code: \(readerError.code.rawValue)")
                nfcError = .readError("NFC error \(readerError.code.rawValue): \(error.localizedDescription)")
            }
        } else {
            nfcError = .sessionInvalidated
        }

        // Call appropriate completion handler
        if session === readerSession {
            readCompletion?(.failure(nfcError))
            readerSession = nil
            readCompletion = nil
        } else if session === writerSession {
            writeCompletion?(.failure(nfcError))
            writerSession = nil
            writeCompletion = nil
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        print("🎯 NFC Tag detected with \(messages.count) NDEF messages")

        for (index, message) in messages.enumerated() {
            print("   📄 Message \(index + 1):")
            print("      - Records: \(message.records.count)")

            for (recordIndex, record) in message.records.enumerated() {
                print("      - Record \(recordIndex + 1):")
                print("         - Type name format: \(record.typeNameFormat.rawValue)")
                if let type = String(data: record.type, encoding: .utf8) {
                    print("         - Type: \(type)")
                }
                if let identifier = String(data: record.identifier, encoding: .utf8) {
                    print("         - Identifier: \(identifier)")
                }
                if let payloadString = String(data: record.payload, encoding: .utf8) {
                    print("         - Payload: \(payloadString)")
                } else {
                    print("         - Payload: \(record.payload.count) bytes (not UTF-8)")
                }
            }
        }

        if session === readerSession {
            // Handle reading
            print("📖 Handling as read operation")
            handleReadResult(messages: messages, session: session)
        } else if session === writerSession {
            // Handle writing - attempt to write to the detected tag
            print("✍️ Handling as write operation")
            handleWriteAttempt(session: session)
        } else {
            print("❓ Unknown session type")
        }
    }

    private func handleReadResult(messages: [NFCNDEFMessage], session: NFCNDEFReaderSession) {
        guard let message = messages.first else {
            readCompletion?(.failure(.tagNotFound))
            readerSession = nil
            readCompletion = nil
            return
        }

        // Generate a tag ID from the message or session
        // NFCNDEFReaderSession doesn't provide direct tag identifiers
        let tagId = generateTagId(from: message)

        // Extract payload as string
        let payload = extractPayload(from: message)

        // Capture AR positioning data at the exact moment of NFC detection
        let arTransforms = getCurrentARTransform()

        let result = NFCResult(
            tagId: tagId,
            ndefMessage: message,
            payload: payload,
            timestamp: Date(),
            arTransform: arTransforms.arTransform,
            cameraTransform: arTransforms.cameraTransform
        )

        readCompletion?(.success(result))
        readerSession = nil
        readCompletion = nil
    }

    private func handleWriteAttempt(session: NFCNDEFReaderSession) {
        // This method is for the NDEF reader session (read-only)
        // Writing is handled by NFCTagReaderSessionDelegate methods
        print("⚠️ handleWriteAttempt called on NDEF reader session - this shouldn't happen for writes")
    }

    private func generateTagId(from message: NFCNDEFMessage) -> String {
        // Generate a deterministic ID from the message content
        // This is a simplified approach - in production you'd want more robust identification
        if let payload = extractPayload(from: message) {
            return "ndef_\(payload.hashValue)"
        }
        return "ndef_unknown_\(Date().timeIntervalSince1970)"
    }

    private func createNDEFMessage(from content: NFCMessageContent) -> NFCNDEFMessage? {
        print("🔨 Creating NDEF message with URL + object ID records")

        var records: [NFCNDEFPayload] = []

        // Record 1: URI record with URL (for web access)
        print("   Record 1 (URL): \(content.url)")
        print("   URL length: \(content.url.count) characters")

        // Validate this is a URL (should start with http:// or https://)
        let isURL = content.url.hasPrefix("http://") || content.url.hasPrefix("https://")

        if isURL {
            // Check URL length - NFC tags have limited capacity (typically ~144 bytes per record)
            if content.url.count > 100 {
                print("⚠️ Warning: URL is \(content.url.count) characters, may exceed NFC tag capacity")
            }

            // Create NDEF URI record (TNF = NFC Well Known, Type = "U")
            // URI format: [URI identifier byte] + [URI string bytes]

            // Determine URI identifier byte based on prefix for optimal compression
            var uriIdentifier: UInt8 = 0x00 // No prefix
            if content.url.hasPrefix("http://") {
                uriIdentifier = 0x03 // http://www.
            } else if content.url.hasPrefix("https://") {
                uriIdentifier = 0x04 // https://www.
            }

            // Remove the prefix if we're using a URI identifier (saves space)
            var uriPayload = content.url
            if uriIdentifier == 0x03 && content.url.hasPrefix("http://") {
                uriPayload = String(content.url.dropFirst(7)) // Remove "http://"
            } else if uriIdentifier == 0x04 && content.url.hasPrefix("https://") {
                uriPayload = String(content.url.dropFirst(8)) // Remove "https://"
            }

            guard let uriData = uriPayload.data(using: .utf8) else {
                print("❌ Failed to convert URI string to data")
                return nil
            }

            var payload = Data()
            payload.append(uriIdentifier)
            payload.append(uriData)

            print("   Record 1 payload size: \(payload.count) bytes")
            print("   Record 1 URI identifier: 0x\(String(format: "%02X", uriIdentifier))")

            let uriRecord = NFCNDEFPayload(
                format: .nfcWellKnown,
                type: "U".data(using: .utf8)!,
                identifier: Data(),
                payload: payload
            )

            records.append(uriRecord)
        } else {
            print("❌ URL doesn't appear to be valid, skipping URI record")
            return nil
        }

        // Record 2: Text record with object ID (for app identification)
        print("   Record 2 (Object ID): \(content.objectId)")
        print("   Object ID length: \(content.objectId.count) characters")

        // Create NDEF Text record (TNF = NFC Well Known, Type = "T")
        // Text format: [status byte] + [language code] + [text]
        // Status byte: bit 7 = UTF-16 (0 for UTF-8), bits 5-0 = language code length
        let languageCode = "en" // English
        guard let languageData = languageCode.data(using: .ascii),
              let textData = content.objectId.data(using: .utf8) else {
            print("❌ Failed to convert object ID to data")
            return nil
        }

        // Status byte: UTF-8 encoding (bit 7 = 0), language code length = 2
        let statusByte: UInt8 = UInt8(languageData.count)
        var textPayload = Data()
        textPayload.append(statusByte)
        textPayload.append(languageData)
        textPayload.append(textData)

        print("   Record 2 payload size: \(textPayload.count) bytes")

        let textRecord = NFCNDEFPayload(
            format: .nfcWellKnown,
            type: "T".data(using: .utf8)!,
            identifier: Data(),
            payload: textPayload
        )

        records.append(textRecord)

        // Calculate total message size
        let totalPayloadSize = records.reduce(0) { $0 + $1.payload.count }
        print("   Total NDEF message size estimate: ~\(totalPayloadSize + (records.count * 10)) bytes")

        // Create NDEF message with URL and object ID records
        let ndefMessage = NFCNDEFMessage(records: records)

        print("✅ Created NDEF message with 2 records:")
        print("   Record 1: URI (URL for web access)")
        print("   Record 2: Text (Object ID for app identification)")

        return ndefMessage
    }

    private func createWriteMessage() -> NFCNDEFMessage? {
        // Create a simple text record
        let textPayload = "CacheRaiders Treasure Tag".data(using: .utf8)!
        let textRecord = NFCNDEFPayload(
            format: .nfcWellKnown,
            type: "T".data(using: .utf8)!,
            identifier: Data(),
            payload: textPayload
        )

        return NFCNDEFMessage(records: [textRecord])
    }

    // MARK: - Helper Methods
    private func extractPayload(from message: NFCNDEFMessage) -> String? {
        guard let record = message.records.first else { return nil }

        // Try different text encodings
        if let text = String(data: record.payload, encoding: .utf8) {
            return text
        } else if let text = String(data: record.payload, encoding: .ascii) {
            return text
        }

        // Return hex representation if text conversion fails
        return record.payload.hexString
    }

    // MARK: - NFCTagReaderSessionDelegate (for writing)
    @available(iOS 13.0, *)
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        print("🎯 NFCTagReaderSession became active")
    }

    @available(iOS 13.0, *)
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print("❌ NFC Tag Session invalidated with error: \(error.localizedDescription)")
        print("   - Error type: \(type(of: error))")
        print("   - Error domain: \((error as NSError).domain)")
        print("   - Error code: \((error as NSError).code)")
        if let readerError = error as? NFCReaderError {
            print("   - Reader error code: \(readerError.code.rawValue) (\(readerError.code))")
        }

        // Check for specific "data is missing" error
        if error.localizedDescription.contains("missing") || error.localizedDescription.contains("data") {
            print("   🚨 This looks like a blank/unformatted NFC tag error!")
            print("   💡 Try using NTAG 213, 215, or 216 tags that are NDEF-compatible")
        }

        // Check if we already handled the completion (success case)
        guard self.writeCompletion != nil else {
            print("ℹ️ Write completion already handled (likely succeeded)")
            DispatchQueue.main.async {
                self.writerSession = nil
            }
            return
        }

        let nfcError: NFCError
        if let readerError = error as? NFCReaderError {
            switch readerError.code {
            case .readerSessionInvalidationErrorUserCanceled:
                nfcError = .userCancelled
                print("   → User cancelled the NFC session")
            case .readerSessionInvalidationErrorSessionTimeout:
                nfcError = .timeout
                print("   → Session timed out")
            case .readerTransceiveErrorTagConnectionLost:
                // Error code 204 - tag connection lost
                nfcError = .readError("Tag connection lost - try holding the device steadier over the NFC tag")
                print("   → Tag connection lost (204) during write operation")
            case .readerTransceiveErrorRetryExceeded:
                // Error code 203 - retry exceeded
                nfcError = .readError("Unable to write to tag - try repositioning the NFC tag")
                print("   → Retry exceeded during write operation")
            case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
                // Error code 205 - session terminated unexpectedly
                nfcError = .readError("NFC session ended unexpectedly - try again")
                print("   → Session terminated unexpectedly during write")
            default:
                nfcError = .readError("NFC error \(readerError.code.rawValue): \(error.localizedDescription)")
                print("   → Unhandled NFC error code during write: \(readerError.code.rawValue)")
            }
        } else {
            nfcError = .sessionInvalidated
        }

        // This is from the writer session
        DispatchQueue.main.async {
            self.writeCompletion?(.failure(nfcError))
            self.writerSession = nil
            self.writeCompletion = nil
            self.writeMessage = nil
            self.writeNDEFMessage = nil
        }
    }

    @available(iOS 13.0, *)
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        print("🎯 NFC Tags detected: \(tags.count)")

        // Log details about detected tags
        for (index, tag) in tags.enumerated() {
            print("   Tag \(index + 1): \(tag)")
            switch tag {
            case .miFare(let miFareTag):
                print("   - Type: MiFare, Identifier: \(miFareTag.identifier.hexString)")
            case .iso7816(let iso7816Tag):
                print("   - Type: ISO7816")
            case .feliCa(let feliCaTag):
                print("   - Type: FeliCa")
            case .iso15693(let iso15693Tag):
                print("   - Type: ISO15693")
            @unknown default:
                print("   - Type: Unknown")
            }
        }

        guard let firstTag = tags.first else {
            session.invalidate(errorMessage: "No tag found")
            return
        }

        // Connect to the tag
        session.connect(to: firstTag) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Failed to connect to tag: \(error.localizedDescription)")
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Failed to connect to tag")
                completion?(.failure(.readError("Failed to connect: \(error.localizedDescription)")))
                return
            }

            print("✅ Connected to NFC tag")

            // Handle different tag types (ISO14443 is most common for NDEF)
            switch firstTag {
            case .miFare(let miFareTag):
                self.writeToMiFareTag(miFareTag, session: session)
            case .iso7816(let iso7816Tag):
                self.writeToISO7816Tag(iso7816Tag, session: session)
            case .feliCa(let feliCaTag):
                print("⚠️ FeliCa tags are not typically used for NDEF")
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Unsupported tag type")
                completion?(.failure(.readError("FeliCa tags not supported")))
            case .iso15693(let iso15693Tag):
                self.writeToISO15693Tag(iso15693Tag, session: session)
            @unknown default:
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Unsupported tag type")
                completion?(.failure(.readError("Unknown tag type")))
            }
        }
    }

    @available(iOS 13.0, *)
    private func writeToMiFareTag(_ tag: NFCMiFareTag, session: NFCTagReaderSession) {
        print("📝 Writing to MiFare tag")
        print("   Tag identifier: \(tag.identifier.hexString)")
        print("   Tag type: MiFare")

        guard let ndefMessage = self.writeNDEFMessage else {
            print("❌ ERROR: writeNDEFMessage is nil!")
            print("   writeMessage: \(self.writeMessage ?? "nil")")
            print("   This should never happen - the message should have been set before starting the session")
            let completion = self.writeCompletion
            self.writeCompletion = nil
            self.writeMessage = nil
            self.writeNDEFMessage = nil
            session.invalidate(errorMessage: "No message to write")
            completion?(.failure(.readError("No message to write")))
            return
        }

        print("✅ NDEF message ready to write")
        print("   Records: \(ndefMessage.records.count)")
        for (i, record) in ndefMessage.records.enumerated() {
            print("   Record \(i): \(record.payload.count) bytes")
        }

        // Query NDEF status
        print("🔍 Querying NDEF status of tag...")
        tag.queryNDEFStatus { [weak self] status, capacity, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Failed to query NDEF status: \(error.localizedDescription)")
                print("   - Error domain: \((error as NSError).domain)")
                print("   - Error code: \((error as NSError).code)")

                // Check for "data is missing" type errors
                if error.localizedDescription.contains("missing") ||
                   error.localizedDescription.contains("data") ||
                   error.localizedDescription.contains("read") {
                    print("   🚨 This tag appears to be blank or not NDEF-formatted!")
                    print("   💡 Solution: Use NTAG 213/215/216 tags or format the tag first")
                }

                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Tag not NDEF compatible")
                completion?(.failure(.readError("Tag query failed: \(error.localizedDescription)")))
                return
            }

            print("📊 NDEF Status: \(status.rawValue), Capacity: \(capacity) bytes")

            // Log what the status means
            switch status {
            case .notSupported:
                print("   - Status: Not supported initially (will attempt to format blank NTAG tags)")
            case .readOnly:
                print("   - Status: Read-only (tag is locked)")
            case .readWrite:
                print("   - Status: Read-write (tag can be written to)")
            @unknown default:
                print("   - Status: Unknown")
            }

            switch status {
            case .notSupported:
                // For blank/unformatted tags, iOS can format them during write
                print("⚠️ Tag reports as not NDEF supported - attempting to format and write...")
                print("   💡 iOS will attempt to format compatible tags (NTAG 213/215/216)")
                print("   💡 MIFARE Classic tags cannot be formatted to NDEF")
                self.attemptWriteToTag(tag, ndefMessage: ndefMessage, session: session)
            case .readOnly:
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Tag is read-only")
                completion?(.failure(.readError("Tag is read-only")))
            case .readWrite:
                // Write the NDEF message
                self.attemptWriteToTag(tag, ndefMessage: ndefMessage, session: session)
            @unknown default:
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Unknown tag status")
                completion?(.failure(.readError("Unknown tag status")))
            }
        }
    }

    @available(iOS 13.0, *)
    private func attemptWriteToTag(_ tag: NFCMiFareTag, ndefMessage: NFCNDEFMessage, session: NFCTagReaderSession) {
        print("📝 Attempting to write NDEF message to tag...")
        print("   - Tag identifier: \(tag.identifier.hexString)")
        print("   - Message records: \(ndefMessage.records.count)")
        print("   - Message size: ~\(ndefMessage.records.reduce(0) { $0 + $1.payload.count }) bytes")

        tag.writeNDEF(ndefMessage) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Failed to write NDEF: \(error.localizedDescription)")
                print("   - Error domain: \((error as NSError).domain)")
                print("   - Error code: \((error as NSError).code)")

                // Provide specific guidance based on error type
                let errorDesc = error.localizedDescription.lowercased()
                if errorDesc.contains("format") || errorDesc.contains("ndef") || errorDesc.contains("not supported") {
                    print("   🚨 Tag formatting failed - this tag type doesn't support NDEF")
                    print("   💡 Supported tags: NTAG 213, NTAG 215, NTAG 216")
                    print("   💡 Avoid: MIFARE Classic, unformatted tags")
                } else if errorDesc.contains("capacity") || errorDesc.contains("size") {
                    print("   🚨 Tag capacity exceeded")
                    print("   💡 Try a larger capacity tag (NTAG 215/216 instead of 213)")
                } else if errorDesc.contains("lock") || errorDesc.contains("read") {
                    print("   🚨 Tag is locked or read-only")
                    print("   💡 This tag has been permanently locked")
                }

                // Try alternative approach for certain error types
                if errorDesc.contains("format") || errorDesc.contains("ndef") {
                    print("   🔄 Attempting alternative formatting approach...")
                    self.tryAlternativeWrite(tag, ndefMessage: ndefMessage, session: session)
                    return // Don't complete yet, alternative method will handle completion
                }

                // Provide user-friendly error message
                var userMessage = "Write failed: \(error.localizedDescription)"
                if errorDesc.contains("format") || errorDesc.contains("ndef") || errorDesc.contains("not supported") {
                    userMessage = "This NFC tag type is not supported. Please use NTAG 213, 215, or 216 tags."
                } else if errorDesc.contains("capacity") {
                    userMessage = "NFC tag capacity too small. Please use a larger capacity tag."
                }

                // Clean up and complete with error
                let writeCompletion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Write failed")
                writeCompletion?(.failure(.readError(userMessage)))
            } else {
                print("✅ Successfully wrote NDEF message to tag")

                // Check if we should lock the tag after writing
                if self.shouldLockTag {
                    print("🔒 Tag locking requested but not supported on this iOS version")
                    print("⚠️ Tag was written but not locked (locking not available)")
                }

                // Continue with completion regardless of locking result
                let tagId = tag.identifier.hexString
                let result = NFCResult(
                    tagId: tagId,
                    ndefMessage: ndefMessage,
                    payload: self.writeMessage,
                    timestamp: Date(),
                    arTransform: nil,
                    cameraTransform: nil
                )
                session.alertMessage = self.shouldLockTag ?
                    "Loot data written successfully!" : "Loot data written successfully!"

                // Clean up and complete with success
                let writeCompletion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                self.shouldLockTag = false

                // Now invalidate the session
                session.invalidate()

                // Call the completion handler
                writeCompletion?(.success(result))
            }
        }
    }

    @available(iOS 13.0, *)
    private func tryAlternativeWrite(_ tag: NFCMiFareTag, ndefMessage: NFCNDEFMessage, session: NFCTagReaderSession) {
        print("🔄 Trying alternative write approach...")

        // Some tags need a "priming" write with minimal data first
        // Create a minimal NDEF message to format the tag
        let minimalPayload = "CacheRaiders".data(using: .utf8)!
        let minimalRecord = NFCNDEFPayload(
            format: .nfcWellKnown,
            type: "T".data(using: .utf8)!,
            identifier: Data(),
            payload: minimalPayload
        )
        let minimalMessage = NFCNDEFMessage(records: [minimalRecord])

        print("   📝 Step 1: Writing minimal message to format tag...")
        tag.writeNDEF(minimalMessage) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                print("   ❌ Minimal format write failed: \(error.localizedDescription)")
                print("   💡 This tag likely doesn't support NDEF formatting")

                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Tag doesn't support NDEF")
                completion?(.failure(.readError("This NFC tag type cannot be formatted for NDEF. Please use NTAG 213, 215, or 216 tags.")))
            } else {
                print("   ✅ Minimal format write succeeded")

                // Now try writing the full message
                print("   📝 Step 2: Writing full message...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Small delay
                    tag.writeNDEF(ndefMessage) { error in
                        if let error = error {
                            print("   ❌ Full message write failed: \(error.localizedDescription)")

                            let completion = self.writeCompletion
                            self.writeCompletion = nil
                            self.writeMessage = nil
                            self.writeNDEFMessage = nil
                            session.invalidate(errorMessage: "Write failed after formatting")
                            completion?(.failure(.readError("Failed to write data after formatting tag")))
                        } else {
                            print("   ✅ Full message write succeeded after formatting!")

                            // Success! Complete the operation
                            let tagId = tag.identifier.hexString
                            let result = NFCResult(
                                tagId: tagId,
                                ndefMessage: ndefMessage,
                                payload: self.writeMessage,
                                timestamp: Date(),
                                arTransform: nil,
                                cameraTransform: nil
                            )

                            let completion = self.writeCompletion
                            self.writeCompletion = nil
                            self.writeMessage = nil
                            self.writeNDEFMessage = nil
                            self.shouldLockTag = false

                            session.invalidate()
                            completion?(.success(result))
                        }
                    }
                }
            }
        }
    }

    @available(iOS 13.0, *)
    private func writeToISO7816Tag(_ tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        print("📝 ISO7816 tags typically don't support NDEF writing")
        let completion = self.writeCompletion
        self.writeCompletion = nil
        self.writeMessage = nil
        self.writeNDEFMessage = nil
        session.invalidate(errorMessage: "Tag type not supported for writing")
        completion?(.failure(.readError("ISO7816 tags not supported for NDEF writing")))
    }

    @available(iOS 13.0, *)
    private func writeToISO15693Tag(_ tag: NFCISO15693Tag, session: NFCTagReaderSession) {
        print("📝 Writing to ISO15693 tag")
        // ISO15693 tags can support NDEF, but implementation is more complex
        // For now, we'll focus on MiFare tags which are most common
        let completion = self.writeCompletion
        self.writeCompletion = nil
        self.writeMessage = nil
        self.writeNDEFMessage = nil
        session.invalidate(errorMessage: "ISO15693 tags not yet supported")
        completion?(.failure(.readError("ISO15693 tags not yet supported")))
    }
}

// MARK: - Extensions
extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

extension NFCReaderError {
    var isUserCancelledError: Bool {
        return code == .readerSessionInvalidationErrorUserCanceled
    }
}

