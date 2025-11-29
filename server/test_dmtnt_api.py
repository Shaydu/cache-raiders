#!/usr/bin/env python3
"""
Comprehensive test for DMTNT (Dead Men Tell No Tales) API endpoints
Tests all endpoints the iOS app will need for skeleton NPC interactions and clue generation
"""
import requests
import json
import sys
import time
from datetime import datetime

BASE_URL = "http://localhost:5001"

def print_header(text):
    """Print a formatted header."""
    print("\n" + "=" * 70)
    print(f"  {text}")
    print("=" * 70)

def print_success(text):
    """Print success message."""
    print(f"✅ {text}")

def print_error(text):
    """Print error message."""
    print(f"❌ {text}")

def print_info(text):
    """Print info message."""
    print(f"ℹ️  {text}")

def wait_for_server(max_wait=10):
    """Wait for server to be ready."""
    print("⏳ Waiting for server to start...")
    for i in range(max_wait):
        try:
            response = requests.get(f"{BASE_URL}/health", timeout=1)
            if response.status_code == 200:
                print_success("Server is ready!")
                return True
        except:
            pass
        time.sleep(1)
        print(f"   Attempt {i+1}/{max_wait}...")
    return False

def test_llm_connection():
    """Test 1: LLM service connection."""
    print_header("TEST 1: LLM Service Connection")
    
    try:
        response = requests.get(f"{BASE_URL}/api/llm/test", timeout=10)
        result = response.json()
        
        if result.get('status') == 'success':
            print_success("LLM Service is working!")
            print(f"   Model: {result.get('model')}")
            print(f"   Provider: {result.get('provider', 'openai')}")
            print(f"   Response: {result.get('response')}")
            return True
        else:
            print_error(f"LLM Service error: {result.get('error')}")
            return False
    except Exception as e:
        print_error(f"Connection error: {e}")
        return False

def test_skeleton_npc_interaction():
    """Test 2: Skeleton NPC conversation endpoint."""
    print_header("TEST 2: Skeleton NPC Interaction (/api/npcs/<id>/interact)")
    
    test_cases = [
        {
            "name": "Basic question about treasure",
            "message": "Where should I dig for the treasure?",
            "npc_name": "Captain Bones",
            "npc_type": "skeleton",
            "is_skeleton": True
        },
        {
            "name": "Question about 200-year-old treasure",
            "message": "Tell me about the 200-year-old treasure",
            "npc_name": "Captain Bones",
            "npc_type": "skeleton",
            "is_skeleton": True
        },
        {
            "name": "Request for a riddle",
            "message": "Give me a riddle about where to dig",
            "npc_name": "Captain Bones",
            "npc_type": "skeleton",
            "is_skeleton": True
        },
        {
            "name": "Question about the area",
            "message": "What do you know about this area?",
            "npc_name": "Captain Bones",
            "npc_type": "skeleton",
            "is_skeleton": True
        }
    ]
    
    all_passed = True
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\n📝 Test Case {i}: {test_case['name']}")
        print(f"   👤 User: {test_case['message']}")
        
        try:
            response = requests.post(
                f"{BASE_URL}/api/npcs/skeleton-1/interact",
                json={
                    "device_uuid": "test-device-123",
                    "message": test_case['message'],
                    "npc_name": test_case['npc_name'],
                    "npc_type": test_case['npc_type'],
                    "is_skeleton": test_case['is_skeleton']
                },
                timeout=30
            )
            
            if response.status_code == 200:
                result = response.json()
                npc_name = result.get('npc_name', 'Skeleton')
                npc_response = result.get('response', '')
                print_success(f"Response received from {npc_name}")
                print(f"   💀 {npc_name}: {npc_response}")
                
                # Validate response
                if not npc_response or len(npc_response) < 10:
                    print_error("Response too short or empty")
                    all_passed = False
                elif "error" in npc_response.lower():
                    print_error("Response contains error message")
                    all_passed = False
            else:
                print_error(f"HTTP {response.status_code}: {response.text}")
                all_passed = False
                
        except requests.exceptions.Timeout:
            print_error("Request timed out (server may be slow)")
            all_passed = False
        except Exception as e:
            print_error(f"Request failed: {e}")
            all_passed = False
    
    return all_passed

