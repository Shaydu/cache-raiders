# Object Generation Flow

## Current Behavior

### How Objects Are Generated

**Currently, objects are generated locally in each app instance:**

1. **Automatic Generation** (`createDefaultLocations()`):
   - When app starts and has GPS location
   - Generates 3 random objects within `maxSearchDistance` of user
   - Each app instance generates **different random objects**
   - Saved to local JSON file

2. **Manual Generation** (via Map View):
   - User taps map to add objects
   - Objects created with UUID IDs
   - Saved locally

3. **AR Generation** (via Randomize button):
   - Creates temporary AR-only objects
   - Not persisted (prefixed with `AR_ITEM_` or `AR_SPHERE_`)

### Current API Sync Behavior

✅ **When API sync is enabled:**
- `addLocation()` → syncs to API automatically
- `markCollected()` → syncs to API automatically
- `loadLocationsFromAPI()` → fetches from API

❌ **Missing:**
- `createDefaultLocations()` does NOT sync to API
- Each app instance still generates its own random objects

## Problem

**If each app generates its own objects:**
- User A generates 3 random objects near them
- User B generates 3 different random objects near them
- They don't see the same objects
- No shared state

## Solutions

### Option 1: Server-Generated Objects (Recommended)

**Generate objects on the server, apps fetch them:**

1. Server has an endpoint: `POST /api/objects/generate`
2. Server generates objects for a region
3. Apps fetch objects from API (no local generation)
4. All users see the same objects

**Pros:**
- ✅ True shared state
- ✅ Consistent experience
- ✅ Server controls object placement

**Cons:**
- Requires server endpoint for generation
- Less control per user

### Option 2: First-Writer-Wins (Current + Fix)

**First app generates, others fetch:**

1. App checks API for objects in area
2. If none exist, generate locally and sync to API
3. Other apps fetch from API (no generation)

**Pros:**
- ✅ Works with current code
- ✅ Users can still generate objects
- ✅ Shared state after first generation

**Cons:**
- Race conditions (multiple users generating simultaneously)
- Need to check API before generating

### Option 3: Hybrid Approach

**Server generates base set, users can add more:**

1. Server provides default objects for regions
2. Users can add custom objects via map
3. All synced via API

## Recommended Implementation

### Update `createDefaultLocations()` to check API first:

```swift
func createDefaultLocations(near userLocation: CLLocation) async {
    if useAPISync {
        // Check if objects exist in API for this area
        do {
            let apiObjects = try await APIService.shared.getObjects(
                latitude: userLocation.coordinate.latitude,
                longitude: userLocation.coordinate.longitude,
                radius: maxSearchDistance,
                includeFound: false
            )
            
            if !apiObjects.isEmpty {
                // Use objects from API
                let loadedLocations = apiObjects.compactMap { 
                    APIService.shared.convertToLootBoxLocation($0) 
                }
                await MainActor.run {
                    self.locations = loadedLocations
                }
                return
            }
        } catch {
            print("⚠️ Error checking API, generating locally: \(error)")
        }
    }
    
    // No objects in API, generate locally
    // ... existing generation code ...
    
    // Sync to API if enabled
    if useAPISync {
        for location in locations {
            await saveLocationToAPI(location)
        }
    }
}
```

## Current State Summary

| Action | Local Generation | API Sync | Shared State |
|--------|-----------------|----------|--------------|
| `createDefaultLocations()` | ✅ Yes | ❌ No | ❌ No |
| `addLocation()` (map tap) | ✅ Yes | ✅ Yes | ✅ Yes |
| `markCollected()` | N/A | ✅ Yes | ✅ Yes |
| `loadLocationsFromAPI()` | N/A | ✅ Yes | ✅ Yes |

**To achieve true shared state, we need to:**
1. Check API before generating objects
2. Sync generated objects to API
3. Or generate objects on server

