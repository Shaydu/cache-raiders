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
        
        // If text is empty, just set it immediately
        guard !text.isEmpty else {
            displayedText = ""
            isRevealing = false
            onComplete?()
            return
        }
        
        let baseDelayPerCharacter = 1.0 / charactersPerSecond

        revealTask = Task {
            var accumulatedText = ""
            // PERFORMANCE: Update less frequently to prevent UI blocking
            // For short messages (<50 chars), update every 2 characters
            // For medium messages (50-100), update every 3 characters  
            // For long messages (>100), update every 5 characters
            let updateFrequency: Int
            if text.count < 50 {
                updateFrequency = 2
            } else if text.count < 100 {
                updateFrequency = 3
            } else {
                updateFrequency = 5
            }
            
            for (index, character) in text.enumerated() {
                // Check if cancelled
                if Task.isCancelled {
                    await MainActor.run {
                        isRevealing = false
                    }
                    return
                }

                // Add character to accumulated text
                accumulatedText.append(character)
                
                // PERFORMANCE: Update displayedText less frequently to prevent UI blocking
                // Always update on the last character to ensure complete text is shown
                let isLastCharacter = index == text.count - 1
                if accumulatedText.count % updateFrequency == 0 || isLastCharacter {
                    // Update UI property on main thread, but do the loop work off main thread
                    await MainActor.run {
                        displayedText = accumulatedText
                    }
                }

                // Play subtle audio tone for each character (based on settings)
                // PERFORMANCE: Only play audio every 5th character to prevent UI freezing
                let shouldPlayAudio: Bool
                if character.isWhitespace {
                    shouldPlayAudio = playAudioForSpaces
                } else if character.isPunctuation {
                    shouldPlayAudio = playAudioForPunctuation
                } else {
                    shouldPlayAudio = true
                }

                // PERFORMANCE: Only play audio every 5th character to prevent UI freezing
                // For long messages, skip audio entirely to prevent blocking
                // Use accumulatedText.count instead of displayedText.count to avoid sync issues
                if shouldPlayAudio && accumulatedText.count % 5 == 0 && text.count < 200 {
                    // Use a subtle system sound - play asynchronously to prevent blocking
                    let toneID = self.audioToneID
                    Task.detached(priority: .background) {
                        AudioServicesPlaySystemSoundWithCompletion(toneID, nil)
                    }
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
            
            // Ensure final text is always displayed (in case last update was missed)
            await MainActor.run {
                displayedText = text
                isRevealing = false
            }
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

