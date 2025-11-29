import SwiftUI

// MARK: - Conversation Message
struct ConversationMessage: Identifiable {
    let id = UUID()
    let text: String
    let isFromUser: Bool
    let timestamp: Date
    
    init(text: String, isFromUser: Bool) {
        self.text = text
        self.isFromUser = isFromUser
        self.timestamp = Date()
    }
}

// MARK: - Skeleton Conversation View
struct SkeletonConversationView: View {
    let npcName: String
    let npcId: String
    var onMapMentioned: (() -> Void)? = nil // Callback when user mentions the map
    @ObservedObject var treasureHuntService: TreasureHuntService
    @ObservedObject var userLocationManager: UserLocationManager
    @Environment(\.dismiss) var dismiss
    @State private var messages: [ConversationMessage] = []
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isTextFieldFocused: Bool
    
    // Initial greeting from skeleton
    private let initialGreeting = "Arr, ye've found me, matey! I be Captain Bones, a skeleton from 200 years ago. I know where the treasure be buried! Ask me anything, and I'll help ye find it!"
    
    var body: some View {
        VStack(spacing: 0) {
            // Compact header with drag indicator
            HStack {
                Text("💀 \(npcName)")
                    .font(.headline)
                    .foregroundColor(.yellow.opacity(0.9))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            // Messages list (scrollable)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Initial greeting (compact)
                        if messages.isEmpty {
                            ShadowgateMessageBox(
                                text: initialGreeting,
                                isFromUser: false,
                                npcName: npcName
                            )
                            .id("greeting")
                        }
                        
                        // Conversation messages
                        ForEach(messages) { message in
                            ShadowgateMessageBox(
                                text: message.text,
                                isFromUser: message.isFromUser,
                                npcName: npcName
                            )
                            .id(message.id)
                        }
                        
                        // Loading indicator
                        if isSending {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Thinking...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: messages.count) { _, _ in
                    // Scroll to bottom when new message arrives
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    } else if messages.isEmpty {
                        withAnimation {
                            proxy.scrollTo("greeting", anchor: .top)
                        }
                    }
                }
            }
            
            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 2)
            }
            
            // Input area (compact)
            HStack(spacing: 8) {
                TextField("Ask...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(isSending)
                    .focused($isTextFieldFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        sendMessage()
                    }
                    .onTapGesture {
                        // Ensure keyboard appears when tapping the field
                        isTextFieldFocused = true
                    }
                
                Button(action: sendMessage) {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundColor(inputText.isEmpty ? .gray : .blue)
                    }
                }
                .disabled(inputText.isEmpty || isSending)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .background(Color.black.opacity(0.95))
        .onAppear {
            // Auto-focus the text field when the view appears
            // Use a longer delay to ensure the sheet is fully presented
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
    }
    
    private func sendMessage() {
        guard !inputText.isEmpty, !isSending else { return }
        
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        
        // Check if user is asking for map/treasure/directions using TreasureHuntService detection
        if treasureHuntService.isMapRequest(userMessage) {
            // Play happy jig sound
            LootBoxAnimation.playOpeningSound()
            
            // Add user message to conversation
            let userMsg = ConversationMessage(text: userMessage, isFromUser: true)
            messages.append(userMsg)
            
            // Fetch treasure map from NPC if we have the required services
            if let userLocation = userLocationManager.currentLocation {
                isSending = true
                Task {
                    do {
                        // Fetch the treasure map (this will NOT call the LLM API)
                        try await treasureHuntService.handleMapRequest(
                            npcId: npcId,
                            npcName: npcName,
                            userLocation: userLocation
                        )
                        
                        await MainActor.run {
                            // Add NPC response about the map (local response, not from LLM)
                            let npcMsg = ConversationMessage(
                                text: "Arr! Here be the treasure map, matey! Follow it to find the booty! The X marks the spot where the treasure be buried!",
                                isFromUser: false
                            )
                            messages.append(npcMsg)
                            
                            isSending = false
                            
                            // Open the treasure map view after a brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                onMapMentioned?()
                            }
                        }
                    } catch {
                        await MainActor.run {
                            // Show error message
                            if let apiError = error as? APIError {
                                switch apiError {
                                case .serverError(let message):
                                    errorMessage = "Failed to get map: \(message)"
                                case .serverUnreachable:
                                    errorMessage = "Cannot reach server. Make sure it's running."
                                default:
                                    errorMessage = "Failed to get treasure map: \(apiError.localizedDescription)"
                                }
                            } else {
                                errorMessage = "Failed to get treasure map: \(error.localizedDescription)"
                            }
                            isSending = false
                        }
                    }
                }
                return // Don't send to LLM API - we intercepted and handled it
            } else {
                // Fallback: just open the map view if services aren't available
                onMapMentioned?()
                return // Don't send to LLM API
            }
        }
        
        // Add user message to conversation
        let userMsg = ConversationMessage(text: userMessage, isFromUser: true)
        messages.append(userMsg)
        
        // Send to LLM API (only if not a map request)
        isSending = true
        errorMessage = nil
        
        Task {
            do {
                let response = try await APIService.shared.interactWithNPC(
                    npcId: npcId,
                    message: userMessage,
                    npcName: npcName,
                    npcType: "skeleton",
                    isSkeleton: true
                )
                
                await MainActor.run {
                    // Add NPC message - it will display with typewriter effect
                    let npcMsg = ConversationMessage(text: response.response, isFromUser: false)
                    messages.append(npcMsg)
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    // Provide user-friendly error messages
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .serverError(let message):
                            if message.contains("LLM service not available") || message.contains("not available") {
                                errorMessage = "LLM service not available on server. Check server logs."
                            } else {
                                errorMessage = "Server error: \(message)"
                            }
                        case .serverUnreachable:
                            errorMessage = "Cannot reach server. Make sure it's running and on the same network."
                        case .httpError(let code):
                            if code == 503 {
                                errorMessage = "LLM service unavailable. Check if LLM service is running on server."
                            } else {
                                errorMessage = "Server error (HTTP \(code))"
                            }
                        default:
                            errorMessage = apiError.localizedDescription
                        }
                    } else {
                        let errorDesc = error.localizedDescription
                        if errorDesc.contains("not available") || errorDesc.contains("unreachable") {
                            errorMessage = "Cannot reach server. Make sure it's running."
                        } else {
                            errorMessage = "Error: \(errorDesc)"
                        }
                    }
                    isSending = false
                }
            }
        }
    }
}

// MARK: - Shadowgate Style Message Box
struct ShadowgateMessageBox: View {
    let text: String
    let isFromUser: Bool
    let npcName: String
    
    var body: some View {
        HStack {
            if isFromUser {
                Spacer()
            }
            
            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 2) {
                if !isFromUser {
                    Text(npcName)
                        .font(.caption2)
                        .foregroundColor(.yellow.opacity(0.8))
                        .fontWeight(.bold)
                }
                
                // Shadowgate-style bordered box
                ZStack {
                    // Dark background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.85))
                    
                    // Border (Shadowgate style - double border effect)
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.yellow.opacity(0.6), Color.orange.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                    
                    // Inner border for depth
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
                        .padding(2)
                    
                    // Text content with typewriter effect
                    VStack(alignment: .leading, spacing: 0) {
                        if isFromUser {
                            // User messages: show immediately, no typewriter
                            Text(text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        } else {
                            // NPC messages: show immediately (no typewriter effect)
                            Text(text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.yellow.opacity(0.95))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            
            if !isFromUser {
                Spacer()
            }
        }
    }
}


