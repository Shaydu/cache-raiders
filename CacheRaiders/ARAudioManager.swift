import AVFoundation
import AudioToolbox
import UIKit
import RealityKit
import ARKit
import CoreLocation

// MARK: - AR Audio Manager
class ARAudioManager {

    private weak var arCoordinator: ARCoordinatorCore?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore) {
        self.arCoordinator = arCoordinator
    }

    // MARK: - Audio Session Management

    /// Setup audio session for AR sounds
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session: \(error)")
        }
    }

    // MARK: - Viewport Chime System

    /// Play a chime sound when an object enters the viewport
    /// Uses a different, gentler sound than the treasure found sound
    func playViewportChime(for locationId: String) {
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            Swift.print("⚠️ Could not configure audio session for chime: \(error)")
        }

        // Get object details for logging
        let location = arCoordinator?.locationManager?.locations.first(where: { $0.id == locationId })
        let objectName = location?.name ?? "Unknown"
        let objectType = location?.type.displayName ?? "Unknown Type"

        // Use a gentle system notification sound for viewport entry
        // System sound 1103 is a soft, pleasant notification chime
        // This is different from the treasure found sound (level-up-01.mp3)
        AudioServicesPlaySystemSound(1103) // Soft notification sound for viewport entry
        Swift.print("🔔 SOUND: Viewport chime (system sound 1103)")

        // Single haptic "bump" when a findable object enters the viewport
        DispatchQueue.main.async {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }

        Swift.print("   Trigger: Object entered viewport")
        Swift.print("   Object: \(objectName) (\(objectType))")
        Swift.print("   Location ID: \(locationId)")
    }
}

