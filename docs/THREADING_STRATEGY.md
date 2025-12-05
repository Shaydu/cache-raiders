# Threading Strategy for UI Performance

## Problem
UI freezing occurs when heavy operations block the main thread. This document outlines the threading strategy to keep the UI responsive.

## Core Principles

1. **Main Thread = UI Only**: Only UI updates should happen on the main thread
2. **Background Threads for Heavy Work**: Network, file I/O, heavy computations
3. **Async/Await for Concurrency**: Use Swift concurrency for clean async code
4. **Actor Isolation for Shared State**: Protect shared mutable state with actors
5. **Throttling/Debouncing**: Limit frequency of expensive operations

## Threading Architecture

### 1. Network Operations
- **All network calls** → Background thread (via async/await)
- **UI updates from network results** → `@MainActor` or `DispatchQueue.main.async`
- **Network queue** → Already implemented in `APIService` (NetworkRequestQueue actor)

### 2. File I/O Operations
- **Saving/loading locations** → Background thread
- **UserDefaults access** → Already thread-safe, but minimize frequency

### 3. Location Processing
- **Distance calculations** → Background thread
- **Filtering nearby locations** → Background thread
- **GPS updates** → Already on background (CLLocationManager delegate)

### 4. AR Operations
- **AR session delegate** → Already on background queue
- **Object placement** → Background thread (use existing queues)
- **Viewport checks** → Background thread with throttling

### 5. Heavy Computations
- **Location filtering** → Background thread
- **Distance calculations** → Background thread
- **Coordinate transformations** → Background thread

## Implementation Strategy

### Phase 1: Network Operations (Already Partially Done)
✅ `APIService` uses async/await
✅ `NetworkRequestQueue` limits concurrent requests
⚠️ Need to ensure all callers use `Task` or `async` context

### Phase 2: File I/O
- Move `saveLocations()` to background thread
- Move `loadLocations()` to background thread
- Use async/await for file operations

### Phase 3: Location Processing
- Move `getNearbyLocations()` filtering to background
- Move distance calculations to background
- Batch location updates

### Phase 4: AR Operations
- Ensure all AR processing uses existing background queues
- Throttle viewport checks
- Batch object placement operations

## Key Files to Update

1. **LootBoxLocationManager.swift**
   - `saveLocations()` → Background thread
   - `loadLocations()` → Background thread
   - `getNearbyLocations()` → Background thread
   - `loadLocationsFromAPI()` → Already async, ensure UI updates on main thread

2. **ARCoordinator.swift**
   - Already has background queues
   - Ensure all heavy operations use them
   - Throttle frequent checks

3. **UserLocationManager.swift**
   - Already uses async/await for network
   - Ensure UI updates on main thread

4. **ContentView.swift**
   - Location update debouncing already implemented
   - Ensure all state updates on main thread

## Best Practices

1. **Always use `Task` or `async` for network calls**
2. **Use `@MainActor` for UI-related state updates**
3. **Use `Task.detached` for CPU-intensive work**
4. **Throttle/debounce frequent operations**
5. **Batch updates when possible**
6. **Use actors for shared mutable state**

## Performance Monitoring

- Use `PerformanceMonitor` to track main thread blocking
- Monitor frame rate during heavy operations
- Log when operations take >16ms (one frame at 60fps)


