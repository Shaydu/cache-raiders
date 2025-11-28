#!/usr/bin/env python3
"""
Test script for LLM integration
Tests skeleton NPC conversation and clue generation
"""
import requests
import json
import sys
import time

BASE_URL = "http://localhost:5001"

def wait_for_server(max_wait=10):
    """Wait for server to be ready."""
    print("⏳ Waiting for server to start...")
    for i in range(max_wait):
        try:
            response = requests.get(f"{BASE_URL}/health", timeout=1)
            if response.status_code == 200:
                print("✅ Server is ready!")
                return True
        except:
            pass
        time.sleep(1)
        print(f"   Attempt {i+1}/{max_wait}...")
    return False

def test_llm_connection():
    """Test if LLM service is working."""
    print("🧪 Testing LLM Connection...")
    try:
        response = requests.get(f"{BASE_URL}/api/llm/test")
        result = response.json()
        
        if result.get('status') == 'success':
            print("✅ LLM Service is working!")
            print(f"   Model: {result.get('model')}")
            print(f"   Response: {result.get('response')}")
            return True
        else:
            print(f"❌ LLM Service error: {result.get('error')}")
            return False
    except Exception as e:
        print(f"❌ Connection error: {e}")
        print(f"   Make sure server is running on {BASE_URL}")
        return False

def test_skeleton_conversation():
    """Test talking to a skeleton NPC."""
    print("\n💀 Testing Skeleton NPC Conversation...")
    
    test_messages = [
        "Where should I dig for the treasure?",
        "Tell me about the 200-year-old treasure",
        "What do you know about this area?",
        "Give me a riddle about where to dig"
    ]
    
    for message in test_messages:
        print(f"\n👤 You: {message}")
        
        try:
            response = requests.post(
                f"{BASE_URL}/api/npcs/skeleton-1/interact",
                json={
                    "device_uuid": "test-device",
                    "message": message,
                    "npc_name": "Captain Bones",
                    "npc_type": "skeleton",
                    "is_skeleton": True
                }
            )
            
            if response.status_code == 200:
                result = response.json()
                print(f"💀 {result.get('npc_name', 'Skeleton')}: {result.get('response')}")
            else:
                print(f"❌ Error: {response.status_code} - {response.text}")
        except Exception as e:
            print(f"❌ Error: {e}")

def test_clue_generation():
    """Test generating a pirate riddle clue."""
    print("\n🗺️  Testing Clue Generation...")
    
    target_location = {
        "latitude": 37.7749,
        "longitude": -122.4194
    }
    
    map_features = [
        "San Francisco Bay",
        "Golden Gate Park trees",
        "Ferry Building",
        "Coit Tower"
    ]
    
    try:
        response = requests.post(
            f"{BASE_URL}/api/llm/generate-clue",
            json={
                "target_location": target_location,
                "map_features": map_features
            }
        )
        
        if response.status_code == 200:
            result = response.json()
            print("✅ Generated Clue:")
            print(f"   {result.get('clue')}")
        else:
            print(f"❌ Error: {response.status_code} - {response.text}")
    except Exception as e:
        print(f"❌ Error: {e}")

def main():
    print("=" * 60)
    print("🧪 LLM Integration Test Suite")
    print("=" * 60)
    
    # Wait for server if needed
    try:
        requests.get(f"{BASE_URL}/health", timeout=1)
    except:
        print("\n⚠️  Server doesn't appear to be running!")
        print("   Start the server in another terminal:")
        print("   cd server")
        print("   python app.py")
        print("\n   Then run this test again.")
        sys.exit(1)
    
    # Test 1: Connection
    if not test_llm_connection():
        print("\n❌ LLM service not available. Check:")
        print("   1. Server is running: python server/app.py")
        print("   2. API key is set in server/.env")
        print("   3. openai package is installed: pip install openai")
        sys.exit(1)
    
    # Test 2: Skeleton conversation
    test_skeleton_conversation()
    
    # Test 3: Clue generation
    test_clue_generation()
    
    print("\n" + "=" * 60)
    print("✅ All tests complete!")
    print("=" * 60)

if __name__ == "__main__":
    main()

