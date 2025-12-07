#!/usr/bin/env python3
"""
Sync System Testing Script
Tests WebSocket object sync, real-time broadcasts, and periodic sync
"""

import requests
import socketio
import time
import json
import threading
import sys
from datetime import datetime

SERVER_URL = "http://localhost:5000"
WS_URL = "http://localhost:5000"

class SyncTester:
    def __init__(self):
        self.sio = socketio.Client()
        self.connected = False
        self.received_events = []
        self.test_results = {}

        # Set up event handlers
        self.setup_event_handlers()

    def setup_event_handlers(self):
        @self.sio.on('connect')
        def on_connect():
            print("🔌 Connected to WebSocket")
            self.connected = True

        @self.sio.on('disconnect')
        def on_disconnect():
            print("🔌 Disconnected from WebSocket")
            self.connected = False

        @self.sio.on('connected')
        def on_connected(data):
            print(f"📡 Server confirmed connection: {data}")

        @self.sio.on('objects_batch')
        def on_objects_batch(data):
            batch_info = f"batch_{data['batch_index'] + 1}_{data['total_batches']}"
            object_count = len(data['objects'])
            print(f"📦 Received {batch_info}: {object_count} objects")
            self.received_events.append(('objects_batch', data))

            if data['is_last_batch']:
                total_objects = sum(len(event[1]['objects']) for event in self.received_events
                               if event[0] == 'objects_batch')
                print(f"✅ All object batches received. Total: {total_objects} objects")
                self.test_results['objects_received'] = total_objects

        @self.sio.on('object_created')
        def on_object_created(data):
            print(f"📦 Real-time: Object created - {data.get('name')} ({data.get('id')})")
            self.received_events.append(('object_created', data))

        @self.sio.on('object_collected')
        def on_object_collected(data):
            print(f"✅ Real-time: Object collected - {data.get('object_id')}")
            self.received_events.append(('object_collected', data))

    def connect(self):
        """Connect to WebSocket"""
        print("🔌 Connecting to WebSocket...")
        try:
            self.sio.connect(WS_URL)
            # Wait for connection
            timeout = 10
            while not self.connected and timeout > 0:
                time.sleep(0.5)
                timeout -= 0.5
            return self.connected
        except Exception as e:
            print(f"❌ WebSocket connection failed: {e}")
            return False

    def disconnect(self):
        """Disconnect from WebSocket"""
        if self.connected:
            self.sio.disconnect()

    def wait_for_events(self, event_type, timeout=10):
        """Wait for specific event type"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            events = [e for e in self.received_events if e[0] == event_type]
            if events:
                return events
            time.sleep(0.1)
        return []

def test_websocket_sync():
    """Test 1: WebSocket object sync on connect"""
    print("\n" + "="*60)
    print("🧪 TEST 1: WebSocket Object Sync on Connect")
    print("="*60)

    tester = SyncTester()

    # Connect and wait for objects
    if tester.connect():
        print("✅ Connected successfully")

        # Wait for object batches
        time.sleep(3)  # Give time for batches to arrive

        # Check results
        object_events = [e for e in tester.received_events if e[0] == 'objects_batch']
        total_objects = sum(len(event[1]['objects']) for event in object_events)

        print(f"📊 Results: {len(object_events)} batches, {total_objects} total objects")

        if total_objects > 0:
            print("✅ PASS: Received objects on connect")
            return True
        else:
            print("❌ FAIL: No objects received")
            return False
    else:
        print("❌ FAIL: Could not connect")
        return False

    tester.disconnect()
    return False

def test_realtime_broadcast():
    """Test 2: Real-time object creation broadcast"""
    print("\n" + "="*60)
    print("🧪 TEST 2: Real-time Object Creation Broadcast")
    print("="*60)

    # Create object via API
    object_data = {
        "id": f"test-sync-{int(time.time())}",
        "name": "Test Sync Object",
        "type": "Chalice",
        "latitude": 40.0758,
        "longitude": -105.3008,
        "radius": 5.0
    }

    tester = SyncTester()

    if not tester.connect():
        print("❌ FAIL: Could not connect for broadcast test")
        return False

    # Clear previous events
    tester.received_events = []

    # Create object
    print(f"📤 Creating test object: {object_data['name']}")
    response = requests.post(f"{SERVER_URL}/api/objects", json=object_data)

    if response.status_code == 200:
        print("✅ Object created via API")

        # Wait for broadcast
        time.sleep(2)

        # Check for object_created event
        created_events = [e for e in tester.received_events if e[0] == 'object_created']
        if created_events:
            event_data = created_events[0][1]
            if event_data.get('id') == object_data['id']:
                print("✅ PASS: Real-time broadcast received")
                tester.disconnect()
                return True
            else:
                print("❌ FAIL: Wrong object ID in broadcast")
                tester.disconnect()
                return False
        else:
            print("❌ FAIL: No object_created broadcast received")
            tester.disconnect()
            return False
    else:
        print(f"❌ FAIL: API creation failed: {response.status_code}")
        tester.disconnect()
        return False

def test_periodic_sync():
    """Test 3: Verify periodic sync is running"""
    print("\n" + "="*60)
    print("🧪 TEST 3: Periodic Sync Verification")
    print("="*60)

    # This is harder to test automatically, but we can check the server logs
    # and database state over time
    print("📊 Periodic sync runs every 120 seconds (2 minutes)")
    print("   To test manually:")
    print("   1. Create an object on one device")
    print("   2. Wait 2+ minutes")
    print("   3. Check if other devices received it via periodic sync")
    print("   4. Check server logs for 'Auto-refreshing from API' messages")

    return "manual_test_required"

def main():
    """Run all sync tests"""
    print("🚀 CacheRaiders Sync System Test Suite")
    print("======================================")

    # Check server is running
    try:
        response = requests.get(f"{SERVER_URL}/health", timeout=5)
        if response.status_code != 200:
            print("❌ Server not responding. Start server first:")
            print("   cd server && python3 app.py")
            return
    except:
        print("❌ Cannot connect to server. Start server first:")
        print("   cd server && python3 app.py")
        return

    print("✅ Server is running")

    results = {}

    # Test 1: WebSocket sync on connect
    results['websocket_sync'] = test_websocket_sync()

    # Test 2: Real-time broadcasts
    results['realtime_broadcast'] = test_realtime_broadcast()

    # Test 3: Periodic sync (manual)
    results['periodic_sync'] = test_periodic_sync()

    # Summary
    print("\n" + "="*60)
    print("📊 TEST RESULTS SUMMARY")
    print("="*60)

    for test_name, result in results.items():
        status = "✅ PASS" if result == True else "❌ FAIL" if result == False else "📝 MANUAL"
        print(f"   {test_name}: {status}")

    print("\n🔧 Manual Testing Instructions:")
    print("   1. Run two iOS simulators/devices")
    print("   2. Connect both to the same server")
    print("   3. Create objects on one device")
    print("   4. Verify they appear on the other device")
    print("   5. Test offline mode: disconnect network, find objects, reconnect")

if __name__ == "__main__":
    main()
