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
    private let initialGreeting = "Arr, ye've found me, matey! I be Captain Bones, the skeleton of a pirate who died 200 years ago today on this very spot. I know where the treasure be buried! Ask me anything, and I'll help ye find it!"
    
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
                        // Initial greeting (compact) - show immediately without typewriter effect
                        if messages.isEmpty {
                            ShadowgateMessageBox(
                                text: initialGreeting,
                                isFromUser: false,
                                npcName: npcName,
                                skipTypewriter: true // Skip typewriter for initial greeting to prevent freezing
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
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: messages.count) { oldCount, newCount in
                    // Only scroll if a new message was actually added (not removed)
                    guard newCount > oldCount else { return }

                    // Scroll to bottom when new message arrives
                    Task { @MainActor in
                        if let lastMessage = messages.last {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        } else if messages.isEmpty {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("greeting", anchor: .top)
                            }
                        }
                    }
                }
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
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
        .onAppear {
            // Auto-focus the text field when the view appears
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 seconds
                isTextFieldFocused = true
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                if !isTextFieldFocused {
                    isTextFieldFocused = true
                }
            }
        }
        .background(drawerBackground)
    }
    

    // MARK: - Actions
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
                // Perform API call off main thread to prevent UI blocking
                Task.detached(priority: .userInitiated) { [treasureHuntService, npcId, npcName, userLocation] in
                    do {
                        // Perform API call on background thread
                        try await treasureHuntService.handleMapRequest(
                            npcId: npcId,
                            npcName: npcName,
                            userLocation: userLocation
                        )

                        // Update UI on main thread
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
                        // Show error message on main thread
                        await MainActor.run {
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

        // Perform API call off main thread to prevent UI blocking
        // Use Task.detached to run on background thread, then update UI on main actor
        Task.detached(priority: .userInitiated) { [npcId, userMessage, npcName] in
            do {
                // Perform API call on background thread
                let response = try await APIService.shared.interactWithNPC(
                    npcId: npcId,
                    message: userMessage,
                    npcName: npcName,
                    npcType: "skeleton",
                    isSkeleton: true
                )

                // Update UI on main thread
                await MainActor.run {
                    // Add NPC message - it will display with typewriter effect
                    let npcMsg = ConversationMessage(text: response.response, isFromUser: false)
                    messages.append(npcMsg)
                    isSending = false
                }
            } catch {
                // Provide user-friendly error messages on main thread
                await MainActor.run {
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
    
    // MARK: - Background
    private var drawerBackground: some View {
        Color(.systemBackground)
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.yellow.opacity(0.1),
                        Color.orange.opacity(0.05),
                        Color.clear
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea()
    }
}

// MARK: - Shadowgate Style Message Box
struct ShadowgateMessageBox: View {
    let text: String
    let isFromUser: Bool
    let npcName: String
    var skipTypewriter: Bool = false // Skip typewriter effect (e.g., for initial greeting)
    
    @StateObject private var typewriterService = TypewriterTextService()
    @AppStorage("enableTypewriterEffect") private var enableTypewriterEffect: Bool = true
    
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
                            // NPC messages: use typewriter effect with sound if enabled
                            // Skip typewriter for initial greeting or when disabled
                            if enableTypewriterEffect && !skipTypewriter {
                                Text(typewriterService.displayedText.isEmpty ? "" : typewriterService.displayedText)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.yellow.opacity(0.95))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            } else {
                                Text(text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.yellow.opacity(0.95))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            
            if !isFromUser {
                Spacer()
            }
        }
        .onAppear {
            // Start typewriter effect for NPC messages if enabled and not skipped
            if !isFromUser && enableTypewriterEffect && !skipTypewriter {
                // Configure typewriter service with same settings as ARConversationOverlay
                typewriterService.charactersPerSecond = 30.0
                typewriterService.audioToneID = 1104 // Keyboard clack sound
                typewriterService.playAudioForSpaces = false
                typewriterService.playAudioForPunctuation = false
                typewriterService.randomVariation = 0.3
                typewriterService.punctuationPauseMultiplier = 3.0
                
                Task { @MainActor [text, typewriterService] in
                    typewriterService.startReveal(text: text)
                }
            }
        }
        .onDisappear {
            // Cancel typewriter effect when view disappears
            if !isFromUser {
                typewriterService.cancel()
            }
        }
        .onChange(of: text) { oldText, newText in
            // Restart typewriter effect if text changes and enabled and not skipped
            if !isFromUser && newText != oldText && enableTypewriterEffect && !skipTypewriter {
                Task { @MainActor in
                    typewriterService.startReveal(text: newText)
                }
            }
        }
        .onChange(of: enableTypewriterEffect) { oldValue, newValue in
            // Handle toggle change
            if !isFromUser {
                Task { @MainActor in
                    if newValue {
                        typewriterService.charactersPerSecond = 30.0
                        typewriterService.audioToneID = 1104
                        typewriterService.playAudioForSpaces = false
                        typewriterService.playAudioForPunctuation = false
                        typewriterService.randomVariation = 0.3
                        typewriterService.punctuationPauseMultiplier = 3.0
                        typewriterService.startReveal(text: text)
                    } else {
                        typewriterService.cancel()
                    }
                }
            }
        }
    }
}
