#!/usr/bin/env python3
"""
Test script to verify WebSocket functionality for CacheRaiders API
Tests connection, events, and real-time updates
"""
import socketio
import time
import json
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
def disconnect():
    print("❌ Disconnected from WebSocket server")
    received_events.append(('disconnect', datetime.now().isoformat()))

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

@sio.event
def pong(data):
    print(f"🏓 Received 'pong' event: {json.dumps(data, indent=2)}")
    received_events.append(('pong', data))

def test_websocket():
    """Test WebSocket connection and events"""
    import sys
    # Allow server URL to be passed as argument, or use network IP
    if len(sys.argv) > 1:
        server_url = sys.argv[1]
    else:
        # Try to detect network IP, fallback to localhost
        import socket
        try:
            # Connect to a remote address to get local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            network_ip = s.getsockname()[0]
            s.close()
            server_url = f"http://{network_ip}:5001"
            print(f"🌐 Detected network IP: {network_ip}")
        except:
            server_url = "http://localhost:5001"
            print("⚠️ Could not detect network IP, using localhost")
    
    print(f"🔌 Testing WebSocket connection to {server_url}")
    print("=" * 60)
    
    try:
        # Connect to the server
        print("\n1. Connecting to WebSocket server...")
        sio.connect(server_url, wait_timeout=5)
        
        if not sio.connected:
            print("❌ Failed to connect to WebSocket server")
            return False
        
        print("✅ Successfully connected!")
        
        # Wait a moment for the 'connected' event
        time.sleep(1)
        
        # Test ping/pong
        print("\n2. Testing ping/pong...")
        sio.emit('ping')
        time.sleep(1)
        
        # Test listening for events (we'll trigger these via REST API)
        print("\n3. Listening for events (will test with REST API calls)...")
        print("   You can now create/collect objects via REST API to see events")
        print("   Waiting 10 seconds to receive any events...")
        
        time.sleep(10)
        
        # Summary
        print("\n" + "=" * 60)
        print("📊 Test Summary:")
        print(f"   Connected: {sio.connected}")
        print(f"   Events received: {len(received_events)}")
        
        if received_events:
            print("\n   Event log:")
            for event_name, event_data in received_events:
                if isinstance(event_data, dict):
                    print(f"   - {event_name}: {json.dumps(event_data)}")
                else:
                    print(f"   - {event_name}: {event_data}")
        
        # Disconnect
        print("\n4. Disconnecting...")
        sio.disconnect()
        
        return True
        
    except socketio.exceptions.ConnectionError as e:
        print(f"❌ Connection error: {e}")
        print("   Make sure the server is running on port 5001")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

if __name__ == "__main__":
    print("🧪 CacheRaiders WebSocket Test")
    print("=" * 60)
    success = test_websocket()
    
    if success:
        print("\n✅ WebSocket test completed successfully!")
        print("\n💡 To test real-time events:")
        print("   1. Keep this script running")
        print("   2. In another terminal, create an object:")
        print("      curl -X POST http://localhost:5001/api/objects \\")
        print("        -H 'Content-Type: application/json' \\")
        print("        -d '{\"id\":\"test-ws\",\"name\":\"Test\",\"type\":\"Chalice\",")
        print("             \"latitude\":37.7749,\"longitude\":-122.4194,\"radius\":5.0}'")
        print("   3. Mark it as found:")
        print("      curl -X POST http://localhost:5001/api/objects/test-ws/found \\")
        print("        -H 'Content-Type: application/json' \\")
        print("        -d '{\"found_by\":\"test-user\"}'")
    else:
        print("\n❌ WebSocket test failed!")
        print("   Make sure the server is running:")
        print("   cd server && python app.py")

