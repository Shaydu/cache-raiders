#!/usr/bin/env python3
"""
Test script to verify websocket receives user location updates.
This tests the full flow: update user location via API -> websocket broadcasts -> client receives
"""
import socketio
import requests
import time
import json
import uuid
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

@sio.on('user_location_updated')
def on_user_location_updated(data):
    print(f"\n📨 Received user_location_updated event:")
    print(f"   Device UUID: {data.get('device_uuid')}")
    print(f"   Location: ({data.get('latitude')}, {data.get('longitude')})")
    if data.get('accuracy'):
        print(f"   Accuracy: {data.get('accuracy')}m")
    if data.get('heading'):
        print(f"   Heading: {data.get('heading')}°")
    print(f"   Updated at: {data.get('updated_at')}")
    received_events.append(('user_location_updated', data))

@sio.on('object_created')
def on_object_created(data):
    # Ignore object events for this test
    pass

@sio.on('object_collected')
def on_object_collected(data):
    # Ignore object events for this test
    pass

def test_user_location_websocket():
    """Test updating user location and receiving it via websocket"""
    print("🧪 Testing user location update via API -> Websocket broadcast\n")
    
    # Connect to websocket
    try:
        sio.connect(WS_URL)
        print("✅ Connected to websocket")
        time.sleep(1)  # Give it a moment to establish connection
    except Exception as e:
        print(f"❌ Failed to connect to websocket: {e}")
        return False
    
    # Generate a test device UUID
    test_device_uuid = f"test-device-{uuid.uuid4()}"
    
    # Get an existing object location to place our test location near
    try:
        response = requests.get(f"{SERVER_URL}/api/objects?include_found=true")
        response.raise_for_status()
        objects = response.json()
        
        if not objects or all(obj['latitude'] == 0 and obj['longitude'] == 0 for obj in objects):
            print("⚠️ No valid object locations found. Using default test location.")
            test_lat, test_lon = 40.0758, -105.3008
        else:
            # Use the first valid object's location, offset slightly
            valid_obj = next((obj for obj in objects if obj['latitude'] != 0 or obj['longitude'] != 0), None)
            if valid_obj:
                test_lat = valid_obj['latitude'] + 0.0005  # ~50m offset
                test_lon = valid_obj['longitude'] + 0.0005
                print(f"📍 Found existing object at ({valid_obj['latitude']}, {valid_obj['longitude']})")
                print(f"   Will place test user location nearby...\n")
            else:
                test_lat, test_lon = 40.0758, -105.3008
    except Exception as e:
        print(f"⚠️ Failed to get existing objects, using default location: {e}")
        test_lat, test_lon = 40.0758, -105.3008
    
    # Prepare location update
    location_data = {
        "latitude": test_lat,
        "longitude": test_lon,
        "accuracy": 10.5,  # 10.5 meters accuracy
        "heading": 45.0    # 45 degrees (northeast)
    }
    
    print(f"📤 Sending user location update via API:")
    print(f"   Device UUID: {test_device_uuid}")
    print(f"   Location: ({test_lat}, {test_lon})")
    print(f"   Accuracy: {location_data['accuracy']}m")
    print(f"   Heading: {location_data['heading']}°\n")
    
    try:
        response = requests.post(
            f"{SERVER_URL}/api/users/{test_device_uuid}/location",
            json=location_data,
            headers={"Content-Type": "application/json"}
        )
        response.raise_for_status()
        result = response.json()
        print(f"✅ API Response: {result.get('message', 'Success')}")
        print(f"   Device UUID: {result.get('device_uuid')}")
        print(f"   Location: ({result.get('latitude')}, {result.get('longitude')})\n")
    except Exception as e:
        print(f"❌ Failed to update user location via API: {e}")
        if hasattr(e, 'response') and e.response is not None:
            try:
                print(f"   Response: {e.response.text}")
            except:
                pass
        sio.disconnect()
        return False
    
    # Wait for websocket event (should arrive within 1 second)
    print("⏳ Waiting for websocket broadcast...")
    time.sleep(2)
    
    # Check if we received the event
    location_events = [e for e in received_events if e[0] == 'user_location_updated']
    
    if location_events:
        event_data = location_events[-1][1]
        if event_data.get('device_uuid') == test_device_uuid:
            print("\n✅ SUCCESS! Websocket received the user_location_updated event")
            print(f"   Event data matches sent location")
            
            # Verify the data matches
            if abs(event_data.get('latitude', 0) - test_lat) < 0.0001 and \
               abs(event_data.get('longitude', 0) - test_lon) < 0.0001:
                print(f"   ✅ Location coordinates match")
            else:
                print(f"   ⚠️ Location coordinates don't match exactly")
                print(f"      Expected: ({test_lat}, {test_lon})")
                print(f"      Received: ({event_data.get('latitude')}, {event_data.get('longitude')})")
            
            if event_data.get('accuracy') == location_data['accuracy']:
                print(f"   ✅ Accuracy matches: {event_data.get('accuracy')}m")
            else:
                print(f"   ⚠️ Accuracy mismatch: expected {location_data['accuracy']}, got {event_data.get('accuracy')}")
            
            if event_data.get('heading') == location_data['heading']:
                print(f"   ✅ Heading matches: {event_data.get('heading')}°")
            else:
                print(f"   ⚠️ Heading mismatch: expected {location_data['heading']}, got {event_data.get('heading')}")
            
            success = True
        else:
            print(f"\n⚠️ Received user_location_updated event, but device UUID doesn't match")
            print(f"   Expected: {test_device_uuid}")
            print(f"   Received: {event_data.get('device_uuid')}")
            success = False
    else:
        print("\n❌ FAILED! No user_location_updated event received via websocket")
        print(f"   Total events received: {len(received_events)}")
        if received_events:
            print(f"   Events received: {[e[0] for e in received_events]}")
        success = False
    
    # Test multiple location updates to verify continuous updates work
    if success:
        print("\n🔄 Testing multiple location updates...")
        for i in range(3):
            # Move slightly each time
            new_lat = test_lat + (i + 1) * 0.0001
            new_lon = test_lon + (i + 1) * 0.0001
            
            update_data = {
                "latitude": new_lat,
                "longitude": new_lon,
                "accuracy": 10.5 + i,
                "heading": 45.0 + i * 10
            }
            
            try:
                response = requests.post(
                    f"{SERVER_URL}/api/users/{test_device_uuid}/location",
                    json=update_data,
                    headers={"Content-Type": "application/json"}
                )
                response.raise_for_status()
                print(f"   Update {i+1}: Location ({new_lat:.6f}, {new_lon:.6f})")
            except Exception as e:
                print(f"   ⚠️ Update {i+1} failed: {e}")
            
            time.sleep(0.5)
        
        # Wait for all events
        time.sleep(1)
        
        all_location_events = [e for e in received_events if e[0] == 'user_location_updated']
        print(f"\n   Total location events received: {len(all_location_events)}")
        if len(all_location_events) >= 4:  # Initial + 3 updates
            print(f"   ✅ Multiple location updates working correctly!")
        else:
            print(f"   ⚠️ Expected at least 4 events, got {len(all_location_events)}")
    
    sio.disconnect()
    return success

if __name__ == "__main__":
    success = test_user_location_websocket()
    exit(0 if success else 1)





