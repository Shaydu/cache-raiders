import Foundation
import AVFoundation

// MARK: - Audio Ping Service
/// Plays a ping sound once per second with pitch that increases as distance decreases
class AudioPingService {
    static let shared = AudioPingService()
    
    private var pingTimer: Timer?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var currentDistance: Double?
    private var isEnabled: Bool = false
    private var connectionFormat: AVAudioFormat? // Store the format used for connections
    private var lastLoggedDistance: Double? // Track last logged distance to reduce log spam
    
    // Pitch range: low pitch when far, high pitch when close
    // Distance range: 0.5m (very close) to 50m (far)
    private let minDistance: Double = 0.5 // meters - closest we can get
    private let maxDistance: Double = 50.0 // meters - beyond this, use minimum pitch
    private let minPitch: Float = 0.5 // Low pitch when far away
    private let maxPitch: Float = 2.0 // High pitch when very close
    
    private init() {
        setupAudioEngine()
    }
    
    deinit {
        stop()
    }
    
    /// Setup the audio engine for pitch-shifted playback
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let engine = audioEngine, let player = playerNode else { return }
        
        // Attach player node to engine
        engine.attach(player)
        
        // Create a time pitch unit for pitch shifting
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(timePitch)
        
        // Get the format from the engine's main mixer node
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        connectionFormat = format // Store for buffer creation
        
        // Connect: player -> timePitch -> mainMixer
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session: \(error)")
        }
    }
    
    /// Start playing pings (once per second)
    func start() {
        // If already running, just update distance and return
        if isEnabled {
            return
        }
        isEnabled = true
        
        // Start audio engine if not already running
        guard let engine = audioEngine else {
            setupAudioEngine()
            return
        }
        
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                Swift.print("❌ Could not start audio engine: \(error)")
                Swift.print("   Error details: \(error.localizedDescription)")
                isEnabled = false
                return
            }
        }
        
        // Play first ping immediately
        playPing()
        
        // Schedule pings every second
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.playPing()
        }
        
        // Add timer to common run loop modes so it works even when scrolling
        if let timer = pingTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    /// Stop playing pings
    func stop() {
        isEnabled = false
        pingTimer?.invalidate()
        pingTimer = nil
        playerNode?.stop()
        audioEngine?.stop()
    }
    
    /// Update the current distance (affects pitch of next ping)
    func updateDistance(_ distance: Double?) {
        currentDistance = distance
    }
    
    /// Play a single submarine ping sound (for location updates)
    /// Uses a fixed medium pitch for location pings
    func playLocationPing() {
        // Ensure audio engine is set up
        if audioEngine == nil || playerNode == nil {
            setupAudioEngine()
        }
        
        guard let engine = audioEngine else {
            Swift.print("❌ Cannot play location ping: audio engine not available")
            return
        }
        
        // Ensure engine is running
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                Swift.print("❌ Could not start audio engine for location ping: \(error)")
                return
            }
        }
        
        // Play the ping at normal pitch
        playSinglePing(pitch: 1.0)
    }
    
    /// Play a single ping with specified pitch multiplier
    private func playSinglePing(pitch: Float) {
        guard let engine = audioEngine, let player = playerNode else {
            Swift.print("❌ Cannot play ping: audio engine or player node not initialized")
            return
        }
        
        // Get or create the time pitch unit
        guard let timePitch = engine.attachedNodes.first(where: { $0 is AVAudioUnitTimePitch }) as? AVAudioUnitTimePitch else {
            Swift.print("❌ Cannot play ping: time pitch unit not found in audio engine")
            return
        }
        
        // Set pitch (in cents, where 0 = no change, 1200 = one octave up, -1200 = one octave down)
        let pitchInCents = (pitch - 1.0) * 1200.0
        timePitch.pitch = pitchInCents
        
        // Generate a simple beep sound programmatically
        let duration: Double = 0.1 // 100ms ping
        let frequency: Double = 800.0 // Base frequency in Hz
        
        // Use the connection format to ensure channel count matches
        guard let audioFormat = connectionFormat else {
            Swift.print("❌ Cannot play ping: connection format not available")
            return
        }
        
        let sampleRate = audioFormat.sampleRate
        let frameCount = Int(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Swift.print("❌ Cannot play ping: failed to create audio buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        guard let channelData = buffer.floatChannelData else {
            Swift.print("❌ Cannot play ping: failed to get channel data from buffer")
            return
        }
        
        let channelCount = Int(audioFormat.channelCount)
        
        // Generate sine wave for all channels
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let value = sin(2.0 * .pi * frequency * time)
            // Apply envelope (fade in/out) to avoid clicks
            let envelope = sin(.pi * time / duration)
            let sampleValue = Float(value * envelope * 0.3) // 0.3 = volume
            
            // Fill all channels with the same value (mono signal duplicated to stereo if needed)
            for channel in 0..<channelCount {
                channelData[channel][frame] = sampleValue
            }
        }
        
        // Play the buffer
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }
    
    /// Play a single ping sound with pitch based on current distance
    private func playPing() {
        // Calculate pitch based on distance
        let pitch = calculatePitch(for: currentDistance)
        
        // Play the ping with calculated pitch
        playSinglePing(pitch: pitch)
        
        // Log ping sound (only when distance changes significantly to avoid spam)
        // Log if this is first ping, or if distance changed by more than 2 meters
        let shouldLog: Bool
        if let currentDist = currentDistance {
            if let lastDist = lastLoggedDistance {
                shouldLog = abs(currentDist - lastDist) > 2.0
            } else {
                shouldLog = true // First ping
            }
        } else {
            shouldLog = lastLoggedDistance != nil // Changed from known to unknown
        }
        
        if shouldLog {
            let distanceStr = currentDistance != nil ? String(format: "%.1fm", currentDistance!) : "unknown"
            let pitchStr = String(format: "%.2f", pitch)
            Swift.print("🔔 SOUND: Audio ping (programmatic beep)")
            Swift.print("   Trigger: Audio mode enabled, proximity to nearest object")
            Swift.print("   Distance: \(distanceStr)")
            Swift.print("   Pitch multiplier: \(pitchStr) (base frequency: 800Hz, pitch range: 0.5-2.0)")
            lastLoggedDistance = currentDistance
        }
    }
    
    /// Calculate pitch based on distance
    /// Returns pitch multiplier (1.0 = normal, >1.0 = higher, <1.0 = lower)
    private func calculatePitch(for distance: Double?) -> Float {
        guard let distance = distance else {
            return minPitch // Far away if no distance
        }
        
        // Clamp distance to our range
        let clampedDistance = max(minDistance, min(maxDistance, distance))
        
        // Normalize distance to 0-1 range (0 = close, 1 = far)
        let normalizedDistance = (clampedDistance - minDistance) / (maxDistance - minDistance)
        
        // Invert so that close = high pitch, far = low pitch
        let invertedDistance = 1.0 - normalizedDistance
        
        // Interpolate between min and max pitch
        let pitch = minPitch + Float(invertedDistance) * (maxPitch - minPitch)
        
        return pitch
    }
}

