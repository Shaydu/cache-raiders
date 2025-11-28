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
    @Environment(\.dismiss) var dismiss
    @State private var messages: [ConversationMessage] = []
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    
    // Initial greeting from skeleton
    private let initialGreeting = "Arr, ye've found me, matey! I be Captain Bones, a skeleton from 200 years ago. I know where the treasure be buried! Ask me anything, and I'll help ye find it!"
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // Initial greeting
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
                                        .scaleEffect(0.8)
                                    Text("Captain Bones is thinking...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                        }
                        .padding()
                    }
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
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                }
                
                // Input area
                HStack(spacing: 12) {
                    TextField("Ask Captain Bones...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSending)
                        .onSubmit {
                            sendMessage()
                        }
                    
                    Button(action: sendMessage) {
                        if isSending {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundColor(inputText.isEmpty ? .gray : .blue)
                        }
                    }
                    .disabled(inputText.isEmpty || isSending)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle("💀 \(npcName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func sendMessage() {
        guard !inputText.isEmpty, !isSending else { return }
        
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        
        // Add user message to conversation
        let userMsg = ConversationMessage(text: userMessage, isFromUser: true)
        messages.append(userMsg)
        
        // Send to API
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
                            errorMessage = apiError.localizedDescription ?? "Unknown error"
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
    
    @StateObject private var typewriterService = TypewriterTextService()
    
    var body: some View {
        HStack {
            if isFromUser {
                Spacer()
            }
            
            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 4) {
                if !isFromUser {
                    Text(npcName)
                        .font(.caption)
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
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        } else {
                            // NPC messages: typewriter effect with audio
                            Text(typewriterService.displayedText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.yellow.opacity(0.95))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .onAppear {
                                    // Configure typewriter service
                                    typewriterService.charactersPerSecond = 30.0
                                    typewriterService.audioToneID = 1103 // Subtle notification sound
                                    typewriterService.playAudioForSpaces = false
                                    typewriterService.playAudioForPunctuation = false
                                    
                                    // Start reveal
                                    typewriterService.startReveal(text: text)
                                }
                                .onDisappear {
                                    typewriterService.cancel()
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
    }
}


