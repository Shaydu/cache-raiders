import Foundation
import Combine

// MARK: - WebSocket Service
// Note: Socket.IO requires a specific client library for full protocol support.
// This service provides basic connection status tracking.
// For full Socket.IO support, consider adding Socket.IO-Client-Swift library.
class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    @Published var isConnected: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
        
        var displayName: String {
            switch self {
            case .disconnected:
                return "Disconnected"
            case .connecting:
                return "Connecting..."
            case .connected:
                return "Connected"
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }
    
    // Socket.IO handshake state
    private enum HandshakeState {
        case notStarted
        case waitingForSessionInfo  // Waiting for "0" packet with session info
        case waitingForNamespaceConfirmation  // Sent "40", waiting for "40" response
        case completed
    }
    private var handshakeState: HandshakeState = .notStarted
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var healthCheckTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private let reconnectInterval: TimeInterval = 5.0
    private let pingInterval: TimeInterval = 30.0
    private let healthCheckInterval: TimeInterval = 10.0
    private let connectionTimeoutInterval: TimeInterval = 10.0 // Timeout after 10 seconds
    
    // Callbacks for WebSocket events
    var onObjectCollected: ((String, String, String) -> Void)? // (object_id, found_by, found_at)
    var onObjectUncollected: ((String) -> Void)? // (object_id)
    var onAllFindsReset: (() -> Void)?
    var onConnectionError: ((String) -> Void)? // (error_message)
    
    var baseURL: String {
        // Use the same validated baseURL as APIService to ensure consistency
        return APIService.shared.baseURL
    }
    
    private init() {
        // Start periodic health checks
        startHealthCheckTimer()
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Connection Management
    
    func connect() {
        guard !isConnected else {
            print("🔌 WebSocket already connected")
            return
        }
        
        // Convert HTTP URL to WebSocket URL
        // Socket.IO endpoint: /socket.io/?EIO=4&transport=websocket
        let httpURL = baseURL.replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        
        guard let wsURL = URL(string: "\(httpURL)/socket.io/?EIO=4&transport=websocket") else {
            let errorMsg = "Invalid WebSocket URL: \(httpURL)"
            connectionStatus = .error(errorMsg)
            DispatchQueue.main.async {
                self.onConnectionError?(errorMsg)
            }
            return
        }
        
        connectionStatus = .connecting
        handshakeState = .waitingForSessionInfo
        
        // Start connection timeout timer
        startConnectionTimeoutTimer()
        
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: WebSocketDelegate(service: self), delegateQueue: nil)
        
        webSocketTask = urlSession?.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        
        receiveMessage()
        
        print("🔌 Attempting WebSocket connection to \(wsURL)")
    }
    
    func disconnect() {
        stopPingTimer()
        stopReconnectTimer()
        stopConnectionTimeoutTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        connectionStatus = .disconnected
        handshakeState = .notStarted
        print("🔌 WebSocket disconnected")
    }
    
    // MARK: - Health Check
    
    private func startHealthCheckTimer() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.checkConnectionHealth()
        }
    }
    
    private func checkConnectionHealth() {
        // Check if API is available (this indicates server is running)
        Task {
            do {
                let isHealthy = try await APIService.shared.checkHealth()
                if isHealthy && !isConnected {
                    // Server is up but WebSocket not connected, try to connect
                    await MainActor.run {
                        if connectionStatus == .disconnected {
                            connect()
                        }
                    }
                } else if !isHealthy {
                    // Server is down
                    await MainActor.run {
                        isConnected = false
                        connectionStatus = .disconnected
                    }
                }
            } catch {
                // Server unavailable
                await MainActor.run {
                    isConnected = false
                    connectionStatus = .disconnected
                }
            }
        }
    }
    
    // MARK: - Message Handling
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("📨 WebSocket received: \(text)")
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        print("📨 WebSocket received (data): \(text)")
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving messages
                self.receiveMessage()
                
            case .failure(let error):
                print("❌ WebSocket receive error: \(error)")
                self.handleError(error)
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        print("📨 WebSocket received raw: \(text)")
        
        // Socket.IO handshake protocol:
        // 1. Server sends "0" packet with session info: 0{"sid":"...","upgrades":[],"pingInterval":25000,"pingTimeout":5000}
        // 2. Client sends "40" to connect to default namespace
        // 3. Server responds with "40" to confirm namespace connection
        
        // Handle Socket.IO handshake
        if text.hasPrefix("0{") {
            // Received session info packet - now send "40" to connect to namespace
            print("✅ Received Socket.IO session info, connecting to namespace...")
            handshakeState = .waitingForNamespaceConfirmation
            sendSocketIOPacket("40")
            return
        }
        
        if text == "40" {
            // Received namespace confirmation - handshake complete!
            print("✅ Socket.IO handshake complete!")
            handshakeState = .completed
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionStatus = .connected
                self.stopConnectionTimeoutTimer()
                self.stopReconnectTimer()
                self.startPingTimer()
            }
            return
        }
        
        // Handle Socket.IO event messages: format is "42["event_name", {...}]"
        // Example: 42["object_collected",{"object_id":"abc","found_by":"user123","found_at":"2024-..."}]
        if text.hasPrefix("42[") {
            // Check if this is the 'connected' event from the server
            if text.contains("\"connected\"") || text.contains("'connected'") {
                // Server sent connected event - handshake is complete
                print("✅ Received Socket.IO 'connected' event from server")
                if handshakeState != .completed {
                    handshakeState = .completed
                    DispatchQueue.main.async {
                        self.isConnected = true
                        self.connectionStatus = .connected
                        self.stopConnectionTimeoutTimer()
                        self.stopReconnectTimer()
                        self.startPingTimer()
                    }
                }
            }
            parseSocketIOEvent(text)
            return
        }
        
        // Handle other Socket.IO packet types
        if text == "3" {
            // Pong response (we sent ping "2", server responds with "3")
            print("📡 Received pong")
            return
        }
        
        // Legacy check for backward compatibility (in case server sends different format)
        if text.contains("connected") && handshakeState == .waitingForNamespaceConfirmation {
            print("✅ Received connection confirmation (legacy format)")
            handshakeState = .completed
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionStatus = .connected
                self.stopConnectionTimeoutTimer()
                self.stopReconnectTimer()
                self.startPingTimer()
            }
            return
        }
        
        print("⚠️ Unhandled Socket.IO message: \(text)")
    }
    
    /// Send a Socket.IO packet
    private func sendSocketIOPacket(_ packet: String) {
        guard let webSocketTask = webSocketTask else {
            print("❌ Cannot send packet: WebSocket not connected")
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(packet)
        webSocketTask.send(message) { error in
            if let error = error {
                print("❌ Failed to send Socket.IO packet '\(packet)': \(error)")
                self.handleError(error)
            } else {
                print("📤 Sent Socket.IO packet: \(packet)")
            }
        }
    }
    
    /// Parse Socket.IO event message format: 42["event_name", {...}]
    private func parseSocketIOEvent(_ text: String) {
        // Find the opening bracket after "42["
        guard let startIndex = text.index(text.startIndex, offsetBy: 3, limitedBy: text.endIndex) else { return }
        
        // Extract the JSON array part: ["event_name", {...}]
        let jsonPart = String(text[startIndex...])
        
        // Try to parse as JSON array
        guard let jsonData = jsonPart.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              jsonArray.count >= 2,
              let eventName = jsonArray[0] as? String,
              let eventData = jsonArray[1] as? [String: Any] else {
            // Fallback: try simple string matching for common events
            if text.contains("object_collected") {
                print("⚠️ Received object_collected event but couldn't parse data")
            }
            return
        }
        
        // Handle different event types
        switch eventName {
        case "object_collected":
            handleObjectCollectedEvent(eventData)
            
        case "object_uncollected":
            handleObjectUncollectedEvent(eventData)
            
        case "all_finds_reset":
            handleAllFindsResetEvent()
            
        default:
            print("📨 Received unhandled Socket.IO event: \(eventName)")
        }
    }
    
    /// Handle object_collected event: {"object_id": "...", "found_by": "...", "found_at": "..."}
    private func handleObjectCollectedEvent(_ data: [String: Any]) {
        guard let objectId = data["object_id"] as? String else {
            print("⚠️ object_collected event missing object_id")
            return
        }
        
        let foundBy = data["found_by"] as? String ?? "unknown"
        let foundAt = data["found_at"] as? String ?? ""
        
        print("🎯 WebSocket: Object collected - ID: \(objectId), by: \(foundBy)")
        
        DispatchQueue.main.async {
            self.onObjectCollected?(objectId, foundBy, foundAt)
        }
    }
    
    /// Handle object_uncollected event: {"object_id": "..."}
    private func handleObjectUncollectedEvent(_ data: [String: Any]) {
        guard let objectId = data["object_id"] as? String else {
            print("⚠️ object_uncollected event missing object_id")
            return
        }
        
        print("🔄 WebSocket: Object uncollected - ID: \(objectId)")
        
        DispatchQueue.main.async {
            self.onObjectUncollected?(objectId)
        }
    }
    
    /// Handle all_finds_reset event
    private func handleAllFindsResetEvent() {
        print("🔄 WebSocket: All finds reset")
        
        DispatchQueue.main.async {
            self.onAllFindsReset?()
        }
    }
    
    func sendPing() {
        guard isConnected, handshakeState == .completed else { return }
        // Socket.IO ping is packet type "2"
        sendSocketIOPacket("2")
    }
    
    // MARK: - Timers
    
    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }
    
    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
    
    private func startReconnectTimer() {
        stopReconnectTimer()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
    
    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    // MARK: - Connection Handlers
    
    func handleConnection() {
        // WebSocket is open, but Socket.IO handshake hasn't completed yet
        // We'll wait for the "0" session info packet before proceeding
        print("✅ WebSocket opened, waiting for Socket.IO handshake...")
        // Don't set isConnected = true yet - wait for Socket.IO handshake to complete
    }
    
    func handleDisconnection() {
        let wasConnected = isConnected
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .disconnected
            self.handshakeState = .notStarted
        }
        print("⚠️ WebSocket disconnected")
        
        // Attempt to reconnect if we were previously connected
        if wasConnected {
            startReconnectTimer()
        }
    }
    
    func handleError(_ error: Error) {
        stopConnectionTimeoutTimer()
        let errorMsg = error.localizedDescription
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .error(errorMsg)
            self.handshakeState = .notStarted
            self.onConnectionError?(errorMsg)
        }
        print("❌ WebSocket error: \(errorMsg)")
        
        // Attempt to reconnect
        startReconnectTimer()
    }
    
    // MARK: - Connection Timeout
    
    private func startConnectionTimeoutTimer() {
        stopConnectionTimeoutTimer()
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeoutInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Check if we're still in connecting state and handshake hasn't completed
            if case .connecting = self.connectionStatus, !self.isConnected, self.handshakeState != .completed {
                let errorMsg = "Connection timeout: Unable to complete Socket.IO handshake to \(self.baseURL) after \(Int(self.connectionTimeoutInterval)) seconds. Please check:\n• Server is running\n• URL is correct\n• Device is on the same network\n• Firewall allows connections"
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.connectionStatus = .error(errorMsg)
                    self.handshakeState = .notStarted
                    self.onConnectionError?(errorMsg)
                }
                print("⏱️ WebSocket connection timeout (handshake state: \(self.handshakeState))")
                // Cancel the connection attempt
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession = nil
            }
        }
    }
    
    private func stopConnectionTimeoutTimer() {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
    }
}

// MARK: - URLSessionWebSocketDelegate
private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    weak var service: WebSocketService?
    
    init(service: WebSocketService) {
        self.service = service
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        service?.handleConnection()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown reason"
        let closeCodeString = closeCodeDescription(closeCode)
        print("🔌 WebSocket closed: \(closeCodeString), reason: \(reasonString)")
        service?.handleDisconnection()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            service?.handleError(error)
        }
    }
    
    private func closeCodeDescription(_ code: URLSessionWebSocketTask.CloseCode) -> String {
        switch code {
        case .invalid:
            return "Invalid"
        case .normalClosure:
            return "Normal closure"
        case .goingAway:
            return "Going away"
        case .protocolError:
            return "Protocol error"
        case .unsupportedData:
            return "Unsupported data"
        case .noStatusReceived:
            return "No status received"
        case .abnormalClosure:
            return "Abnormal closure"
        case .invalidFramePayloadData:
            return "Invalid frame payload data"
        case .policyViolation:
            return "Policy violation"
        case .messageTooBig:
            return "Message too big"
        case .mandatoryExtensionMissing:
            return "Mandatory extension missing"
        case .internalServerError:
            return "Internal server error"
        @unknown default:
            return "Unknown code (\(code.rawValue))"
        }
    }
}

