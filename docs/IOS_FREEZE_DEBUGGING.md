# iOS App Freeze Debugging Guide

## Overview
This guide covers the most reliable methods to identify and fix app freezes on iOS, specifically for the CacheRaiders AR app.

## 1. Using Xcode Instruments (Most Reliable)

### Time Profiler
**Best for:** Finding what code is consuming CPU time and blocking the main thread

**Steps:**
1. In Xcode: **Product → Profile** (⌘I) or **Product → Scheme → Edit Scheme → Run → Diagnostics → Enable "Main Thread Checker"**
2. Select **Time Profiler** template
3. Run your app and reproduce the freeze
4. Stop recording
5. Look for:
   - **Main Thread** - Check if it's 100% busy (red bar)
   - **Heavy functions** - Functions taking >10% of CPU time
   - **Call tree** - Sort by "Weight" to see what's consuming time

**What to look for:**
- Functions with high "Weight" percentage
- Main thread blocked for extended periods
- Recurring function calls (loops)
- ARKit frame processing taking too long

### System Trace
**Best for:** Understanding thread activity and blocking operations

**Steps:**
1. **Product → Profile** (⌘I)
2. Select **System Trace** template
3. Run app and reproduce freeze
4. Look for:
   - **Thread states** - Red = blocked, Green = running
   - **Main thread** - Should be green most of the time
   - **Synchronization issues** - Locks, semaphores blocking threads

### Allocations
**Best for:** Memory leaks causing performance degradation

**Steps:**
1. **Product → Profile** (⌘I)
2. Select **Allocations** template
3. Look for:
   - Continuously growing memory
   - Objects not being deallocated
   - Large allocations

## 2. Main Thread Checker (Built-in)

**Enable in Xcode:**
1. **Product → Scheme → Edit Scheme**
2. **Run → Diagnostics**
3. Check **"Main Thread Checker"**

This will **automatically detect** when you're doing work on the main thread that shouldn't be there.

**Common violations:**
- Network calls on main thread
- Heavy computations on main thread
- File I/O on main thread
- Database operations on main thread

## 3. Manual Debugging Techniques

### A. Add Performance Logging

Add this to identify slow operations:

```swift
func measureTime<T>(_ operation: () -> T, label: String) -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = operation()
    let timeElapsed = CFAbsoluteTimeGetCurrent() - start
    if timeElapsed > 0.016 { // More than one frame (60fps = 16ms per frame)
        print("⚠️ SLOW OPERATION: \(label) took \(String(format: "%.3f", timeElapsed * 1000))ms")
    }
    return result
}

// Usage:
let result = measureTime({
    // Your code here
}, label: "AR object placement")
```

### B. Check for Blocking Operations

Look for these patterns in your code:

**❌ Bad (blocks main thread):**
```swift
// Synchronous network call
let data = try Data(contentsOf: url)

// Heavy computation on main thread
let result = processLargeArray(data) // Takes 100ms+

// Database query on main thread
let objects = try context.fetch(request)
```

**✅ Good (off main thread):**
```swift
// Async network call
Task {
    let data = try await URLSession.shared.data(from: url)
    await MainActor.run {
        // Update UI on main thread
    }
}

// Heavy computation off main thread
Task.detached(priority: .userInitiated) {
    let result = processLargeArray(data)
    await MainActor.run {
        // Update UI
    }
}
```

## 4. Common Freeze Causes in AR Apps

### A. ARKit Frame Processing
**Problem:** Processing every AR frame on main thread

**Solution:**
```swift
// In ARCoordinator, throttle frame processing
private var lastFrameProcessTime: Date?
private let frameProcessInterval: TimeInterval = 0.033 // ~30fps max

func processARFrame(_ frame: ARFrame) {
    let now = Date()
    if let lastTime = lastFrameProcessTime,
       now.timeIntervalSince(lastTime) < frameProcessInterval {
        return // Skip this frame
    }
    lastFrameProcessTime = now
    // Process frame...
}
```

### B. Too Many AR Anchors/Entities
**Problem:** Rendering too many objects causes frame drops

**Solution:**
- Limit visible objects (cull distant objects)
- Use LOD (Level of Detail) - simpler models when far away
- Batch updates instead of per-object updates

### C. Location Updates Too Frequent
**Problem:** Processing location updates on every GPS fix

**Solution:**
```swift
// In UserLocationManager
private var lastLocationProcessTime: Date?
private let locationProcessInterval: TimeInterval = 1.0 // Max once per second

func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let now = Date()
    if let lastTime = lastLocationProcessTime,
       now.timeIntervalSince(lastTime) < locationProcessInterval {
        return // Skip this update
    }
    lastLocationProcessTime = now
    // Process location...
}
```

### D. Network Calls Blocking
**Problem:** Synchronous or too many concurrent network calls

