# iOS Freeze Fixes - Immediate Actions

## 🔴 Critical Issue Found: Expensive Raycasts

### Problem
`ARGroundingService.findHighestBlockingSurface()` is called **many times** and performs **up to 10 ARKit raycasts per call**. This is extremely expensive and causes freezes.

**Evidence:**
- Called 10+ times in `ARCoordinator.swift` during object placement
- Each call can do up to 10 raycasts (center + 9 grid positions)
- Raycasts are **synchronous** and block the thread
- Called in loops during object randomization

### Immediate Fix: Cache Raycast Results

Add caching to `ARGroundingService.swift`:

```swift
// Add to ARGroundingService class
private var raycastCache: [String: (y: Float, timestamp: Date)] = [:]
private let cacheTimeout: TimeInterval = 0.5 // Cache for 500ms
private let cacheGridSize: Float = 0.5 // Cache within 0.5m grid

func findHighestBlockingSurface(x: Float, z: Float, cameraPos: SIMD3<Float>, silent: Bool = false) -> Float? {
    // Check cache first
    let cacheKey = "\(Int(x / cacheGridSize))_\(Int(z / cacheGridSize))"
    if let cached = raycastCache[cacheKey],
       Date().timeIntervalSince(cached.timestamp) < cacheTimeout {
        return cached.y
    }
    
    // ... existing raycast code ...
    
    // Cache the result
    if let result = /* your result */ {
        raycastCache[cacheKey] = (result, Date())
        
        // Clean old cache entries (keep cache small)
        let now = Date()
        raycastCache = raycastCache.filter { now.timeIntervalSince($0.value.timestamp) < cacheTimeout * 2 }
    }
    
    return result
}
```

### Better Fix: Throttle Raycasts

Limit raycasts to max 10 per second:

```swift
// Add to ARGroundingService class
private var lastRaycastTime: Date = Date()
private let minRaycastInterval: TimeInterval = 0.1 // Max 10 per second
private var pendingRaycastQueue: [(x: Float, z: Float, cameraPos: SIMD3<Float>, completion: (Float?) -> Void)] = []

func findHighestBlockingSurface(x: Float, z: Float, cameraPos: SIMD3<Float>, silent: Bool = false) -> Float? {
    let now = Date()
    let timeSinceLastRaycast = now.timeIntervalSince(lastRaycastTime)
    
    // If called too soon, return cached/default value
    if timeSinceLastRaycast < minRaycastInterval {
        // Return cached value or default
        return cameraPos.y - 1.5 // Default ground height
    }
    
    lastRaycastTime = now
    // ... existing raycast code ...
}
```

## 🟡 Other Freeze Sources

### 1. Too Many Concurrent Network Requests

**Problem:** Multiple API calls happening simultaneously

**Fix:** Add request queue to `APIService.swift`:

```swift
actor NetworkRequestQueue {
    private var activeCount = 0
    private let maxConcurrent = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    func waitForSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func releaseSlot() {
        activeCount -= 1
        if let next = waiters.popFirst() {
            activeCount += 1
            next.resume()
        }
    }
}

// In APIService
private static let requestQueue = NetworkRequestQueue()

private func makeRequest<T: Decodable>(...) async throws -> T {
    await Self.requestQueue.waitForSlot()
    defer { Self.requestQueue.releaseSlot() }
    // ... existing code ...
}
```

### 2. Location Updates Too Frequent

**Problem:** `onChange(of: userLocationManager.currentLocation)` triggers API calls too often

**Fix:** Add debouncing to `ContentView.swift`:

```swift
@State private var locationUpdateTask: Task<Void, Never>?

.onChange(of: userLocationManager.currentLocation) { _, newLocation in
    // Cancel previous task
    locationUpdateTask?.cancel()
    
    // Debounce: wait 2 seconds before API call
    locationUpdateTask = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        
        if let location = newLocation {
            guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else {
                return
            }
            await locationManager.loadLocationsFromAPI(userLocation: location)
        }
    }
}
```

### 3. Viewport Checks Too Frequent

**Problem:** `checkViewportVisibility()` called every frame

**Fix:** Already throttled in `ARCoordinator.swift:62`, but ensure it's working:

```swift
// In checkViewportVisibility()
let now = Date()
let timeSinceLastCheck = now.timeIntervalSince(lastViewportCheck)
guard timeSinceLastCheck >= 0.1 else { return } // Max 10 checks per second
lastViewportCheck = now
```

## 🟢 Performance Monitoring

### Add Performance Logging

Create `PerformanceMonitor.swift`:

```swift
import Foundation

class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    func measure<T>(_ label: String, operation: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        if elapsed > 0.016 { // More than one frame (60fps = 16ms)
            print("⚠️ SLOW: \(label) took \(String(format: "%.1f", elapsed * 1000))ms")
        }
        
        return result
    }
    
    func measureAsync<T>(_ label: String, operation: () async -> T) async -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = await operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        if elapsed > 0.016 {
            print("⚠️ SLOW: \(label) took \(String(format: "%.1f", elapsed * 1000))ms")
        }
        
        return result
    }
}

// Usage:
let result = PerformanceMonitor.shared.measure("Raycast") {
    groundingService.findHighestBlockingSurface(...)
}
```

## 📊 Quick Diagnostic Steps

### Step 1: Enable Main Thread Checker
1. **Product → Scheme → Edit Scheme**
2. **Run → Diagnostics**
3. Check **"Main Thread Checker"**
4. Run app - violations show in console

### Step 2: Profile with Time Profiler
1. **Product → Profile** (⌘I)
2. Select **"Time Profiler"**
3. Reproduce freeze
4. Look at **"Call Tree"** sorted by **"Weight"**
5. Find functions taking >10% CPU time

### Step 3: Check for These Patterns

**❌ Bad (causes freezes):**
```swift
// Synchronous raycast in loop
for location in locations {
    let y = groundingService.findHighestBlockingSurface(...) // BLOCKS!
}

// Too many concurrent network calls
for location in locations {
    Task {
        await APIService.shared.createObject(location) // No limit!
    }
}

// Heavy computation on main thread
let result = processLargeArray(data) // On main thread
```

**✅ Good (won't freeze):**
```swift
// Throttled raycasts
let now = Date()
guard now.timeIntervalSince(lastRaycast) >= 0.1 else { return defaultY }
let y = groundingService.findHighestBlockingSurface(...)

// Limited concurrent requests
await requestQueue.waitForSlot()
defer { requestQueue.releaseSlot() }
await APIService.shared.createObject(location)

// Off main thread
Task.detached {
    let result = processLargeArray(data)
    await MainActor.run { /* update UI */ }
}
```

## 🎯 Priority Fix Order

1. **HIGHEST:** Cache/throttle `findHighestBlockingSurface` raycasts
2. **HIGH:** Add network request queue
3. **MEDIUM:** Debounce location update API calls
4. **LOW:** Add performance monitoring

## 🔧 Testing After Fixes

1. **Test with many objects:** Place 20+ loot boxes, check for freeze
2. **Test rapid location changes:** Move device quickly
3. **Test network issues:** Disable WiFi, check for freeze
4. **Profile again:** Run Time Profiler to verify improvements

## 📝 Notes

- ARKit raycasts are **expensive** - each one takes ~5-10ms
- 10 raycasts = 50-100ms = 3-6 dropped frames
- Called in loops = freeze
- **Solution:** Cache results, throttle calls, use defaults when possible




