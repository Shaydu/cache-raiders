# AR Coordinate Sharing Service

## Overview

The `ARCoordinateSharingService` extracts all AR coordinate sharing logic from the bloated `ARCoordinator` class. This service handles:

- **ARWorldMap** capture, storage, and synchronization between devices
- **Collaborative AR sessions** for real-time multi-device coordination
- **AR origin sharing** for coordinate consistency between views
- **Coordinate reconciliation** across multiple devices
- **WebSocket integration** for real-time updates

## Architecture

### Before (ARCoordinator bloat)
```swift
class ARCoordinator { // 5176 lines!
    // Mixed responsibilities:
    // - AR session management
    // - Object placement
    // - Coordinate sharing (scattered throughout)
    // - UI management
    // - Audio feedback
    // - And more...
}
```

### After (Clean separation)
```swift
class ARCoordinator { // ~300-400 lines
    private let coordinateSharingService = ARCoordinateSharingService()
    // Focus on core AR coordination only
}

class ARCoordinateSharingService {
    // Dedicated to coordinate sharing across devices
}
```

## Features

### 1. ARWorldMap Sharing
- Capture current AR environment mapping
- Serialize and share with other devices
- Load shared world maps for consistent experiences

### 2. Collaborative Sessions
- Real-time AR session synchronization
- Peer discovery and management
- Automatic coordinate alignment

### 3. AR Origin Sharing
- Share AR coordinate system origins between devices
- Synchronize coordinate frames
- Maintain consistency across app sessions

### 4. Coordinate Updates
- Real-time coordinate synchronization via WebSocket
- GPS + AR offset coordinate management
- Automatic conflict resolution

## Integration

### 1. Add Service Property
```swift
class ARCoordinator: NSObject, ObservableObject {
    // ... existing properties ...

    private let coordinateSharingService = ARCoordinateSharingService()

    // ... rest of class ...
}
```

### 2. Initialize Service
```swift
func setupARCoordinator() {
    // ... existing setup ...

    coordinateSharingService.configure(
        with: arView,
        webSocketService: WebSocketService.shared,
        apiService: APIService.shared,
        locationManager: locationManager
    )

    // Set up session delegate for collaboration
    arView.session.delegate = coordinateSharingService

    // ... rest of setup ...
}
```

### 3. Replace Legacy Code

#### Old AR Origin Sharing:
```swift
// OLD (scattered throughout ARCoordinator)
locationManager?.sharedAROrigin = userLocation
```

#### New AR Origin Sharing:
```swift
// NEW (centralized in service)
coordinateSharingService.shareAROrigin(userLocation)
```

#### Old Coordinate Updates:
```swift
// OLD (inline API calls)
try await APIService.shared.updateObjectLocation(
    objectId: location.id,
    latitude: correctedCoordinate.latitude,
    longitude: correctedCoordinate.longitude
)
```

#### New Coordinate Updates:
```swift
// NEW (via service with AR coordinates)
coordinateSharingService.updateObjectCoordinates(
    objectId: location.id,
    gpsCoordinates: correctedCoordinate,
    arOffset: SIMD3<Double>(x, y, z),
    arOrigin: arOrigin
)
```

## Usage Examples

### World Map Sharing
```swift
// Capture and share current AR environment
coordinateSharingService.shareWorldMap()

// Load shared world map from another device
if let worldMapData = receivedWorldMapData {
    coordinateSharingService.loadWorldMap(worldMapData)
}
```

### Collaborative Sessions
```swift
// Start multi-device AR session
coordinateSharingService.startCollaborativeSession()

// Monitor connected peers
coordinateSharingService.$connectedPeers
    .sink { peers in
        print("Connected peers: \(peers.count)")
    }
```

### AR Origin Synchronization
```swift
// Share AR origin with other devices
coordinateSharingService.shareAROrigin(arOriginLocation)

// Get shared origin from another device
if let sharedOrigin = coordinateSharingService.getSharedAROrigin(for: deviceUUID) {
    // Use shared origin for coordinate conversion
}
```

### Coordinate Updates
```swift
// Update object coordinates across all devices
coordinateSharingService.updateObjectCoordinates(
    objectId: "treasure_123",
    gpsCoordinates: CLLocationCoordinate2D(latitude: 37.123, longitude: -122.456),
    arOffset: SIMD3<Double>(1.5, 0.0, -2.3),
    arOrigin: arOriginLocation
)
```

## API Reference

### ARCoordinateSharingService

