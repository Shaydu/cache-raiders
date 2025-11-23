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
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var healthCheckTimer: Timer?
    private let reconnectInterval: TimeInterval = 5.0
    private let pingInterval: TimeInterval = 30.0
    private let healthCheckInterval: TimeInterval = 10.0
    
    // Callbacks for WebSocket events
    var onObjectCollected: ((String, String, String) -> Void)? // (object_id, found_by, found_at)
    var onObjectUncollected: ((String) -> Void)? // (object_id)
    var onAllFindsReset: (() -> Void)?
    
    var baseURL: String {
        if let customURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !customURL.isEmpty {
            return customURL
        }
        // Default port is 5001
        return "http://localhost:5001"
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
            connectionStatus = .error("Invalid URL")
            return
        }
        
        connectionStatus = .connecting
        
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: WebSocketDelegate(service: self), delegateQueue: nil)
        
        webSocketTask = urlSession?.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        
        receiveMessage()
        startPingTimer()
        
        print("🔌 Attempting WebSocket connection to \(wsURL)")
    }
    
    func disconnect() {
        stopPingTimer()
        stopReconnectTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        connectionStatus = .disconnected
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
                self.handleDisconnection()
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        // Socket.IO messages are typically in format: "42["event", data]"
        // Check for connection confirmation
        if text.contains("connected") || text.contains("0{\"sid\"") || text.contains("40") {
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionStatus = .connected
                self.stopReconnectTimer()
            }
            return
        }
        
        // Parse Socket.IO event messages: format is "42["event_name", {...}]"
        // Example: 42["object_collected",{"object_id":"abc","found_by":"user123","found_at":"2024-..."}]
        if text.hasPrefix("42[") {
            parseSocketIOEvent(text)
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
        guard isConnected else { return }
        let message = URLSessionWebSocketTask.Message.string("2")
        webSocketTask?.send(message) { error in
            if let error = error {
                print("❌ WebSocket ping error: \(error)")
                self.handleDisconnection()
            }
        }
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
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionStatus = .connected
            self.stopReconnectTimer()
        }
        print("✅ WebSocket connected")
    }
    
    func handleDisconnection() {
        let wasConnected = isConnected
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .disconnected
        }
        print("⚠️ WebSocket disconnected")
        
        // Attempt to reconnect if we were previously connected
        if wasConnected {
            startReconnectTimer()
        }
    }
    
    func handleError(_ error: Error) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .error(error.localizedDescription)
        }
        print("❌ WebSocket error: \(error.localizedDescription)")
        
        // Attempt to reconnect
        startReconnectTimer()
    }
}

// MARK: - URLSessionWebSocketDelegate
private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var service: WebSocketService?
    
    init(service: WebSocketService) {
        self.service = service
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        service?.handleConnection()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        service?.handleDisconnection()
    }
}

