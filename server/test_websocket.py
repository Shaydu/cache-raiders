#!/usr/bin/env python3
"""Test WebSocket/Socket.IO connection to the server"""

import socketio
import time
import sys

def test_socketio_connection(server_url):
    """Test Socket.IO connection to server"""
    print(f"🧪 Testing Socket.IO connection to {server_url}")
    print("=" * 60)
    
    # Create Socket.IO client
    sio = socketio.Client(logger=True, engineio_logger=True)
    
    connected = False
    error_msg = None
    
    @sio.event
    def connect():
        nonlocal connected
        connected = True
        print("✅ Connected to server!")
        print(f"   Session ID: {sio.sid}")
    
    @sio.event
    def disconnect():
        print("⚠️  Disconnected from server")
    
    @sio.event
    def connect_error(data):
        nonlocal error_msg
        error_msg = str(data)
        print(f"❌ Connection error: {data}")
    
    try:
        print(f"\n1. Attempting connection to {server_url}...")
        sio.connect(server_url, transports=['websocket'])
        
        print("\n2. Waiting for connection confirmation...")
        time.sleep(2)
        
        if connected:
            print("\n✅ SUCCESS! WebSocket connection is working!")
            print(f"   Server URL: {server_url}")
            print(f"   Session ID: {sio.sid}")
            print(f"   Transport: {sio.transport()}")
            
            # Test sending a message
            print("\n3. Testing message send...")
            device_uuid = "test-device-12345"
            sio.emit('register_device', {'device_uuid': device_uuid})
            print(f"   ✅ Sent register_device event")
            
            time.sleep(1)
            
            print("\n4. Disconnecting...")
            sio.disconnect()
            print("   ✅ Disconnected cleanly")
            
            return True
        else:
            print(f"\n❌ FAILED: Could not establish connection")
            if error_msg:
                print(f"   Error: {error_msg}")
            return False
            
    except Exception as e:
        print(f"\n❌ EXCEPTION: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        if sio.connected:
            sio.disconnect()

if __name__ == "__main__":
    # Test the server
    server_url = sys.argv[1] if len(sys.argv) > 1 else "http://192.168.1.74:5001"
    
    print("🔍 Socket.IO WebSocket Connection Test")
    print("=" * 60)
    print(f"Server URL: {server_url}")
    print("=" * 60)
    print()
    
    success = test_socketio_connection(server_url)
    
    print("\n" + "=" * 60)
    if success:
        print("✅ TEST PASSED - WebSocket connection works!")
        print("\nIf iOS still fails, the issue is likely:")
        print("  • iOS app using wrong URL (check Settings)")
        print("  • iOS network restrictions")
        print("  • iOS app not on same WiFi network")
        sys.exit(0)
    else:
        print("❌ TEST FAILED - WebSocket connection does not work")
        print("\nPossible issues:")
        print("  • Server not running")
        print("  • Wrong IP address")
        print("  • Firewall blocking connections")
        print("  • Socket.IO not properly configured")
        sys.exit(1)
