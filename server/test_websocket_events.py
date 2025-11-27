#!/usr/bin/env python3
"""
Comprehensive WebSocket test that creates objects and verifies events are received
"""
import socketio
import time
import json
import requests
import sys
from datetime import datetime

# Create a Socket.IO client
sio = socketio.Client()

# Track received events
received_events = []

@sio.event
def connect():
    print("✅ Connected to WebSocket server")
    received_events.append(('connect', datetime.now().isoformat()))

@sio.event
def connected(data):
    print(f"📨 Received 'connected' event: {json.dumps(data, indent=2)}")
    received_events.append(('connected', data))

@sio.event
def object_created(data):
    print(f"📦 Received 'object_created' event:")
    print(f"   {json.dumps(data, indent=2)}")
    received_events.append(('object_created', data))

@sio.event
def object_collected(data):
    print(f"🎯 Received 'object_collected' event:")
    print(f"   {json.dumps(data, indent=2)}")
    received_events.append(('object_collected', data))

@sio.event
def object_uncollected(data):
    print(f"🔄 Received 'object_uncollected' event:")
    print(f"   {json.dumps(data, indent=2)}")
    received_events.append(('object_uncollected', data))

def test_websocket_events():
    """Test WebSocket connection and real-time events"""
    # Get server URL from argument or use network IP
    if len(sys.argv) > 1:
        server_url = sys.argv[1]
    else:
        import socket
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            network_ip = s.getsockname()[0]
            s.close()
            server_url = f"http://{network_ip}:5001"
        except:
            server_url = "http://localhost:5001"
    
    print(f"🔌 Testing WebSocket events on {server_url}")
    print("=" * 60)
    
    try:
        # Connect to the server
        print("\n1. Connecting to WebSocket server...")
        sio.connect(server_url, wait_timeout=5)
        
        if not sio.connected:
            print("❌ Failed to connect to WebSocket server")
            return False
        
        print("✅ Successfully connected!")
        time.sleep(1)  # Wait for connected event
        
        # Test 1: Create an object via REST API and verify websocket event
        print("\n2. Testing 'object_created' event...")
        test_object_id = f"test-ws-{int(time.time())}"
        create_response = requests.post(
            f"{server_url}/api/objects",
            json={
                "id": test_object_id,
                "name": "WebSocket Test Object",
                "type": "Chalice",
                "latitude": 37.7749,
                "longitude": -122.4194,
                "radius": 5.0,
                "created_by": "websocket-test"
            },
            headers={"Content-Type": "application/json"}
        )
        
        if create_response.status_code == 201:
            print(f"   ✅ Created object via REST API: {test_object_id}")
        else:
            print(f"   ⚠️ Failed to create object: {create_response.status_code}")
            print(f"   Response: {create_response.text}")
        
        time.sleep(2)  # Wait for websocket event
        
        # Test 2: Mark object as found and verify websocket event
        print("\n3. Testing 'object_collected' event...")
        collect_response = requests.post(
            f"{server_url}/api/objects/{test_object_id}/found",
            json={"found_by": "websocket-test-user"},
            headers={"Content-Type": "application/json"}
        )
        
        if collect_response.status_code == 200:
            print(f"   ✅ Marked object as found via REST API")
        else:
            print(f"   ⚠️ Failed to mark as found: {collect_response.status_code}")
            print(f"   Response: {collect_response.text}")
        
        time.sleep(2)  # Wait for websocket event
        
        # Test 3: Unmark object and verify websocket event
        print("\n4. Testing 'object_uncollected' event...")
        uncollect_response = requests.delete(
            f"{server_url}/api/objects/{test_object_id}/found",
            headers={"Content-Type": "application/json"}
        )
        
        if uncollect_response.status_code == 200:
            print(f"   ✅ Unmarked object via REST API")
        else:
            print(f"   ⚠️ Failed to unmark: {uncollect_response.status_code}")
        
        time.sleep(2)  # Wait for websocket event
        
        # Cleanup: Delete the test object
        print("\n5. Cleaning up test object...")
        # Note: There's no DELETE endpoint for objects, so we'll leave it
        
        # Summary
        print("\n" + "=" * 60)
        print("📊 Test Summary:")
        print(f"   Connected: {sio.connected}")
        print(f"   Total events received: {len(received_events)}")
        
        # Check which events we received
        event_types = [event[0] for event in received_events]
        print(f"\n   Events received:")
        for event_type in set(event_types):
            count = event_types.count(event_type)
            print(f"   - {event_type}: {count} time(s)")
        
        # Verify we got the expected events
        expected_events = ['object_created', 'object_collected', 'object_uncollected']
        missing_events = [e for e in expected_events if e not in event_types]
        
        if missing_events:
            print(f"\n   ⚠️ Missing events: {', '.join(missing_events)}")
        else:
            print(f"\n   ✅ All expected events received!")
        
        # Disconnect
        print("\n6. Disconnecting...")
        sio.disconnect()
        
        return len(missing_events) == 0
        
    except socketio.exceptions.ConnectionError as e:
        print(f"❌ Connection error: {e}")
        print("   Make sure the server is running")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    print("🧪 CacheRaiders WebSocket Events Test")
    print("=" * 60)
    success = test_websocket_events()
    
    if success:
        print("\n✅ All WebSocket events working correctly!")
        print("   The server is ready for real-time updates.")
    else:
        print("\n❌ Some WebSocket events are missing!")
        print("   Check the server logs for issues.")