def test_clue_generation():
    """Test 3: Clue generation endpoint."""
    print_header("TEST 3: Clue Generation (/api/llm/generate-clue)")
    
    test_cases = [
        {
            "name": "San Francisco location with provided features",
            "target_location": {
                "latitude": 37.7749,
                "longitude": -122.4194
            },
            "map_features": [
                "San Francisco Bay",
                "Golden Gate Park trees",
                "Ferry Building"
            ],
            "fetch_real_features": False
        },
        {
            "name": "New York location with real OSM data",
            "target_location": {
                "latitude": 40.7128,
                "longitude": -74.0060
            },
            "map_features": None,
            "fetch_real_features": True
        },
        {
            "name": "London location with provided features",
            "target_location": {
                "latitude": 51.5074,
                "longitude": -0.1278
            },
            "map_features": [
                "Thames River",
                "Big Ben",
                "Westminster Abbey"
            ],
            "fetch_real_features": False
        }
    ]
    
    all_passed = True
    
    for i, test_case in enumerate(test_cases, 1):
        print(f"\n📝 Test Case {i}: {test_case['name']}")
        print(f"   📍 Location: {test_case['target_location']['latitude']}, {test_case['target_location']['longitude']}")
        
        if test_case['map_features']:
            print(f"   🗺️  Features: {', '.join(test_case['map_features'][:3])}")
        else:
            print(f"   🗺️  Fetching real OSM features...")
        
        try:
            payload = {
                "target_location": test_case['target_location'],
                "fetch_real_features": test_case['fetch_real_features']
            }
            
            if test_case['map_features']:
                payload["map_features"] = test_case['map_features']
            
            response = requests.post(
                f"{BASE_URL}/api/llm/generate-clue",
                json=payload,
                timeout=30
            )
            
            if response.status_code == 200:
                result = response.json()
                clue = result.get('clue', '')
                used_real_data = result.get('used_real_map_data', False)
                
                print_success("Clue generated successfully")
                print(f"   🎯 Clue: {clue}")
                if used_real_data:
                    print(f"   📊 Used real OSM map data")
                
                # Validate clue
                if not clue or len(clue) < 10:
                    print_error("Clue too short or empty")
                    all_passed = False
                elif "error" in clue.lower():
                    print_error("Clue contains error message")
                    all_passed = False
                elif len(clue) > 500:
                    print_error("Clue too long (should be 1-2 lines)")
                    all_passed = False
            else:
                print_error(f"HTTP {response.status_code}: {response.text}")
                all_passed = False
                
        except requests.exceptions.Timeout:
            print_error("Request timed out")
            all_passed = False
        except Exception as e:
            print_error(f"Request failed: {e}")
            all_passed = False
    
    return all_passed

def test_error_handling():
    """Test 4: Error handling for invalid requests."""
    print_header("TEST 4: Error Handling")
    
    all_passed = True
    
    # Test missing required fields
    print("\n📝 Test: Missing device_uuid")
    try:
        response = requests.post(
            f"{BASE_URL}/api/npcs/skeleton-1/interact",
            json={"message": "Hello"},
            timeout=5
        )
        if response.status_code == 400:
            print_success("Correctly rejected missing device_uuid")
        else:
            print_error(f"Expected 400, got {response.status_code}")
            all_passed = False
    except Exception as e:
        print_error(f"Request failed: {e}")
        all_passed = False
    
    # Test missing location
    print("\n📝 Test: Missing target_location")
    try:
        response = requests.post(
            f"{BASE_URL}/api/llm/generate-clue",
            json={},
            timeout=5
        )
        if response.status_code == 400:
            print_success("Correctly rejected missing location")
        else:
            print_error(f"Expected 400, got {response.status_code}")
            all_passed = False
    except Exception as e:
        print_error(f"Request failed: {e}")
        all_passed = False
    
    return all_passed

def main():
    """Run all tests."""
    print("\n" + "=" * 70)
    print("  🧪 DMTNT API Endpoint Test Suite")
    print("  Testing all endpoints needed for Dead Men Tell No Tales mode")
    print("=" * 70)
    print(f"\n⏰ Test started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"🌐 Server URL: {BASE_URL}")
    
    # Wait for server
    try:
        requests.get(f"{BASE_URL}/health", timeout=1)
        print_success("Server is reachable")
    except:
        print_error("Server doesn't appear to be running!")
        print("\n💡 Start the server in another terminal:")
        print("   cd server")
        print("   python app.py")
        print("\n   Then run this test again.")
        sys.exit(1)
    
    results = {}
    
    # Run tests
    results['llm_connection'] = test_llm_connection()
    results['skeleton_interaction'] = test_skeleton_npc_interaction()
    results['clue_generation'] = test_clue_generation()
    results['error_handling'] = test_error_handling()
    
    # Summary
    print_header("TEST SUMMARY")
    
    total_tests = len(results)
    passed_tests = sum(1 for v in results.values() if v)
    
    for test_name, passed in results.items():
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"   {status} - {test_name.replace('_', ' ').title()}")
    
    print(f"\n📊 Results: {passed_tests}/{total_tests} tests passed")
    
    if passed_tests == total_tests:
        print_success("All tests passed! API is ready for DMTNT mode.")
        return 0
    else:
        print_error(f"{total_tests - passed_tests} test(s) failed. Check the output above.")
        return 1

if __name__ == "__main__":
    sys.exit(main())



