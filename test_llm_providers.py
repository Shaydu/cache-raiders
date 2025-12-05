#!/usr/bin/env python3
"""
Test script for both Ollama and OpenAI LLM providers
"""

import json
import requests
import sys

SERVER_URL = "http://localhost:5001"
TEST_MESSAGE = "Where is the treasure?"

def test_provider(provider: str, model: str = None):
    """Test a specific LLM provider."""
    print(f"\n{'='*60}")
    print(f"🧪 Testing {provider.upper()} Provider")
    print(f"{'='*60}\n")
    
    # Step 1: Switch to the provider
    print(f"1️⃣ Switching to {provider}...")
    switch_data = {"provider": provider}
    if model:
        switch_data["model"] = model
    
    try:
        switch_response = requests.post(
            f"{SERVER_URL}/api/llm/provider",
            json=switch_data,
            timeout=10
        )
        
        if switch_response.status_code == 200:
            switch_result = switch_response.json()
            print(f"✅ Successfully switched to {provider}")
            if "model" in switch_result:
                print(f"   Model: {switch_result.get('model', 'default')}")
        else:
            print(f"❌ Failed to switch provider: HTTP {switch_response.status_code}")
            print(f"   Response: {switch_response.text}")
            return False
    except Exception as e:
        print(f"❌ Error switching provider: {e}")
        return False
    
    # Step 2: Get provider info
    print(f"\n2️⃣ Getting provider info...")
    try:
        info_response = requests.get(f"{SERVER_URL}/api/llm/provider", timeout=5)
        if info_response.status_code == 200:
            info = info_response.json()
            print(f"✅ Provider info retrieved")
            print(f"   Current provider: {info.get('provider', 'unknown')}")
            print(f"   Model: {info.get('model', 'unknown')}")
            if provider == "ollama":
                print(f"   Ollama URL: {info.get('ollama_base_url', 'unknown')}")
            elif provider == "openai":
                print(f"   API Key configured: {info.get('api_key_configured', False)}")
        else:
            print(f"⚠️  Could not get provider info: HTTP {info_response.status_code}")
    except Exception as e:
        print(f"⚠️  Error getting provider info: {e}")
    
    # Step 3: Test NPC interaction
    print(f"\n3️⃣ Testing NPC interaction with {provider}...")
    test_data = {
        "device_uuid": "test-device-llm-test",
        "message": TEST_MESSAGE,
        "npc_name": "Captain Bones",
        "npc_type": "skeleton",
        "is_skeleton": True
    }
    
    try:
        start_time = __import__('time').time()
        interact_response = requests.post(
            f"{SERVER_URL}/api/npcs/skeleton-1/interact",
            json=test_data,
            timeout=60  # Longer timeout for LLM responses
        )
        elapsed_time = __import__('time').time() - start_time
        
        if interact_response.status_code == 200:
            result = interact_response.json()
            print(f"✅ NPC interaction successful! (took {elapsed_time:.2f}s)")
            print(f"   NPC: {result.get('npc_name', 'Unknown')}")
            print(f"   Response: {result.get('response', 'No response')[:100]}...")
            return True
        else:
            print(f"❌ NPC interaction failed: HTTP {interact_response.status_code}")
            print(f"   Response: {interact_response.text[:200]}")
            return False
    except requests.exceptions.Timeout:
        print(f"❌ Request timed out after 60 seconds")
        return False
    except Exception as e:
        print(f"❌ Error during NPC interaction: {e}")
        return False

def main():
    print("🚀 LLM Provider Test Suite")
    print("="*60)
    
    # Check server health
    print("\n📡 Checking server health...")
    try:
        health = requests.get(f"{SERVER_URL}/health", timeout=5)
        if health.status_code == 200:
            print("✅ Server is running")
        else:
            print(f"❌ Server returned HTTP {health.status_code}")
            sys.exit(1)
    except Exception as e:
        print(f"❌ Cannot connect to server: {e}")
        sys.exit(1)
    
    results = {}
    
    # Test Ollama
    results['ollama'] = test_provider("ollama", "llama3:8b")
    
    # Test OpenAI (if available)
    print(f"\n{'='*60}")
    print("🔑 Checking OpenAI API key...")
    try:
        info_response = requests.get(f"{SERVER_URL}/api/llm/provider", timeout=5)
        if info_response.status_code == 200:
            info = info_response.json()
            # Check if OpenAI key is configured
            if info.get('api_key_configured') or True:  # Try anyway
                results['openai'] = test_provider("openai", "gpt-4o-mini")
            else:
                print("⚠️  OpenAI API key not configured, skipping OpenAI test")
                results['openai'] = None
    except Exception as e:
        print(f"⚠️  Could not check OpenAI configuration: {e}")
        results['openai'] = None
    
    # Summary
    print(f"\n{'='*60}")
    print("📊 Test Summary")
    print(f"{'='*60}\n")
    
    for provider, result in results.items():
        if result is True:
            print(f"✅ {provider.upper()}: PASSED")
        elif result is False:
            print(f"❌ {provider.upper()}: FAILED")
        else:
            print(f"⏭️  {provider.upper()}: SKIPPED")
    
    print()

if __name__ == "__main__":
    main()

