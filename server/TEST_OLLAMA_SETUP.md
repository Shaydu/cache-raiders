# Testing Ollama Docker Setup

## Current Status
❌ **Docker daemon is not running**

## Setup Steps

### 1. Start Docker Desktop
- Open Docker Desktop application on your Mac
- Wait for it to fully start (whale icon in menu bar should be steady)

### 2. Start the Containers
```bash
cd server
docker-compose up -d
```

This will:
- Pull the Ollama image (first time only)
- Start the Ollama container on port 11434
- Start the API container (depends on Ollama)
- Configure networking so API can reach Ollama

### 3. Verify Containers are Running
```bash
docker-compose ps
```

You should see both `ollama` and `api` containers with status "Up"

### 4. Run the Test Script
```bash
python3 test_ollama_docker.py
```

This will test:
- ✅ Docker daemon status
- ✅ Container status
- ✅ Ollama connectivity from localhost (for local API)
- ✅ Ollama connectivity via container name (for Docker API)
- ✅ Available models
- ✅ Chat API functionality

## Configuration Details

### When Running in Docker (docker-compose)
- **API connects to**: `http://ollama:11434` (container name)
- **Environment**: `DOCKER_CONTAINER=true`
- **LLM_PROVIDER**: `ollama`
- **LLM_BASE_URL**: `http://ollama:11434`

### When Running Locally (python app.py)
- **API connects to**: `http://localhost:11434` (exposed port)
- **Environment**: `DOCKER_CONTAINER` not set
- **LLM_PROVIDER**: from `.env` file (default: `openai`)
- **LLM_BASE_URL**: from `.env` file (default: `http://localhost:11434`)

## Troubleshooting

### Error: "Connection refused" to localhost:11434
- **Cause**: Ollama container not running or port not exposed
- **Fix**: 
  1. Start Docker Desktop
  2. Run `docker-compose up -d`
  3. Wait 10-20 seconds for containers to start
  4. Check: `docker-compose ps`

### Error: "Connection refused" to ollama:11434
- **Cause**: API is running locally but trying to use container name
- **Fix**: 
  - If running API locally: Use `http://localhost:11434` in `.env`
  - If running API in Docker: Make sure `DOCKER_CONTAINER=true` is set

### No models available
- **Cause**: Ollama container is new and has no models
- **Fix**: 
  ```bash
  docker exec -it cache-raiders-ollama ollama pull llama2
  ```
  Or use the admin interface to pull models

## Quick Test Commands

```bash
# Check if Ollama is responding
curl http://localhost:11434/api/tags

# Check available models
curl http://localhost:11434/api/tags | jq '.models[].name'

# Test chat (from host)
curl -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model": "llama2", "messages": [{"role": "user", "content": "Say hello"}], "stream": false}'

# Test from within API container
docker exec -it cache-raiders-api curl http://ollama:11434/api/tags
```

## Next Steps

Once Docker is running and containers are up:
1. Run `python3 test_ollama_docker.py` to verify everything
2. Check the API logs: `docker-compose logs api`
3. Check Ollama logs: `docker-compose logs ollama`
4. Test the API endpoint: `curl http://localhost:5001/api/llm/test`

