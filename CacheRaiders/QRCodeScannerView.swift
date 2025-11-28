import SwiftUI
@preconcurrency import AVFoundation
import CoreMedia

// MARK: - QR Code Scanner View
struct QRCodeScannerView: UIViewControllerRepresentable {
    @Binding var scannedURL: String?
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.delegate = context.coordinator
        context.coordinator.viewController = controller
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        // No updates needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QRCodeScannerDelegate {
        let parent: QRCodeScannerView
        weak var viewController: QRCodeScannerViewController?
        
        init(_ parent: QRCodeScannerView) {
            self.parent = parent
        }
        
        func didScanQRCode(_ url: String) {
            // Show success feedback before dismissing
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let viewController = self.viewController else {
                    self?.parent.scannedURL = url
                    self?.parent.dismiss()
                    return
                }
                
                // Show success animation/feedback
                let successView = UIView()
                successView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
                successView.layer.cornerRadius = 12
                successView.translatesAutoresizingMaskIntoConstraints = false
                
                let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
                checkmark.tintColor = .white
                checkmark.contentMode = .scaleAspectFit
                checkmark.translatesAutoresizingMaskIntoConstraints = false
                
                let label = UILabel()
                label.text = "QR Code Scanned!"
                label.textColor = .white
                label.font = .systemFont(ofSize: 18, weight: .semibold)
                label.textAlignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                
                let urlLabel = UILabel()
                urlLabel.text = url
                urlLabel.textColor = .white
                urlLabel.font = .systemFont(ofSize: 14, weight: .regular)
                urlLabel.textAlignment = .center
                urlLabel.numberOfLines = 2
                urlLabel.translatesAutoresizingMaskIntoConstraints = false
                
                successView.addSubview(checkmark)
                successView.addSubview(label)
                successView.addSubview(urlLabel)
                
                viewController.view.addSubview(successView)
                
                NSLayoutConstraint.activate([
                    successView.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
                    successView.centerYAnchor.constraint(equalTo: viewController.view.centerYAnchor),
                    successView.widthAnchor.constraint(equalToConstant: 280),
                    successView.heightAnchor.constraint(equalToConstant: 140),
                    
                    checkmark.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
                    checkmark.topAnchor.constraint(equalTo: successView.topAnchor, constant: 16),
                    checkmark.widthAnchor.constraint(equalToConstant: 48),
                    checkmark.heightAnchor.constraint(equalToConstant: 48),
                    
                    label.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
                    label.topAnchor.constraint(equalTo: checkmark.bottomAnchor, constant: 8),
                    
                    urlLabel.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
                    urlLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                    urlLabel.leadingAnchor.constraint(equalTo: successView.leadingAnchor, constant: 16),
                    urlLabel.trailingAnchor.constraint(equalTo: successView.trailingAnchor, constant: -16)
                ])
                
                // Animate in
                successView.alpha = 0
                successView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                    successView.alpha = 1
                    successView.transform = .identity
                } completion: { _ in
                    // Reduced delay for faster dismissal - still shows success feedback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        UIView.animate(withDuration: 0.15) {
                            successView.alpha = 0
                        } completion: { _ in
                            successView.removeFromSuperview()
                            self.parent.scannedURL = url
                            self.parent.dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - QR Code Scanner View Controller
protocol QRCodeScannerDelegate: AnyObject {
    func didScanQRCode(_ url: String)
}

@MainActor
class QRCodeScannerViewController: UIViewController {
    weak var delegate: QRCodeScannerDelegate?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var scanningFrameView: UIView?
    private var lastScanTime: Date = Date.distantPast
    private let scanDebounceInterval: TimeInterval = 0.1 // Prevent duplicate scans within 100ms (faster response)
    private var sessionStartAttempts = 0
    private let maxSessionStartAttempts = 5
    
    // CRITICAL: AVCaptureSession requires a dedicated serial queue for all operations
    // Using a global concurrent queue causes thread safety issues and camera freezes
    private let sessionQueue = DispatchQueue(label: "com.cacheraiders.qrscanner.session")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        // Request camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        default:
            showPermissionDenied()
        }
        
        // Add close button
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Cancel", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor.systemGray.withAlphaComponent(0.7)
        closeButton.layer.cornerRadius = 8
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 80),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // Add instruction label
        let instructionLabel = UILabel()
        instructionLabel.text = "Align QR code"
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.font = .systemFont(ofSize: 14, weight: .medium)
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        instructionLabel.layer.cornerRadius = 8
        instructionLabel.clipsToBounds = true
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.adjustsFontSizeToFitWidth = true
        instructionLabel.minimumScaleFactor = 0.8
        view.addSubview(instructionLabel)
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            instructionLabel.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
    
    private func setupCamera() {
        print("📷 QR Scanner: Starting camera setup...")
        // CRITICAL: All AVCaptureSession operations must be on the dedicated serial queue
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            print("📷 QR Scanner: Creating capture session on session queue...")
            let session = AVCaptureSession()
            // Use medium preset for faster startup and better performance
            // Medium quality is sufficient for QR code detection and provides faster frame processing
            if session.canSetSessionPreset(.medium) {
                session.sessionPreset = .medium
            } else {
                session.sessionPreset = .low // Fallback for older devices
            }
            
            guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async {
                    self.showError("Camera not available")
                }
                return
            }
            
