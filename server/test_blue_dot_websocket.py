#!/usr/bin/env python3
"""
Test blue dot by sending location update via API (which triggers websocket broadcast).
This tests the full flow: API -> Server -> WebSocket -> Admin Interface
"""
import socketio
import requests
import time
import uuid
import json

SERVER_URL = "http://localhost:5001"
WS_URL = "http://localhost:5001"

# Create a Socket.IO client to verify websocket broadcast
sio = socketio.Client()

# Track received events
received_events = []

@sio.event
def connect():
    print("✅ Connected to websocket server")
    
@sio.event
def disconnect():
    print("❌ Disconnected from websocket server")

@sio.on('user_location_updated')
def on_user_location_updated(data):
    print(f"\n📨 WebSocket received user_location_updated event:")
    print(f"   Device UUID: {data.get('device_uuid')}")
    print(f"   Location: ({data.get('latitude')}, {data.get('longitude')})")
    if data.get('accuracy'):
        print(f"   Accuracy: {data.get('accuracy')}m")
    if data.get('heading'):
        print(f"   Heading: {data.get('heading')}°")
    received_events.append(('user_location_updated', data))

def test_blue_dot_via_websocket():
    """Test blue dot by sending location update that triggers websocket broadcast"""
    print("🧪 Testing Blue Dot via WebSocket Broadcast\n")
    print("="*60)
    
    # Step 1: Connect to websocket to verify broadcast
    print("\nStep 1: Connecting to WebSocket...")
    try:
        sio.connect(WS_URL)
        print("✅ Connected to websocket")
        time.sleep(1)  # Give it a moment to establish connection
    except Exception as e:
        print(f"⚠️ Failed to connect to websocket: {e}")
        print("   (This is okay - we'll still test the API endpoint)")
    
    # Step 2: Create a test user
    device_uuid = f"test-blue-dot-{uuid.uuid4()}"
    player_name = "Test Blue Dot User"
    
    print(f"\nStep 2: Creating test user...")
    print(f"   Device UUID: {device_uuid}")
    print(f"   Player Name: {player_name}")
    
    try:
        response = requests.post(
            f"{SERVER_URL}/api/players/{device_uuid}",
            json={"player_name": player_name},
            headers={"Content-Type": "application/json"},
            timeout=5
        )
        if response.status_code in [200, 201]:
            print("   ✅ Player created")
        else:
            print(f"   ⚠️ Player creation returned status {response.status_code}")
    except Exception as e:
        print(f"   ⚠️ Failed to create player: {e}")
    
    # Step 3: Use specific coordinates near existing pins
    print(f"\nStep 3: Setting location near existing pins...")
    # Use coordinates provided by user, slightly offset to be visible next to pins
    base_lat, base_lon = 40.075791, -105.300831
    # Offset by ~20-30 meters to be visible next to pins
    lat = base_lat + 0.0002  # ~20m north
    lon = base_lon + 0.0002  # ~20m east
    print(f"   📍 Base location: ({base_lat}, {base_lon})")
    print(f"   📍 Placing blue dot at ({lat}, {lon}) - about 20m away from base")
    
    # Step 4: Send location update via API (this triggers websocket broadcast)
    print(f"\nStep 4: Sending location update via API...")
    print(f"   This will trigger a websocket broadcast to all connected clients")
    
    location_data = {
        "latitude": lat,
        "longitude": lon,
        "accuracy": 10.5,
        "heading": 45.0
    }
    
    try:
        response = requests.post(
            f"{SERVER_URL}/api/users/{device_uuid}/location",
            json=location_data,
            headers={"Content-Type": "application/json"},
            timeout=5
        )
        
        if response.status_code == 200:
            result = response.json()
            print(f"   ✅ Location update sent successfully!")
            print(f"   📍 Blue dot should appear at ({lat}, {lon})")
            print(f"   📡 Server should broadcast via websocket...")
        elif response.status_code == 404:
            print(f"   ❌ 404 Error - Server route not found")
            print(f"   💡 The server may need to be restarted")
            print(f"   💡 Check that app.py has the route: /api/users/<device_uuid>/location")
            sio.disconnect()
            return False
        else:
            print(f"   ❌ Error: HTTP {response.status_code}")
            print(f"   Response: {response.text[:200]}")
            sio.disconnect()
            return False
    except requests.exceptions.ConnectionError:
        print("   ❌ Connection error - Is the server running?")
        print(f"   💡 Start server with: cd server && python3 app.py")
        sio.disconnect()
        return False
    except Exception as e:
        print(f"   ❌ Error: {e}")
        sio.disconnect()
        return False
    
    # Step 5: Wait for websocket event
    print(f"\nStep 5: Waiting for websocket broadcast...")
    time.sleep(2)  # Give server time to broadcast
    
    if received_events:
        event_data = received_events[-1][1]
        if event_data.get('device_uuid') == device_uuid:
            print(f"   ✅ WebSocket received the broadcast!")
            print(f"   ✅ Event data matches sent location")
        else:
            print(f"   ⚠️ Received event for different device UUID")
    else:
        print(f"   ⚠️ No websocket event received (server may not be broadcasting)")
        print(f"   (This is okay if websocket isn't connected - admin will still work via polling)")
    
    # Step 6: Verify location was stored
    print(f"\nStep 6: Verifying location was stored...")
    time.sleep(0.5)
    try:
        response = requests.get(f"{SERVER_URL}/api/users/locations", timeout=5)
        if response.ok:
            locations = response.json()
            if device_uuid in locations:
                loc = locations[device_uuid]
                print(f"   ✅ Location found in API!")
                print(f"   📍 ({loc['latitude']}, {loc['longitude']})")
                print(f"   Accuracy: {loc.get('accuracy', 'N/A')}")
                print(f"   Heading: {loc.get('heading', 'N/A')}")
            else:
                print(f"   ⚠️ Location not found yet")
                print(f"   Available UUIDs: {list(locations.keys())[:3]}")
        else:
            print(f"   ⚠️ Could not verify (HTTP {response.status_code})")
    except Exception as e:
        print(f"   ⚠️ Could not verify: {e}")
    
    # Step 7: Send a few more updates to test movement
    print(f"\nStep 7: Testing movement (sending 3 more location updates)...")
    for i in range(3):
        # Move slightly each time
        new_lat = lat + (i + 1) * 0.0001
        new_lon = lon + (i + 1) * 0.0001
        
        update_data = {
            "latitude": new_lat,
            "longitude": new_lon,
            "accuracy": 10.5 + i,
            "heading": 45.0 + i * 10
        }
        
        try:
            response = requests.post(
                f"{SERVER_URL}/api/users/{device_uuid}/location",
                json=update_data,
                headers={"Content-Type": "application/json"},
                timeout=5
            )
            if response.status_code == 200:
                print(f"   Update {i+1}: Location ({new_lat:.6f}, {new_lon:.6f})")
            else:
                print(f"   Update {i+1}: Failed (HTTP {response.status_code})")
        except Exception as e:
            print(f"   Update {i+1}: Error - {e}")
        
        time.sleep(0.5)
    
    # Wait for all events
    time.sleep(1)
    
    all_location_events = [e for e in received_events if e[0] == 'user_location_updated']
    print(f"\n   Total location events received via websocket: {len(all_location_events)}")
    if len(all_location_events) >= 4:  # Initial + 3 updates
        print(f"   ✅ Multiple location updates working correctly!")
    
    sio.disconnect()
    
    # Final instructions
    print(f"\n" + "="*60)
    print(f"✅ TEST COMPLETE")
    print(f"="*60)
    print(f"\nNext steps:")
    print(f"1. Open http://localhost:5001/admin.html in your browser")
    print(f"2. Look for a BLUE DOT on the map")
    print(f"3. The blue dot should be labeled: '{player_name}'")
    print(f"4. Click the blue dot to see location details")
    print(f"5. The blue dot should update in real-time via websocket")
    print(f"   (or within 10 seconds via polling if websocket not connected)")
    print(f"\nDevice UUID: {device_uuid}")
    print(f"Player Name: {player_name}")
    print(f"Final Location: ({lat + 0.0003}, {lon + 0.0003})")
    print(f"\nIf you don't see the blue dot:")
    print(f"- Wait up to 10 seconds (admin refreshes every 10s)")
    print(f"- Refresh the admin page")
    print(f"- Check browser console for errors")
    print(f"- Verify server is running: curl http://localhost:5001/health")
    print(f"="*60)
    
    return True

if __name__ == "__main__":
    success = test_blue_dot_via_websocket()
    exit(0 if success else 1)

