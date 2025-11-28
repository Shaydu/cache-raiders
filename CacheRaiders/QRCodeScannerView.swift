import SwiftUI
import AVFoundation

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

class QRCodeScannerViewController: UIViewController {
    weak var delegate: QRCodeScannerDelegate?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var scanningFrameView: UIView?
    private var lastScanTime: Date = Date.distantPast
    private let scanDebounceInterval: TimeInterval = 0.3 // Prevent duplicate scans within 300ms
    
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
        instructionLabel.text = "Align QR code inside the green square"
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        instructionLabel.layer.cornerRadius = 8
        instructionLabel.clipsToBounds = true
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.widthAnchor.constraint(equalToConstant: 280),
            instructionLabel.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        // Use medium preset for faster processing - still high quality enough for QR codes
        // This significantly improves scan speed while maintaining accuracy
        session.sessionPreset = .medium
        self.captureSession = session
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showError("Camera not available")
            return
        }
        
        let videoInput: AVCaptureDeviceInput
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            showError("Failed to create video input: \(error.localizedDescription)")
            return
        }
        
        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        } else {
            showError("Cannot add video input")
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            
            // Process metadata on background queue for faster performance
            // Delegate callback will dispatch to main queue when needed
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
            metadataOutput.metadataObjectTypes = [.qr]
            self.metadataOutput = metadataOutput
        } else {
            showError("Cannot add metadata output")
            return
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        
        // Add scanning frame overlay
        addScanningFrame()
        
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
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
        
        // Keep preview layer and metadata rect in sync with layout
        previewLayer?.frame = view.layer.bounds
        
        if let previewLayer = previewLayer,
           let metadataOutput = metadataOutput,
           let scanningFrame = scanningFrameView {
            let frameInViewCoords = scanningFrame.convert(scanningFrame.bounds, to: view)
            let rectOfInterest = previewLayer.metadataOutputRectConverted(fromLayerRect: frameInViewCoords)
            metadataOutput.rectOfInterest = rectOfInterest
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
        
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if let session = captureSession, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate
extension QRCodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // Debounce: prevent duplicate scans within the debounce interval
        let now = Date()
        guard now.timeIntervalSince(lastScanTime) >= scanDebounceInterval else {
            return // Too soon since last scan, ignore
        }
        
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }
        
        // Validate that it looks like a URL
        guard stringValue.hasPrefix("http://") || stringValue.hasPrefix("https://") else {
            return
        }
        
        // Mark this scan time to prevent duplicates
        lastScanTime = now
        
        // Stop scanning immediately to prevent further processing
        captureSession?.stopRunning()
        
        // Dispatch UI updates to main queue
        DispatchQueue.main.async { [weak self] in
            // Play haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            // Notify delegate
            self?.delegate?.didScanQRCode(stringValue)
        }
    }
}

