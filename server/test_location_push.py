#!/usr/bin/env python3
"""
Test script to verify websocket receives location updates when objects are created.
This tests the full flow: create object via API -> websocket broadcasts -> client receives
"""
import socketio
import requests
import time
import json
from datetime import datetime

SERVER_URL = "http://localhost:5001"
WS_URL = "http://localhost:5001"

# Create a Socket.IO client
sio = socketio.Client()

# Track received events
received_events = []

@sio.event
def connect():
    print("✅ Connected to websocket server")
    
@sio.event
def disconnect():
    print("❌ Disconnected from websocket server")

@sio.on('object_created')
def on_object_created(data):
    print(f"\n📨 Received object_created event:")
    print(f"   ID: {data.get('id')}")
    print(f"   Name: {data.get('name')}")
    print(f"   Type: {data.get('type')}")
    print(f"   Location: ({data.get('latitude')}, {data.get('longitude')})")
    received_events.append(('object_created', data))

@sio.on('object_collected')
def on_object_collected(data):
    print(f"\n📨 Received object_collected event:")
    print(f"   Object ID: {data.get('object_id')}")
    received_events.append(('object_collected', data))

@sio.on('user_location_updated')
def on_user_location_updated(data):
    print(f"\n📨 Received user_location_updated event:")
    print(f"   Device UUID: {data.get('device_uuid')}")
    print(f"   Location: ({data.get('latitude')}, {data.get('longitude')})")
    received_events.append(('user_location_updated', data))

def test_location_push():
    """Test creating an object and receiving it via websocket"""
    print("🧪 Testing location push via API -> Websocket broadcast\n")
    
    # Connect to websocket
    try:
        sio.connect(WS_URL)
        print("✅ Connected to websocket")
        time.sleep(1)  # Give it a moment to establish connection
    except Exception as e:
        print(f"❌ Failed to connect to websocket: {e}")
        return False
    
    # Get an existing object to place our test object next to
    try:
        response = requests.get(f"{SERVER_URL}/api/objects?include_found=true")
        response.raise_for_status()
        objects = response.json()
        
        if not objects:
            print("⚠️ No existing objects found. Creating one at default location.")
            base_lat, base_lon = 40.0758, -105.3008
        else:
            # Use the first object's location
            base_lat = objects[0]['latitude']
            base_lon = objects[0]['longitude']
            print(f"📍 Found existing object at ({base_lat}, {base_lon})")
            print(f"   Will create test object nearby...\n")
    except Exception as e:
        print(f"❌ Failed to get existing objects: {e}")
        sio.disconnect()
        return False
    
    # Create a new object slightly offset from the existing one
    # Offset by ~0.001 degrees (roughly 100 meters)
    test_id = f"test-ws-push-{int(time.time())}"
    test_lat = base_lat + 0.001
    test_lon = base_lon + 0.001
    
    test_object = {
        "id": test_id,
        "name": "WebSocket Test Object",
        "type": "Treasure Chest",
        "latitude": test_lat,
        "longitude": test_lon,
        "radius": 5.0,
        "created_by": "test-script"
    }
    
    print(f"📤 Creating test object via API:")
    print(f"   ID: {test_id}")
    print(f"   Name: {test_object['name']}")
    print(f"   Location: ({test_lat}, {test_lon})")
    print(f"   (Offset by ~100m from existing object)\n")
    
    try:
        response = requests.post(
            f"{SERVER_URL}/api/objects",
            json=test_object,
            headers={"Content-Type": "application/json"}
        )
        response.raise_for_status()
        result = response.json()
        print(f"✅ API Response: {result.get('message', 'Success')}")
        print(f"   Created object ID: {result.get('id', test_id)}\n")
    except Exception as e:
        print(f"❌ Failed to create object via API: {e}")
        sio.disconnect()
        return False
    
    # Wait for websocket event (should arrive within 1 second)
    print("⏳ Waiting for websocket broadcast...")
    time.sleep(2)
    
    # Check if we received the event
    object_created_events = [e for e in received_events if e[0] == 'object_created']
    
    if object_created_events:
        event_data = object_created_events[-1][1]
        if event_data.get('id') == test_id:
            print("\n✅ SUCCESS! Websocket received the object_created event")
            print(f"   Event data matches created object")
            success = True
        else:
            print(f"\n⚠️ Received object_created event, but ID doesn't match")
            print(f"   Expected: {test_id}")
            print(f"   Received: {event_data.get('id')}")
            success = False
    else:
        print("\n❌ FAILED! No object_created event received via websocket")
        print(f"   Total events received: {len(received_events)}")
        success = False
    
    # Cleanup: delete the test object
    try:
        print(f"\n🧹 Cleaning up test object...")
        response = requests.delete(f"{SERVER_URL}/api/objects/{test_id}")
        if response.status_code == 200:
            print(f"✅ Test object deleted")
        else:
            print(f"⚠️ Failed to delete test object (status: {response.status_code})")
    except Exception as e:
        print(f"⚠️ Error during cleanup: {e}")
    
    sio.disconnect()
    return success

if __name__ == "__main__":
    success = test_location_push()
    exit(0 if success else 1)




