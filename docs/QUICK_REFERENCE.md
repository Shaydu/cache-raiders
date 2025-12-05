# NFC Loot Writer - Quick Reference Guide

## File Locations at a Glance

| Component | File Path | Key Lines |
|-----------|-----------|-----------|
| **NFC Writing UI** | `/CacheRaiders/NFCWritingView.swift` | 13-713 |
| **NFC Service** | `/CacheRaiders/NFCService.swift` | Entire file |
| **AR Integration** | `/CacheRaiders/NFCARIntegrationService.swift` | Integration layer |
| **Data Model** | `/CacheRaiders/LootBoxLocation.swift` | 81-213 |
| **API Endpoint** | `/server/app.py` | 647-811 |
| **Requirements** | `/docs/requirements/nfc.md` | Full spec |

---

## Step-by-Step Flow

### 1. User Selects Loot Type
```
NFCWritingView → lootTypeSelectionView (L196-226)
→ User taps loot type
→ selectedLootType = chosen type
→ startWriting() (L382-388)
```

### 2. Capture AR Position
```
startPositioning() (L390-421)
→ Check location available (L401-405)
→ captureARPosition() (L452-512)
  ├─ Get GPS: lat, lon, altitude
  ├─ Get AR anchor transform (simd_float4x4)
  ├─ Serialize to base64
  └─ Ready for NFC write
```

### 3. Write to NFC Tag
```
writeNFCWithCompleteData() (L514-555)
→ Create compact URL: "https://server/nfc/abc123"
→ NFCService.writeNFC(message) (NFCService.swift L91-131)
  ├─ Create NDEF URI record (L312-377)
  ├─ Start NFCTagReaderSession
  ├─ Connect to tag
  ├─ writeToMiFareTag() (L511-612)
  │  ├─ Query NDEF status
  │  ├─ Write NDEF message
  │  └─ Return NFCResult (tagId, payload)
  └─ Completion callback
```

### 4. Create Server Object
```
createObjectWithCompleteData() (L557-699)
→ Generate objectId from NFC tag + timestamp
→ Build comprehensive objectData dict:
  {
    "id": "nfc_<tagId>_<timestamp>",
    "name": "Treasure Chest",
    "type": "treasure_chest",
    "latitude": 40.7128,
    "longitude": -74.0060,
    "radius": 3.0,
    "created_by": "Player1",
    "ar_anchor_transform": "base64...",
    ... (20+ other fields)
  }
→ POST to /api/objects (L623-631)
→ Get 201 response
```

### 5. Server Processing
```
app.py create_object() (L647-811)
→ Validate required fields (L654-657)
→ Retry logic on database lock (L663-713):
  ├─ INSERT INTO objects
  ├─ On locked: retry 3x with exponential backoff
  ├─ On success: break retry loop
  └─ On error: return error response
→ Fetch created object
→ Broadcast via WebSocket: socketio.emit('object_created')
→ Return 201 with object ID
```

### 6. Real-Time Sync
```
Server broadcasts → WebSocket 'object_created' event
Client receives → NotificationCenter("WebSocketObjectCreated")
LootBoxLocation manager (L575-624):
  ├─ Convert WebSocket data to LootBoxLocation
  ├─ Add to locations array
  ├─ Save to Core Data
  ├─ Post ObjectCreatedRealtime notification
  └─ AR view updates in real-time
```

---

## API Request/Response

### POST /api/objects

**Request**:
```http
POST /api/objects HTTP/1.1
Content-Type: application/json

{
  "id": "nfc_abc123_1701360000",
  "name": "Treasure Chest",
  "type": "treasure_chest",
  "latitude": 40.7128,
  "longitude": -74.0060,
  "altitude": 10.5,
  "radius": 3.0,
  "created_by": "Player1",
  "ar_anchor_transform": "base64-encoded..."
  // ... 15+ more fields
}
```

**Success Response (201)**:
```json
{
  "id": "nfc_abc123_1701360000",
  "message": "Object created successfully"
}
```

**Error Response (400/500)**:
```json
{
  "error": "Missing required field: latitude"
}
```

---

## Error Handling Quick Map

### If NFC Writing Fails
- Location: `writeNFCWithCompleteData()` L548-551
- User sees: `.error` state with error message
- Recovery: "Try Again" button → retry from loot selection

### If AR Capture Fails
- Location: `captureARPosition()` L414-420
- Fallback: Uses GPS-only positioning (no AR anchor)
- Continues: Proceeds to NFC writing anyway

### If API Creation Fails
- Location: `createObjectWithCompleteData()` L691-697
- User sees: Error message with HTTP status code
- Recovery: "Try Again" button

### If Database is Locked
- Location: `app.py` L692-713
- Handling: Automatic retry with exponential backoff (3x max)
- Timeout: 100ms → 200ms → 400ms

