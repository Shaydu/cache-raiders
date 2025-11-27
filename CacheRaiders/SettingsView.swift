import SwiftUI
import CoreLocation
import Combine

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var locationManager: LootBoxLocationManager
    @ObservedObject var userLocationManager: UserLocationManager
    @ObservedObject private var webSocketService = WebSocketService.shared
    @StateObject private var viewModel: SettingsViewModel
    @Environment(\.dismiss) var dismiss
    @State private var previousDistance: Double = 10.0
    @State private var showQRScanner = false
    @State private var scannedURL: String?
    
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
    
    // Count visible items by type
    private func countForType(_ type: LootBoxType) -> Int {
        return locationManager.locations.filter { $0.type == type }.count
    }
    
    var body: some View {
        NavigationView {
            List {
                searchDistanceSection
                maxObjectLimitSection
                findableTypesSection
                mapDisplaySection
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
                viewModel.loadAPIURL()
                viewModel.loadUserName()
                viewModel.selectedObjectId = locationManager.selectedDatabaseObjectId
                if locationManager.useAPISync {
                    viewModel.loadDatabaseObjects()
                    viewModel.loadLeaderboard()
                    WebSocketService.shared.connect()
                }
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
                
                Spacer()
                
                Button(action: {
                    showQRScanner = true
                }) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan QR Code")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                
                Spacer()
                
                Button("Use Default") {
                    viewModel.resetAPIURL()
                }
                .buttonStyle(.bordered)
            }
            
            Text("Enter your computer's local IP address (e.g., 192.168.1.100:5001). Find it with: ifconfig (Mac) or ipconfig (Windows). Or scan the QR code from the server admin page.")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text("Current: \(APIService.shared.baseURL)")
                .font(.caption)
                .foregroundColor(.blue)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerView(scannedURL: $scannedURL)
        }
        .onChange(of: scannedURL) { oldURL, newURL in
            guard let url = newURL, url != oldURL else { return }
            
            // Defer state modification to next run loop to avoid "Modifying state during view update" warning
            DispatchQueue.main.async {
                // Update the form field immediately so user sees the URL
                self.viewModel.apiURL = url
                
                // Save the URL and reconnect WebSocket
                let saved = self.viewModel.saveAPIURL()
                
                if saved {
                    // Reset scannedURL after processing to allow scanning again
                    self.scannedURL = nil
                } else {
                    // If save failed, still reset to allow retry
                    self.scannedURL = nil
                }
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
                        if let userLocation = userLocationManager.currentLocation {
                            Task {
                                await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                            }
                        }
                        WebSocketService.shared.connect()
                    } else {
                        WebSocketService.shared.disconnect()
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
            if let userLocation = userLocationManager.currentLocation {
                Task {
                    await locationManager.loadLocationsFromAPI(userLocation: userLocation)
                    await MainActor.run {
                        viewModel.displayAlert(title: "Success", message: "Refreshed locations from API. Check console for details.")
                        viewModel.isLoading = false
                    }
                }
            } else {
                viewModel.displayAlert(title: "Error", message: "No user location available. Please enable location services.")
                viewModel.isLoading = false
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

