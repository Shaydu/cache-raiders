import SwiftUI
import Combine
import AudioToolbox

// MARK: - AR Conversation Overlay
/// 2D UI overlay that appears in the bottom third of the screen during NPC conversations
struct ARConversationOverlay: View {
    let npcName: String
    let message: String
    let isUserMessage: Bool

    @StateObject private var typewriterService = TypewriterTextService()
    @State private var isVisible: Bool = false

    var body: some View {
        GeometryReader { geometry in
            VStack {
                // Spacer to push content to halfway point (50% from top)
                Spacer()
                    .frame(height: geometry.size.height * 0.5)

                if isVisible {
                    VStack(alignment: .leading, spacing: 8) {
                        // NPC name header
                        HStack {
                            Text(isUserMessage ? "You" : "💀 \(npcName)")
                                .font(.system(.headline, design: .monospaced))
                                .foregroundColor(isUserMessage ? .blue : .yellow)
                            Spacer()
                        }

                        // Message content with typewriter effect
                        Text(isUserMessage ? message : typewriterService.displayedText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: -5)
                    )
                    .padding(.horizontal, 16)
                    .frame(maxHeight: geometry.size.height * 0.33, alignment: .bottom) // Constrain to bottom third
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Spacer to fill remaining space below
                Spacer()
            }
        }
        .onAppear {
            // Animate appearance
            withAnimation(.easeOut(duration: 0.3)) {
                isVisible = true
            }

            // Start typewriter effect for NPC messages
            if !isUserMessage {
                typewriterService.charactersPerSecond = 30.0
                typewriterService.audioToneID = 1104 // Keyboard clack
                typewriterService.playAudioForSpaces = false
                typewriterService.playAudioForPunctuation = false
                typewriterService.randomVariation = 0.3
                typewriterService.punctuationPauseMultiplier = 3.0

                typewriterService.startReveal(text: message)
            }
        }
        .onDisappear {
            typewriterService.cancel()
        }
    }
}

// MARK: - Conversation State Manager
/// Manages the display of conversation messages in AR
class ARConversationManager: ObservableObject {
    @Published var currentMessage: ConversationMessage?

    struct ConversationMessage: Identifiable {
        let id = UUID()
        let npcName: String
        let message: String
        let isUserMessage: Bool
    }

    func showMessage(npcName: String, message: String, isUserMessage: Bool, duration: TimeInterval = 8.0) {
        // Show the message
        currentMessage = ConversationMessage(
            npcName: npcName,
            message: message,
            isUserMessage: isUserMessage
        )

        // Auto-dismiss after duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.dismissMessage()
        }
    }

    func dismissMessage() {
        withAnimation {
            currentMessage = nil
        }
    }
}
