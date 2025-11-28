import Foundation

// MARK: - Performance Monitor
/// Helper class for monitoring and logging performance issues
/// Helps identify slow operations that could cause freezes
class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    /// Threshold for logging slow operations (in seconds)
    /// Default: 0.016 seconds (one frame at 60fps)
    var slowOperationThreshold: TimeInterval = 0.016
    
    /// Whether performance monitoring is enabled
    var isEnabled: Bool = true
    
    private init() {}
    
    /// Measures the execution time of a synchronous operation
    /// - Parameters:
    ///   - label: Description of the operation
    ///   - operation: The operation to measure
    /// - Returns: The result of the operation
    func measure<T>(_ label: String, operation: () -> T) -> T {
        guard isEnabled else {
            return operation()
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        let result = operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        if elapsed > slowOperationThreshold {
            let elapsedMs = elapsed * 1000
            Swift.print("⚠️ [PERF] SLOW OPERATION: \(label) took \(String(format: "%.1f", elapsedMs))ms")
            Swift.print("   Threshold: \(String(format: "%.1f", slowOperationThreshold * 1000))ms (one frame at 60fps)")
        }
        
        return result
    }
    
    /// Measures the execution time of an asynchronous operation
    /// - Parameters:
    ///   - label: Description of the operation
    ///   - operation: The async operation to measure
    /// - Returns: The result of the operation
    func measureAsync<T>(_ label: String, operation: () async -> T) async -> T {
        guard isEnabled else {
            return await operation()
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        let result = await operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        if elapsed > slowOperationThreshold {
            let elapsedMs = elapsed * 1000
            Swift.print("⚠️ [PERF] SLOW ASYNC OPERATION: \(label) took \(String(format: "%.1f", elapsedMs))ms")
            Swift.print("   Threshold: \(String(format: "%.1f", slowOperationThreshold * 1000))ms (one frame at 60fps)")
        }
        
        return result
    }
    
    /// Measures the execution time of an async throwing operation
    /// - Parameters:
    ///   - label: Description of the operation
    ///   - operation: The async throwing operation to measure
    /// - Returns: The result of the operation
    func measureAsyncThrowing<T>(_ label: String, operation: () async throws -> T) async rethrows -> T {
        guard isEnabled else {
            return try await operation()
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        if elapsed > slowOperationThreshold {
            let elapsedMs = elapsed * 1000
            Swift.print("⚠️ [PERF] SLOW ASYNC OPERATION: \(label) took \(String(format: "%.1f", elapsedMs))ms")
            Swift.print("   Threshold: \(String(format: "%.1f", slowOperationThreshold * 1000))ms (one frame at 60fps)")
        }
        
        return result
    }
    
    /// Logs a performance metric without measuring
    /// - Parameters:
    ///   - label: Description of the metric
    ///   - value: The metric value
    ///   - unit: Unit of measurement (default: "ms")
    func logMetric(_ label: String, value: Double, unit: String = "ms") {
        guard isEnabled else { return }
        Swift.print("📊 [PERF] \(label): \(String(format: "%.1f", value))\(unit)")
    }
}

