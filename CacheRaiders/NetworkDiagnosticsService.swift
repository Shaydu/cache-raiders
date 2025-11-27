import Foundation
import Network
import os

/// Network Diagnostics Service - Tests port connectivity and network path
class NetworkDiagnosticsService {
    static let shared = NetworkDiagnosticsService()
    
    private init() {}
    
    // MARK: - Port Connectivity Test
    
    /// Test TCP connectivity to a specific host and port
    func testPort(host: String, port: Int, timeout: TimeInterval = 5.0) async -> PortTestResult {
        let startTime = Date()
        
        // Use Network framework for modern iOS port testing
        guard let portUInt16 = UInt16(exactly: port) else {
            return PortTestResult(
                host: host,
                port: port,
                reachable: false,
                latency: nil,
                error: "Invalid port number: \(port)"
            )
        }
        
        // Create TCP connection using Network framework
        let hostEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: portUInt16)
        )
        
        let connection = NWConnection(to: hostEndpoint, using: .tcp)
        
        return await withCheckedContinuation { continuation in
            // Use a thread-safe flag to track if we've already resumed
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if hasResumed.withLock({ resumed in
                        if !resumed {
                            resumed = true
                            return true
                        }
                        return false
                    }) {
                        let latency = Date().timeIntervalSince(startTime) * 1000 // Convert to ms
                        connection.cancel()
                        continuation.resume(returning: PortTestResult(
                            host: host,
                            port: port,
                            reachable: true,
                            latency: latency,
                            error: nil
                        ))
                    }
                case .failed(let error):
                    if hasResumed.withLock({ resumed in
                        if !resumed {
                            resumed = true
                            return true
                        }
                        return false
                    }) {
                        let latency = Date().timeIntervalSince(startTime) * 1000
                        continuation.resume(returning: PortTestResult(
                            host: host,
                            port: port,
                            reachable: false,
                            latency: latency,
                            error: error.localizedDescription
                        ))
                    }
                case .waiting:
                    // Connection is waiting (e.g., for network)
                    // Don't treat as failure yet, but set a timeout
                    break
                default:
                    break
                }
            }
            
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            
            // Set timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if hasResumed.withLock({ resumed in
                    if !resumed {
                        resumed = true
                        return true
                    }
                    return false
                }) {
                    connection.cancel()
                    continuation.resume(returning: PortTestResult(
                        host: host,
                        port: port,
                        reachable: false,
                        latency: timeout * 1000,
                        error: "Connection timeout after \(Int(timeout))s"
                    ))
                }
            }
        }
    }
    
    /// Test multiple ports concurrently
    func testPorts(host: String, ports: [Int], timeout: TimeInterval = 5.0) async -> [PortTestResult] {
        await withTaskGroup(of: PortTestResult.self) { group in
            for port in ports {
                group.addTask {
                    await self.testPort(host: host, port: port, timeout: timeout)
                }
            }
            
            var results: [PortTestResult] = []
            for await result in group {
                results.append(result)
            }
            
            return results.sorted { $0.port < $1.port }
        }
    }
    
    // MARK: - HTTP Connectivity Test
    
    /// Test HTTP connectivity to a specific URL
    func testHTTPConnectivity(url: String, timeout: TimeInterval = 10.0) async -> HTTPTestResult {
        guard let testURL = URL(string: url) else {
            return HTTPTestResult(
                url: url,
                reachable: false,
                statusCode: nil,
                latency: nil,
                error: "Invalid URL: \(url)"
            )
        }
        
        let startTime = Date()
        
        var request = URLRequest(url: testURL)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(startTime) * 1000 // Convert to ms
            
            if let httpResponse = response as? HTTPURLResponse {
                return HTTPTestResult(
                    url: url,
                    reachable: true,
                    statusCode: httpResponse.statusCode,
                    latency: latency,
                    error: nil
                )
            } else {
                return HTTPTestResult(
                    url: url,
                    reachable: true,
                    statusCode: nil,
                    latency: latency,
                    error: nil
                )
            }
        } catch {
            let latency = Date().timeIntervalSince(startTime) * 1000
            return HTTPTestResult(
                url: url,
                reachable: false,
                statusCode: nil,
                latency: latency,
                error: error.localizedDescription
            )
        }
    }
    
    // MARK: - Network Path Diagnostics (Simplified Traceroute)
    
    /// Perform a simplified traceroute-like test
    /// Note: iOS doesn't allow raw ICMP sockets, so we use TCP connection attempts with TTL
    func traceRoute(host: String, maxHops: Int = 15, timeout: TimeInterval = 3.0) async -> TraceRouteResult {
        var hops: [TraceHop] = []
        
        // Extract hostname/IP from URL if needed
        let targetHost: String
        if let url = URL(string: host), let hostComponent = url.host {
            targetHost = hostComponent
        } else if host.contains("://") {
            if let url = URL(string: host), let hostComponent = url.host {
                targetHost = hostComponent
            } else {
                return TraceRouteResult(
                    host: host,
                    hops: [],
                    error: "Invalid host format: \(host)"
                )
            }
        } else {
            targetHost = host
        }
        
        // Get the port from URL or use default
        let targetPort: Int
        if let url = URL(string: host), let port = url.port {
            targetPort = port
        } else if host.contains("://") {
            if let url = URL(string: host), let port = url.port {
                targetPort = port
            } else {
                targetPort = 80 // Default HTTP port
            }
        } else {
            targetPort = 80
        }
        
        // Test connectivity to target first
        let finalTest = await testPort(host: targetHost, port: targetPort, timeout: timeout)
        if !finalTest.reachable {
            return TraceRouteResult(
                host: host,
                hops: [],
                error: "Target host \(targetHost):\(targetPort) is not reachable: \(finalTest.error ?? "Unknown error")"
            )
        }
        
        // For iOS, we can't do true traceroute (no raw sockets)
        // Instead, we'll test connectivity and provide network diagnostics
        // We can test if we can reach the host and measure latency
        
        let testResult = await testPort(host: targetHost, port: targetPort, timeout: timeout)
        
        if testResult.reachable {
            hops.append(TraceHop(
                hop: 1,
                host: targetHost,
                latency: testResult.latency ?? 0,
                error: nil
            ))
        }
        
        return TraceRouteResult(
            host: host,
            hops: hops,
            error: nil
        )
    }
    
    // MARK: - Comprehensive Network Diagnostic
    
    /// Run comprehensive network diagnostics
    func runFullDiagnostics(serverURL: String) async -> NetworkDiagnosticReport {
        var report = NetworkDiagnosticReport(serverURL: serverURL)
        
        // Normalize URL - ensure it has a scheme
        var normalizedURL = serverURL
        if !normalizedURL.contains("://") {
            normalizedURL = "http://\(normalizedURL)"
        }
        
        // Extract host and port from URL
        guard let url = URL(string: normalizedURL),
              let host = url.host else {
            report.error = "Invalid server URL: \(serverURL). Please use format: http://192.168.68.50:5001"
            return report
        }
        
        // Extract port - handle both explicit port and default ports
        let port: Int
        if let urlPort = url.port {
            port = urlPort
        } else {
            // Default ports based on scheme
            port = (url.scheme == "https" || url.scheme == "wss") ? 443 : 80
        }
        
        print("🔍 [Network Diagnostics] Testing server: \(host):\(port)")
        print("   Full URL: \(normalizedURL)")
        
        // Test 1: HTTP connectivity (use normalized URL)
        print("🔍 [Network Diagnostics] Test 1: HTTP connectivity...")
        report.httpTest = await testHTTPConnectivity(url: normalizedURL, timeout: 10.0)
        
        // Test 2: TCP port connectivity (always test the actual port from URL)
        print("🔍 [Network Diagnostics] Test 2: TCP port \(port) connectivity...")
        report.portTest = await testPort(host: host, port: port, timeout: 5.0)
        
        // Test 3: Test common ports (including the actual port)
        print("🔍 [Network Diagnostics] Test 3: Common ports...")
        var commonPorts = [5001, 5000, 8080, 3000, 8000, 80, 443]
        // Ensure the actual port is in the list
        if !commonPorts.contains(port) {
            commonPorts.insert(port, at: 0) // Add at beginning
        }
        report.commonPortsTest = await testPorts(host: host, ports: commonPorts, timeout: 3.0)
        
        // Test 4: Simplified trace route (only if HTTP works)
        if report.httpTest?.reachable == true {
            print("🔍 [Network Diagnostics] Test 4: Network path...")
            report.traceRoute = await traceRoute(host: normalizedURL, maxHops: 15)
        } else {
            report.traceRoute = TraceRouteResult(
                host: normalizedURL,
                hops: [],
                error: "Skipped: HTTP connectivity failed"
            )
        }
        
        print("🔍 [Network Diagnostics] Complete")
        return report
    }
}

