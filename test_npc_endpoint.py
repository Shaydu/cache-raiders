#!/usr/bin/env python3
"""
Test script for NPC interaction endpoint
Helps isolate whether the problem is in the app, server endpoint, or LLM API
"""

import sys
import json
import requests
from typing import Optional

def test_npc_endpoint(server_url: str = "http://localhost:5001") -> bool:
    """Test the NPC interaction endpoint and return True if successful."""
    
    print("🧪 Testing NPC Interaction Endpoint")
    print("=" * 50)
    print(f"Server URL: {server_url}\n")
    
    # Test 1: Check if server is running
    print("📡 Test 1: Checking if server is running...")
    try:
        health_response = requests.get(f"{server_url}/health", timeout=5)
        if health_response.status_code == 200:
            print("✅ Server is running")
        else:
            print(f"❌ Server returned HTTP {health_response.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        print(f"❌ Cannot connect to server at {server_url}")
        print("   Make sure your Flask server is running: cd server && python app.py")
        return False
    except Exception as e:
        print(f"❌ Error checking server: {e}")
        return False
    print()
    
    # Test 2: Check LLM service availability
    print("🤖 Test 2: Checking LLM service availability...")
    try:
        llm_test = requests.get(f"{server_url}/api/llm/test-connection", timeout=5)
        if llm_test.status_code == 200:
            llm_data = llm_test.json()
            if llm_data.get("status") == "success":
                print("✅ LLM service is available")
                print(f"   Response: {json.dumps(llm_data, indent=2)}")
            else:
                print("⚠️  LLM service may not be fully initialized")
                print(f"   Response: {json.dumps(llm_data, indent=2)}")
        else:
            print(f"⚠️  LLM test endpoint returned HTTP {llm_test.status_code}")
    except Exception as e:
        print(f"⚠️  Could not test LLM service: {e}")
        print("   This might be okay - will test on actual request")
    print()
    
    # Test 3: Test NPC interaction endpoint
    print("💬 Test 3: Testing NPC interaction endpoint...")
    endpoint = f"{server_url}/api/npcs/skeleton-1/interact"
    print(f"   Endpoint: POST {endpoint}\n")
    
    request_body = {
        "device_uuid": "test-device-123",
        "message": "Where is the treasure?",
        "npc_name": "Captain Bones",
        "npc_type": "skeleton",
        "is_skeleton": True
    }
    
    print("   Request body:")
    print(json.dumps(request_body, indent=2))
    print()
    
    try:
        response = requests.post(
            endpoint,
            json=request_body,
            headers={"Content-Type": "application/json"},
            timeout=60  # LLM calls can take time
        )
        
        print(f"   Response (HTTP {response.status_code}):")
        
        if response.status_code == 200:
            try:
                response_data = response.json()
                print(json.dumps(response_data, indent=2))
                
                if "response" in response_data:
                    response_text = response_data["response"]
                    if response_text and not response_text.startswith("Error"):
                        print("\n✅ SUCCESS: Endpoint is working correctly!")
                        print(f"   LLM Response: {response_text}")
                        print("\n💡 If the app still doesn't work, the problem is likely:")
                        print("   - Network connectivity (app can't reach server)")
                        print("   - Wrong baseURL in app settings")
                        print("   - iOS app code issue")
                        return True
                    else:
                        print("\n⚠️  Endpoint responded but LLM returned an error")
                        print(f"   Response: {response_text}")
                        print("   Check LLM service configuration:")
                        print("   - Ollama: Is 'ollama serve' running?")
                        print("   - OpenAI: Is OPENAI_API_KEY set correctly?")
                        return False
                else:
                    print("\n⚠️  Endpoint responded but response format is unexpected")
                    print("   Missing 'response' field in JSON")
                    return False
            except json.JSONDecodeError:
                print("⚠️  Response is not valid JSON:")
                print(response.text)
                return False
                
        elif response.status_code == 503:
            print("\n❌ LLM service not available (503)")
            print("   Check server logs for LLM initialization errors")
            print("   Response:", response.text)
            return False
            
        elif response.status_code == 400:
            print("\n❌ Bad request (400)")
            print("   Check request format")
            print("   Response:", response.text)
            return False
            
        elif response.status_code == 500:
            print("\n❌ Server error (500)")
            print("   Check server logs for error details")
            print("   Response:", response.text)
            return False
            
        else:
            print(f"\n❌ Unexpected HTTP status: {response.status_code}")
            print("   Response:", response.text)
            return False
            
    except requests.exceptions.Timeout:
        print("\n❌ Request timed out (60 seconds)")
        print("   LLM might be too slow or not responding")
        return False
    except Exception as e:
        print(f"\n❌ Error making request: {e}")
        return False

if __name__ == "__main__":
    server_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:5001"
    success = test_npc_endpoint(server_url)
    print("\n" + "=" * 50)
    print("Test complete!")
    sys.exit(0 if success else 1)