**Solution:**
```swift
// Add request queue with max concurrency
actor RequestQueue {
    private var activeRequests = 0
    private let maxConcurrent = 3
    private var pendingTasks: [CheckedContinuation<Void, Never>] = []
    
    func waitForSlot() async {
        if activeRequests < maxConcurrent {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { continuation in
            pendingTasks.append(continuation)
        }
    }
    
    func releaseSlot() {
        activeRequests -= 1
        if let next = pendingTasks.popFirst() {
            activeRequests += 1
            next.resume()
        }
    }
}
```

## 5. Specific Issues in CacheRaiders

### Issue 1: ARCoordinator.swift (3228 lines)
**Problem:** Very large file, likely has performance bottlenecks

**Solution:**
- Profile with Time Profiler to find slow methods
- Consider breaking into smaller components
- Check `updateUIView` throttling (already implemented in ARLootBoxView.swift:60-78)

### Issue 2: Location Updates Every 5 Seconds
**Problem:** `UserLocationManager.sendCurrentLocationToServer()` called every 5 seconds

**Solution:**
- Already using `Task` (async) - good ✅
- But check if too many concurrent requests
- Add request queue if needed

### Issue 3: API Calls in onChange Handlers
**Problem:** `ContentView.onChange` triggers API calls

**Solution:**
- Already using `Task.detached` - good ✅
- Add debouncing to prevent rapid-fire calls:

```swift
private var locationUpdateTask: Task<Void, Never>?

.onChange(of: userLocationManager.currentLocation) { _, newLocation in
    // Cancel previous task
    locationUpdateTask?.cancel()
    
    // Debounce: wait 2 seconds before making API call
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

## 6. Quick Diagnostic Checklist

Run through this checklist when debugging freezes:

- [ ] **Time Profiler** - Is main thread 100% busy?
- [ ] **System Trace** - Are threads blocked?
- [ ] **Main Thread Checker** - Any violations?
- [ ] **Allocations** - Memory growing continuously?
- [ ] **Network calls** - Too many concurrent requests?
- [ ] **AR frame processing** - Processing every frame?
- [ ] **Location updates** - Too frequent?
- [ ] **UI updates** - Updating on every state change?
- [ ] **Heavy computations** - On main thread?

## 7. Recommended Fixes for CacheRaiders

### Priority 1: Add Request Throttling
Add to `APIService.swift`:
```swift
private let requestQueue = RequestQueue() // From example above

func makeRequest<T: Decodable>(...) async throws -> T {
    await requestQueue.waitForSlot()
    defer { requestQueue.releaseSlot() }
    // ... existing code ...
}
```

### Priority 2: Profile ARCoordinator
Run Time Profiler and identify:
- Slow methods in ARCoordinator
- Frame processing bottlenecks
- Entity update frequency

### Priority 3: Add Performance Monitoring
Add performance logging to:
- `ARCoordinator.updateUIView`
- `ARCoordinator.placeObjects`
- `UserLocationManager.sendCurrentLocationToServer`
- `LootBoxLocationManager.loadLocationsFromAPI`

## 8. Testing Freeze Scenarios

### Test 1: Rapid Location Changes
- Move device quickly
- Check if app freezes during location updates

### Test 2: Many AR Objects
- Place 20+ loot boxes
- Check frame rate and responsiveness

### Test 3: Network Issues
- Disable WiFi/cellular
- Check if app freezes waiting for network

### Test 4: Background/Foreground
- Put app in background
- Return to foreground
- Check if freeze occurs

## 9. Emergency Freeze Fix

If app is frozen and you need immediate fix:

1. **Add timeout to all network calls:**
```swift
let request = URLRequest(url: url, timeoutInterval: 5.0) // 5 second timeout
```

2. **Add cancellation support:**
```swift
private var networkTasks: [Task<Void, Never>] = []

func cancelAllNetworkTasks() {
    networkTasks.forEach { $0.cancel() }
    networkTasks.removeAll()
}
```

3. **Add watchdog timer:**
```swift
private var watchdogTimer: Timer?

func startWatchdog() {
    watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
        // If main thread is blocked, this won't fire
        print("✅ Watchdog: App is responsive")
    }
}
```

## 10. Resources

- [Apple: Instruments User Guide](https://developer.apple.com/documentation/xcode/instruments)
- [WWDC: Understanding Crashes and Performance Issues](https://developer.apple.com/videos/play/wwdc2021/10212/)
- [WWDC: Diagnose Performance Issues with Instruments](https://developer.apple.com/videos/play/wwdc2020/10078/)

---

## Quick Start: Find Freeze Now

1. **Enable Main Thread Checker:**
   - Product → Scheme → Edit Scheme → Run → Diagnostics → Enable "Main Thread Checker"
   - Run app - violations will show in console

2. **Run Time Profiler:**
   - Product → Profile (⌘I)
   - Select "Time Profiler"
   - Reproduce freeze
   - Look at "Call Tree" sorted by "Weight"

3. **Check for these patterns:**
   - `DispatchQueue.main.sync` (blocking!)
   - Heavy loops on main thread
   - Synchronous network calls
   - Too many UI updates per second

