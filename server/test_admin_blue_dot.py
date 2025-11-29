#!/usr/bin/env python3
"""
Test script to verify blue dot appears in admin interface.
1. Sends a test user location via API
2. Verifies it appears in /api/users/locations endpoint
3. Instructions for checking admin.html
"""
import requests
import time
import uuid
import json

SERVER_URL = "http://localhost:5001"

def test_admin_blue_dot():
    """Test that user location appears in admin interface"""
    print("🧪 Testing Blue Dot in Admin Interface\n")
    
    # Generate a test device UUID
    test_device_uuid = f"test-device-{uuid.uuid4()}"
    test_player_name = f"Test User {int(time.time())}"
    
    # Step 1: Create a player name for this device
    print("Step 1: Creating player name...")
    try:
        response = requests.post(
            f"{SERVER_URL}/api/players/{test_device_uuid}",
            json={"player_name": test_player_name},
            headers={"Content-Type": "application/json"}
        )
        if response.status_code in [200, 201]:
            print(f"✅ Player created: {test_player_name}")
        else:
            print(f"⚠️ Player creation returned status {response.status_code}")
    except Exception as e:
        print(f"⚠️ Failed to create player (may already exist): {e}")
    
    # Step 2: Get an existing object location to place our test location near
    print("\nStep 2: Finding a location near existing objects...")
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
                print(f"   Placing test user at ({test_lat}, {test_lon}) - about 50m away")
            else:
                test_lat, test_lon = 40.0758, -105.3008
    except Exception as e:
        print(f"⚠️ Failed to get existing objects, using default location: {e}")
        test_lat, test_lon = 40.0758, -105.3008
    
    # Step 3: Send location update
    print(f"\nStep 3: Sending user location update...")
    location_data = {
        "latitude": test_lat,
        "longitude": test_lon,
        "accuracy": 10.5,
        "heading": 45.0
    }
    
    try:
        response = requests.post(
            f"{SERVER_URL}/api/users/{test_device_uuid}/location",
            json=location_data,
            headers={"Content-Type": "application/json"}
        )
        response.raise_for_status()
        result = response.json()
        print(f"✅ Location update sent successfully")
        print(f"   Device UUID: {test_device_uuid}")
        print(f"   Location: ({test_lat}, {test_lon})")
        print(f"   Accuracy: {location_data['accuracy']}m")
        print(f"   Heading: {location_data['heading']}°")
    except Exception as e:
        print(f"❌ Failed to send location update: {e}")
        if hasattr(e, 'response') and e.response is not None:
            try:
                print(f"   Response: {e.response.text}")
            except:
                pass
        return False
    
    # Step 4: Verify location appears in API
    print(f"\nStep 4: Verifying location appears in /api/users/locations...")
    time.sleep(0.5)  # Give server a moment to process
    
    try:
        response = requests.get(f"{SERVER_URL}/api/users/locations")
        response.raise_for_status()
        locations = response.json()
        
        if test_device_uuid in locations:
            loc = locations[test_device_uuid]
            print(f"✅ Location found in API!")
            print(f"   Latitude: {loc['latitude']}")
            print(f"   Longitude: {loc['longitude']}")
            print(f"   Accuracy: {loc.get('accuracy', 'N/A')}")
            print(f"   Heading: {loc.get('heading', 'N/A')}")
            print(f"   Updated at: {loc.get('updated_at', 'N/A')}")
        else:
            print(f"❌ Location not found in API")
            print(f"   Available device UUIDs: {list(locations.keys())[:5]}...")
            return False
    except Exception as e:
        print(f"❌ Failed to verify location: {e}")
        return False
    
    # Step 5: Instructions for checking admin interface
    print(f"\n" + "="*60)
    print(f"✅ TEST COMPLETE - Blue dot should appear in admin interface")
    print(f"="*60)
    print(f"\nTo verify in admin interface:")
    print(f"1. Open http://localhost:5001/admin.html in your browser")
    print(f"2. Look for a blue dot marker on the map")
    print(f"3. The blue dot should be labeled: '{test_player_name}'")
    print(f"4. Click the blue dot to see location details")
    print(f"5. The location should be near existing object markers")
    print(f"\nDevice UUID: {test_device_uuid}")
    print(f"Player Name: {test_player_name}")
    print(f"Location: ({test_lat}, {test_lon})")
    print(f"\nThe admin interface refreshes user locations every 10 seconds.")
    print(f"If you don't see it immediately, wait up to 10 seconds.")
    print(f"="*60)
    
    return True

if __name__ == "__main__":
    success = test_admin_blue_dot()
    exit(0 if success else 1)





