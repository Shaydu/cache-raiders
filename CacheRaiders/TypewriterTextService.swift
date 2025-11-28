import Foundation
import AudioToolbox
import Combine

// MARK: - Typewriter Text Service
/// Service that handles Shadowgate-style typewriter text reveal with audio feedback
class TypewriterTextService: ObservableObject {
    @Published var displayedText: String = ""
    
    private var revealTask: Task<Void, Never>?
    private var isRevealing: Bool = false
    
    // Configuration
    var charactersPerSecond: Double = 30.0 // Base speed of character reveal
    var audioToneID: SystemSoundID = 1103 // Subtle notification sound
    var playAudioForSpaces: Bool = false // Whether to play audio for spaces
    var playAudioForPunctuation: Bool = false // Whether to play audio for punctuation
    var randomVariation: Double = 0.3 // Random timing variation (0.0 - 1.0, default 30% variance)
    var punctuationPauseMultiplier: Double = 3.0 // How much longer to pause after punctuation
    
    /// Start revealing text character by character with typewriter effect
    /// - Parameters:
    ///   - text: The full text to reveal
    ///   - onComplete: Optional callback when reveal is complete
    func startReveal(text: String, onComplete: (() -> Void)? = nil) {
        // Cancel any existing reveal
        cancel()
        
        // Reset displayed text
        displayedText = ""
        isRevealing = true
        
        let baseDelayPerCharacter = 1.0 / charactersPerSecond

        revealTask = Task { @MainActor in
            for character in text {
                // Check if cancelled
                if Task.isCancelled {
                    isRevealing = false
                    return
                }

                // Add character
                displayedText.append(character)

                // Play subtle audio tone for each character (based on settings)
                let shouldPlayAudio: Bool
                if character.isWhitespace {
                    shouldPlayAudio = playAudioForSpaces
                } else if character.isPunctuation {
                    shouldPlayAudio = playAudioForPunctuation
                } else {
                    shouldPlayAudio = true
                }

                if shouldPlayAudio {
                    // Use a subtle system sound
                    AudioServicesPlaySystemSoundWithCompletion(audioToneID, nil)
                }

                // Calculate variable delay for this character (old adventure game feel)
                var characterDelay = baseDelayPerCharacter

                // Add random variation (±randomVariation%)
                let randomFactor = 1.0 + Double.random(in: -randomVariation...randomVariation)
                characterDelay *= randomFactor

                // Add longer pause after punctuation (like human typing)
                if character == "." || character == "!" || character == "?" {
                    characterDelay *= punctuationPauseMultiplier
                } else if character == "," || character == ";" || character == ":" {
                    characterDelay *= (punctuationPauseMultiplier * 0.5) // Shorter pause for commas
                }

                // Wait before revealing next character
                try? await Task.sleep(nanoseconds: UInt64(characterDelay * 1_000_000_000))
            }
            
            // Reveal complete
            isRevealing = false
            onComplete?()
        }
    }
    
    /// Cancel the current reveal
    func cancel() {
        revealTask?.cancel()
        revealTask = nil
        isRevealing = false
    }
    
    /// Skip to end (show all text immediately)
    func skipToEnd(fullText: String) {
        cancel()
        displayedText = fullText
    }
    
    deinit {
        cancel()
    }
}

