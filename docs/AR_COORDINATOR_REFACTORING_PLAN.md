# ARCoordinator Refactoring Plan

ARCoordinator is currently **2105 lines** and handles too many responsibilities. This plan outlines what can be extracted to follow DRY and Single Responsibility principles.

## Current Responsibilities in ARCoordinator

1. **Viewport Visibility Tracking** (~150 lines)
   - `isObjectInViewport()` - Check if objects are visible
   - `checkViewportVisibility()` - Monitor viewport changes
   - `playViewportChime()` - Play sound when objects enter viewport

2. **Object Placement Logic** (~600+ lines)
   - `placeBoxAtPosition()` - Core placement with collision checking
   - `placeLootBoxAtLocation()` - GPS-based placement
   - `placeLootBoxAtTapLocation()` - Tap-based placement
   - `placeARSphereAtLocation()` - Sphere-specific placement
   - `placeLootBoxInFrontOfCamera()` - Fallback placement
   - `placeSingleSphere()` - Single sphere placement
   - `placeARItem()` - Generic item placement
   - `createSphereEntity()` - Sphere entity creation
   - `placeItemAsBox()` - Box entity placement

3. **Position Calculation** (~200+ lines)
   - GPS to AR coordinate conversion
   - Bearing calculations
   - Distance validation
   - Surface detection integration
   - Indoor/outdoor position generation
   - Room boundary checking

4. **Collision Detection** (~100+ lines)
   - Check collisions between objects
   - GPS collision detection
   - Minimum separation enforcement
   - Camera distance validation

5. **Object Finding/Collection** (~130 lines)
   - `findLootBox()` - Handle object discovery
   - Collection callbacks
   - Cleanup after finding

6. **Randomization Logic** (~200 lines)
   - `randomizeLootBoxes()` - Random placement logic
   - Placement strategy determination
   - Surface-based placement attempts

7. **ARSessionDelegate** (~130 lines)
   - Session lifecycle management
   - Plane anchor handling
   - Error handling
   - Interruption handling

8. **State Management**
   - Tracking placed boxes
   - Tracking findable objects
   - Viewport visibility state
   - Mode flags (sphereModeActive, etc.)

## Proposed Extraction Plan

### 1. ARViewportVisibilityTracker ✅ **HIGH PRIORITY**
**Extract:** Viewport visibility checking and chime playing

**File:** `ARViewportVisibilityTracker.swift`

**Responsibilities:**
- Monitor which objects are in viewport
- Play chime when objects enter viewport
- Track visibility state

**Methods to extract:**
- `isObjectInViewport()`
- `checkViewportVisibility()`
- `playViewportChime()`
- State: `objectsInViewport: Set<String>`

**Benefits:**
- Clean separation of viewport concerns
- Easier to test
- Can be reused

---

### 2. ARObjectPlacementService ✅ **HIGH PRIORITY**
**Extract:** All object placement logic

**File:** `ARObjectPlacementService.swift`

**Responsibilities:**
- Place objects at various locations
- Handle different placement types (GPS, tap, random)
- Coordinate with factories for entity creation

**Methods to extract:**
- `placeBoxAtPosition()`
- `placeLootBoxAtLocation()`
- `placeLootBoxAtTapLocation()`
- `placeARSphereAtLocation()`
- `placeLootBoxInFrontOfCamera()`
- `placeSingleSphere()`
- `placeARItem()`
- `createSphereEntity()`
- `placeItemAsBox()`

**Dependencies needed:**
- `ARGroundingService` (already exists)
- `ARObjectCollisionDetector` (new)
- `ARPositionCalculator` (new)
- Access to `LootBoxFactory`

**Benefits:**
- Centralizes all placement logic
- Easier to test placement scenarios
- Reduces ARCoordinator by ~600 lines

---

### 3. ARPositionCalculator ✅ **HIGH PRIORITY**
**Extract:** GPS to AR position conversion and validation

