#!/usr/bin/env python3
"""
Quick script to send a blue dot location update.
Usage: python3 send_blue_dot.py
"""
import requests
import uuid

SERVER_URL = "http://localhost:5001"

# Coordinates near existing pins
LAT = 40.075991  # ~20m north of 40.075791
LON = -105.300631  # ~20m east of -105.300831

device_uuid = f"test-blue-dot-{uuid.uuid4()}"
player_name = "Test Blue Dot"

print(f"🧪 Sending blue dot location update...")
print(f"   Location: ({LAT}, {LON})")
print(f"   Device UUID: {device_uuid}")
print(f"   Player Name: {player_name}\n")

# Create player
try:
    requests.post(
        f"{SERVER_URL}/api/players/{device_uuid}",
        json={"player_name": player_name},
        headers={"Content-Type": "application/json"},
        timeout=2
    )
except:
    pass  # Ignore errors

# Send location update
try:
    response = requests.post(
        f"{SERVER_URL}/api/users/{device_uuid}/location",
        json={
            "latitude": LAT,
            "longitude": LON,
            "accuracy": 10.5,
            "heading": 45.0
        },
        headers={"Content-Type": "application/json"},
        timeout=2
    )
    
    if response.status_code == 200:
        print("✅ Location update sent successfully!")
        print(f"   Blue dot should appear in admin interface at ({LAT}, {LON})")
        print(f"\n   Open http://localhost:5001/admin.html to see it")
    elif response.status_code == 404:
        print("❌ 404 Error - Server route not found")
        print("   💡 The server needs to be restarted to register the route")
        print("   💡 Stop the server (Ctrl+C) and restart with: python3 app.py")
    else:
        print(f"❌ Error: HTTP {response.status_code}")
        print(f"   Response: {response.text[:200]}")
except requests.exceptions.ConnectionError:
    print("❌ Connection error - Is the server running?")
    print("   💡 Start server with: cd server && python3 app.py")
except Exception as e:
    print(f"❌ Error: {e}")





