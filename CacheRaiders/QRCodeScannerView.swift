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
        context.coordinator.parent = self
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        // Update delegate reference if it changed
        if uiViewController.delegate !== context.coordinator {
            uiViewController.delegate = context.coordinator
        }
        // Ensure view controller reference is set
        context.coordinator.viewController = uiViewController
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QRCodeScannerDelegate {
        var parent: QRCodeScannerView
        weak var viewController: QRCodeScannerViewController?
        
        init(_ parent: QRCodeScannerView) {
            self.parent = parent
        }
        
        func didScanQRCode(_ url: String) {
            print("📷 QR Scanner Coordinator: Received scan callback with URL: \(url)")
            // Show success feedback before dismissing
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    // Fallback if self is nil
                    print("⚠️ QR Scanner Coordinator: Self is nil, setting scannedURL directly")
                    return
                }
                
                guard let viewController = self.viewController else {
                    print("⚠️ QR Scanner Coordinator: ViewController is nil, setting scannedURL and dismissing")
                    self.parent.scannedURL = url
                    self.parent.dismiss()
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
    private var scanButton: UIButton?
    private var instructionLabel: UILabel?
    private var lastScanTime: Date = Date.distantPast
    private let scanDebounceInterval: TimeInterval = 0.1 // Prevent duplicate scans within 100ms (faster response)
    private var sessionStartAttempts = 0
    private let maxSessionStartAttempts = 5
    private var isScanning = false // Track scanning state
    
    // CRITICAL: AVCaptureSession requires a dedicated serial queue for all operations
    // Using a global concurrent queue causes thread safety issues and camera freezes
    private let sessionQueue = DispatchQueue(label: "com.cacheraiders.qrscanner.session")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        print("📷 QR Scanner: viewDidLoad() called")
        
        // Set background to black initially, but the preview layer will show the camera feed
        // The preview layer will be behind all UI elements, so the camera feed will be visible
        view.backgroundColor = .black
        
        // Ensure view is opaque so it covers the AR view behind it
        view.isOpaque = true
        
        // DEBUG: Listen for app state changes to track interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // DEBUG: Listen for sheet/dialog notifications that might interrupt camera
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSheetPresented),
            name: NSNotification.Name("SheetPresented"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSheetDismissed),
            name: NSNotification.Name("SheetDismissed"),
            object: nil
        )
        
        // DEBUG: Listen for camera interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: nil
        )
        
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
        
        // Add scan button
        let scanButton = UIButton(type: .system)
        scanButton.setTitle("Scan", for: .normal)
        scanButton.setTitleColor(.white, for: .normal)
        scanButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
        scanButton.layer.cornerRadius = 12
        scanButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        scanButton.addTarget(self, action: #selector(scanButtonTapped), for: .touchUpInside)
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanButton)
        self.scanButton = scanButton
        
        NSLayoutConstraint.activate([
            scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            scanButton.widthAnchor.constraint(equalToConstant: 200),
            scanButton.heightAnchor.constraint(equalToConstant: 56)
        ])
        
        // Add instruction label
        let instructionLabel = UILabel()
        instructionLabel.text = "Tap 'Scan' to start scanning"
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
        self.instructionLabel = instructionLabel
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: scanButton.topAnchor, constant: -16),
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
            
            // PERFORMANCE: Optimize camera settings quickly without blocking
            // Use minimal configuration to prevent freezing during setup
            do {
                try videoCaptureDevice.lockForConfiguration()
                
                // PERFORMANCE: Skip format searching to prevent freeze - use default format
                // Format searching can be slow and cause UI freezing
                // Default format is usually sufficient for QR code scanning
                
                // Enable autofocus for better QR code detection (quick operation)
                if videoCaptureDevice.isFocusModeSupported(.continuousAutoFocus) {
                    videoCaptureDevice.focusMode = .continuousAutoFocus
                }
                
                videoCaptureDevice.unlockForConfiguration()
                print("✅ QR Scanner: Camera configured (using default format for performance)")
            } catch {
                print("⚠️ QR Scanner: Could not optimize camera settings: \(error.localizedDescription)")
                // Continue anyway - camera will work with default settings
            }
            
            let metadataOutput = AVCaptureMetadataOutput()
            
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                
                // PERFORMANCE: Use background queue for metadata processing to prevent UI freezing
                // Metadata processing happens frequently and should not block main thread
                metadataOutput.metadataObjectTypes = [.qr]
                
                // Update UI on main thread - must set session and metadataOutput synchronously
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    print("📷 QR Scanner: Setting up UI on main thread...")
                    
                    // Store references BEFORE UI setup so they're available
                    self.captureSession = session
                    self.metadataOutput = metadataOutput
                    
                    // CRITICAL: Set delegate on background queue to prevent UI freezing
                    // Use a dedicated serial queue for metadata processing
                    let metadataQueue = DispatchQueue(label: "com.cacheraiders.qrscanner.metadata", qos: .userInitiated)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
                    print("📷 QR Scanner: Delegate set, metadata types: \(metadataOutput.metadataObjectTypes ?? [])")
                    
                    // CRITICAL: Ensure rectOfInterest is set to full frame initially
                    // This allows scanning anywhere in the frame, not just a specific region
                    let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    self.sessionQueue.async {
                        metadataOutput.rectOfInterest = fullRect
                        print("📷 QR Scanner: Set rectOfInterest to full frame")
                    }
                    
                    // Create preview layer with session
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    
                    // Configure connection for proper orientation
                    if let connection = previewLayer.connection {
                        if #available(iOS 17.0, *) {
                            if connection.isVideoRotationAngleSupported(90) {
                                connection.videoRotationAngle = 90
                            }
                        } else {
                            if connection.isVideoOrientationSupported {
                                connection.videoOrientation = .portrait
                            }
                        }
                    }
                    
                    self.previewLayer = previewLayer
                    
                    // CRITICAL: Remove any existing preview layers first to avoid conflicts
                    if let existingLayers = self.view.layer.sublayers {
                        for layer in existingLayers {
                            if layer is AVCaptureVideoPreviewLayer {
                                layer.removeFromSuperlayer()
                            }
                        }
                    }
                    
                    // CRITICAL: Insert preview layer at index 0 so it's behind all UI elements
                    // This ensures the camera feed is visible as the background
                    self.view.layer.insertSublayer(previewLayer, at: 0)
                    
                    // PERFORMANCE: Skip verbose logging to prevent UI delays
                    // Only log essential information
                    
                    // Set frame - use view bounds, will be updated in viewDidLayoutSubviews if needed
                    let bounds = self.view.layer.bounds
                    if bounds.width > 0 && bounds.height > 0 {
                        previewLayer.frame = bounds
                        print("📷 QR Scanner: Preview layer added with frame: \(bounds)")
                        print("📷 QR Scanner: Preview layer isHidden: \(previewLayer.isHidden), opacity: \(previewLayer.opacity)")
                    } else {
                        print("⚠️ QR Scanner: View bounds are zero, will update in viewDidLayoutSubviews")
                    }
                    
                    // Add scanning frame overlay
                    self.addScanningFrame()
                    
                    // Update preview layer frame after layout (will be called again in viewDidLayoutSubviews)
                    self.updatePreviewLayerFrame()
                    
                    // Start preview session so user can see camera feed
                    // Metadata scanning will only be active when user taps "Scan" button
                    print("📷 QR Scanner: Starting camera preview...")
                    self.startPreviewSession()
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
        
        // CRITICAL: Always set rectOfInterest to full frame for better scanning
        // This allows scanning anywhere in the camera view, not just a specific region
        // The scanning frame overlay is just visual guidance, not a restriction
        guard let output = metadataOutput else { return }
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        
        // Update rectOfInterest on session queue
        sessionQueue.async {
            output.rectOfInterest = fullRect
            print("📷 QR Scanner: Updated rectOfInterest to full frame for better scanning")
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
        
        // Ensure preview layer frame matches view bounds
        if let previewLayer = previewLayer {
            let bounds = view.layer.bounds
            if bounds.width > 0 && bounds.height > 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true) // Prevent animation during layout
                previewLayer.frame = bounds
                CATransaction.commit()
                
                // Update rectOfInterest after frame is set
                updatePreviewLayerFrame()
                
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
        // Stop scanning before dismissing
        stopScanning()
        dismiss(animated: true)
    }
    
    @objc private func scanButtonTapped() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }
    
    private func startScanning() {
        guard !isScanning else { return }
        
        isScanning = true
        updateScanButton()
        
        // Start the capture session
        startSessionIfNeeded()
        
        // Update instruction label
        instructionLabel?.text = "Align QR code in the frame"
    }
    
    private func stopScanning() {
        guard isScanning else { return }
        
        isScanning = false
        updateScanButton()
        
        // Don't stop the session - keep preview running
        // Just disable scanning (metadata processing will check isScanning flag)
        print("📷 QR Scanner: Scanning paused by user - preview still running")
        
        // Update instruction label
        instructionLabel?.text = "Tap 'Scan' to start scanning"
    }
    
    private func updateScanButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.scanButton else { return }
            if self.isScanning {
                button.setTitle("Pause", for: .normal)
                button.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.9)
            } else {
                button.setTitle("Scan", for: .normal)
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        print("📷 QR Scanner: viewWillAppear() called")
        // Don't start here - wait for viewDidAppear when view is fully laid out
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        print("📷 QR Scanner: viewDidAppear() called")
        
        // CRITICAL: Ensure preview layer is properly set up and visible
        if let previewLayer = previewLayer {
            let bounds = view.layer.bounds
            print("📷 QR Scanner: viewDidAppear - view bounds: \(bounds)")
            print("📷 QR Scanner: Preview layer exists, superlayer: \(previewLayer.superlayer != nil ? "exists" : "nil")")
            print("📷 QR Scanner: Preview layer frame: \(previewLayer.frame)")
            print("📷 QR Scanner: Preview layer isHidden: \(previewLayer.isHidden), opacity: \(previewLayer.opacity)")
            
            if bounds.width > 0 && bounds.height > 0 {
                // Ensure preview layer is in the view's layer hierarchy
                if previewLayer.superlayer != view.layer {
                    // Remove from any other superlayer first
                    previewLayer.removeFromSuperlayer()
                    // Add to view's layer at index 0 (behind UI elements)
                    view.layer.insertSublayer(previewLayer, at: 0)
                    print("📷 QR Scanner: Preview layer re-added to view hierarchy")
                }
                
                // Ensure preview layer is visible
                previewLayer.isHidden = false
                previewLayer.opacity = 1.0
                previewLayer.frame = bounds
                print("📷 QR Scanner: Preview layer frame set in viewDidAppear: \(bounds)")
                print("📷 QR Scanner: View background color: \(view.backgroundColor?.description ?? "nil")")
            } else {
                print("⚠️ QR Scanner: View bounds are invalid in viewDidAppear")
            }
        } else {
            print("⚠️ QR Scanner: Preview layer is nil in viewDidAppear - camera setup may not be complete")
        }
        
        // Start preview session so user can see camera feed
        // Metadata scanning will only be active when user taps "Scan" button
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startPreviewSession()
        }
    }
    
    private func startPreviewSession() {
        // Start session for camera preview (so user can see the feed)
        // This is separate from scanning - preview always runs, scanning is controlled by isScanning
        guard let session = captureSession else {
            print("⏳ QR Scanner: Session not ready yet for preview")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startPreviewSession()
            }
            return
        }
        
        guard !session.isRunning else {
            print("✅ QR Scanner: Preview session already running")
            return
        }
        
        // Start session on the dedicated session queue
        let capturedSession = session
        sessionQueue.async { [weak self] in
            guard self != nil else { return }
            
            print("📷 QR Scanner: Starting preview session...")
            capturedSession.startRunning()
            print("✅ QR Scanner: Preview session started - camera feed visible")
        }
    }
    
    private func startSessionIfNeeded() {
        // This is called when user wants to start scanning
        // Preview should already be running, we just need to ensure metadata is enabled
        guard isScanning else {
            print("📷 QR Scanner: Scanning not enabled - waiting for user to tap 'Scan' button")
            return
        }
        
        // Ensure preview session is running
        startPreviewSession()
        
        // Prevent infinite retries
        guard sessionStartAttempts < maxSessionStartAttempts else {
            print("⚠️ QR Scanner: Max session start attempts reached")
            showError("Failed to start camera. Please try again.")
            isScanning = false
            updateScanButton()
            return
        }
        
        sessionStartAttempts += 1
        
        // Capture session before entering nonisolated context
        guard let session = captureSession else {
            print("⏳ QR Scanner: Session not ready yet, attempt \(sessionStartAttempts)/\(maxSessionStartAttempts)")
            // Session setup might still be in progress, try again after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startSessionIfNeeded()
            }
            return
        }
        
        // Session should already be running for preview, but verify
        if !session.isRunning {
            startPreviewSession()
        }
        
        print("✅ QR Scanner: Scanning enabled - metadata processing active")
        sessionStartAttempts = 0 // Reset on success
        
        // Ensure preview layer frame is set before starting
        if let previewLayer = previewLayer {
            let bounds = view.layer.bounds
            if bounds.width > 0 && bounds.height > 0 {
                previewLayer.frame = bounds
                print("📷 QR Scanner: Preview layer frame set to: \(bounds)")
            }
        }
        
        // Update rectOfInterest if needed
        updatePreviewLayerFrame()
        
        // Start session on the dedicated session queue
        // CRITICAL: Must start on session queue, not main queue
        let capturedSession = session
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard !capturedSession.isRunning else {
                print("✅ QR Scanner: Session already running (checked on session queue)")
                DispatchQueue.main.async {
                    self.sessionStartAttempts = 0
                }
                return
            }
            
            print("📷 QR Scanner: Starting session on session queue...")
            let startTime = Date()
            capturedSession.startRunning()
            let startDuration = Date().timeIntervalSince(startTime)
            print("📷 QR Scanner: Session startRunning() call completed in \(String(format: "%.3f", startDuration))s")
            
            // Give it a moment to start, then verify
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                if capturedSession.isRunning {
                    print("✅ QR Scanner: Camera session started successfully")
                    print("📷 QR Scanner: Metadata object types: \(self.metadataOutput?.metadataObjectTypes ?? [])")
                    
                    // Verify preview layer is still properly configured
                    if let previewLayer = self.previewLayer {
                        print("📷 QR Scanner: Preview layer verification:")
                        print("   - Superlayer: \(previewLayer.superlayer != nil ? "exists" : "nil")")
                        print("   - Frame: \(previewLayer.frame)")
                        print("   - IsHidden: \(previewLayer.isHidden)")
                        print("   - Opacity: \(previewLayer.opacity)")
                        print("   - VideoGravity: \(previewLayer.videoGravity.rawValue)")
                        
                        // Ensure it's visible
                        if previewLayer.isHidden || previewLayer.opacity < 1.0 {
                            print("⚠️ QR Scanner: Preview layer not fully visible, fixing...")
                            previewLayer.isHidden = false
                            previewLayer.opacity = 1.0
                        }
                    } else {
                        print("⚠️ QR Scanner: Preview layer is nil after session started!")
                    }
                    
                    self.sessionStartAttempts = 0
                } else {
                    print("⚠️ QR Scanner: Session start may have failed, retrying...")
                    if self.sessionStartAttempts < self.maxSessionStartAttempts {
                        self.startSessionIfNeeded()
                    }
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        print("📷 QR Scanner: viewWillDisappear() called - stopping camera")
        
        // CRITICAL: Stop session on the dedicated session queue
        // Capture session before entering nonisolated context
        let session = captureSession
        if let session = session, session.isRunning {
            print("📷 QR Scanner: Stopping session in viewWillDisappear")
            sessionQueue.async {
                session.stopRunning()
                print("📷 QR Scanner: Session stopped successfully")
            }
        } else {
            print("📷 QR Scanner: Session was not running (already stopped)")
        }
    }
    
    deinit {
        print("📷 QR Scanner: deinit() called - cleaning up")
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
        
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
    
    // MARK: - Interruption Handlers (Debug Logging)
    
    @objc private func handleAppWillResignActive(_ notification: Notification) {
        print("🚨 QR Scanner INTERRUPTION: App will resign active - camera may pause")
    }
    
    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        print("✅ QR Scanner: App became active - camera should resume")
        // Restart preview session (always show preview)
        startPreviewSession()
        // If scanning was active, ensure it continues
        if isScanning {
            startSessionIfNeeded()
        }
    }
    
    @objc private func handleSheetPresented(_ notification: Notification) {
        print("🚨 QR Scanner INTERRUPTION: Sheet presented - may affect camera")
    }
    
    @objc private func handleSheetDismissed(_ notification: Notification) {
        print("✅ QR Scanner: Sheet dismissed - camera should resume")
    }
    
    @objc private func handleSessionWasInterrupted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            print("🚨 QR Scanner INTERRUPTION: Camera session interrupted (unknown reason)")
            return
        }
        
        let reasonString: String
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            reasonString = "device not available in background"
        case .audioDeviceInUseByAnotherClient:
            reasonString = "audio device in use by another client"
        case .videoDeviceInUseByAnotherClient:
            reasonString = "video device in use by another client (AR camera?)"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            reasonString = "device not available with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            reasonString = "device not available due to system pressure"
        @unknown default:
            reasonString = "unknown reason (\(reasonValue))"
        }
        
        print("🚨 QR Scanner INTERRUPTION: Camera session interrupted - reason: \(reasonString)")
        
        // Log interruption type if available
        if let interruptionType = userInfo[AVCaptureSessionInterruptionReasonKey] {
            print("   Interruption reason code: \(interruptionType)")
        }
    }
    
    @objc private func handleSessionInterruptionEnded(_ notification: Notification) {
        print("✅ QR Scanner: Camera session interruption ended - attempting to resume")
        // Restart preview session (always show preview)
        startPreviewSession()
        // If scanning was active, ensure it continues
        if isScanning {
            startSessionIfNeeded()
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate
extension QRCodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // PERFORMANCE: Early return if no objects to process - do this quickly
        guard !metadataObjects.isEmpty else { return }
        
        // Check if scanning is enabled - only process if user has tapped "Scan"
        // We need to check this on main thread since isScanning is @MainActor
        Task { @MainActor [weak self] in
            guard let self = self, self.isScanning else {
                return // Scanning not enabled, ignore metadata
            }
            
            // PERFORMANCE: Process on background thread to prevent UI freezing
            // Extract data quickly without blocking
            guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = metadataObject.stringValue else {
                return // Silently ignore invalid objects
            }
            
            // Quick validation - do minimal work here
            guard stringValue.hasPrefix("http://") || stringValue.hasPrefix("https://") else {
                return // Silently ignore non-URL codes
            }
            
            // CRITICAL: Capture values before entering main actor context
            let capturedString = stringValue
            let currentTime = Date()
            
            // Debounce: prevent duplicate scans within the debounce interval
            guard currentTime.timeIntervalSince(self.lastScanTime) >= self.scanDebounceInterval else {
                return // Too soon since last scan, ignore silently
            }
            
            // Mark this scan time to prevent duplicates
            self.lastScanTime = currentTime
            
            print("✅ QR Scanner: Processing valid QR code: \(capturedString)")
            
            // Stop scanning after successful scan
            self.isScanning = false
            self.updateScanButton()
            self.instructionLabel?.text = "Tap 'Scan' to start scanning"
            
            // Play haptic feedback (must be on main thread)
            let generator = UINotificationFeedbackGenerator()
            generator.prepare() // Prepare generator for immediate feedback
            generator.notificationOccurred(.success)
            
            // Notify delegate immediately (non-blocking)
            self.delegate?.didScanQRCode(capturedString)
        }
    }
}