**File:** `ARPositionCalculator.swift`

**Responsibilities:**
- Convert GPS coordinates to AR world positions
- Calculate bearings and distances
- Validate positions
- Generate random positions
- Check room boundaries

**Methods to extract:**
- GPS to AR conversion logic from `placeLootBoxAtLocation()`
- `generateIndoorPosition()`
- `isPositionWithinRoomBounds()`
- Position validation logic
- Bearing calculations

**Benefits:**
- Reusable position calculations
- Testable without AR session
- Clear separation of coordinate systems

---

### 4. ARObjectCollisionDetector ✅ **MEDIUM PRIORITY**
**Extract:** Collision detection logic

**File:** `ARObjectCollisionDetector.swift`

**Responsibilities:**
- Check collisions between AR objects
- Check GPS coordinate collisions
- Validate minimum separations
- Camera distance validation

**Methods to extract:**
- Collision checking from `placeBoxAtPosition()`
- GPS collision checking from `checkAndPlaceBoxes()`
- Distance validation logic

**Benefits:**
- Single source of truth for collision rules
- Easier to adjust collision parameters
- Testable collision logic

---

### 5. ARObjectCollectionHandler ✅ **MEDIUM PRIORITY**
**Extract:** Object finding and collection logic

**File:** `ARObjectCollectionHandler.swift`

**Responsibilities:**
- Handle object discovery
- Manage collection callbacks
- Cleanup after finding

**Methods to extract:**
- `findLootBox()`
- Collection notification logic
- Cleanup logic

**Benefits:**
- Separates collection logic from placement
- Easier to modify collection behavior

---

### 6. ARRandomizationService ✅ **LOW PRIORITY**
**Extract:** Random object placement logic

**File:** `ARRandomizationService.swift`

**Responsibilities:**
- Randomize loot boxes
- Placement strategy selection
- Multiple placement attempts

**Methods to extract:**
- `randomizeLootBoxes()`
- `getPlacementStrategy()`
- Random position generation logic

**Benefits:**
- Isolates randomization complexity
- Easier to adjust randomization parameters

---

### 7. ARSessionLifecycleHandler ✅ **LOW PRIORITY** (Optional)
**Extract:** ARSessionDelegate methods

**File:** `ARSessionLifecycleHandler.swift`

**Responsibilities:**
- Handle AR session lifecycle
- Plane anchor management
- Error and interruption handling

**Methods to extract:**
- All `ARSessionDelegate` methods
- Plane anchor filtering logic

**Benefits:**
- Cleaner separation of AR session concerns
- Can be tested independently

**Note:** This might not be worth extracting if it's tightly coupled to ARCoordinator state.

---

## Implementation Order

1. **Phase 1: High Priority**
   - ✅ `ARGroundingService` (already exists, but needs to be updated with improved logic)
   - `ARViewportVisibilityTracker`
   - `ARPositionCalculator`

2. **Phase 2: Core Placement**
   - `ARObjectCollisionDetector`
   - `ARObjectPlacementService`

3. **Phase 3: Additional Features**
   - `ARObjectCollectionHandler`
   - `ARRandomizationService`

## Estimated Impact

- **Current:** 2105 lines
- **After Phase 1:** ~1800 lines (save ~300 lines)
- **After Phase 2:** ~1200 lines (save ~900 lines)
- **After Phase 3:** ~800-900 lines (save ~1200 lines)

## Benefits

1. **Maintainability:** Each service has a single responsibility
2. **Testability:** Services can be tested independently
3. **Reusability:** Services can be used by other components
4. **Readability:** ARCoordinator becomes a coordinator, not a god class
5. **DRY:** Avoid code duplication across placement methods

## Notes

- Keep ARCoordinator as the main coordinator that wires services together
- Services should be injected as dependencies
- Maintain backward compatibility during refactoring
- Test each extraction independently before moving to next phase