            let videoInput: AVCaptureDeviceInput
            
            do {
                videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            } catch {
                DispatchQueue.main.async {
                    self.showError("Failed to create video input: \(error.localizedDescription)")
                }
                return
            }
            
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                DispatchQueue.main.async {
                    self.showError("Cannot add video input")
                }
                return
            }
            
            // PERFORMANCE: Optimize camera for faster frame rate and smoother scanning
            // Set frame duration to achieve 30fps for smooth video feed
            do {
                try videoCaptureDevice.lockForConfiguration()
                
                // Find a format that supports higher frame rate for faster scanning
                // Prefer formats that support 30fps or higher for responsive QR detection
                let desiredFPS: Float64 = 30.0
                let formats = videoCaptureDevice.formats
                // Try to find a format that supports the desired FPS, but don't block if not available
                if let format = formats.first(where: { format in
                    let ranges = format.videoSupportedFrameRateRanges
                    return ranges.contains { $0.maxFrameRate >= desiredFPS }
                }) {
                    videoCaptureDevice.activeFormat = format
                    // Set frame rate to 30fps for faster scanning
                    let frameDuration = CMTime(value: 1, timescale: Int32(desiredFPS))
                    videoCaptureDevice.activeVideoMinFrameDuration = frameDuration
                    videoCaptureDevice.activeVideoMaxFrameDuration = frameDuration
                    print("✅ QR Scanner: Camera optimized for 30fps scanning")
                } else {
                    // Use default format - it will still work, just might be slightly slower
                    print("ℹ️ QR Scanner: Using default frame rate (may vary by device)")
                }
                
                // Enable autofocus for better QR code detection
                if videoCaptureDevice.isFocusModeSupported(.continuousAutoFocus) {
                    videoCaptureDevice.focusMode = .continuousAutoFocus
                }
                
                videoCaptureDevice.unlockForConfiguration()
            } catch {
                print("⚠️ QR Scanner: Could not optimize camera settings: \(error.localizedDescription)")
                // Continue anyway - camera will work with default settings
            }
            
            let metadataOutput = AVCaptureMetadataOutput()
            
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                
                // Standard practice: metadata delegate callbacks should be on main queue
                // Note: self is @MainActor isolated, delegate callbacks will be on main queue
                metadataOutput.metadataObjectTypes = [.qr]
                
                // Update UI on main thread - must set session and metadataOutput synchronously
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    print("📷 QR Scanner: Setting up UI on main thread...")
                    
                    // Store references BEFORE UI setup so they're available
                    self.captureSession = session
                    self.metadataOutput = metadataOutput
                    
                    // Set delegate on main thread (self is @MainActor isolated)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    print("📷 QR Scanner: Delegate set, metadata types: \(metadataOutput.metadataObjectTypes)")
                    
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    // Don't adjust mirroring - let the system handle it automatically
                    self.view.layer.addSublayer(previewLayer)
                    self.previewLayer = previewLayer
                    
                    // Set frame immediately with current view bounds
                    let bounds = self.view.layer.bounds
                    if bounds.width > 0 && bounds.height > 0 {
                        previewLayer.frame = bounds
                        print("📷 QR Scanner: Preview layer added with frame: \(bounds)")
                    } else {
                        print("⚠️ QR Scanner: View bounds are zero, will update in viewDidLayoutSubviews")
                    }
                    
                    // Add scanning frame overlay
                    self.addScanningFrame()
                    
                    // Update preview layer frame after layout (will be called again in viewDidLayoutSubviews)
                    self.updatePreviewLayerFrame()
                    
                    // Start session after UI is set up if view is already visible
                    // Otherwise, viewDidAppear will start it
                    if self.isViewLoaded && self.view.window != nil {
                        print("📷 QR Scanner: View is visible, starting session...")
                        self.startSessionIfNeeded()
                    } else {
                        print("📷 QR Scanner: View not visible yet, will start in viewDidAppear")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.showError("Cannot add metadata output")
                }
                return
            }
        }
    }
    
    private func updatePreviewLayerFrame() {
        guard let previewLayer = previewLayer else { return }
        
        // Only update if bounds are valid
        let bounds = view.layer.bounds
        guard bounds.width > 0 && bounds.height > 0 else {
            print("⚠️ QR Scanner: View bounds invalid, skipping preview layer update")
            return
        }
        
        previewLayer.frame = bounds
        
        // Update rectOfInterest after layout
        if metadataOutput != nil,
           let scanningFrame = scanningFrameView {
            let frameInViewCoords = scanningFrame.convert(scanningFrame.bounds, to: view)
            let rectOfInterest = previewLayer.metadataOutputRectConverted(fromLayerRect: frameInViewCoords)
            
            // Validate rectOfInterest before setting
            guard rectOfInterest.width > 0 && rectOfInterest.height > 0,
                  rectOfInterest.minX >= 0 && rectOfInterest.minY >= 0,
                  rectOfInterest.maxX <= 1.0 && rectOfInterest.maxY <= 1.0 else {
                print("⚠️ QR Scanner: Invalid rectOfInterest, using full frame")
                // Use full frame if calculated rect is invalid
                let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                
                // CRITICAL: Update rectOfInterest on session queue
                // Capture metadataOutput before the closure
                guard let output = metadataOutput else { return }
                sessionQueue.async {
                    output.rectOfInterest = fullRect
                }
                return
            }
            
            // CRITICAL: Update rectOfInterest on session queue
            // Capture metadataOutput before the closure
            guard let output = metadataOutput else { return }
            sessionQueue.async {
                output.rectOfInterest = rectOfInterest
            }
        }
    }
    
    private func addScanningFrame() {
        let scanningFrame = UIView()
        scanningFrame.layer.borderColor = UIColor.systemGreen.cgColor
        scanningFrame.layer.borderWidth = 3
        scanningFrame.layer.cornerRadius = 12
        scanningFrame.backgroundColor = .clear
        scanningFrame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanningFrame)
        self.scanningFrameView = scanningFrame
        
        NSLayoutConstraint.activate([
            scanningFrame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanningFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            scanningFrame.widthAnchor.constraint(equalToConstant: 250),
            scanningFrame.heightAnchor.constraint(equalToConstant: 250)
        ])
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Update preview layer frame when layout changes
        updatePreviewLayerFrame()
        
        // Ensure preview layer frame matches view bounds
        if let previewLayer = previewLayer {
            let bounds = view.layer.bounds
            if bounds.width > 0 && bounds.height > 0 {
                previewLayer.frame = bounds
                print("📷 QR Scanner: Preview layer frame updated in viewDidLayoutSubviews: \(bounds)")
            }
        }
    }
    
    private func showPermissionDenied() {
        let alert = UIAlertController(
            title: "Camera Permission Required",
            message: "Please enable camera access in Settings to scan QR codes.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
    
    @objc private func closeTapped() {
        dismiss(animated: true)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Don't start here - wait for viewDidAppear when view is fully laid out
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        print("📷 QR Scanner: viewDidAppear called")
        // CRITICAL: Start session on the dedicated session queue after view is fully visible
        // This ensures the preview layer has correct frame and the camera can start properly
        startSessionIfNeeded()
    }
    
    private func startSessionIfNeeded() {
        // Prevent infinite retries
        guard sessionStartAttempts < maxSessionStartAttempts else {
            print("⚠️ QR Scanner: Max session start attempts reached")
            showError("Failed to start camera. Please try again.")
            return
        }
        
        sessionStartAttempts += 1
        
        // Capture session before entering nonisolated context
        guard let session = captureSession else {
            print("⏳ QR Scanner: Session not ready yet, attempt \(sessionStartAttempts)/\(maxSessionStartAttempts)")
            // Session setup might still be in progress, try again after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startSessionIfNeeded()
            }
            return
        }
        
        guard !session.isRunning else {
            print("✅ QR Scanner: Session already running")
            return
        }
        
        // Update preview layer frame one more time before starting
        updatePreviewLayerFrame()
        
        // Start session immediately - no delay needed
        // The preview layer frame will be updated in viewDidLayoutSubviews if needed
        sessionQueue.async {
            guard !session.isRunning else { return }
            
            session.startRunning()
            print("✅ QR Scanner: Camera session started successfully")
            // Reset attempts on main actor
            DispatchQueue.main.async {
                self.sessionStartAttempts = 0
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // CRITICAL: Stop session on the dedicated session queue
        // Capture session before entering nonisolated context
        let session = captureSession
        if let session = session, session.isRunning {
            sessionQueue.async {
                session.stopRunning()
            }
        }
    }
    
    deinit {
        // Clean up camera session when view controller is deallocated
        // CRITICAL: Use the dedicated session queue
        // Capture session before entering nonisolated context
        let session = captureSession
        if let session = session, session.isRunning {
            sessionQueue.async {
                session.stopRunning()
            }
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate
extension QRCodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // PERFORMANCE: Early return if no objects to process
        guard !metadataObjects.isEmpty else { return }
        
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }
        
        // Validate that it looks like a URL
        guard stringValue.hasPrefix("http://") || stringValue.hasPrefix("https://") else {
            return
        }
        
        // Use DispatchQueue.main.async for faster response (lower overhead than Task)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Debounce: prevent duplicate scans within the debounce interval
            let now = Date()
            guard now.timeIntervalSince(self.lastScanTime) >= self.scanDebounceInterval else {
                return // Too soon since last scan, ignore
            }
            
            // Mark this scan time to prevent duplicates
            self.lastScanTime = now
            
            // CRITICAL: Stop scanning on the dedicated session queue
            // Capture session before entering nonisolated context
            let session = self.captureSession
            if let session = session, session.isRunning {
                self.sessionQueue.async {
                    session.stopRunning()
                }
            }
            
            // Play haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            // Notify delegate immediately
            self.delegate?.didScanQRCode(stringValue)
        }
    }
}

