#!/usr/bin/env python3
"""
Connection test script for CacheRaiders server.
Tests connectivity from a client perspective.
"""
import requests
import sys
import json
from urllib.parse import urlparse

def test_connection(base_url):
    """Test connection to the server."""
    print(f"\n🔍 Testing connection to: {base_url}")
    print("=" * 60)
    
    # Test 1: Health check
    print("\n1️⃣ Testing health endpoint...")
    try:
        response = requests.get(f"{base_url}/health", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"   ✅ Health check passed")
            print(f"   📊 Response: {json.dumps(data, indent=2)}")
        else:
            print(f"   ❌ Health check failed: HTTP {response.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        print(f"   ❌ Connection refused - Server may not be running or URL is incorrect")
        print(f"   💡 Make sure:")
        print(f"      - Server is running (python app.py)")
        print(f"      - URL is correct (check IP address)")
        print(f"      - Device is on the same network")
        return False
    except requests.exceptions.Timeout:
        print(f"   ❌ Connection timeout - Server may be unreachable")
        return False
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False
    
    # Test 2: Server info
    print("\n2️⃣ Testing server info endpoint...")
    try:
        response = requests.get(f"{base_url}/api/server-info", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"   ✅ Server info retrieved")
            print(f"   📊 Detected IP: {data.get('local_ip')}")
            print(f"   📊 Server URL: {data.get('server_url')}")
            print(f"   📊 Port: {data.get('port')}")
        else:
            print(f"   ⚠️ Server info failed: HTTP {response.status_code}")
    except Exception as e:
        print(f"   ⚠️ Error getting server info: {e}")
    
    # Test 3: Connection test endpoint
    print("\n3️⃣ Testing connection test endpoint...")
    try:
        response = requests.get(f"{base_url}/api/debug/connection-test", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"   ✅ Connection test passed")
            print(f"   📊 Server detected your IP: {data.get('server_info', {}).get('remote_addr')}")
            print(f"   📊 Recommended URL: {data.get('server_info', {}).get('server_url')}")
        else:
            print(f"   ⚠️ Connection test failed: HTTP {response.status_code}")
    except Exception as e:
        print(f"   ⚠️ Error in connection test: {e}")
    
    # Test 4: Network info
    print("\n4️⃣ Testing network info endpoint...")
    try:
        response = requests.get(f"{base_url}/api/debug/network-info", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"   ✅ Network info retrieved")
            print(f"   📊 Available IPs:")
            for ip_info in data.get('detected_ips', []):
                if not ip_info.get('ip', '').startswith('127.'):
                    print(f"      - {ip_info.get('interface')}: {ip_info.get('ip')}")
            print(f"   📊 Recommended URLs:")
            for url in data.get('recommended_urls', []):
                print(f"      - {url}")
        else:
            print(f"   ⚠️ Network info failed: HTTP {response.status_code}")
    except Exception as e:
        print(f"   ⚠️ Error getting network info: {e}")
    
    # Test 5: API endpoint
    print("\n5️⃣ Testing API endpoint (objects)...")
    try:
        response = requests.get(f"{base_url}/api/objects?include_found=true", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"   ✅ API endpoint working")
            print(f"   📊 Objects returned: {len(data)}")
        else:
            print(f"   ⚠️ API endpoint failed: HTTP {response.status_code}")
    except Exception as e:
        print(f"   ⚠️ Error testing API: {e}")
    
    print("\n" + "=" * 60)
    print("✅ All tests completed!")
    return True

if __name__ == '__main__':
    if len(sys.argv) > 1:
        base_url = sys.argv[1]
        # Add http:// if not present
        if not base_url.startswith('http://') and not base_url.startswith('https://'):
            base_url = f"http://{base_url}"
    else:
        # Default to localhost
        base_url = "http://localhost:5001"
        print("💡 Usage: python test_connection.py [URL]")
        print(f"   Example: python test_connection.py http://192.168.1.100:5001")
        print(f"   Using default: {base_url}\n")
    
    success = test_connection(base_url)
    sys.exit(0 if success else 1)



