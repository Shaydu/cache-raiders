import UIKit
import SwiftUI
import RealityKit
import ARKit

// MARK: - AR UI Manager
class ARUIManager {

    private weak var arCoordinator: ARCoordinatorCore?

    // MARK: - Initialization
    init(arCoordinator: ARCoordinatorCore) {
        self.arCoordinator = arCoordinator
    }

    // MARK: - Dialog State Management

    /// Dialog state tracking - pause AR session when sheet is open
    private var isDialogOpen: Bool = false {
        didSet {
            if isDialogOpen != oldValue {
                if isDialogOpen {
                    pauseARSession()
                } else {
                    resumeARSession()
                }
            }
        }
    }

    var dialogOpen: Bool {
        get { isDialogOpen }
        set { isDialogOpen = newValue }
    }

    // MARK: - AR Session Management (for UI purposes)

    private func pauseARSession() {
        // Implementation will be provided by main coordinator
        Swift.print("⏸️ AR session paused (dialog open)")
    }

    private func resumeARSession() {
        // Implementation will be provided by main coordinator
        Swift.print("▶️ AR session resumed (dialog closed)")
    }

    // MARK: - Alert and UI Presentation

    /// Show server unavailable alert for NPC interactions
    func showServerUnavailableAlert(for npcType: NPCType) {
        Swift.print("   📱 Showing server unavailable alert for \(npcType.defaultName)")

        // Use a simple alert instead of the full conversation view
        let alert = UIAlertController(
            title: "Server Unavailable",
            message: "The server is not running or unreachable. Please start the server and try again. For testing without a server, you can still find the treasure X and corgi locations that appear nearby.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

        // Find the current view controller to present the alert
        presentAlert(alert)
    }

    /// Show text input prompt for skeleton conversation
    func showSkeletonTextInput(for skeletonEntity: AnchorEntity, in arView: ARView, npcId: String, npcName: String, treasureHuntService: TreasureHuntService?, userLocationManager: UserLocationManager?) {
        Swift.print("   ========== showSkeletonTextInput CALLED ==========")
        Swift.print("   NPC ID: \(npcId)")
        Swift.print("   NPC Name: \(npcName)")
        Swift.print("   Skeleton Entity: \(skeletonEntity.name)")

        // Show alert with text input
        DispatchQueue.main.async {
            Swift.print("   📝 Creating UIAlertController for text input...")
            let alert = UIAlertController(title: "💀 Talk to \(npcName)", message: "Ask the skeleton about the treasure...", preferredStyle: .alert)

            alert.addTextField { textField in
                textField.placeholder = "Ask about the treasure..."
                textField.autocapitalizationType = .sentences
            }

            alert.addAction(UIAlertAction(title: "Ask", style: .default) { [weak self] _ in
                guard let self = self,
                      let textField = alert.textFields?.first,
                      let message = textField.text,
                      !message.isEmpty else {
                    return
                }

                // Show user message in 2D overlay (bottom third of screen)
                // Note: conversationManager not available in this context
                Swift.print("💬 User: \(message)")

                // Check if this is a map/direction request
                let isMapRequest = treasureHuntService?.isMapRequest(message) ?? false

                // Get response from API
                Task {
                    do {
                        if isMapRequest, let userLocation = userLocationManager?.currentLocation {
                            // User is asking for the map - fetch and show treasure map via service
                            Swift.print("🗺️ Map request detected in message: '\(message)'")
                            try await treasureHuntService?.handleMapRequest(
                                npcId: npcId,
                                npcName: npcName,
                                userLocation: userLocation
                            )
                        } else {
                            // Regular conversation
                            let response = try await APIService.shared.interactWithNPC(
                                npcId: npcId,
                                message: message,
                                npcName: npcName,
                                npcType: "skeleton",
                                isSkeleton: true
                            )

                            await MainActor.run {
                                // Show skeleton response in 2D overlay after a brief delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                                    self?.showConversationMessage(
                                        npcName: npcName,
                                        message: response.response,
                                        isUserMessage: false,
                                        duration: 10.0
                                    )
                                }
                            }
                        }
                    } catch {
                        await MainActor.run { [weak self] in
                            // Provide user-friendly error messages
                            let errorMessage: String
                            if let apiError = error as? APIError {
                                switch apiError {
                                case .serverError(let message):
                                    if message.contains("LLM service not available") || message.contains("not available") {
                                        errorMessage = "Arr, the treasure map service be down! The server needs the LLM service running. Check the server logs, matey!"
                                    } else {
                                        errorMessage = message
                                    }
                                case .serverUnreachable:
                                    errorMessage = "Arr, I can't reach the server! Make sure it's running and we're on the same network, matey!"
                                case .httpError(let code):
                                    if code == 503 {
                                        errorMessage = "The treasure map service be unavailable! Check if the LLM service is running on the server."
                                    } else {
                                        errorMessage = "Server error \(code). Check the server, matey!"
                                    }
                                default:
                                    errorMessage = apiError.localizedDescription
                                }
                            } else {
                                // For other errors, provide a generic but friendly message
                                let errorDesc = error.localizedDescription
                                if errorDesc.contains("not available") || errorDesc.contains("unreachable") {
                                    errorMessage = "Arr, I can't reach the server! Make sure it's running, matey!"
                                } else {
                                    errorMessage = errorDesc
                                }
                            }

                            // Show error message in overlay
                            self?.showConversationMessage(
                                npcName: npcName,
                                message: errorMessage,
                                isUserMessage: false,
                                duration: 8.0
                            )
                        }
                    }
                }
            })

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

            // Present the alert
            self.presentAlert(alert)
        }
    }

    /// Present an alert controller on the current view controller
    private func presentAlert(_ alert: UIAlertController) {
        // Find the current view controller to present the alert
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            var currentVC = rootViewController
            while let presentedVC = currentVC.presentedViewController {
                currentVC = presentedVC
            }
            currentVC.present(alert, animated: true, completion: nil)
        }
    }

    // MARK: - Notification Management

    /// Show a collection notification
    func showCollectionNotification(_ message: String, duration: TimeInterval = 5.0) {
        arCoordinator?.collectionNotificationBinding?.wrappedValue = message

        // Hide notification after specified duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.arCoordinator?.collectionNotificationBinding?.wrappedValue = nil
        }
    }

    /// Combine map pieces to reveal treasure location
    func combineMapPieces() {
        Swift.print("🗺️ Combining map pieces - revealing treasure location!")

        // Show notification that map is combined
        showCollectionNotification("🗺️ Map Combined! The treasure location has been revealed on the map!")

        // TODO: In a full implementation, this would:
        // 1. Reveal a special treasure location on the map
        // 2. Place a treasure chest at a specific GPS location
        // 3. Show visual indicators in AR
        Swift.print("💡 Map pieces combined - treasure location should be revealed")
    }

    // MARK: - UI Bindings Management

    /// Update distance to nearest object binding
    func updateDistanceToNearest(_ distance: Double?) {
        arCoordinator?.distanceToNearestBinding?.wrappedValue = distance
    }

    /// Update temperature status binding
    func updateTemperatureStatus(_ status: String?) {
        arCoordinator?.temperatureStatusBinding?.wrappedValue = status
    }

    /// Update nearest object direction binding
    func updateNearestObjectDirection(_ direction: Double?) {
        arCoordinator?.nearestObjectDirectionBinding?.wrappedValue = direction
    }

    /// Update conversation NPC binding
    func updateConversationNPC(_ npc: ConversationNPC?) {
        arCoordinator?.conversationNPCBinding?.wrappedValue = npc
    }
    
    /// Show a conversation message via coordinator bindings (fallback to print)
    private func showConversationMessage(npcName: String, message: String, isUserMessage: Bool, duration: TimeInterval) {
        // Currently, ARCoordinatorCore does not expose a `conversationOverlayBinding`.
        // Fallback to console output to avoid compile errors and still surface messages during development.
        let prefix = isUserMessage ? "You" : npcName
        Swift.print("\u{1F4AC} \(prefix): \(message)")
    }
}
