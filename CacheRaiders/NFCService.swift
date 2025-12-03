import CoreNFC
import UIKit

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

    // MARK: - NFC Result
    struct NFCResult {
        let tagId: String
        let ndefMessage: NFCNDEFMessage?
        let payload: String?
        let timestamp: Date
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
    func scanNFC(completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
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

        // Create new reader session
        print("📱 Creating NFC reader session...")
        readerSession = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        readerSession?.alertMessage = "Hold your iPhone near an NFC tag to read it."

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

    @available(iOS 13.0, *)
    func writeNFC(message: String, completion: @escaping (Result<NFCResult, NFCError>) -> Void) {
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
        guard let ndefMessage = createNDEFMessage(from: message) else {
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
            default:
                nfcError = .sessionInvalidated
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

        let result = NFCResult(
            tagId: tagId,
            ndefMessage: message,
            payload: payload,
            timestamp: Date()
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

    private func createNDEFMessage(from urlString: String) -> NFCNDEFMessage? {
        print("🔨 Creating compact NDEF URI record")
        print("   URL: \(urlString)")
        print("   URL length: \(urlString.count) characters")

        // Validate this is a URL (should start with http:// or https://)
        let isURL = urlString.hasPrefix("http://") || urlString.hasPrefix("https://")

        if !isURL {
            print("⚠️ Input doesn't appear to be a valid URL")
            return nil
        }

        // Check URL length - NFC tags have limited capacity (typically ~144 bytes)
        if urlString.count > 100 {
            print("⚠️ Warning: URL is \(urlString.count) characters, may exceed NFC tag capacity")
        }

        // Create NDEF URI record (TNF = NFC Well Known, Type = "U")
        // URI format: [URI identifier byte] + [URI string bytes]

        // Determine URI identifier byte based on prefix for optimal compression
        var uriIdentifier: UInt8 = 0x00 // No prefix
        if urlString.hasPrefix("http://") {
            uriIdentifier = 0x03 // http://www.
        } else if urlString.hasPrefix("https://") {
            uriIdentifier = 0x04 // https://www.
        }

        // Remove the prefix if we're using a URI identifier (saves space)
        var uriPayload = urlString
        if uriIdentifier == 0x03 && urlString.hasPrefix("http://") {
            uriPayload = String(urlString.dropFirst(7)) // Remove "http://"
        } else if uriIdentifier == 0x04 && urlString.hasPrefix("https://") {
            uriPayload = String(urlString.dropFirst(8)) // Remove "https://"
        }

        guard let uriData = uriPayload.data(using: .utf8) else {
            print("❌ Failed to convert URI string to data")
            return nil
        }

        var payload = Data()
        payload.append(uriIdentifier)
        payload.append(uriData)

        print("   URI payload size: \(payload.count) bytes")
        print("   URI identifier: 0x\(String(format: "%02X", uriIdentifier))")
        print("   Total NDEF message size estimate: ~\(payload.count + 10) bytes")

        let uriRecord = NFCNDEFPayload(
            format: .nfcWellKnown,
            type: "U".data(using: .utf8)!,
            identifier: Data(),
            payload: payload
        )

        // Create NDEF message with the URI record
        let ndefMessage = NFCNDEFMessage(records: [uriRecord])

        print("✅ Created compact URI NDEF record")
        print("   Record type: URI (compact)")
        print("   Payload contains object ID only")

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
        if let readerError = error as? NFCReaderError {
            print("   - Reader error code: \(readerError.code.rawValue)")
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
            default:
                nfcError = .sessionInvalidated
                print("   → Session invalidated: \(readerError.code)")
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
        tag.queryNDEFStatus { [weak self] status, capacity, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Failed to query NDEF status: \(error.localizedDescription)")
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Tag not NDEF compatible")
                completion?(.failure(.readError("Tag query failed: \(error.localizedDescription)")))
                return
            }

            print("📊 NDEF Status: \(status.rawValue), Capacity: \(capacity) bytes")

            switch status {
            case .notSupported:
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Tag is not NDEF formatted")
                completion?(.failure(.readError("Tag is not NDEF formatted")))
            case .readOnly:
                let completion = self.writeCompletion
                self.writeCompletion = nil
                self.writeMessage = nil
                self.writeNDEFMessage = nil
                session.invalidate(errorMessage: "Tag is read-only")
                completion?(.failure(.readError("Tag is read-only")))
            case .readWrite:
                // Write the NDEF message
                tag.writeNDEF(ndefMessage) { error in
                    if let error = error {
                        print("❌ Failed to write NDEF: \(error.localizedDescription)")
                        let completion = self.writeCompletion
                        self.writeCompletion = nil
                        self.writeMessage = nil
                        self.writeNDEFMessage = nil
                        session.invalidate(errorMessage: "Write failed")
                        completion?(.failure(.readError("Write failed: \(error.localizedDescription)")))
                    } else {
                        print("✅ Successfully wrote NDEF message to tag")
                        let tagId = tag.identifier.hexString
                        let result = NFCResult(
                            tagId: tagId,
                            ndefMessage: ndefMessage,
                            payload: self.writeMessage,
                            timestamp: Date()
                        )
                        session.alertMessage = "Loot data written successfully!"

                        // Call completion handler BEFORE invalidating
                        // and clear it immediately so the invalidation handler doesn't call it again
                        let completion = self.writeCompletion
                        self.writeCompletion = nil
                        self.writeMessage = nil
                        self.writeNDEFMessage = nil

                        // Now invalidate the session (this will trigger didInvalidateWithError)
                        session.invalidate()

                        // Call the completion handler
                        completion?(.success(result))
                    }
                }
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
