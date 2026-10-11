import SwiftUI
import CoreLocation
import Combine

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @ObservedObject private var webSocketService = WebSocketService.shared
    @ObservedObject private var offlineModeManager = OfflineModeManager.shared
    @StateObject private var viewModel: SettingsViewModel
    @Environment(\.dismiss) var dismiss
    @State private var previousDistance: Double = 10.0
    @State private var showQRScanner = false
    @State private var scannedURL: String?
    @State private var isTestingConnection = false
    @State private var testResult: WebSocketService.TestResult?
    @State private var isTestingMultiplePorts = false
    @State private var multiPortTestResult: WebSocketService.MultiPortTestResult?
    @State private var isRunningNetworkDiagnostics = false
    @State private var networkDiagnosticReport: NetworkDiagnosticReport?
    @State private var showNetworkDiagnostics = false
    
    // PERFORMANCE: Cache expensive computed values to avoid recomputing on every view update
    @State private var cachedGroupedTypes: [(models: [String], typeCounts: [(type: LootBoxType, count: Int)])] = []
    @State private var regenerateTask: Task<Void, Never>?
    
    init(locationManager: LootBoxLocationManager, userLocationManager: UserLocationManager) {
        self.locationManager = locationManager
        self.userLocationManager = userLocationManager
        _viewModel = StateObject(wrappedValue: SettingsViewModel(locationManager: locationManager, userLocationManager: userLocationManager))
    }
    
    // Helper function to get icon name for each findable type
    // Uses the factory pattern to ensure consistency with the rest of the app
    private func iconName(for type: LootBoxType) -> String {
        return type.factory.iconName
    }
    
    // Helper function to get model names for each findable type (uses factory)
    private func modelNames(for type: LootBoxType) -> [String] {
        return type.factory.modelNames
    }
    
    // PERFORMANCE: Use cached grouped types instead of computing on every view update
    private var groupedFindableTypes: [(models: [String], types: [LootBoxType])] {
        // Return cached data or compute once and cache
        return cachedGroupedTypes.map { group in
            (models: group.models, types: group.typeCounts.map { $0.type })
        }
    }
    
    // PERFORMANCE: Use cached counts instead of filtering locations array repeatedly
    private func countForType(_ type: LootBoxType) -> Int {
        // Find in cached data for O(1) lookup
        for group in cachedGroupedTypes {
            if let typeCount = group.typeCounts.first(where: { $0.type == type }) {
                return typeCount.count
            }
        }
        return 0
    }
    
    // PERFORMANCE: Update cached data off main thread when locations change
    private func updateCachedTypeData() {
        // Capture display names and model names on main actor before entering detached task
        let typeDisplayNames = Dictionary(uniqueKeysWithValues: LootBoxType.allCases.map { ($0, $0.displayName) })
        let typeModelNames = Dictionary(uniqueKeysWithValues: LootBoxType.allCases.map { ($0, $0.factory.modelNames) })
        
        Task.detached(priority: .userInitiated) { [locations = locationManager.locations, typeDisplayNames, typeModelNames] in
            // Build type counts dictionary off main thread
            var typeCounts: [LootBoxType: Int] = [:]
            for location in locations {
                typeCounts[location.type, default: 0] += 1
            }
            
            // Group types by their model names
            var groups: [[String]: [LootBoxType]] = [:]
            
            for type in LootBoxType.allCases {
                let models = typeModelNames[type] ?? []
                let key = models.sorted()
                if groups[key] == nil {
                    groups[key] = []
                }
                groups[key]?.append(type)
            }
            
            // Build result with counts
            let result = groups.map { (models: $0.key, typeCounts: $0.value.map { type in
                (type: type, count: typeCounts[type] ?? 0)
            }) }
            .sorted { group1, group2 in
                let name1 = typeDisplayNames[group1.typeCounts.first?.type ?? LootBoxType.treasureChest] ?? ""
                let name2 = typeDisplayNames[group2.typeCounts.first?.type ?? LootBoxType.treasureChest] ?? ""
                return name1 < name2
            }
            
            // Update UI on main thread
            await MainActor.run {
                self.cachedGroupedTypes = result
            }
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                searchDistanceSection
                maxObjectLimitSection
                findableTypesSection
                mapDisplaySection
                conversationSection
                arZoomSection
                arDebugSection
                userProfileSection
                leaderboardSection
                apiSyncSection
                arLensSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                previousDistance = locationManager.maxSearchDistance
                
                // PERFORMANCE: Load network-dependent operations on background thread
                Task(priority: .userInitiated) {
                    // Load API URL (network helper operations can be slow)
                    await MainActor.run {
                        viewModel.loadAPIURL()
                    }
                    
                    // Load user name
                    await MainActor.run {
                        viewModel.loadUserName()
                    }
                    
                    await MainActor.run {
                        viewModel.selectedObjectId = locationManager.selectedDatabaseObjectId
                        
                        // Set up error callback to display connection errors to user
                        WebSocketService.shared.onConnectionError = { errorMessage in
                            Task { @MainActor in
                                viewModel.displayAlert(title: "WebSocket Connection Failed", message: errorMessage)
                            }
                        }
                        
                        if locationManager.useAPISync {
                            viewModel.loadDatabaseObjects()
                            viewModel.loadLeaderboard()
                            WebSocketService.shared.connect()
                        }
                    }
                }
                
                // Update cached type data
                updateCachedTypeData()
            }
            .onChange(of: locationManager.locations.count) { _, _ in
                // Update cache when locations change
                updateCachedTypeData()
            }
            .alert(viewModel.alertTitle, isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.alertMessage)
            }
        }
    }
    
    // MARK: - View Sections
    
    private var searchDistanceSection: some View {
        Section("Search Distance") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Maximum Search Distance: \(Int(locationManager.maxSearchDistance))m")
                    .font(.headline)
                
                Slider(
                    value: Binding(
                        get: { locationManager.maxSearchDistance },
                        set: { newValue in
                            locationManager.maxSearchDistance = newValue
                            locationManager.saveMaxDistance()
                            
                            // PERFORMANCE: Debounce regeneration and move to background thread
                            if previousDistance != newValue {
                                // Cancel any pending regeneration task
                                regenerateTask?.cancel()
                                
                                // Debounce: wait 500ms after user stops adjusting slider
                                regenerateTask = Task { @MainActor [weak locationManager] in
                                    // Capture userLocationManager from the view context
                                    let currentUserLocationManager = userLocationManager
                                    
                                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
                                    
                                    guard !Task.isCancelled,
                                          let locationManager = locationManager,
                                          let userLocation = currentUserLocationManager.currentLocation else {
                                        return
                                    }
                                    
                                    print("🔄 Search distance changed from \(previousDistance)m to \(newValue)m, regenerating loot boxes")
                                    
                                    // Move heavy regeneration to background thread
                                    Task.detached(priority: .userInitiated) {
                                        await MainActor.run {
                                            locationManager.regenerateLocations(near: userLocation)
                                        }
                                    }
                                }
                            }
                            previousDistance = newValue
                        }
                    ),
                    in: 10...100,
                    step: 10
                )
                
                HStack {
                    Text("10m")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("100m")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text("Loot boxes within this distance will appear in AR")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    private var maxObjectLimitSection: some View {
        Section("AR Object Limit") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Maximum Objects in AR: \(locationManager.maxObjectLimit)")
                    .font(.headline)
                
                Slider(
                    value: Binding(
                        get: { Double(locationManager.maxObjectLimit) },
                        set: { newValue in
                            locationManager.maxObjectLimit = Int(newValue)
                            locationManager.saveMaxObjectLimit()
                        }
                    ),
                    in: 1...25,
                    step: 1
                )
                
                HStack {
                    Text("1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("25")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text("Maximum number of objects that can be placed in AR at once")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    private var findableTypesSection: some View {
        Section("Findable Types") {
            ForEach(Array(groupedFindableTypes.enumerated()), id: \.offset) { index, group in
                if group.types.count > 1 {
                    ForEach(Array(group.types.enumerated()), id: \.offset) { typeIndex, type in
                        HStack(spacing: 12) {
                            Image(systemName: iconName(for: type))
                                .foregroundColor(Color(type.color))
                                .font(.title3)
                                .frame(width: 30)
                            
                            if group.models.isEmpty {
                                Text(type.displayName)
                                    .font(.body)
                            } else {
                                Text("\(type.displayName) (\(group.models.joined(separator: ", ")))")
                                    .font(.body)
                            }
                            
                            Spacer()
                            
                            Text("\(countForType(type))")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    let firstType = group.types.first!
                    HStack(spacing: 12) {
                        Image(systemName: iconName(for: firstType))
                            .foregroundColor(Color(firstType.color))
                            .font(.title3)
                            .frame(width: 30)
                        
                        let typeNames = group.types.map { $0.displayName }.joined(separator: ", ")
                        
                        if group.models.isEmpty {
                            Text(typeNames)
                                .font(.body)
                        } else {
                            Text("\(typeNames) (\(group.models.joined(separator: ", ")))")
                                .font(.body)
                        }
                        
                        Spacer()
                        
                        // Sum up counts for all types in this group
                        let totalCount = group.types.reduce(0) { $0 + countForType($1) }
                        Text("\(totalCount)")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    private var mapDisplaySection: some View {
        Section("Map Display") {
            Toggle("Show Found on Map", isOn: Binding(
                get: { locationManager.showFoundOnMap },
                set: { newValue in
                    locationManager.showFoundOnMap = newValue
                    locationManager.saveShowFoundOnMap()
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, found items appear in deep red and unfound items appear in green on the map")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var conversationSection: some View {
        Section("Conversation") {
            Toggle("Typewriter Effect", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "enableTypewriterEffect") },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: "enableTypewriterEffect")
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, NPC messages will type out character by character with sound effects. When disabled, messages appear instantly.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var arZoomSection: some View {
        Section("AR Zoom") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Zoom Level: \(String(format: "%.1f", locationManager.arZoomLevel))x")
                    .font(.headline)
                
                Slider(
                    value: Binding(
                        get: { locationManager.arZoomLevel },
                        set: { newValue in
                            locationManager.arZoomLevel = newValue
                            locationManager.saveARZoomLevel()
                        }
                    ),
                    in: 0.5...3.0,
                    step: 0.1
                )
                
                HStack {
                    Text("0.5x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("1.0x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("3.0x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text("Adjust the zoom level of the AR camera view. Lower values show more area, higher values zoom in closer.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    var arDebugSection: some View {
        Section("AR Debug") {
            Toggle("Debug AR and Location", isOn: Binding(
                get: { locationManager.showARDebugVisuals },
                set: { newValue in
                    locationManager.showARDebugVisuals = newValue
                    locationManager.saveDebugVisuals()
                }
            ))
            .padding(.vertical, 4)
            
            Text("Enable to see ARKit feature points (green triangles) and anchor origins for debugging. Also plays a submarine ping sound when location is sent to the server.")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Toggle("Disable Occlusion", isOn: Binding(
                get: { locationManager.disableOcclusion },
                set: { newValue in
                    locationManager.disableOcclusion = newValue
                    locationManager.saveDisableOcclusion()
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, objects will be visible even when behind walls. Useful for finding hidden objects.")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Toggle("Disable Ambient Light", isOn: Binding(
                get: { locationManager.disableAmbientLight },
                set: { newValue in
                    locationManager.disableAmbientLight = newValue
                    locationManager.saveDisableAmbientLight()
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, objects will have uniform brightness regardless of real-world lighting conditions.")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Toggle("Enable Object Recognition", isOn: Binding(
                get: { locationManager.enableObjectRecognition },
                set: { newValue in
                    locationManager.enableObjectRecognition = newValue
                    locationManager.saveEnableObjectRecognition()
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, uses Vision framework to classify objects in camera view. Disabled by default to save battery and processing power.")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Toggle("Enable Audio Mode", isOn: Binding(
                get: { locationManager.enableAudioMode },
                set: { newValue in
                    locationManager.enableAudioMode = newValue
                    locationManager.saveEnableAudioMode()
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, plays a ping sound once per second. The pitch increases as you get closer to objects, reaching maximum pitch when you're on top of them.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Toggle("Use Generic Doubloon Icons", isOn: Binding(
                get: { locationManager.useGenericDoubloonIcons },
                set: { newValue in
                    locationManager.useGenericDoubloonIcons = newValue
                    locationManager.saveUseGenericDoubloonIcons()
                }
            ))
            .padding(.vertical, 4)

            Text("When enabled, objects appear as generic doubloon icons in AR and reveal their true form with a special animation when found.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    var userProfileSection: some View {
        Section("User Profile") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Name")
                    .font(.headline)
                
                        TextField("Enter your name", text: $viewModel.userName)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.words)
                            .disableAutocorrection(true)
                            .onSubmit {
                                viewModel.saveUserName()
                            }
                        
                        HStack {
                            Button("Save Name") {
                                viewModel.saveUserName()
                            }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Text("Device ID: \(APIService.shared.currentUserID.prefix(8))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text("Your name will appear on the leaderboard when you find objects. This name is linked to your device ID.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    var leaderboardSection: some View {
        Section("Leaderboard") {
            NavigationLink(destination: LeaderboardView()) {
                HStack {
                    Image(systemName: "trophy.fill")
                        .foregroundColor(.yellow)
                    Text("View Leaderboard")
                    Spacer()
                    if !viewModel.leaderboard.isEmpty {
                        Text("\(viewModel.leaderboard.count) players")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if !viewModel.leaderboard.isEmpty {
                ForEach(Array(viewModel.leaderboard.prefix(3).enumerated()), id: \.offset) { index, finder in
                    HStack {
                        ZStack {
                            Circle()
                                .fill(index < 3 ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.3))
                                .frame(width: 28, height: 28)
                            
                            if index == 0 {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption2)
                            } else {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(index < 3 ? .black : .primary)
                            }
                        }
                        
                        Text(finder.user)
                            .font(.caption)
                        
                        Spacer()
                        
                        Text("\(finder.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    private var apiSyncSection: some View {
        Section("API Sync") {
            apiURLConfigurationView
            apiSyncToggleView
            webSocketStatusView
            if locationManager.useAPISync {
                showOnlyNextItemToggle
                apiSyncButtonsView
                databaseObjectsListView
            }
        }
    }
    
    private var showOnlyNextItemToggle: some View {
        Toggle("Show Only Next Item", isOn: Binding(
            get: { locationManager.showOnlyNextItem },
            set: { newValue in
                locationManager.showOnlyNextItem = newValue
                locationManager.saveShowOnlyNextItem()
            }
        ))
        .padding(.vertical, 4)
    }
    
    private var apiURLConfigurationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Server URL")
                .font(.headline)
            
            TextField(viewModel.getSuggestedURLPlaceholder(), text: $viewModel.apiURL)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .onSubmit {
                    _ = viewModel.saveAPIURL()
                }
            
            HStack {
                Button("Save URL") {
                    _ = viewModel.saveAPIURL()
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    showQRScanner = true
                }) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan QR")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                
                Spacer()
            }
            
            Text("Enter your computer's local IP address (e.g., 192.168.1.100:5001) or scan a QR code. Find it with: ifconfig (Mac) or ipconfig (Windows).")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            // WebSocket connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(webSocketService.isConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                
                VStack(alignment: .leading, spacing: 2) {
                    if locationManager.useAPISync {
                        Text("WebSocket: \(webSocketService.connectionStatus.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if case .error(let errorMessage) = webSocketService.connectionStatus {
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundColor(.red)
                                .lineLimit(3)
                        }
                    } else {
                        Text("API Sync disabled - Enable to connect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Server: \(APIService.shared.baseURL)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 4)
            
            // Offline Mode Toggle
            Divider()
                .padding(.vertical, 4)
            
            Toggle("Offline Mode", isOn: Binding(
                get: { OfflineModeManager.shared.isOfflineMode },
                set: { newValue in
                    OfflineModeManager.shared.isOfflineMode = newValue
                }
            ))
            .padding(.vertical, 4)
            
            HStack(spacing: 8) {
                Circle()
                    .fill(OfflineModeManager.shared.isOfflineMode ? Color.orange : Color.blue)
                    .frame(width: 12, height: 12)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(OfflineModeManager.shared.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if OfflineModeManager.shared.isOfflineMode {
                        Text("Using local SQLite database. WebSocket and API calls disabled.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if OfflineModeManager.shared.pendingSyncCount > 0 {
                            Text("\(OfflineModeManager.shared.pendingSyncCount) item(s) pending sync when you go online")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text("Connected to server. WebSocket and API calls enabled.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            
            // Test Connection Button
            Button(action: {
                isTestingConnection = true
                testResult = nil
                WebSocketService.shared.testConnection { result in
                    DispatchQueue.main.async {
                        isTestingConnection = false
                        testResult = result
                        viewModel.displayAlert(
                            title: result.connected ? "Connection Test Successful" : "Connection Test Failed",
                            message: result.summary
                        )
                    }
                }
            }) {
                HStack {
                    if isTestingConnection {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "network")
                    }
                    Text(isTestingConnection ? "Testing Connection..." : "Test WebSocket Connection")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isTestingConnection || isTestingMultiplePorts)
            .padding(.vertical, 4)
            
            // Test Multiple Ports Button
            Button(action: {
                isTestingMultiplePorts = true
                multiPortTestResult = nil
                
                // Extract host from baseURL
                let baseURL = APIService.shared.baseURL
                let host: String
                if let url = URL(string: baseURL), let hostComponent = url.host {
                    host = hostComponent
                } else {
                    // Fallback: try to extract IP from URL string
                    let components = baseURL.replacingOccurrences(of: "http://", with: "")
                        .replacingOccurrences(of: "https://", with: "")
                        .split(separator: ":")
                    host = String(components.first ?? "localhost")
                }
                
                WebSocketService.shared.testMultiplePorts(baseHost: host) { result in
                    DispatchQueue.main.async {
                        isTestingMultiplePorts = false
                        multiPortTestResult = result
                        
                        if let workingPort = result.workingPort, let workingURL = result.workingURL {
                            // Found a working port - update the URL automatically
                            viewModel.apiURL = workingURL
                            _ = viewModel.saveAPIURL()
                            viewModel.displayAlert(
                                title: "Working Port Found!",
                                message: "Port \(workingPort) is working!\n\nUpdated API URL to: \(workingURL)\n\nReconnecting WebSocket..."
                            )
                        } else {
                            viewModel.displayAlert(
                                title: "No Working Ports Found",
                                message: result.summary
                            )
                        }
                    }
                }
            }) {
                HStack {
                    if isTestingMultiplePorts {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "network.badge.shield.half.filled")
                    }
                    Text(isTestingMultiplePorts ? "Testing Ports..." : "Test Multiple Ports (Auto-Detect)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(isTestingConnection || isTestingMultiplePorts)
            .padding(.vertical, 4)
            
            if let multiResult = multiPortTestResult {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Text("Port Test Results:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Text(multiResult.summary)
                        .font(.caption2)
                        .foregroundColor(multiResult.workingPort != nil ? .green : .orange)
                }
                .padding(.vertical, 4)
            }
            
            if let result = testResult {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Text("Last Test Results:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Text(result.summary)
                        .font(.caption2)
                        .foregroundColor(result.connected ? .green : .red)
                }
                .padding(.vertical, 4)
            }
            
            // Run Full Diagnostics Button
            Button(action: {
                isTestingConnection = true
                WebSocketService.shared.runDiagnostics { report in
                    DispatchQueue.main.async {
                        isTestingConnection = false
                        viewModel.displayAlert(
                            title: "Connection Diagnostics",
                            message: report
                        )
                    }
                }
            }) {
                HStack {
                    if isTestingConnection {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "stethoscope")
                    }
                    Text(isTestingConnection ? "Running Diagnostics..." : "Run Full Diagnostics")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(isTestingConnection || isTestingMultiplePorts)
            .padding(.vertical, 4)
            
            // Network Diagnostics Button (Port & Router Testing)
            Button(action: {
                let serverURL = viewModel.apiURL.isEmpty ? APIService.shared.baseURL : viewModel.apiURL
                guard !serverURL.isEmpty else {
                    viewModel.displayAlert(title: "Error", message: "No server URL configured")
                    return
                }
                
                isRunningNetworkDiagnostics = true
                networkDiagnosticReport = nil
                
                Task {
                    let report = await NetworkDiagnosticsService.shared.runFullDiagnostics(serverURL: serverURL)
                    await MainActor.run {
                        networkDiagnosticReport = report
                        isRunningNetworkDiagnostics = false
                        showNetworkDiagnostics = true
                    }
                }
            }) {
                HStack {
                    if isRunningNetworkDiagnostics {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "network")
                    }
                    Text(isRunningNetworkDiagnostics ? "Testing Network..." : "Test Ports & Router")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(isTestingConnection || isTestingMultiplePorts || isRunningNetworkDiagnostics)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showNetworkDiagnostics) {
            if let report = networkDiagnosticReport {
                NetworkDiagnosticsView(report: report)
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerView(scannedURL: $scannedURL)
        }
        .onChange(of: scannedURL) { _, newValue in
            if let url = newValue {
                viewModel.apiURL = url
                _ = viewModel.saveAPIURL()
                scannedURL = nil // Reset for next scan
            }
        }
    }
    
    private var apiSyncToggleView: some View {
        Group {
            Toggle("Enable API Sync", isOn: Binding(
                get: { locationManager.useAPISync },
                set: { newValue in
                    locationManager.useAPISync = newValue
                    if newValue {
                        // Set up error callback to display connection errors to user
                        WebSocketService.shared.onConnectionError = { errorMessage in
                            Task { @MainActor in
                                viewModel.displayAlert(title: "WebSocket Connection Failed", message: errorMessage)
                            }
                        }
                        
                        if let userLocation = userLocationManager.currentLocation {
                            Task {
                                await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                            }
                        }
                        WebSocketService.shared.connect()
                    } else {
                        WebSocketService.shared.disconnect()
                        WebSocketService.shared.onConnectionError = nil
                    }
                }
            ))
            .padding(.vertical, 4)
            
            Text("When enabled, objects and their found status are synced with the shared API server. This allows multiple devices to see the same objects and track who found what.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var webSocketStatusView: some View {
        Group {
            if locationManager.useAPISync {
                HStack(spacing: 8) {
                    Circle()
                        .fill(webSocketService.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text("WebSocket: \(webSocketService.connectionStatus.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var apiSyncButtonsView: some View {
        Group {
            refreshFromAPIButton
            syncLocalItemsButton
            viewDatabaseContentsButton
            refreshDatabaseListButton
            Divider()
                .padding(.vertical, 4)
            resetAllFindsButton
        }
    }
    
    private var refreshFromAPIButton: some View {
        Button(action: {
            guard !viewModel.isLoading else { return }
            viewModel.isLoading = true
            Task {
                // Pass nil for userLocation to load ALL objects (no distance filter)
                // This matches what the admin panel shows
                await locationManager.loadLocationsFromAPI(userLocation: nil, includeFound: true)
                await MainActor.run {
                    viewModel.displayAlert(title: "Success", message: "Refreshed all locations from API. Check console for details.")
                    viewModel.isLoading = false
                }
            }
        }) {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("Refresh from API")
            }
        }
        .disabled(viewModel.isLoading)
        .padding(.vertical, 4)
    }
    
    private var syncLocalItemsButton: some View {
        Group {
            Button(action: {
                guard !viewModel.isLoading else { return }
                viewModel.isLoading = true
                Task {
                    await locationManager.syncAllLocationsToAPI()
                    await MainActor.run {
                        viewModel.displayAlert(title: "Success", message: "Sync completed. Check console for details.")
                        viewModel.isLoading = false
                    }
                }
            }) {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.up.circle")
                    }
                    Text("Sync Local Items to API")
                }
            }
            .disabled(viewModel.isLoading)
            .padding(.vertical, 4)
            
            Text("Use this to sync items that were created before API sync was enabled")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var viewDatabaseContentsButton: some View {
        Group {
            Button(action: {
                guard !viewModel.isLoading else { return }
                viewModel.isLoading = true
                Task {
                    await locationManager.viewDatabaseContents(userLocation: userLocationManager.currentLocation)
                    await MainActor.run {
                        viewModel.displayAlert(title: "Database Contents", message: "Database contents logged to console. Check Xcode console for full details.")
                        viewModel.isLoading = false
                    }
                }
            }) {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "externaldrive.fill")
                    }
                    Text("View Database Contents")
                }
            }
            .disabled(viewModel.isLoading)
            .padding(.vertical, 4)
            
            Text("View all objects in the shared database (check console for output)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var refreshDatabaseListButton: some View {
        Button(action: {
            viewModel.loadDatabaseObjects()
        }) {
            HStack {
                if viewModel.isLoadingDatabase {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                }
                Text("Refresh Database List")
            }
        }
        .disabled(viewModel.isLoadingDatabase)
        .padding(.vertical, 4)
    }
    
    private var resetAllFindsButton: some View {
        Group {
            Button(action: {
                guard !viewModel.isLoading else { return }
                viewModel.isLoading = true
                Task {
                    do {
                        let response = try await APIService.shared.resetAllFinds()
                        
                        if let userLocation = userLocationManager.currentLocation {
                            await locationManager.loadLocationsFromAPI(userLocation: userLocation, includeFound: true)
                        }
                        
                        await MainActor.run {
                            viewModel.displayAlert(title: "Reset Complete", message: "All objects have been reset to unfound status.\n\n\(response.finds_removed) find record(s) removed.")
                            viewModel.isLoading = false
                            viewModel.loadDatabaseObjects()
                        }
                    } catch {
                        await MainActor.run {
                            viewModel.displayAlert(title: "Error", message: "Failed to reset finds: \(error.localizedDescription)")
                            viewModel.isLoading = false
                        }
                    }
                }
            }) {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    Text("Reset All Finds")
                }
                .foregroundColor(.red)
            }
            .disabled(viewModel.isLoading)
            .padding(.vertical, 4)
            
            Text("Reset all objects to unfound status. This affects all users and cannot be undone.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var databaseObjectsListView: some View {
        Group {
            if viewModel.isLoadingDatabase {
                HStack {
                    ProgressView()
                    Text("Loading database...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if viewModel.databaseObjects.isEmpty {
                Text("No objects in database. Tap 'Refresh Database List' to load.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                databaseObjectsListContent
            }
        }
    }
    
    private var databaseObjectsListContent: some View {
        let displayedObjects: [APIObject] = {
            if locationManager.showOnlyNextItem {
                // Show only the first unfound item
                return viewModel.databaseObjects.filter { !$0.collected }.prefix(1).map { $0 }
            } else {
                // Show all objects
                return viewModel.databaseObjects
            }
        }()
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Database Objects (\(displayedObjects.count)\(locationManager.showOnlyNextItem ? " of \(viewModel.databaseObjects.count)" : ""))")
                    .font(.headline)
                Spacer()
                if viewModel.selectedObjectId != nil {
                    Text("1 Selected")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            .padding(.top, 4)
            
            if locationManager.showOnlyNextItem && !displayedObjects.isEmpty {
                Text("Showing only the next unfound item. Disable 'Show Only Next Item' to see all items.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)
            } else if viewModel.selectedObjectId != nil {
                Text("Tap an item to deselect. Only the selected object will appear in AR and be used for audio search.")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .padding(.bottom, 4)
            } else {
                Text("Tap an item to select it. Only the selected object will appear in AR and be used for audio search.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)
            }
            
            if displayedObjects.isEmpty {
                Text("No items to display.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(displayedObjects, id: \.id) { obj in
                    databaseObjectRow(obj: obj)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func databaseObjectRow(obj: APIObject) -> some View {
        let isSelected = viewModel.selectedObjectId == obj.id
        return Button(action: {
            if isSelected {
                viewModel.setSelectedObjectId(nil)
            } else {
                viewModel.setSelectedObjectId(obj.id)
            }
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .font(.title3)
                
                Button(action: {
                    viewModel.toggleCollectedStatus(for: obj)
                }) {
                    Image(systemName: obj.collected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(obj.collected ? .orange : .green)
                        .font(.caption)
                }
                .buttonStyle(PlainButtonStyle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(obj.name)
                        .font(.body)
                        .fontWeight(isSelected ? .bold : .medium)
                        .foregroundColor(isSelected ? .primary : .secondary)
                    
                    HStack(spacing: 4) {
                        Text(obj.type)
                            .font(.caption)
                            .foregroundColor(isSelected ? .secondary : .secondary.opacity(0.6))
                        
                        Text("•")
                            .foregroundColor(isSelected ? .secondary : .secondary.opacity(0.6))
                        
                        Text(obj.collected ? "Found" : "Not Found")
                            .font(.caption)
                            .foregroundColor(obj.collected ? .orange : .green)
                    }
                    
                    if let foundBy = obj.found_by {
                        Text("Found by: \(viewModel.playerNameCache[foundBy] ?? foundBy)")
                            .font(.caption2)
                            .foregroundColor(isSelected ? .secondary : .secondary.opacity(0.6))
                            .onAppear {
                                viewModel.fetchPlayerNameIfNeeded(deviceUUID: foundBy)
                            }
                    }
                    
                    Text("Location: \(String(format: "%.6f", obj.latitude)), \(String(format: "%.6f", obj.longitude))")
                        .font(.caption2)
                        .foregroundColor(isSelected ? .secondary : .secondary.opacity(0.6))
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var arLensSection: some View {
        Section("AR Camera Lens & FOV") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select the camera lens and video format for AR view")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                ARLensSelector(locationManager: locationManager)
                    .padding(.vertical, 4)
                
                Text("Field of View (FOV) options:\n• Ultra Wide: Widest view (shows most area)\n• Wide: Standard view\n• Telephoto: Narrow view (zoomed in)\n\nYou can choose different resolutions and frame rates for each lens type. Higher resolution = better quality, 60fps = smoother motion.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
            .padding(.vertical, 4)
        }
    }
    
    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cache Raiders")
                    .font(.headline)
                Text("An AR treasure hunting game")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
}

