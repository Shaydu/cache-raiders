# NFC Token Placement Requirements

## Overview
Add NFC token placement functionality to the + menu in open game mode, allowing players to create custom treasure objects by writing loot data to NFC tags and placing them with high-precision AR coordinates.

## Core Features

### 1. NFC Token Writing
- **User Interface**: Add "Place NFC Token" option to the + menu in open mode
- **Loot Type Selection**: Allow users to select from available loot types:
  - Chalice
  - Temple Relic
  - Treasure Chest
  - Loot Chest
  - Loot Cart
  - Sphere
  - Cube
  - Turkey (seasonal)
- **Token Writing**: Write selected loot type data to NFC tag
- **Validation**: Ensure NFC tag is writable and has sufficient capacity

### 2. Precise AR Positioning
- **Coordinate Capture**: Use existing PreciseARPositioningService for high-precision placement
- **Multi-Tier Accuracy**:
  - GPS macro positioning (5-10 meter accuracy)
  - NFC discovery zone (within 10 meters)
  - AR grounding (10-20cm accuracy)
  - NFC touch precision (<4cm accuracy)
- **Fallback Handling**: Graceful degradation if AR precision unavailable
- **Coordinate Storage**: Store both GPS and AR coordinates for optimal placement

### 3. Database Integration & API Sync
- **Server Storage**: Store NFC object data in application database
- **API Endpoints**: Use existing `/api/objects` POST endpoint for creation
- **Multi-Player Sync**: Ensure objects are visible to all players via real-time sync
- **Object Metadata**: Include NFC tag ID, placement coordinates, loot type, and creator info

### 4. Statistics Tracking
- **Placement Tracking**: Record who placed each NFC object
- **Discovery Tracking**: Track who finds each NFC object and when
- **Find Count Statistics**: Maintain count of total discoveries per object
- **Analytics Data**: Store timestamps and user information for each interaction

## User Experience Flow

### NFC Object Placement Flow

#### Step 1: Access Feature
- User opens + menu in open game mode
- Selects "Place NFC Token" option
- App checks NFC availability and permissions

#### Step 2: Loot Type Selection
- Display grid/list of available loot types with icons
- Show descriptions and rarity information
- Allow user to select desired loot type
- Optional: Custom naming for the object

#### Step 3: NFC Writing
- Prompt user to hold iPhone near NFC tag
- Display writing progress and status
- Write loot type data to tag
- Confirm successful write operation

#### Step 4: AR Positioning
- Transition to AR camera view
- Use GPS guidance to approach placement area
- Activate AR precision positioning
- Capture high-precision coordinates
- Confirm placement location

#### Step 5: Database Sync
- Create object record in local database
- Sync to server via API
- Notify other players of new object
- Update placement statistics

### NFC Object Discovery Flow

#### Step 1: GPS/AR Guidance
- User sees NFC objects in nearby locations list or map
- GPS guidance provides directional hints ("Head Northeast for 25m")
- AR view shows object location with precision placement
- Visual indicators guide user to general area

#### Step 2: NFC Proximity Detection
- When user gets within ~10 meters, switch to NFC discovery mode
- App prompts user to look for physical NFC tag nearby
- Guidance changes to "Look around for the NFC tag"
- AR indicators become more localized

#### Step 3: Physical NFC Scanning
- User must physically scan the NFC tag with their iOS device
- Hold iPhone near the tag to read the encoded loot data
- App validates tag data matches expected object
- Only successful NFC scan completes the discovery

#### Step 4: Discovery Confirmation
- Object is marked as "found" only after successful NFC scan
- Statistics are recorded (who found it, when, find count)
- Object disappears from other players' views
- Success feedback and loot collection animation

### Step 2: Loot Type Selection
- Display grid/list of available loot types with icons
- Show descriptions and rarity information
- Allow user to select desired loot type
- Optional: Custom naming for the object

### Step 3: NFC Writing
- Prompt user to hold iPhone near NFC tag
- Display writing progress and status
- Write loot type data to tag
- Confirm successful write operation

### Step 4: AR Positioning
- Transition to AR camera view
- Use GPS guidance to approach placement area
- Activate AR precision positioning
- Capture high-precision coordinates
- Confirm placement location

### Step 5: Database Sync
- Create object record in local database
- Sync to server via API
- Notify other players of new object
- Update placement statistics

## Key Differences: NFC vs Regular Treasure Objects

### Regular Treasure Objects
- **Discovery Method**: Proximity-based (get close enough in AR view)
- **Collection Trigger**: GPS/AR proximity detection
- **User Action Required**: Navigate to location, object auto-collects