---

## Key Data Structures

### NFCResult (NFCService.swift L18-23)
```swift
struct NFCResult {
    let tagId: String              // "04:1234:AB:CD"
    let ndefMessage: NFCNDEFMessage?
    let payload: String?           // URL written
    let timestamp: Date
}
```

### LootBoxLocation (LootBoxLocation.swift L81-169)
```swift
struct LootBoxLocation {
    let id: String                 // "nfc_<tagId>_<timestamp>"
    let name: String               // "Treasure Chest"
    let type: LootBoxType          // .treasureChest
    let latitude: Double           // 40.7128
    let longitude: Double          // -74.0060
    let radius: Double             // 3.0 meters
    let ar_anchor_transform: String?  // Base64 matrix
    var collected: Bool            // false initially
    var created_by: String?        // "Player1"
}
```

### WritingStep (NFCWritingView.swift L32-39)
```swift
enum WritingStep {
    case selecting      // Pick loot type
    case positioning    // Capture AR position
    case writing        // Write NFC tag
    case creating       // Create server object
    case success        // Done!
    case error          // Something failed
}
```

---

## Important Constants

| Constant | Value | Location | Purpose |
|----------|-------|----------|---------|
| NFC Radius | 3.0m | L579 | Detection radius for NFC objects |
| AR Anchor Range | 8.0m | L602 | Use AR anchor if within this distance |
| URL Length Limit | 100 chars | NFCService L326 | Max NDEF URI length |
| Database Retries | 3 | app.py L660 | Max retries on lock |
| Retry Delay | 0.1s | app.py L661 | Initial exponential backoff |

---

## Logging/Debugging Tips

### View NFC Diagnostics
- Button in NFCWritingView: "Check NFC Status" (L123-134)
- Shows device NFC capabilities
- File: NFCDiagnosticsSheet (L715-803)

### Debug Messages
Search for these patterns in Xcode console:
- `"📝 Writing to MiFare tag"` - NFC write started
- `"✅ Successfully wrote NDEF message"` - NFC write success
- `"❌ Failed to write NDEF"` - NFC write error
- `"📤 Creating comprehensive database object"` - API call preparing
- `"📥 Server response"` - Server responded
- `"✅ NFC loot object created successfully"` - Complete success

### Monitor WebSocket Events
LootBoxLocation.swift L575-624 shows WebSocket object creation handler
Set breakpoint in `handleWebSocketObjectCreated()` to debug real-time sync

---

## Common Issues & Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| "NFC not supported" | Device doesn't support NFC | Check device is iPhone 7+ |
| NFC write timeout | No tag near device | Hold iPhone closer to tag |
| "Missing latitude" | Location services disabled | Enable location in Settings |
| "Database locked" | Concurrent writes | Retries automatically (3x) |
| Object not syncing | Network issue | Check API server is running |
| AR anchor not captured | ARKit unavailable | Falls back to GPS-only |

---

## Testing the Complete Flow

### Manual Test Steps:
1. Open app in NFCWritingView
2. Select a loot type (e.g., Treasure Chest)
3. Wait for AR positioning prompt
4. Hold iPhone near NFC tag (MiFare Type 4)
5. Watch NFC write complete
6. Check other connected devices see object appear in real-time
7. Verify coordinates in success screen

### Quick Testing Code:
```python
# Test API directly
import requests
data = {
    "id": "test_123_1701360000",
    "name": "Test Treasure",
    "type": "treasure_chest",
    "latitude": 40.7128,
    "longitude": -74.0060,
    "radius": 3.0,
    "created_by": "TestUser"
}
response = requests.post("http://localhost:5000/api/objects", json=data)
print(response.status_code, response.json())
```

---

## Database Schema (Relevant Fields)

```sql
CREATE TABLE objects (
    id TEXT PRIMARY KEY,
    name TEXT,
    type TEXT,
    latitude REAL,
    longitude REAL,
    radius REAL,
    created_at TEXT,
    created_by TEXT,
    grounding_height REAL,
    ar_anchor_transform TEXT,  -- Base64 encoded
    ar_origin_latitude REAL,
    ar_origin_longitude REAL,
    ar_offset_x REAL,
    ar_offset_y REAL,
    ar_offset_z REAL,
    ar_placement_timestamp TEXT
);
```

---

## Files to Review for More Details

1. **Complete Architecture**: `/docs/NFC_PLACEMENT_IMPLEMENTATION_PLAN.md`
2. **Requirements Spec**: `/docs/requirements/nfc.md`
3. **Unit Tests**: Look for test_*.py files in /server
4. **Diagnostics**: Built-in NFCDiagnosticsSheet in NFCWritingView.swift

