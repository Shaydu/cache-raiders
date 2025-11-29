#!/usr/bin/env python3
"""
Test script to verify Ollama Docker container is running and accessible.
Tests both localhost (for local API) and container name (for Docker API).
"""
import os
import sys
import subprocess
import requests
import json

def check_docker_running():
    """Check if Docker daemon is running."""
    try:
        result = subprocess.run(['docker', 'info'], 
                              capture_output=True, 
                              timeout=5)
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False

def check_containers_running():
    """Check if docker-compose containers are running."""
    try:
        os.chdir(os.path.dirname(__file__))
        result = subprocess.run(['docker-compose', 'ps'], 
                              capture_output=True, 
                              text=True,
                              timeout=10)
        if result.returncode == 0:
            output = result.stdout
            # Check if ollama container is in the output
            if 'ollama' in output.lower() and 'up' in output.lower():
                return True, output
            return False, output
        return False, result.stderr
    except Exception as e:
        return False, str(e)

def test_ollama_connection(base_url, description):
    """Test connection to Ollama at the given URL."""
    print(f"\n🔍 Testing Ollama connection: {description}")
    print(f"   URL: {base_url}")
    
    # Test 1: Check if Ollama API is responding
    try:
        tags_url = f"{base_url}/api/tags"
        print(f"   Testing: GET {tags_url}")
        response = requests.get(tags_url, timeout=5)
        
        if response.status_code == 200:
            data = response.json()
            models = [m.get('name', 'unknown') for m in data.get('models', [])]
            print(f"   ✅ Connection successful!")
            print(f"   📦 Available models: {', '.join(models) if models else 'No models installed'}")
            return True, models
        else:
            print(f"   ❌ HTTP {response.status_code}: {response.text[:100]}")
            return False, None
    except requests.exceptions.ConnectionError as e:
        print(f"   ❌ Connection refused: {str(e)}")
        return False, None
    except requests.exceptions.Timeout:
        print(f"   ❌ Connection timeout")
        return False, None
    except Exception as e:
        print(f"   ❌ Error: {str(e)}")
        return False, None

def test_ollama_chat(base_url):
    """Test a simple chat request to Ollama."""
    print(f"\n💬 Testing Ollama chat API...")
    try:
        chat_url = f"{base_url}/api/chat"
        payload = {
            "model": "llama2",  # Default model
            "messages": [{"role": "user", "content": "Say 'Ahoy!' in pirate speak."}],
            "stream": False
        }
        print(f"   Testing: POST {chat_url}")
        response = requests.post(chat_url, json=payload, timeout=30)
        
        if response.status_code == 200:
            data = response.json()
            content = data.get('message', {}).get('content', '')
            print(f"   ✅ Chat test successful!")
            print(f"   📝 Response: {content[:100]}...")
            return True
        else:
            print(f"   ❌ HTTP {response.status_code}: {response.text[:200]}")
            return False
    except Exception as e:
        print(f"   ❌ Error: {str(e)}")
        return False

def main():
    print("=" * 60)
    print("🐳 Ollama Docker Connection Test")
    print("=" * 60)
    
    # Step 1: Check Docker daemon
    print("\n1️⃣ Checking Docker daemon...")
    if not check_docker_running():
        print("   ❌ Docker daemon is not running!")
        print("   💡 Start Docker Desktop or run: sudo systemctl start docker")
        return 1
    print("   ✅ Docker daemon is running")
    
    # Step 2: Check containers
    print("\n2️⃣ Checking Docker containers...")
    containers_ok, container_output = check_containers_running()
    if not containers_ok:
        print("   ⚠️  Containers may not be running")
        print(f"   Output: {container_output[:200]}")
        print("   💡 Try: docker-compose up -d")
    else:
        print("   ✅ Containers are running")
        print(f"   {container_output[:300]}")
    
    # Step 3: Test localhost connection (for local API)
    print("\n3️⃣ Testing localhost connection (for locally running API)...")
    localhost_ok, models = test_ollama_connection("http://localhost:11434", "Localhost")
    
    # Step 4: Test container name connection (for Docker API)
    print("\n4️⃣ Testing container name connection (for Docker API)...")
    container_ok, _ = test_ollama_connection("http://ollama:11434", "Container name (ollama)")
    
    # Step 5: Test chat if localhost works
    if localhost_ok:
        test_ollama_chat("http://localhost:11434")
    
    # Summary
    print("\n" + "=" * 60)
    print("📊 Summary")
    print("=" * 60)
    
    if localhost_ok:
        print("✅ Localhost connection: WORKING")
        print("   → API can connect if running locally (python app.py)")
    else:
        print("❌ Localhost connection: FAILED")
        print("   → Make sure Ollama container is running: docker-compose up -d")
        print("   → Check port 11434 is exposed: docker-compose ps")
    
    if container_ok:
        print("✅ Container name connection: WORKING")
        print("   → API can connect if running in Docker")
    else:
        print("⚠️  Container name connection: FAILED (expected if testing from host)")
        print("   → This is normal when testing from your host machine")
        print("   → Container name 'ollama' only works from within Docker network")
    
    # Check environment configuration
    print("\n🔧 Configuration Check:")
    llm_base_url = os.getenv("LLM_BASE_URL", "http://localhost:11434")
    docker_container = os.getenv("DOCKER_CONTAINER", "not set")
    print(f"   LLM_BASE_URL: {llm_base_url}")
    print(f"   DOCKER_CONTAINER: {docker_container}")
    
    if docker_container == "not set":
        print("   💡 Running locally - should use http://localhost:11434")
    else:
        print("   💡 Running in Docker - should use http://ollama:11434")
    
    print("\n" + "=" * 60)
    
    if localhost_ok:
        return 0
    else:
        print("\n❌ Ollama is not accessible. Please:")
        print("   1. Start Docker Desktop")
        print("   2. Run: cd server && docker-compose up -d")
        print("   3. Wait for containers to start")
        print("   4. Run this test again")
        return 1

if __name__ == "__main__":
    sys.exit(main())