// MARK: - Result Types

struct PortTestResult {
    let host: String
    let port: Int
    let reachable: Bool
    let latency: Double? // in milliseconds
    let error: String?
    
    var summary: String {
        if reachable {
            let latencyStr = latency != nil ? String(format: "%.0fms", latency!) : "N/A"
            return "✅ Port \(port) reachable (\(latencyStr))"
        } else {
            return "❌ Port \(port) not reachable: \(error ?? "Unknown error")"
        }
    }
}

struct HTTPTestResult {
    let url: String
    let reachable: Bool
    let statusCode: Int?
    let latency: Double? // in milliseconds
    let error: String?
    
    var summary: String {
        if reachable {
            let latencyStr = latency != nil ? String(format: "%.0fms", latency!) : "N/A"
            let statusStr = statusCode != nil ? " (HTTP \(statusCode!))" : ""
            return "✅ HTTP reachable (\(latencyStr))\(statusStr)"
        } else {
            return "❌ HTTP not reachable: \(error ?? "Unknown error")"
        }
    }
}

struct TraceHop {
    let hop: Int
    let host: String
    let latency: Double // in milliseconds
    let error: String?
}

struct TraceRouteResult {
    let host: String
    let hops: [TraceHop]
    let error: String?
    
    var summary: String {
        if let error = error {
            return "❌ Trace failed: \(error)"
        }
        if hops.isEmpty {
            return "⚠️ No hops recorded"
        }
        return "✅ Trace complete: \(hops.count) hop(s)"
    }
}

struct NetworkDiagnosticReport {
    let serverURL: String
    var httpTest: HTTPTestResult?
    var portTest: PortTestResult?
    var commonPortsTest: [PortTestResult] = []
    var traceRoute: TraceRouteResult?
    var error: String?
    
    var summary: String {
        var parts: [String] = []
        parts.append("Network Diagnostics for \(serverURL)\n")
        
        if let httpTest = httpTest {
            parts.append("\nHTTP Test:")
            parts.append("  \(httpTest.summary)")
        }
        
        if let portTest = portTest {
            parts.append("\nPort Test:")
            parts.append("  \(portTest.summary)")
        }
        
        if !commonPortsTest.isEmpty {
            parts.append("\nCommon Ports Test:")
            for test in commonPortsTest {
                parts.append("  \(test.summary)")
            }
        }
        
        if let traceRoute = traceRoute {
            parts.append("\nTrace Route:")
            parts.append("  \(traceRoute.summary)")
        }
        
        if let error = error {
            parts.append("\nError: \(error)")
        }
        
        return parts.joined(separator: "\n")
    }
}

