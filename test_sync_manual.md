# 🔄 CacheRaiders Sync System Testing Guide

## Overview
This guide tests the hybrid synchronization system that combines real-time WebSocket broadcasts with periodic two-way sync for guaranteed consistency.

## Prerequisites
1. **Server Running**: Start the server first
   ```bash
   cd server
   python3 app.py
   ```

2. **Test Data**: Ensure you have some objects in the database
   ```bash
   cd server
   python3 -c "
   import sqlite3
   conn = sqlite3.connect('cache_raiders.db')
   cursor = conn.cursor()
   cursor.execute('SELECT COUNT(*) FROM objects')
   print(f'Objects in DB: {cursor.fetchone()[0]}')
   conn.close()
   "
   ```

3. **Two Test Devices**: Use iOS Simulator + physical device, or two simulators

## 🧪 Test Scenarios

### **Test 1: WebSocket Object Sync on Connect**
**What it tests**: New devices receive all objects when connecting

**Steps**:
1. Start Server
2. Create test objects via API:
   ```bash
   curl -X POST http://localhost:5000/api/objects \
     -H "Content-Type: application/json" \
     -d '{
       "id": "test-connect-1",
       "name": "Connection Test Object",
       "type": "Chalice",
       "latitude": 40.0758,
       "longitude": -105.3008,
       "radius": 5.0
     }'
   ```
3. **Device A**: Connect to server (should receive objects via `objects_batch`)
4. **Device B**: Connect to server (should also receive all objects)

**Expected Results**:
- Console logs show: `📦 Received batch_X_X: Y objects`
- Both devices should show the same objects on map
- Device B should have objects immediately without manual refresh

**Debug Logs to Check**:
```
🗺️ [MapView] allAnnotations computed with X locations
📦 WebSocket: Received objects batch 1/2 with 50 objects
✅ Added new object to locations array (total: X)
```

### **Test 2: Real-time Object Creation**
**What it tests**: New objects broadcast to all connected devices instantly

**Steps**:
1. Connect both devices to server
2. **Device A**: Create new object via AR placement or API
3. **Device B**: Should immediately see the new object appear

**Expected Results**:
- Device B sees object instantly (<1 second)
- No manual refresh needed
- Object appears on map and in AR

**Debug Logs to Check**:
```
📦 WebSocket: Object created - ID: xxx
✅ Added new object to locations array (total: X)
🗺️ [MapView] allAnnotations computed with X locations
```

### **Test 3: Automatic Sync on WebSocket Connect**
**What it tests**: Devices sync local changes when reconnecting

**Steps**:
1. **Device A**: Create object, then disconnect WiFi
2. **Device A**: Find an object while offline
3. **Device A**: Reconnect WiFi
4. Check that the find was synced to server

**Expected Results**:
- Console shows: `🔄 WebSocket connected - automatically syncing with server...`
- Find appears on server and other devices
- No manual sync button press needed

**Debug Logs to Check**:
```
🔄 WebSocket connected - automatically syncing with server...
🔄 Processed coordinate update for object xxx
✅ Auto-sync complete - device and server are now synchronized
```

### **Test 4: Periodic Two-way Sync**
**What it tests**: Safety net sync every 2 minutes

**Steps**:
1. Connect Device A
2. Create object on Device A
3. Disconnect Device B's network
4. Wait 2+ minutes
5. Reconnect Device B's network

**Expected Results**:
- Device B receives object via periodic sync (not real-time)
- Server logs show: `🔄 Auto-refreshing from API (every 120s)...`

**Debug Logs to Check**:
```
🔄 Auto-refreshing from API (every 120s)...
🔄 Processed coordinate update for object xxx
```

### **Test 5: Offline Mode**
**What it tests**: Full offline functionality with sync on reconnect

**Steps**:
1. Enable offline mode on Device A (Settings → API Sync toggle)
2. Create objects and find items while offline
3. Disable offline mode (back online)
4. Check that all changes synced

**Expected Results**:
- Works completely offline
- On reconnect: `📡 Online mode enabled - connecting to server and WebSocket`
- All local changes sync to server
- Server state syncs to device

**Debug Logs to Check**:
```
📴 Offline mode enabled - using local SQLite database
📡 Online mode enabled - connecting to server and WebSocket
🔄 Syncing X pending finds to server...
```

## 🛠️ Testing Tools

### **WebSocket Monitoring**
```bash
# Monitor WebSocket traffic
cd server
python3 -c "
import socketio
sio = socketio.Client()

@sio.on('*')
def catch_all(event, data):
    print(f'📡 {event}: {data}')

sio.connect('http://localhost:5000')
sio.wait()
"
```

### **Database Monitoring**
```bash
# Watch database changes
cd server
watch -n 2 'sqlite3 cache_raiders.db "SELECT id, name, type FROM objects ORDER BY created_at DESC LIMIT 5;"'
```

### **Server Logs**
```bash
# Monitor server logs for sync events
cd server
tail -f server.log | grep -E "(🔄|📦|✅|object_created|objects_batch)"
```

### **API Testing**
```bash
# Create test object
curl -X POST http://localhost:5000/api/objects \
  -H "Content-Type: application/json" \
  -d '{"id": "test-123", "name": "Test Object", "type": "Chalice", "latitude": 40.0758, "longitude": -105.3008, "radius": 5.0}'

# Check current objects
curl http://localhost:5000/api/objects | jq '. | length'
```

## 🐛 Troubleshooting

### **Issue: Objects not appearing on new device**
- Check: WebSocket connection status in Settings
- Check: Server logs for `objects_batch` emissions
- Check: Device console for `📦 Received batch` messages

### **Issue: Real-time updates not working**
- Check: WebSocket connected (green indicator in Settings)
- Check: Server logs for `object_created` broadcasts
- Check: Device console for `📦 WebSocket: Object created` messages

### **Issue: Periodic sync not working**
- Check: API sync enabled in Settings
- Check: Not in offline mode
- Check: Server logs for `🔄 Auto-refreshing from API` messages

### **Issue: Offline changes not syncing**
- Check: Offline mode properly disabled
- Check: WebSocket reconnects on coming online
- Check: Server logs for sync operations

## 📊 Performance Metrics

Monitor these during testing:
- **Connection time**: How long for `objects_batch` to complete
- **Broadcast latency**: Time from create to appear on other devices
- **Periodic sync duration**: How long the 2-minute sync takes
- **Memory usage**: During batch processing

## 🎯 Success Criteria

- ✅ New devices get all objects within 5 seconds of connecting
- ✅ Object creation appears on other devices within 1 second
- ✅ Offline changes sync within 10 seconds of reconnection
- ✅ Periodic sync completes without errors every 2 minutes
- ✅ No data loss during network interruptions




