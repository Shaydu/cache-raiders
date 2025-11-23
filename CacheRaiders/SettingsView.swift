import SwiftUI
import CoreLocation
import SystemConfiguration
import Combine

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @ObservedObject private var webSocketService = WebSocketService.shared
    @Environment(\.dismiss) var dismiss
    @State private var previousDistance: Double = 10.0
    @State private var isLoading: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var alertTitle: String = ""
    @State private var databaseObjects: [APIObject] = []
    @State private var isLoadingDatabase: Bool = false
    @State private var apiURL: String = ""
    @State private var selectedObjectId: String? = nil
    @State private var userName: String = ""
    @State private var leaderboard: [TopFinder] = []
    @State private var isLoadingLeaderboard: Bool = false
    @State private var playerNameCache: [String: String] = [:] // Cache for player names by device UUID
    
    // Helper function to get icon name for each findable type
    // Uses the factory pattern to ensure consistency with the rest of the app
    private func iconName(for type: LootBoxType) -> String {
        return type.factory.iconName
    }
    
    // Helper function to get model names for each findable type (uses factory)
    private func modelNames(for type: LootBoxType) -> [String] {
        return type.factory.modelNames
    }
    
    // Group types by their model names to deduplicate
    private var groupedFindableTypes: [(models: [String], types: [LootBoxType])] {
        var groups: [[String]: [LootBoxType]] = [:]
        
        for type in LootBoxType.allCases {
            let models = modelNames(for: type)
            let key = models.sorted()
            if groups[key] == nil {
                groups[key] = []
            }
            groups[key]?.append(type)
        }
        
        return groups.map { (models: $0.key, types: $0.value) }
            .sorted { $0.types.first?.displayName ?? "" < $1.types.first?.displayName ?? "" }
    }
    
    var body: some View {
        NavigationView {
            List {
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
                                    
                                    // Regenerate locations when distance changes
                                    if previousDistance != newValue, let userLocation = userLocationManager.currentLocation {
                                        print("🔄 Search distance changed from \(previousDistance)m to \(newValue)m, regenerating loot boxes")
                                        locationManager.regenerateLocations(near: userLocation)
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
                
                Section("Findable Types") {
                    ForEach(Array(groupedFindableTypes.enumerated()), id: \.offset) { index, group in
                        // If group has multiple types, show each separately so they can have their own icons
                        if group.types.count > 1 {
                            ForEach(Array(group.types.enumerated()), id: \.offset) { typeIndex, type in
                                HStack(spacing: 12) {
                                    // Each type gets its own icon from its factory
                                    Image(systemName: iconName(for: type))
                                        .foregroundColor(Color(type.color))
                                        .font(.title3)
                                        .frame(width: 30)
                                    
                                    // Show type name and models if any
                                    if group.models.isEmpty {
                                        Text(type.displayName)
                                            .font(.body)
                                    } else {
                                        Text("\(type.displayName) (\(group.models.joined(separator: ", ")))")
                                            .font(.body)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } else {
                            // Single type in group - show as before
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
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                
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
                
                Section("AR Debug") {
                    Toggle("Show AR Debug Visuals", isOn: Binding(
                        get: { locationManager.showARDebugVisuals },
                        set: { newValue in
                            locationManager.showARDebugVisuals = newValue
                            locationManager.saveDebugVisuals()
                        }
                    ))
                    .padding(.vertical, 4)
                    
                    Text("Enable to see ARKit feature points (green triangles) and anchor origins for debugging")
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
                }
                
                Section("User Profile") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Name")
                            .font(.headline)
                        
                        TextField("Enter your name", text: $userName)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.words)
                            .disableAutocorrection(true)
                            .onSubmit {
                                saveUserName()
                            }
                        
                        HStack {
                            Button("Save Name") {
                                saveUserName()
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
                
                Section("Leaderboard") {
                    NavigationLink(destination: LeaderboardView()) {
                        HStack {
                            Image(systemName: "trophy.fill")
                                .foregroundColor(.yellow)
                            Text("View Leaderboard")
                            Spacer()
                            if !leaderboard.isEmpty {
                                Text("\(leaderboard.count) players")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Quick preview of top 3
                    if !leaderboard.isEmpty {
                        ForEach(Array(leaderboard.prefix(3).enumerated()), id: \.offset) { index, finder in
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
                
                Section("API Sync") {
                    // API URL Configuration
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Server URL")
                            .font(.headline)
                        
                        TextField(getSuggestedURLPlaceholder(), text: $apiURL)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .onSubmit {
                                saveAPIURL()
                            }
                        
                        HStack {
                            Button("Save URL") {
                                saveAPIURL()
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Button("Use Default") {
                                resetAPIURL()
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Text("Enter your computer's local IP address (e.g., 192.168.1.100:5001). Find it with: ifconfig (Mac) or ipconfig (Windows)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("Current: \(APIService.shared.baseURL)")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .padding(.vertical, 4)
                    
                    Toggle("Enable API Sync", isOn: Binding(
                        get: { locationManager.useAPISync },
                        set: { newValue in
                            locationManager.useAPISync = newValue
                            // If enabling, try to load from API and connect WebSocket
                            if newValue {
                                if let userLocation = userLocationManager.currentLocation {
                                    Task {
                                        await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                                    }
                                }
                                // Connect WebSocket
                                WebSocketService.shared.connect()
                            } else {
                                // Disconnect WebSocket when API sync is disabled
                                WebSocketService.shared.disconnect()
                            }
                        }
                    ))
                    .padding(.vertical, 4)
                    
                    Text("When enabled, objects and their found status are synced with the shared API server. This allows multiple devices to see the same objects and track who found what.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    // WebSocket Connection Status
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
                    
                    if locationManager.useAPISync {
                        Button(action: {
                            guard !isLoading else { return }
                            isLoading = true
                            if let userLocation = userLocationManager.currentLocation {
                                Task {
                                    await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                                    await MainActor.run {
                                        alertTitle = "Success"
                                        alertMessage = "Refreshed locations from API. Check console for details."
                                        showAlert = true
                                        isLoading = false
                                    }
                                }
                            } else {
                                alertTitle = "Error"
                                alertMessage = "No user location available. Please enable location services."
                                showAlert = true
                                isLoading = false
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Refresh from API")
                            }
                        }
                        .disabled(isLoading)
                        .padding(.vertical, 4)
                        
                        Button(action: {
                            guard !isLoading else { return }
                            isLoading = true
                            Task {
                                await locationManager.syncAllLocationsToAPI()
                                await MainActor.run {
                                    alertTitle = "Success"
                                    alertMessage = "Sync completed. Check console for details."
                                    showAlert = true
                                    isLoading = false
                                }
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text("Sync Local Items to API")
                            }
                        }
                        .disabled(isLoading)
                        .padding(.vertical, 4)
                        
                        Text("Use this to sync items that were created before API sync was enabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            guard !isLoading else { return }
                            isLoading = true
                            Task {
                                await locationManager.viewDatabaseContents(userLocation: userLocationManager.currentLocation)
                                await MainActor.run {
                                    alertTitle = "Database Contents"
                                    alertMessage = "Database contents logged to console. Check Xcode console for full details."
                                    showAlert = true
                                    isLoading = false
                                }
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "externaldrive.fill")
                                }
                                Text("View Database Contents")
                            }
                        }
                        .disabled(isLoading)
                        .padding(.vertical, 4)
                        
                        Text("View all objects in the shared database (check console for output)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            loadDatabaseObjects()
                        }) {
                            HStack {
                                if isLoadingDatabase {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise.circle")
                                }
                                Text("Refresh Database List")
                            }
                        }
                        .disabled(isLoadingDatabase)
                        .padding(.vertical, 4)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        Button(action: {
                            guard !isLoading else { return }
                            isLoading = true
                            Task {
                                do {
                                    let response = try await APIService.shared.resetAllFinds()
                                    
                                    // Reload locations from API to update local state
                                    // Use includeFound: true to ensure we get all objects after reset
                                    if let userLocation = userLocationManager.currentLocation {
                                        await locationManager.loadLocationsFromAPI(userLocation: userLocation, includeFound: true)
                                    }
                                    
                                    await MainActor.run {
                                        alertTitle = "Reset Complete"
                                        alertMessage = "All objects have been reset to unfound status.\n\n\(response.finds_removed) find record(s) removed."
                                        showAlert = true
                                        isLoading = false
                                        // Refresh database list
                                        loadDatabaseObjects()
                                        // Note: Map view will update automatically via @Published properties
                                    }
                                } catch {
                                    await MainActor.run {
                                        alertTitle = "Error"
                                        alertMessage = "Failed to reset finds: \(error.localizedDescription)"
                                        showAlert = true
                                        isLoading = false
                                    }
                                }
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                Text("Reset All Finds")
                            }
                            .foregroundColor(.red)
                        }
                        .disabled(isLoading)
                        .padding(.vertical, 4)
                        
                        Text("Reset all objects to unfound status. This affects all users and cannot be undone.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        // Display database objects list
                        if isLoadingDatabase {
                            HStack {
                                ProgressView()
                                Text("Loading database...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else if databaseObjects.isEmpty {
                            Text("No objects in database. Tap 'Refresh Database List' to load.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Database Objects (\(databaseObjects.count))")
                                        .font(.headline)
                                    Spacer()
                                    if selectedObjectId != nil {
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
                                
                                if selectedObjectId != nil {
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
                                
                                ForEach(databaseObjects, id: \.id) { obj in
                                    let isSelected = selectedObjectId == obj.id
                                    Button(action: {
                                        // Toggle selection: if already selected, deselect; otherwise select this one
                                        if isSelected {
                                            selectedObjectId = nil
                                            locationManager.setSelectedDatabaseObjectId(nil)
                                        } else {
                                            selectedObjectId = obj.id
                                            locationManager.setSelectedDatabaseObjectId(obj.id)
                                        }
                                    }) {
                                        HStack(alignment: .top, spacing: 8) {
                                            // Selection indicator
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(isSelected ? .blue : .secondary)
                                                .font(.title3)
                                            
                                            // Status indicator
                                            Image(systemName: obj.collected ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(obj.collected ? .orange : .green)
                                                .font(.caption)
                                            
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(obj.name)
                                                    .font(.body)
                                                    .fontWeight(isSelected ? .bold : .medium)
                                                    .foregroundColor(isSelected ? .primary : (isSelected ? nil : .secondary))
                                                
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
                                                    Text("Found by: \(playerNameCache[foundBy] ?? foundBy)")
                                                        .font(.caption2)
                                                        .foregroundColor(isSelected ? .secondary : .secondary.opacity(0.6))
                                                        .onAppear {
                                                            // Fetch player name if not in cache
                                                            if playerNameCache[foundBy] == nil {
                                                                Task {
                                                                    do {
                                                                        if let playerName = try await APIService.shared.getPlayerName(deviceUUID: foundBy) {
                                                                            await MainActor.run {
                                                                                playerNameCache[foundBy] = playerName
                                                                            }
                                                                        }
                                                                    } catch {
                                                                        print("⚠️ Failed to fetch player name for \(foundBy): \(error.localizedDescription)")
                                                                    }
                                                                }
                                                            }
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
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
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
                // Load current API URL
                loadAPIURL()
                // Load user name
                loadUserName()
                // Load selected object ID
                selectedObjectId = locationManager.selectedDatabaseObjectId
                // Load database objects when view appears if API sync is enabled
                if locationManager.useAPISync {
                    loadDatabaseObjects()
                    loadLeaderboard()
                    // Ensure WebSocket is connected
                    WebSocketService.shared.connect()
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func getSuggestedURLPlaceholder() -> String {
        let currentURL = APIService.shared.baseURL
        // If it's not localhost, use that as placeholder
        if !currentURL.contains("localhost") {
            return currentURL
        }
        // Otherwise, try to suggest based on device IP (default port is 5001)
        if let suggested = getSuggestedLocalIP() {
            return "http://\(suggested):5001"
        }
        return "http://192.168.1.1:5001"
    }
    
    private func getSuggestedLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if name == "en0" {
                        break
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        
        if let deviceIP = address {
            let components = deviceIP.split(separator: ".")
            if components.count == 4 {
                // Try common server IPs: .1 (router), .100, or same as device
                // First try .1 (often the router/server)
                return "\(components[0]).\(components[1]).\(components[2]).1"
            }
        }
        
        return nil
    }
    
    private func loadUserName() {
        // First load from local storage
        userName = APIService.shared.currentUserName
        // If userName is the UUID (meaning no name set), clear the field
        if userName == APIService.shared.currentUserID {
            userName = ""
        }
        
        // Then try to load from server if API sync is enabled
        if locationManager.useAPISync {
            Task {
                do {
                    if let serverName = try await APIService.shared.getPlayerNameFromServer() {
                        await MainActor.run {
                            // Update local storage and UI if server has a name
                            if !serverName.isEmpty {
                                userName = serverName
                                APIService.shared.setUserName(serverName)
                            }
                        }
                    }
                } catch {
                    // Silently fail - local storage is primary
                    print("⚠️ Failed to load player name from server: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func saveUserName() {
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        APIService.shared.setUserName(trimmedName)
        
        alertTitle = "Name Saved"
        if trimmedName.isEmpty {
            alertMessage = "Name cleared. Device ID will be used instead."
        } else {
            alertMessage = "Your name '\(trimmedName)' has been saved. It will appear on the leaderboard when you find objects."
        }
        showAlert = true
    }
    
    private func loadLeaderboard() {
        guard locationManager.useAPISync else { return }
        
        isLoadingLeaderboard = true
        Task {
            do {
                let stats = try await APIService.shared.getStats()
                await MainActor.run {
                    self.leaderboard = stats.top_finders
                    self.isLoadingLeaderboard = false
                }
            } catch {
                await MainActor.run {
                    self.leaderboard = []
                    self.isLoadingLeaderboard = false
                }
            }
        }
    }
    
    private func loadAPIURL() {
        // Load saved URL, or use suggested IP if none exists
        if let savedURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !savedURL.isEmpty {
            apiURL = savedURL
        } else {
            // Auto-populate with suggested local network IP (default port is 5001)
            if let suggested = getSuggestedLocalIP() {
                let suggestedURL = "http://\(suggested):5001"
                apiURL = suggestedURL
                // Auto-save it so it's used immediately as default
                UserDefaults.standard.set(suggestedURL, forKey: "apiBaseURL")
                print("✅ Auto-configured API URL to: \(suggestedURL)")
            } else {
                // Fallback to a common default for 10.0.x.x networks
                let fallbackURL = "http://10.0.0.1:5001"
                apiURL = fallbackURL
                UserDefaults.standard.set(fallbackURL, forKey: "apiBaseURL")
                print("⚠️ Using fallback API URL: \(fallbackURL)")
            }
        }
    }
    
    private func saveAPIURL() {
        let trimmedURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Don't save if field is empty
        guard !trimmedURL.isEmpty else {
            alertTitle = "No URL Entered"
            alertMessage = "Please enter a URL before saving (e.g., 192.168.1.100:5001 or http://192.168.1.100:5001)"
            showAlert = true
            return
        }
        
        // Validate and save the URL
        var urlString = trimmedURL
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "http://\(urlString)"
        }
        
        // Basic validation - check if it's a valid URL
        guard URL(string: urlString) != nil else {
            alertTitle = "Invalid URL"
            alertMessage = "Please enter a valid URL (e.g., 192.168.1.100:5001 or http://192.168.1.100:5001)"
            showAlert = true
            return
        }
        
        // Save the URL
        UserDefaults.standard.set(urlString, forKey: "apiBaseURL")
        alertTitle = "URL Saved"
        alertMessage = "API URL updated to: \(urlString)\n\nReconnecting to new server..."
        showAlert = true
        
        // Reconnect WebSocket and reload database if API sync is enabled
        if locationManager.useAPISync {
            WebSocketService.shared.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WebSocketService.shared.connect()
                // Reload database objects with new URL
                self.loadDatabaseObjects()
            }
        }
    }
    
    private func resetAPIURL() {
        apiURL = ""
        UserDefaults.standard.removeObject(forKey: "apiBaseURL")
        alertTitle = "URL Reset"
        alertMessage = "Using default API URL: \(APIService.shared.baseURL)"
        showAlert = true
        
        // Reconnect WebSocket if API sync is enabled
        if locationManager.useAPISync {
            WebSocketService.shared.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WebSocketService.shared.connect()
            }
        }
    }
    
    private func loadDatabaseObjects() {
        guard locationManager.useAPISync else { return }
        
        isLoadingDatabase = true
        Task {
            do {
                // Check API health first
                let isHealthy = try await APIService.shared.checkHealth()
                guard isHealthy else {
                    await MainActor.run {
                        databaseObjects = []
                        isLoadingDatabase = false
                        alertTitle = "API Unavailable"
                        let currentURL = APIService.shared.baseURL
                        if currentURL.contains("localhost") {
                            alertMessage = "Cannot connect to \(currentURL).\n\nTo connect to your local network server:\n1. Find your computer's IP (ifconfig on Mac, ipconfig on Windows)\n2. Enter it in the 'API Server URL' field above (e.g., http://192.168.1.100:5001)\n3. Tap 'Save URL'\n4. Make sure your server is running and accessible on your network"
                        } else {
                            alertMessage = "Cannot connect to API server at \(currentURL).\n\nMake sure:\n• The server is running\n• The URL is correct\n• Your device is on the same network\n• Firewall allows connections on port 5001"
                        }
                        showAlert = true
                    }
                    return
                }
                
                // Get all objects from API
                let apiObjects: [APIObject]
                if let userLocation = userLocationManager.currentLocation {
                    apiObjects = try await APIService.shared.getObjects(
                        latitude: userLocation.coordinate.latitude,
                        longitude: userLocation.coordinate.longitude,
                        radius: 10000.0, // 10km radius to see all nearby objects
                        includeFound: true // Include found objects too
                    )
                } else {
                    apiObjects = try await APIService.shared.getObjects(includeFound: true)
                }
                
                await MainActor.run {
                    databaseObjects = apiObjects.sorted { obj1, obj2 in
                        // Sort: unfound first, then by name
                        if obj1.collected != obj2.collected {
                            return !obj1.collected // Unfound items first
                        }
                        return obj1.name < obj2.name
                    }
                    isLoadingDatabase = false
                }
            } catch {
                await MainActor.run {
                    databaseObjects = []
                    isLoadingDatabase = false
                    alertTitle = "Error"
                    alertMessage = "Failed to load database objects: \(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }
}

