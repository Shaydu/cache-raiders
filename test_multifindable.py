#!/usr/bin/env python3
"""
Test script to verify multifindable functionality.
Tests that:
1. NFC-placed items (multifindable=1) disappear only for the user who found them
2. Regular items (multifindable=0) disappear for everyone once found
"""

import requests
import json

BASE_URL = "http://localhost:5001"

def test_multifindable_logic():
    print("🧪 Testing multifindable logic...")

    # Test user IDs
    user1 = "63BCDF3F-B34D-4012-BC8F-560254F7286A"  # From database
    user2 = "06B7DADE-C470-43D2-BE27-B53849BCE336"  # From database
    user3 = "test-user-new"

    # Test scenarios
    print(f"\n👤 User 1: {user1}")
    print(f"👤 User 2: {user2}")
    print(f"👤 User 3: {user3}")

    # Get objects for each user
    def get_objects_for_user(user_id, include_found=False):
        url = f"{BASE_URL}/api/objects?user_id={user_id}"
        if include_found:
            url += "&include_found=true"
        response = requests.get(url)
        if response.status_code == 200:
            return response.json()
        else:
            print(f"❌ Error getting objects for user {user_id}: {response.status_code}")
            return []

    # Test with include_found=false (default behavior)
    print("\n📋 Testing object visibility (include_found=false):")

    objects_user1 = get_objects_for_user(user1)
    objects_user2 = get_objects_for_user(user2)
    objects_user3 = get_objects_for_user(user3)

    print(f"User 1 sees {len(objects_user1)} objects")
    print(f"User 2 sees {len(objects_user2)} objects")
    print(f"User 3 sees {len(objects_user3)} objects")

    # Find multifindable objects
    multifindable_objects = [obj for obj in objects_user1 if obj.get('multifindable', False)]
    single_find_objects = [obj for obj in objects_user1 if not obj.get('multifindable', False)]

    print(f"\n🔍 Found {len(multifindable_objects)} multifindable objects")
    print(f"🔍 Found {len(single_find_objects)} single-find objects")

    # Check specific behavior
    nfc_object_id = "test-nfc-object-970CC641"
    found_nfc_user1 = any(obj['id'] == nfc_object_id for obj in objects_user1)
    found_nfc_user2 = any(obj['id'] == nfc_object_id for obj in objects_user2)
    found_nfc_user3 = any(obj['id'] == nfc_object_id for obj in objects_user3)

    print(f"\n🎯 NFC object '{nfc_object_id}' visibility:")
    print(f"  User 1: {'✅ Visible' if found_nfc_user1 else '❌ Hidden'}")
    print(f"  User 2: {'✅ Visible' if found_nfc_user2 else '❌ Hidden'}")
    print(f"  User 3: {'✅ Visible' if found_nfc_user3 else '❌ Hidden'}")

    # Test with include_found=true
    print("\n📋 Testing with include_found=true:")
    objects_all_user1 = get_objects_for_user(user1, include_found=True)
    print(f"User 1 sees {len(objects_all_user1)} objects (including found)")

    # Verify multifindable flag is present
    sample_object = objects_all_user1[0] if objects_all_user1 else None
    if sample_object and 'multifindable' in sample_object:
        print("✅ multifindable field present in API response")
    else:
        print("❌ multifindable field missing in API response")

if __name__ == "__main__":
    test_multifindable_logic()



