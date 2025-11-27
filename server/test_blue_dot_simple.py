#!/usr/bin/env python3
"""
Simple test to create a blue dot in admin interface.
Run this script, then check admin.html - the blue dot should appear.
"""
import requests
import time
import uuid

SERVER_URL = "http://localhost:5001"

def main():
    print("🧪 Creating test blue dot for admin interface\n")
    
    # Use a simple test device UUID
    device_uuid = "test-blue-dot-user"
    player_name = "Test Blue Dot User"
    
    # Step 1: Create player name
    print(f"1. Creating player: {player_name}")
    try:
        requests.post(
            f"{SERVER_URL}/api/players/{device_uuid}",
            json={"player_name": player_name},
            headers={"Content-Type": "application/json"}
        )
        print("   ✅ Player created")
    except Exception as e:
        print(f"   ⚠️ {e}")
    
    # Step 2: Get a location near existing objects
    print("\n2. Finding location near existing objects...")
    try:
        response = requests.get(f"{SERVER_URL}/api/objects?include_found=true")
        objects = response.json() if response.ok else []
        
        # Find first object with valid coordinates
        valid_obj = next((obj for obj in objects if obj.get('latitude', 0) != 0 or obj.get('longitude', 0) != 0), None)
        
        if valid_obj:
            # Place blue dot slightly offset from object
            lat = valid_obj['latitude'] + 0.0003  # ~30m away
            lon = valid_obj['longitude'] + 0.0003
            print(f"   📍 Found object at ({valid_obj['latitude']}, {valid_obj['longitude']})")
            print(f"   📍 Placing blue dot at ({lat}, {lon})")
        else:
            # Default location
            lat, lon = 40.0758, -105.3008
            print(f"   📍 Using default location ({lat}, {lon})")
    except Exception as e:
        lat, lon = 40.0758, -105.3008
        print(f"   ⚠️ Using default location: {e}")
    
    # Step 3: Send location update
    print(f"\n3. Sending location update...")
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
            print("   ✅ Location update sent successfully!")
            print(f"   📍 Blue dot should appear at ({lat}, {lon})")
        elif response.status_code == 404:
            print("   ❌ 404 Error - Server route not found")
            print("   💡 The server may need to be restarted to register the route")
            print("   💡 Check that app.py has the route: /api/users/<device_uuid>/location")
            return False
        else:
            print(f"   ❌ Error: HTTP {response.status_code}")
            print(f"   Response: {response.text[:200]}")
            return False
    except requests.exceptions.ConnectionError:
        print("   ❌ Connection error - Is the server running?")
        print(f"   💡 Start server with: cd server && python3 app.py")
        return False
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False
    
    # Step 4: Verify location was stored
    print(f"\n4. Verifying location was stored...")
    time.sleep(0.5)
    try:
        response = requests.get(f"{SERVER_URL}/api/users/locations", timeout=5)
        if response.ok:
            locations = response.json()
            if device_uuid in locations:
                print("   ✅ Location found in API!")
                loc = locations[device_uuid]
                print(f"   📍 ({loc['latitude']}, {loc['longitude']})")
            else:
                print(f"   ⚠️ Location not found yet (may take a moment)")
                print(f"   Available UUIDs: {list(locations.keys())[:3]}")
        else:
            print(f"   ⚠️ Could not verify (HTTP {response.status_code})")
    except Exception as e:
        print(f"   ⚠️ Could not verify: {e}")
    
    print(f"\n" + "="*60)
    print(f"✅ TEST COMPLETE")
    print(f"="*60)
    print(f"\nNext steps:")
    print(f"1. Open http://localhost:5001/admin.html in your browser")
    print(f"2. Look for a BLUE DOT on the map")
    print(f"3. The blue dot should be labeled: '{player_name}'")
    print(f"4. Click the blue dot to see location details")
    print(f"\nIf you don't see the blue dot:")
    print(f"- Wait up to 10 seconds (admin refreshes every 10s)")
    print(f"- Or refresh the admin page")
    print(f"- Check browser console for errors")
    print(f"- Verify server is running: curl http://localhost:5001/health")
    print(f"="*60)
    
    return True

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)


