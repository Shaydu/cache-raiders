#!/usr/bin/env python3
"""
Compare Ollama and OpenAI responses to the same query
"""

import json
import requests
import time

SERVER_URL = "http://localhost:5001"
TEST_MESSAGE = "Where is the treasure buried? Give me a clue."

def test_provider(provider: str, model: str = None):
    """Test a specific LLM provider and return the response."""
    print(f"\n🔄 Switching to {provider.upper()}...")
    
    # Switch provider
    switch_data = {"provider": provider}
    if model:
        switch_data["model"] = model
    
    try:
        switch_response = requests.post(
            f"{SERVER_URL}/api/llm/provider",
            json=switch_data,
            timeout=10
        )
        
        if switch_response.status_code != 200:
            print(f"❌ Failed to switch to {provider}: HTTP {switch_response.status_code}")
            return None, None
    except Exception as e:
        print(f"❌ Error switching to {provider}: {e}")
        return None, None
    
    # Wait a moment for provider to initialize
    time.sleep(1)
    
    # Test NPC interaction
    test_data = {
        "device_uuid": "test-comparison-device",
        "message": TEST_MESSAGE,
        "npc_name": "Captain Bones",
        "npc_type": "skeleton",
        "is_skeleton": True
    }
    
    try:
        start_time = time.time()
        interact_response = requests.post(
            f"{SERVER_URL}/api/npcs/skeleton-1/interact",
            json=test_data,
            timeout=120  # Longer timeout for Ollama
        )
        elapsed_time = time.time() - start_time
        
        if interact_response.status_code == 200:
            result = interact_response.json()
            response_text = result.get('response', 'No response')
            return response_text, elapsed_time
        else:
            print(f"❌ Request failed: HTTP {interact_response.status_code}")
            print(f"   Response: {interact_response.text[:200]}")
            return None, None
    except requests.exceptions.Timeout:
        print(f"❌ Request timed out")
        return None, None
    except Exception as e:
        print(f"❌ Error: {e}")
        return None, None

def main():
    print("="*70)
    print("🔬 LLM Provider Comparison Test")
    print("="*70)
    print(f"\n📝 Test Message: \"{TEST_MESSAGE}\"")
    print(f"🎭 NPC: Captain Bones (Skeleton)")
    print("\n" + "="*70)
    
    # Check server
    try:
        health = requests.get(f"{SERVER_URL}/health", timeout=5)
        if health.status_code != 200:
            print("❌ Server is not healthy")
            return
    except Exception as e:
        print(f"❌ Cannot connect to server: {e}")
        return
    
    results = {}
    
    # Test Ollama
    print("\n" + "="*70)
    print("🤖 Testing OLLAMA (llama3:8b)")
    print("="*70)
    ollama_response, ollama_time = test_provider("ollama", "llama3:8b")
    results['ollama'] = {
        'response': ollama_response,
        'time': ollama_time
    }
    
    # Test OpenAI
    print("\n" + "="*70)
    print("🤖 Testing OPENAI (gpt-4o-mini)")
    print("="*70)
    openai_response, openai_time = test_provider("openai", "gpt-4o-mini")
    results['openai'] = {
        'response': openai_response,
        'time': openai_time
    }
    
    # Comparison
    print("\n" + "="*70)
    print("📊 COMPARISON RESULTS")
    print("="*70)
    
    if ollama_response and openai_response:
        print("\n⏱️  Response Times:")
        print(f"   Ollama:  {ollama_time:.2f} seconds")
        print(f"   OpenAI:  {openai_time:.2f} seconds")
        print(f"   Difference: {abs(ollama_time - openai_time):.2f} seconds")
        
        print("\n" + "-"*70)
        print("💬 OLLAMA Response:")
        print("-"*70)
        print(ollama_response)
        
        print("\n" + "-"*70)
        print("💬 OPENAI Response:")
        print("-"*70)
        print(openai_response)
        
        print("\n" + "-"*70)
        print("📏 Response Length:")
        print("-"*70)
        print(f"   Ollama:  {len(ollama_response)} characters")
        print(f"   OpenAI:  {len(openai_response)} characters")
        
        print("\n" + "-"*70)
        print("🔍 Key Differences:")
        print("-"*70)
        ollama_words = set(ollama_response.lower().split())
        openai_words = set(openai_response.lower().split())
        
        only_ollama = ollama_words - openai_words
        only_openai = openai_words - ollama_words
        
        if only_ollama:
            print(f"\n   Words only in Ollama ({len(only_ollama)}):")
            print(f"   {', '.join(list(only_ollama)[:10])}")
        
        if only_openai:
            print(f"\n   Words only in OpenAI ({len(only_openai)}):")
            print(f"   {', '.join(list(only_openai)[:10])}")
        
        print("\n" + "="*70)
        print("✅ Both providers are working!")
        print("="*70)
    else:
        print("\n❌ One or both providers failed")
        if not ollama_response:
            print("   Ollama: FAILED")
        if not openai_response:
            print("   OpenAI: FAILED")

if __name__ == "__main__":
    main()

