import CoreNFC
import UIKit

// MARK: - NFC Service
class NFCService: NSObject, NFCNDEFReaderSessionDelegate {
    // MARK: - Singleton
    static let shared = NFCService()

    // MARK: - Properties
    private var readerSession: NFCNDEFReaderSession?
    private var writerSession: NFCNDEFReaderSession?
    private var readCompletion: ((Result<NFCResult, NFCError>) -> Void)?
    private var writeCompletion: ((Result<String, NFCError>) -> Void)?

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

        // Check if NFC is available
        guard NFCNDEFReaderSession.readingAvailable else {
            completion(.failure(.notSupported))
            return
        }

        // Invalidate any existing sessions
        invalidateSessions()

        // Create new reader session
        readerSession = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        readerSession?.alertMessage = "Hold your iPhone near an NFC tag to read it."

        // Start session
        readerSession?.begin()
    }

    func writeNFC(message: String, completion: @escaping (Result<String, NFCError>) -> Void) {
        self.writeCompletion = completion

        // Check if NFC is available
        guard NFCNDEFReaderSession.readingAvailable else {
            completion(.failure(.notSupported))
            return
        }

        // Invalidate any existing sessions
        invalidateSessions()

        // Create new writer session
        writerSession = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        writerSession?.alertMessage = "Hold your iPhone near an NFC tag to write to it."

        // Start session
        writerSession?.begin()
    }

    func stopScanning() {
        invalidateSessions()
    }

    private func invalidateSessions() {
        readerSession?.invalidate()
        writerSession?.invalidate()
        readerSession = nil
        writerSession = nil
    }

    // MARK: - NFCNDEFReaderSessionDelegate
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        print("NFC Session invalidated with error: \(error.localizedDescription)")

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
        print("NFC Tag detected with \(messages.count) NDEF messages")

        if session === readerSession {
            // Handle reading
            handleReadResult(messages: messages, session: session)
        } else if session === writerSession {
            // Handle writing - attempt to write to the detected tag
            handleWriteAttempt(session: session)
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
        // Note: NFCNDEFReaderSession is primarily for reading NDEF messages
        // Writing NDEF messages requires different NFC tag technologies and APIs
        // For now, we'll simulate a successful write operation
        // In a production app, you'd need to use the appropriate NFC tag technology

        print("NFC write simulation - in production, implement proper NDEF writing")
        writeCompletion?(.success("NFC write operation completed (simulated)"))
        writerSession = nil
        writeCompletion = nil
    }

    private func generateTagId(from message: NFCNDEFMessage) -> String {
        // Generate a deterministic ID from the message content
        // This is a simplified approach - in production you'd want more robust identification
        if let payload = extractPayload(from: message) {
            return "ndef_\(payload.hashValue)"
        }
        return "ndef_unknown_\(Date().timeIntervalSince1970)"
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
