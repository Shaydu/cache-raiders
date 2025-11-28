# LLM Data Flow Documentation

## Overview
This document explains how the iOS app communicates with the LLM service for NPC conversations.

## Data Flow Path

### 1. User Interaction (iOS App)
- **Location**: `SkeletonConversationView.swift` (line 148)
- **Action**: User types a message and taps send
- **Code**: 
  ```swift
  let response = try await APIService.shared.interactWithNPC(
      npcId: npcId,
      message: userMessage,
      npcName: npcName,
      npcType: "skeleton",
      isSkeleton: true
  )
  ```

### 2. API Service Layer (iOS App)
- **Location**: `APIService.swift` (line 798)
- **Method**: `interactWithNPC(npcId:message:npcName:npcType:isSkeleton:)`
- **Endpoint**: `POST {baseURL}/api/npcs/{npcId}/interact`
- **Request Body**:
  ```json
  {
    "device_uuid": "user-device-id",
    "message": "user's message",
    "npc_name": "Captain Bones",
    "npc_type": "skeleton",
    "is_skeleton": true
  }
  ```
- **Response**:
  ```json
  {
    "npc_id": "skeleton-1",
    "npc_name": "Captain Bones",
    "response": "LLM-generated response text"
  }
  ```

### 3. Server API Endpoint
- **Location**: `server/app.py` (line 1933)
- **Route**: `/api/npcs/<npc_id>/interact`
- **Method**: `POST`
- **Checks**:
  1. Verifies `LLM_AVAILABLE` flag is `True`
  2. Validates request data (device_uuid, message required)
  3. Extracts NPC info from request body
- **Calls**: `llm_service.generate_npc_response(...)`

### 4. LLM Service Layer (Python)
- **Location**: `server/llm_service.py` (line 240)
- **Method**: `generate_npc_response(npc_name, npc_type, user_message, is_skeleton, ...)`
- **Process**:
  1. Fetches real map features from OpenStreetMap (if user location provided)
  2. Builds system prompt based on NPC type (skeleton, corgi, etc.)
  3. Creates message array: `[{"role": "system", "content": system_prompt}, {"role": "user", "content": user_message}]`
  4. Calls `_call_llm(messages=messages)`

### 5. LLM Provider Call
- **Location**: `server/llm_service.py` (line 150)
- **Method**: `_call_llm(prompt=None, messages=None, max_tokens=None)`
- **Routing**:
  - If `provider == "ollama"` or `provider == "local"`: Calls `_call_ollama()`
  - Otherwise: Calls `_call_openai()`

#### Ollama Path (Local)
- **Location**: `server/llm_service.py` (line 161)
- **Endpoint**: `POST {ollama_base_url}/api/chat` (default: `http://localhost:11434/api/chat`)
- **Request**:
  ```json
  {
    "model": "model-name",
    "messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}],
    "options": {"temperature": 0.7, "num_predict": 150},
    "stream": false
  }
  ```
- **Response**: `{"message": {"content": "LLM response text"}}`

#### OpenAI Path (Cloud)
- **Location**: `server/llm_service.py` (line 211)
- **API**: OpenAI Chat Completions API
- **Endpoint**: `https://api.openai.com/v1/chat/completions`
- **Request**: Uses OpenAI Python SDK
- **Response**: `response.choices[0].message.content`

### 6. Response Path (Back to App)
1. LLM Service returns `{"response": "text"}`
2. Server endpoint wraps in JSON: `{"npc_id": "...", "npc_name": "...", "response": "..."}`
3. API Service decodes response
4. `SkeletonConversationView` displays response with typewriter effect

## Configuration

### LLM Provider Selection
- **Environment Variable**: `LLM_PROVIDER` (default: `"ollama"`)
- **Options**: `"ollama"`, `"local"`, `"openai"`, `"anthropic"`
- **Location**: `server/llm_service.py` (line 115)

### API Keys
- **OpenAI**: `OPENAI_API_KEY` environment variable
- **Ollama**: No API key needed (local service)

### Base URLs
- **Server API**: Set in `APIService.baseURL` (iOS app)
- **Ollama**: `LLM_BASE_URL` environment variable (default: `http://localhost:11434`)

## Troubleshooting

### LLM Not Responding

1. **Check LLM Service Availability**
   - Server logs should show: `✅ LLM Service initialized with {provider}`
   - Check `LLM_AVAILABLE` flag in server logs
   - Test endpoint: `GET /api/llm/test-connection`

2. **Check Provider Status**
   - **Ollama**: Ensure `ollama serve` is running
   - **OpenAI**: Verify `OPENAI_API_KEY` is set and valid

3. **Check Network Connectivity**
   - iOS app → Server: Verify `baseURL` is correct
   - Server → LLM: For Ollama, check `localhost:11434` is accessible

4. **Check Server Logs**
   - Look for errors in `/api/npcs/<id>/interact` endpoint
   - Check for LLM service errors in `llm_service.py`

5. **Common Issues**
   - **503 Error**: `LLM_AVAILABLE = False` - LLM service not initialized
   - **Connection Error**: Ollama not running or wrong URL
   - **API Key Error**: OpenAI key missing or invalid
   - **Timeout**: LLM model too slow or not loaded

## Testing

### Test LLM Connection
```bash
curl http://localhost:5001/api/llm/test-connection
```

### Test NPC Interaction
```bash
curl -X POST http://localhost:5001/api/npcs/skeleton-1/interact \
  -H "Content-Type: application/json" \
  -d '{
    "device_uuid": "test-device",
    "message": "Where is the treasure?",
    "npc_name": "Captain Bones",
    "npc_type": "skeleton",
    "is_skeleton": true
  }'
```

## Architecture Notes

- **Server-Side LLM**: All LLM calls happen on the server, not the iOS app
- **Shared State**: Server maintains conversation history and quest state
- **API Key Security**: API keys stored on server, never exposed to client
- **Real Map Data**: Server fetches OpenStreetMap features for location-based clues

