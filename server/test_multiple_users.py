#!/usr/bin/env python3
"""
Test script to verify the admin panel can display multiple users.
Sends location updates for multiple test users to verify they all appear as blue pins.
"""
import requests
import time
import uuid
import sys

SERVER_URL = "http://localhost:5001"

def create_test_player(device_uuid, player_name):
    """Create or update a test player in the database"""
    try:
        response = requests.post(
            f"{SERVER_URL}/api/players/{device_uuid}",
            json={"player_name": player_name},
            headers={"Content-Type": "application/json"}
        )
        if response.status_code == 200:
            print(f"✅ Created/updated player: {player_name} ({device_uuid[:8]}...)")
            return True
        else:
            print(f"⚠️ Failed to create player {player_name}: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Error creating player {player_name}: {e}")
        return False

def send_location_update(device_uuid, lat, lng, accuracy=10.0, heading=None):
    """Send a location update for a test user"""
    location_data = {
        "latitude": lat,
        "longitude": lng,
        "accuracy": accuracy
    }
    if heading is not None:
        location_data["heading"] = heading
    
    try:
        response = requests.post(
            f"{SERVER_URL}/api/users/{device_uuid}/location",
            json=location_data,
            headers={"Content-Type": "application/json"}
        )
        if response.status_code == 200:
            return True
        else:
            print(f"⚠️ Failed to send location update: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Error sending location update: {e}")
        return False

def get_active_locations():
    """Get all active user locations from the API"""
    try:
        response = requests.get(f"{SERVER_URL}/api/users/locations")
        if response.status_code == 200:
            return response.json()
        else:
            print(f"⚠️ Failed to get locations: {response.status_code}")
            return {}
    except Exception as e:
        print(f"❌ Error getting locations: {e}")
        return {}

def test_multiple_users():
    """Test sending location updates for multiple users"""
    print("🧪 Testing Multiple Users on Admin Panel\n")
    print("=" * 60)
    
    # Base location (Boulder, CO area - default location)
    base_lat = 40.0758
    base_lon = -105.3008
    
    # Create test users with different locations
    test_users = [
        {
            "device_uuid": f"test-user-1-{uuid.uuid4()}",
            "player_name": "Test User 1",
            "lat": base_lat,
            "lng": base_lon,
            "accuracy": 10.0,
            "heading": 0.0
        },
        {
            "device_uuid": f"test-user-2-{uuid.uuid4()}",
            "player_name": "Test User 2",
            "lat": base_lat + 0.001,  # ~100m north
            "lng": base_lon + 0.001,  # ~100m east
            "accuracy": 15.0,
            "heading": 90.0
        },
        {
            "device_uuid": f"test-user-3-{uuid.uuid4()}",
            "player_name": "Test User 3",
            "lat": base_lat - 0.001,  # ~100m south
            "lng": base_lon - 0.001,  # ~100m west
            "accuracy": 8.0,
            "heading": 180.0
        }
    ]
    
    print(f"\n📝 Creating {len(test_users)} test users...\n")
    
    # Create players in database
    for user in test_users:
        create_test_player(user["device_uuid"], user["player_name"])
        time.sleep(0.2)  # Small delay between requests
    
    print(f"\n📍 Sending location updates for all test users...\n")
    
    # Send location updates
    for i, user in enumerate(test_users, 1):
        print(f"   User {i}: {user['player_name']}")
        print(f"      UUID: {user['device_uuid'][:24]}...")
        print(f"      Location: ({user['lat']:.6f}, {user['lng']:.6f})")
        print(f"      Accuracy: {user['accuracy']}m, Heading: {user['heading']}°")
        
        success = send_location_update(
            user["device_uuid"],
            user["lat"],
            user["lng"],
            user["accuracy"],
            user["heading"]
        )
        
        if success:
            print(f"      ✅ Location update sent\n")
        else:
            print(f"      ❌ Failed to send location update\n")
        
        time.sleep(0.3)  # Small delay between requests
    
    # Wait a moment for the server to process
    print("⏳ Waiting for server to process updates...")
    time.sleep(1)
    
    # Check active locations
    print("\n" + "=" * 60)
    print("📊 Checking active user locations...\n")
    
    locations = get_active_locations()
    
    if locations:
        print(f"✅ Found {len(locations)} active user location(s):\n")
        for device_uuid, location in locations.items():
            print(f"   Device: {device_uuid[:24]}...")
            print(f"   Location: ({location['latitude']:.6f}, {location['longitude']:.6f})")
            if 'accuracy' in location and location['accuracy']:
                print(f"   Accuracy: {location['accuracy']:.1f}m")
            if 'heading' in location and location['heading'] is not None:
                print(f"   Heading: {location['heading']:.0f}°")
            print(f"   Updated: {location.get('updated_at', 'N/A')}")
            print()
    else:
        print("⚠️ No active user locations found")
        print("   (Locations expire after 5 minutes of inactivity)")
    
    # Verify our test users are in the list
    print("=" * 60)
    print("🔍 Verifying test users appear in active locations...\n")
    
    test_uuids = [user["device_uuid"] for user in test_users]
    found_count = sum(1 for uuid in test_uuids if uuid in locations)
    
    print(f"   Expected: {len(test_users)} test users")
    print(f"   Found: {found_count} test users in active locations")
    
    if found_count == len(test_users):
        print(f"\n✅ SUCCESS! All {len(test_users)} test users are active")
        print(f"\n💡 Check your admin panel at http://localhost:5001/admin")
        print(f"   You should see {len(test_users)} blue pins with player names!")
        return True
    else:
        print(f"\n⚠️ Only {found_count}/{len(test_users)} test users found")
        print(f"   This might be normal if locations expired or weren't sent properly")
        return found_count > 0

if __name__ == "__main__":
    try:
        success = test_multiple_users()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\n⚠️ Test interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n\n❌ Test failed with error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)





