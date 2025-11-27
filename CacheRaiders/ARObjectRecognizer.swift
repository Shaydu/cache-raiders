import Foundation
import Vision
import ARKit

// MARK: - AR Object Recognizer
/// Handles Vision-based object recognition in AR frames
class ARObjectRecognizer {
    private let objectClassificationRequest = VNClassifyImageRequest()
    private var lastRecognitionTime = Date.distantPast
    private let recognitionInterval: TimeInterval = 3.0 // Classify every 3 seconds
    
    init() {
        setupObjectRecognition()
    }
    
    private func setupObjectRecognition() {
        // Configure image classification request
        // Note: usesCPUOnly was deprecated in iOS 17+ - Vision now auto-selects optimal processing unit
        
        // Use built-in classification model for general object recognition
        print("🔍 Object recognition initialized - will classify objects every \(recognitionInterval) seconds")
    }
    
    /// Perform object recognition on a camera frame
    func performObjectRecognition(on pixelBuffer: CVPixelBuffer) {
        // Throttle recognition to avoid excessive processing
        let now = Date()
        guard now.timeIntervalSince(lastRecognitionTime) >= recognitionInterval else { return }
        lastRecognitionTime = now
        
        // Create Vision image request handler
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        do {
            try imageRequestHandler.perform([objectClassificationRequest])
            
            // Process results
            if let results = objectClassificationRequest.results {
                processObjectRecognitionResults(results)
            }
        } catch {
            print("❌ Object recognition failed: \(error.localizedDescription)")
        }
    }
    
    private func processObjectRecognitionResults(_ results: [VNClassificationObservation]) {
        // Filter for high-confidence results (> 0.5) and limit to top 5
        let topResults = results
            .filter { $0.confidence > 0.3 } // Lower threshold for more results
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
        
        guard !topResults.isEmpty else {
            print("🔍 No objects classified in current frame (low confidence)")
            return
        }
        
        print("🔍 Object Classification Results (top \(topResults.count)):")
        
        for (index, result) in topResults.enumerated() {
            let objectName = result.identifier
            let confidence = result.confidence
            
            // Clean up the identifier (remove underscores, capitalize)
            let cleanName = objectName.replacingOccurrences(of: "_", with: " ").capitalized
            
            print("   \(index + 1). \(cleanName) - \(String(format: "%.1f", confidence * 100))% confidence")
        }
    }
}