### NFC Treasure Objects
- **Discovery Method**: Physical NFC tag scanning required
- **Collection Trigger**: Successful NFC read operation
- **User Action Required**: Navigate to location + physically scan NFC tag
- **Security**: Physical possession/verification of NFC tag required

### Hybrid Approach Benefits
- **GPS/AR Guidance**: Still guides users to general location
- **Physical Interaction**: Requires finding and scanning actual NFC tag
- **Anti-Cheating**: Cannot be found just by GPS spoofing or AR manipulation
- **Real-World Integration**: Bridges digital and physical treasure hunting

## Technical Requirements

### NFC Integration
- **CoreNFC Framework**: Use iOS NFC reading/writing capabilities
- **Tag Compatibility**: Support NDEF-formatted tags
- **Data Format**: Store loot type as structured NDEF record
- **Reading vs Writing**: Separate flows for placement (write) vs discovery (read)
- **Error Handling**: Handle write failures, tag incompatibilities, and user cancellation

### AR Positioning & Guidance
- **ARKit Integration**: Leverage existing PreciseARPositioningService
- **GeoAnchors**: Use ARGeoAnchor for GPS-to-AR coordinate conversion
- **Visual Anchoring**: Implement Look-Around anchoring for iOS 17+ devices
- **Coordinate Precision**: Aim for <20cm accuracy when possible
- **Discovery Guidance**: Provide directional hints until user reaches NFC scanning range

### NFC Discovery Logic
- **Proximity Detection**: Switch to NFC mode when within ~10 meters
- **Tag Validation**: Verify scanned tag matches expected object data
- **Discovery Completion**: Only mark as found after successful NFC scan
- **Fallback Handling**: Graceful handling when NFC scanning fails

### Database Schema
- **Objects Table**: Extend existing object schema
- **NFC Metadata**: Add NFC tag ID, write timestamp, creator user ID
- **Statistics Tables**: New tables for placement and discovery tracking
- **API Endpoints**: Extend existing object CRUD operations
- **Discovery Validation**: Server-side validation of NFC tag authenticity

### Statistics Implementation
- **Placement Stats**: Track creator, creation time, location
- **Discovery Stats**: Track finder, discovery time, NFC tag validation
- **Find Count Statistics**: Maintain count of total discoveries per object
- **Analytics Queries**: Enable querying by user, object type, time periods
- **Privacy Compliance**: Ensure user data handling meets privacy requirements

## Implementation Plan

### Phase 1: Core NFC Writing
- Add "Place NFC Token" to + menu
- Create loot type selection UI
- Implement NFC writing functionality
- Basic error handling and validation

### Phase 2: AR Positioning Integration
- Integrate with existing PreciseARPositioningService
- Implement coordinate capture flow
- Add placement confirmation UI
- Test precision accuracy

### Phase 3: Database & API Integration
- Extend object creation API calls
- Add NFC-specific metadata fields
- Implement server-side storage
- Test multi-player synchronization

### Phase 4: Statistics Tracking
- Design and implement statistics schema
- Add placement tracking on creation
- Add discovery tracking on find events
- Create analytics queries and reporting

### Phase 5: Testing & Polish
- End-to-end testing of complete flow
- NFC tag compatibility testing
- AR positioning accuracy validation
- Performance optimization and UI polish

## Success Criteria

### Functional Requirements
- ✅ Users can write loot data to NFC tags
- ✅ Objects appear with high-precision AR placement
- ✅ Multi-player synchronization works correctly
- ✅ Statistics are accurately tracked and stored

### Performance Requirements
- ✅ NFC writing completes within 3 seconds
- ✅ AR positioning achieves <50cm accuracy
- ✅ Database sync completes within 5 seconds
- ✅ No impact on existing AR performance

### User Experience Requirements
- ✅ Intuitive loot type selection interface
- ✅ Clear progress indication throughout flow
- ✅ Helpful error messages and recovery options
- ✅ Seamless integration with existing open mode features

## Dependencies

### External Dependencies
- CoreNFC framework (iOS 11+)
- ARKit framework with geo-tracking capabilities
- Existing API service infrastructure
- Database schema extensions

### Internal Dependencies
- PreciseARPositioningService
- APIService for server communication
- LootBoxLocation and related data models
- Existing ARCoordinator architecture

## Risk Assessment

### High Risk Items
- NFC tag compatibility across different manufacturers
- AR positioning accuracy in various environments
- Database schema changes affecting existing functionality

### Mitigation Strategies
- Comprehensive NFC tag testing across multiple brands
- Fallback positioning strategies for low-accuracy scenarios
- Database migration testing and rollback procedures
