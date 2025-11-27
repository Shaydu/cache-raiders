import SwiftUI

struct NetworkDiagnosticsView: View {
    let report: NetworkDiagnosticReport
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Network Diagnostics")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Server: \(report.serverURL)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    
                    // HTTP Test
                    if let httpTest = report.httpTest {
                        TestResultCard(
                            title: "HTTP Connectivity",
                            result: httpTest.reachable ? "✅ Reachable" : "❌ Not Reachable",
                            details: [
                                ("Status Code", httpTest.statusCode != nil ? "\(httpTest.statusCode!)" : "N/A"),
                                ("Latency", httpTest.latency != nil ? String(format: "%.0f ms", httpTest.latency!) : "N/A"),
                                ("Error", httpTest.error ?? "None")
                            ],
                            isSuccess: httpTest.reachable
                        )
                    }
                    
                    // Port Test
                    if let portTest = report.portTest {
                        TestResultCard(
                            title: "Port Connectivity",
                            result: portTest.reachable ? "✅ Port \(portTest.port) Reachable" : "❌ Port \(portTest.port) Not Reachable",
                            details: [
                                ("Host", portTest.host),
                                ("Port", "\(portTest.port)"),
                                ("Latency", portTest.latency != nil ? String(format: "%.0f ms", portTest.latency!) : "N/A"),
                                ("Error", portTest.error ?? "None")
                            ],
                            isSuccess: portTest.reachable
                        )
                    }
                    
                    // Common Ports Test
                    if !report.commonPortsTest.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Common Ports Test")
                                .font(.headline)
                            
                            ForEach(report.commonPortsTest, id: \.port) { test in
                                HStack {
                                    Text("Port \(test.port):")
                                        .font(.subheadline)
                                        .frame(width: 80, alignment: .leading)
                                    
                                    if test.reachable {
                                        Label(test.latency != nil ? String(format: "%.0f ms", test.latency!) : "Reachable", systemImage: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else {
                                        Label("Not Reachable", systemImage: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                
                                if let error = test.error {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 88)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    
                    // Trace Route
                    if let traceRoute = report.traceRoute {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Network Path")
                                .font(.headline)
                            
                            if let error = traceRoute.error {
                                Text("❌ \(error)")
                                    .foregroundColor(.red)
                            } else if traceRoute.hops.isEmpty {
                                Text("⚠️ No path information available")
                                    .foregroundColor(.orange)
                            } else {
                                ForEach(traceRoute.hops, id: \.hop) { hop in
                                    HStack {
                                        Text("Hop \(hop.hop):")
                                            .font(.subheadline)
                                            .frame(width: 60, alignment: .leading)
                                        
                                        Text(hop.host)
                                            .font(.system(.subheadline, design: .monospaced))
                                        
                                        Spacer()
                                        
                                        Text(String(format: "%.0f ms", hop.latency))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    
                    // Error
                    if let error = report.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            Text(error)
                                .font(.subheadline)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    
                    // Interpretation
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interpretation")
                            .font(.headline)
                        
                        interpretationText
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Network Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var interpretationText: Text {
        var text = Text("")
        
        let httpReachable = report.httpTest?.reachable ?? false
        let portReachable = report.portTest?.reachable ?? false
        let anyPortReachable = report.commonPortsTest.contains { $0.reachable }
        
        // Extract server info
        let serverHost = report.serverURL.contains("://") ? 
            (URL(string: report.serverURL)?.host ?? "unknown") : 
            report.serverURL.split(separator: ":").first.map(String.init) ?? "unknown"
        
        if httpReachable && portReachable {
            text = text + Text("✅ Server is reachable. Connection issues are likely not due to router/firewall blocking.\n\n")
        } else if httpReachable && !portReachable {
            text = text + Text("⚠️ HTTP works but specific port is blocked. This suggests:\n• Router firewall may be blocking the port\n• Port forwarding may be needed\n• Server may not be listening on that port\n\n")
        } else if !httpReachable && anyPortReachable {
            text = text + Text("⚠️ Some ports work but HTTP doesn't. Check:\n• Server is running\n• Correct URL/port\n• HTTP vs HTTPS mismatch\n\n")
        } else if !httpReachable && !anyPortReachable {
            text = text + Text("❌ No ports are reachable from \(serverHost). This suggests:\n\n")
            text = text + Text("1. Server may not be running:\n")
            text = text + Text("   • Check if server process is running on \(serverHost)\n")
            text = text + Text("   • Try: python app.py (in server/ directory)\n")
            text = text + Text("   • Check server logs for errors\n\n")
            
            text = text + Text("2. Network connectivity issue:\n")
            text = text + Text("   • Device and server must be on same Wi-Fi network\n")
            text = text + Text("   • Verify IP address: \(serverHost)\n")
            text = text + Text("   • Try pinging \(serverHost) from terminal: ping \(serverHost)\n\n")
            
            text = text + Text("3. Router/Firewall blocking:\n")
            text = text + Text("   • Router firewall may be blocking all connections\n")
            text = text + Text("   • Check router admin panel for firewall rules\n")
            text = text + Text("   • Try temporarily disabling firewall to test\n\n")
            
            text = text + Text("4. Server IP address changed:\n")
            text = text + Text("   • Server IP may have changed (DHCP)\n")
            text = text + Text("   • Check server's current IP: ifconfig (Mac/Linux) or ipconfig (Windows)\n")
            text = text + Text("   • Update server URL in settings if IP changed\n\n")
        }
        
        if let portTest = report.portTest, !portTest.reachable {
            text = text + Text("💡 Port \(portTest.port) Troubleshooting:\n")
            text = text + Text("• Verify server is listening on port \(portTest.port)\n")
            text = text + Text("• Check server logs for binding errors\n")
            text = text + Text("• Test from server itself: curl http://localhost:\(portTest.port)/health\n")
            text = text + Text("• Check router firewall settings\n")
            text = text + Text("• Ensure device and server are on same network\n\n")
        }
        
        // Add specific error details if available
        if let httpError = report.httpTest?.error {
            text = text + Text("\nHTTP Error Details: \(httpError)\n")
        }
        if let portError = report.portTest?.error {
            text = text + Text("\nPort Error Details: \(portError)\n")
        }
        
        return text
    }
}

struct TestResultCard: View {
    let title: String
    let result: String
    let details: [(String, String)]
    let isSuccess: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            
            Text(result)
                .font(.subheadline)
                .foregroundColor(isSuccess ? .green : .red)
            
            ForEach(details, id: \.0) { detail in
                HStack {
                    Text("\(detail.0):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    
                    Text(detail.1)
                        .font(.system(.caption, design: .monospaced))
                    
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

