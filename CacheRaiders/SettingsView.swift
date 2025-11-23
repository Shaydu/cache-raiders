import SwiftUI
import CoreLocation
import SystemConfiguration

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
    
    // Helper function to get icon name for each findable type
    private func iconName(for type: LootBoxType) -> String {
        switch type {
        case .chalice:
            return "cup.and.saucer.fill"
        case .templeRelic:
            return "building.columns.fill"
        case .treasureChest:
            return "shippingbox.fill"
        case .sphere:
            return "circle.fill"
        case .cube:
            return "cube.fill"
        }
    }
    
    // Helper function to get model names for each findable type
    private func modelNames(for type: LootBoxType) -> [String] {
        switch type {
        case .chalice:
            return ["Chalice", "Chalice-basic"]
        case .templeRelic:
            return ["Stylised_Treasure_Chest", "Treasure_Chest"]
        case .treasureChest:
            return ["Treasure_Chest"]
        case .sphere, .cube:
            return [] // Spheres and cubes are procedural, no models
        }
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
                
                Section("Loot Box Size") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Min Size Slider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Minimum Size: \(String(format: "%.2f", locationManager.lootBoxMinSize))m")
                                .font(.headline)
                            
                            Slider(
                                value: Binding(
                                    get: { locationManager.lootBoxMinSize },
                                    set: { newValue in
                                        // Ensure min doesn't exceed max
                                        let clampedValue = min(newValue, locationManager.lootBoxMaxSize)
                                        locationManager.lootBoxMinSize = clampedValue
                                        locationManager.saveLootBoxSizes()
                                        // This will trigger onSizeChanged callback in ARCoordinator
                                    }
                                ),
                                in: 0.25...1.5,
                                step: 0.05
                            )
                            
                            HStack {
                                Text("0.25m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("1.5m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Max Size Slider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Maximum Size: \(String(format: "%.2f", locationManager.lootBoxMaxSize))m")
                                .font(.headline)
                            
                            Slider(
                                value: Binding(
                                    get: { locationManager.lootBoxMaxSize },
                                    set: { newValue in
                                        // Ensure max doesn't go below min
                                        let clampedValue = max(newValue, locationManager.lootBoxMinSize)
                                        locationManager.lootBoxMaxSize = clampedValue
                                        locationManager.saveLootBoxSizes()
                                        // This will trigger onSizeChanged callback in ARCoordinator
                                    }
                                ),
                                in: 0.25...1.5,
                                step: 0.05
                            )
                            
                            HStack {
                                Text("0.25m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("1.5m")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Text("Loot boxes will randomly vary in size between min and max")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Findable Types") {
                    ForEach(Array(groupedFindableTypes.enumerated()), id: \.offset) { index, group in
                        HStack(spacing: 12) {
                            // Use icon from first type in group
                            let firstType = group.types.first!
                            Image(systemName: iconName(for: firstType))
                                .foregroundColor(Color(firstType.color))
                                .font(.title3)
                                .frame(width: 30)
                            
                            // Show all type names that share these models
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
                                    do {
                                        await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                                        await MainActor.run {
                                            alertTitle = "Success"
                                            alertMessage = "Refreshed locations from API. Check console for details."
                                            showAlert = true
                                            isLoading = false
                                        }
                                    } catch {
                                        await MainActor.run {
                                            alertTitle = "Error"
                                            alertMessage = "Failed to refresh from API: \(error.localizedDescription)"
                                            showAlert = true
                                            isLoading = false
                                        }
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
                                do {
                                    await locationManager.syncAllLocationsToAPI()
                                    await MainActor.run {
                                        alertTitle = "Success"
                                        alertMessage = "Sync completed. Check console for details."
                                        showAlert = true
                                        isLoading = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        alertTitle = "Error"
                                        alertMessage = "Failed to sync to API: \(error.localizedDescription)"
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
                                do {
                                    await locationManager.viewDatabaseContents(userLocation: userLocationManager.currentLocation)
                                    await MainActor.run {
                                        alertTitle = "Database Contents"
                                        alertMessage = "Database contents logged to console. Check Xcode console for full details."
                                        showAlert = true
                                        isLoading = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        alertTitle = "Error"
                                        alertMessage = "Failed to view database contents: \(error.localizedDescription)"
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
                                    let findsRemoved = response["finds_removed"] as? Int ?? 0
                                    
                                    // Reload locations from API to update local state
                                    if let userLocation = userLocationManager.currentLocation {
                                        await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                                    }
                                    
                                    await MainActor.run {
                                        alertTitle = "Reset Complete"
                                        alertMessage = "All objects have been reset to unfound status.\n\n\(findsRemoved) find record(s) removed."
                                        showAlert = true
                                        isLoading = false
                                        // Refresh database list
                                        loadDatabaseObjects()
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
                                Text("Database Objects (\(databaseObjects.count))")
                                    .font(.headline)
                                    .padding(.top, 4)
                                
                                ForEach(databaseObjects, id: \.id) { obj in
                                    HStack(alignment: .top, spacing: 8) {
                                        // Status indicator
                                        Image(systemName: obj.collected ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(obj.collected ? .green : .orange)
                                            .font(.caption)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(obj.name)
                                                .font(.body)
                                                .fontWeight(.medium)
                                            
                                            HStack(spacing: 4) {
                                                Text(obj.type)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                
                                                Text("•")
                                                    .foregroundColor(.secondary)
                                                
                                                Text(obj.collected ? "Found" : "Not Found")
                                                    .font(.caption)
                                                    .foregroundColor(obj.collected ? .green : .orange)
                                            }
                                            
                                            if let foundBy = obj.found_by {
                                                Text("Found by: \(foundBy)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Text("Location: \(String(format: "%.6f", obj.latitude)), \(String(format: "%.6f", obj.longitude))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
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
                // Load database objects when view appears if API sync is enabled
                if locationManager.useAPISync {
                    loadDatabaseObjects()
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
        // Otherwise, try to suggest based on device IP (Docker uses port 5000)
        if let suggested = getSuggestedLocalIP() {
            return "http://\(suggested):5000"
        }
        return "http://192.168.1.1:5000"
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
    
    private func loadAPIURL() {
        // Load saved URL, or use suggested IP if none exists
        if let savedURL = UserDefaults.standard.string(forKey: "apiBaseURL"), !savedURL.isEmpty {
            apiURL = savedURL
        } else {
            // Auto-populate with suggested local network IP (Docker uses port 5000)
            if let suggested = getSuggestedLocalIP() {
                let suggestedURL = "http://\(suggested):5000"
                apiURL = suggestedURL
                // Auto-save it so it's used immediately as default
                UserDefaults.standard.set(suggestedURL, forKey: "apiBaseURL")
                print("✅ Auto-configured API URL to: \(suggestedURL)")
            } else {
                // Fallback to a common default for 10.0.x.x networks
                let fallbackURL = "http://10.0.0.1:5000"
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