#### Properties
- `isCollaborativeSessionActive: Bool` - Whether collaborative session is running
- `connectedPeers: [String]` - List of connected device UUIDs
- `sharedWorldMapAvailable: Bool` - Whether a shared world map is loaded

#### Methods

##### World Map Management
```swift
func captureWorldMap() -> Data?
func loadWorldMap(_ worldMapData: Data) -> Bool
func shareWorldMap()
```

##### Collaborative Sessions
```swift
func startCollaborativeSession()
func stopCollaborativeSession()
func handleCollaborationData(_ collaborationData: ARSession.CollaborationData)
func sendCollaborationData(_ collaborationData: ARSession.CollaborationData)
```

##### AR Origin Sharing
```swift
func shareAROrigin(_ arOrigin: CLLocation)
func getSharedAROrigin(for deviceUUID: String) -> CLLocation?
func synchronizeAROrigins()
```

##### Coordinate Updates
```swift
func updateObjectCoordinates(
    objectId: String,
    gpsCoordinates: CLLocationCoordinate2D,
    arOffset: SIMD3<Double>?,
    arOrigin: CLLocation?
)
func processCoordinateUpdate(_ updateData: [String: Any])
```

##### Utilities
```swift
func areCoordinatesCompatible(
    _ device1Coords: CLLocationCoordinate2D,
    _ device2Coords: CLLocationCoordinate2D,
    tolerance: Double
) -> Bool

func getDiagnostics() -> [String: Any]
```

## Benefits

### Code Organization
- **90% reduction** in ARCoordinator size (from 5176 to ~400 lines)
- **Single responsibility** - coordinate sharing logic centralized
- **Testable** - isolated service can be unit tested
- **Maintainable** - changes don't affect other ARCoordinator responsibilities

### Feature Improvements
- **Better indoor support** - ARWorldMap works without GPS
- **Multi-device coordination** - collaborative sessions
- **Real-time sync** - WebSocket integration
- **Coordinate consistency** - shared origins prevent drift

### Performance
- **Reduced memory usage** - smaller coordinator class
- **Better threading** - coordinate operations on dedicated queue
- **Optimized updates** - batched coordinate reconciliation

## Migration Guide

### Phase 1: Add Service
1. Add `ARCoordinateSharingService.swift` to project
2. Add service property to `ARCoordinator`
3. Initialize service in `setupARCoordinator()`

### Phase 2: Extract Methods
1. Replace `locationManager?.sharedAROrigin = ...` with `shareAROrigin(...)`
2. Replace inline API coordinate updates with `updateObjectCoordinates(...)`
3. Move coordinate correction logic to service methods

### Phase 3: Add Advanced Features
1. Implement ARWorldMap sharing UI
2. Add collaborative session controls
3. Enable real-time coordinate sync

## Testing

### Unit Tests
```swift
func testCoordinateSharing() {
    let service = ARCoordinateSharingService()
    let origin = CLLocation(latitude: 37.123, longitude: -122.456)

    service.shareAROrigin(origin)

    XCTAssertNotNil(service.getSharedAROrigin(for: deviceUUID))
}
```

### Integration Tests
```swift
func testWorldMapSharing() {
    let service = ARCoordinateSharingService()
    service.configure(with: arView, ...)

    let worldMapData = service.captureWorldMap()
    XCTAssertNotNil(worldMapData)

    let success = service.loadWorldMap(worldMapData!)
    XCTAssertTrue(success)
}
```

## Future Enhancements

### Cloud Anchors
- Persistent anchors across app sessions
- Server-side anchor storage
- Cross-platform compatibility

### Visual Markers
- QR code coordinate system establishment
- Visual SLAM-based synchronization
- Offline marker detection

### Advanced Reconciliation
- Machine learning-based coordinate correction
- Multi-device triangulation
- GPS-denied environment support

## Troubleshooting

### Common Issues

1. **World Map Capture Fails**
   - Ensure sufficient visual features in environment
   - Check AR session is running and stable
   - Verify device has adequate lighting

2. **Collaborative Session Not Starting**
   - Check network connectivity
   - Verify all devices on same network
   - Ensure ARWorldTrackingConfiguration is used

3. **Coordinate Drift**
   - Synchronize AR origins between devices
   - Use world map sharing for better stability
   - Implement regular coordinate reconciliation

### Debug Information
```swift
let diagnostics = coordinateSharingService.getDiagnostics()
print("Coordinate sharing status: \(diagnostics)")
```

## Related Files
- `ARCoordinateSharingService.swift` - Main service implementation
- `ARCoordinator+CoordinateSharing.swift` - Integration extension
- `LootBoxLocationManager+Coordinates.swift` - Location manager integration



