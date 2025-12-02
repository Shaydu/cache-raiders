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
    private var instructionLabel: UILabel?
    private var lastScanTime: Date = Date.distantPast
    private let scanDebounceInterval: TimeInterval = 0.1 // Prevent duplicate scans within 100ms
    private var isProcessingScan = false // Prevent concurrent scan processing
    private var sessionStartAttempts = 0
    private let maxSessionStartAttempts = 5
    
    // CRITICAL: AVCaptureSession requires a dedicated serial queue for all operations
    private let sessionQueue = DispatchQueue(label: "com.cacheraiders.qrscanner.session")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        print("📷 QR Scanner: viewDidLoad() called")
        
        view.backgroundColor = .black
        view.isOpaque = true
        
        // Listen for app state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
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
        
        // Add instruction label
        let instructionLabel = UILabel()
        instructionLabel.text = "Align QR code in the frame"
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        instructionLabel.layer.cornerRadius = 8
        instructionLabel.clipsToBounds = true
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.adjustsFontSizeToFitWidth = true
        instructionLabel.minimumScaleFactor = 0.8
        view.addSubview(instructionLabel)
        self.instructionLabel = instructionLabel
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            instructionLabel.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func setupCamera() {
        print("📷 QR Scanner: Starting camera setup...")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            print("📷 QR Scanner: Creating capture session on session queue...")
            let session = AVCaptureSession()
            if session.canSetSessionPreset(.medium) {
                session.sessionPreset = .medium
            } else {
                session.sessionPreset = .low
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
            
            // Optimize camera settings
            do {
                try videoCaptureDevice.lockForConfiguration()
                if videoCaptureDevice.isFocusModeSupported(.continuousAutoFocus) {
                    videoCaptureDevice.focusMode = .continuousAutoFocus
                }
                videoCaptureDevice.unlockForConfiguration()
                print("✅ QR Scanner: Camera configured")
            } catch {
                print("⚠️ QR Scanner: Could not optimize camera settings: \(error.localizedDescription)")
            }
            
            let metadataOutput = AVCaptureMetadataOutput()
            
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.metadataObjectTypes = [.qr]
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    print("📷 QR Scanner: Setting up UI on main thread...")
                    
                    self.captureSession = session
                    self.metadataOutput = metadataOutput
                    
                    // Set delegate on background queue
                    let metadataQueue = DispatchQueue(label: "com.cacheraiders.qrscanner.metadata", qos: .userInitiated)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
                    print("📷 QR Scanner: Delegate set")
                    
                    // Set rectOfInterest to full frame
                    let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    self.sessionQueue.async {
                        metadataOutput.rectOfInterest = fullRect
                    }
                    
                    // Create preview layer
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    
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
                    
                    // Remove existing preview layers
                    if let existingLayers = self.view.layer.sublayers {
                        for layer in existingLayers {
                            if layer is AVCaptureVideoPreviewLayer {
                                layer.removeFromSuperlayer()
                            }
                        }
                    }
                    
                    // Insert preview layer at index 0 (behind UI)
                    self.view.layer.insertSublayer(previewLayer, at: 0)
                    
                    let bounds = self.view.layer.bounds
                    if bounds.width > 0 && bounds.height > 0 {
                        previewLayer.frame = bounds
                        print("📷 QR Scanner: Preview layer added with frame: \(bounds)")
                    }
                    
                    // Add scanning frame overlay
                    self.addScanningFrame()
                    
                    // Start session automatically
                    print("📷 QR Scanner: Starting scanning session...")
                    self.startSession()
                }
            } else {
                DispatchQueue.main.async {
                    self.showError("Cannot add metadata output")
                }
                return
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
        
        if let previewLayer = previewLayer {
            let bounds = view.layer.bounds
            if bounds.width > 0 && bounds.height > 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                previewLayer.frame = bounds
                CATransaction.commit()
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
        stopSession()
        dismiss(animated: true)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        print("📷 QR Scanner: viewDidAppear() called")
        
        if let previewLayer = previewLayer {
            let bounds = view.layer.bounds
            if bounds.width > 0 && bounds.height > 0 {
                if previewLayer.superlayer != view.layer {
                    previewLayer.removeFromSuperlayer()
                    view.layer.insertSublayer(previewLayer, at: 0)
                }
                previewLayer.isHidden = false
                previewLayer.opacity = 1.0
                previewLayer.frame = bounds
            }
        }
        
        // Start session if not already running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startSession()
        }
    }
    
    private func startSession() {
        guard sessionStartAttempts < maxSessionStartAttempts else {
            print("⚠️ QR Scanner: Max session start attempts reached")
            showError("Failed to start camera. Please try again.")
            return
        }
        
        sessionStartAttempts += 1
        
        guard let session = captureSession else {
            print("⏳ QR Scanner: Session not ready yet, attempt \(sessionStartAttempts)/\(maxSessionStartAttempts)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startSession()
            }
            return
        }
        
        guard !session.isRunning else {
            print("✅ QR Scanner: Session already running")
            sessionStartAttempts = 0
            return
        }
        
        let capturedSession = session
        sessionQueue.async { [weak self] in
            guard self != nil else { return }
            
            print("📷 QR Scanner: Starting session on session queue...")
            capturedSession.startRunning()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                if capturedSession.isRunning {
                    print("✅ QR Scanner: Camera session started successfully")
                    self.sessionStartAttempts = 0
                } else {
                    print("⚠️ QR Scanner: Session start may have failed, retrying...")
                    if self.sessionStartAttempts < self.maxSessionStartAttempts {
                        self.startSession()
                    }
                }
            }
        }
    }
    
    private func stopSession() {
        let session = captureSession
        if let session = session, session.isRunning {
        print("📷 QR Scanner: Stopping session")
        sessionQueue.async { [weak self] in
            session.stopRunning()
            print("📷 QR Scanner: Session stopped")
            // Reset processing flag when session stops
            DispatchQueue.main.async {
                self?.isProcessingScan = false
            }
        }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("📷 QR Scanner: viewWillDisappear() called")
        stopSession()
    }
    
    deinit {
        print("📷 QR Scanner: deinit() called")
        NotificationCenter.default.removeObserver(self)
        let session = captureSession
        if let session = session, session.isRunning {
            sessionQueue.async {
                session.stopRunning()
            }
        }
    }
    
    // MARK: - Interruption Handlers
    
    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        print("✅ QR Scanner: App became active - resuming camera")
        startSession()
    }
    
    @objc private func handleSessionWasInterrupted(_ notification: Notification) {
        print("🚨 QR Scanner: Camera session interrupted")
    }
    
    @objc private func handleSessionInterruptionEnded(_ notification: Notification) {
        print("✅ QR Scanner: Camera session interruption ended - resuming")
        startSession()
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate
extension QRCodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !metadataObjects.isEmpty else { return }
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = metadataObject.stringValue else {
                return
            }
            
            // Validate URL
            guard stringValue.hasPrefix("http://") || stringValue.hasPrefix("https://") else {
                return
            }
            
            let capturedString = stringValue
            let currentTime = Date()

            // Prevent concurrent scan processing
            guard !self.isProcessingScan else {
                print("📷 QR Scanner: Ignoring scan - already processing one")
                return
            }

            // Debounce duplicate scans
            guard currentTime.timeIntervalSince(self.lastScanTime) >= self.scanDebounceInterval else {
                print("📷 QR Scanner: Ignoring scan - within debounce interval")
                return
            }

            // Mark as processing
            self.isProcessingScan = true
            self.lastScanTime = currentTime
            
            print("✅ QR Scanner: Processing valid QR code: \(capturedString)")
            
            // Stop session after successful scan
            self.stopSession()

            // Play haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)

            // Notify delegate
            self.delegate?.didScanQRCode(capturedString)

            // Reset processing flag after a delay to allow delegate processing
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isProcessingScan = false
            }
        }
    }
}


