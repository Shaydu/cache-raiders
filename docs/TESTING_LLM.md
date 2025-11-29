# Testing LLM Integration

## Quick Start

### 1. Install Dependencies

```bash
cd server
pip install -r requirements.txt
```

This installs:
- `openai` - OpenAI API client
- `python-dotenv` - Environment variable loading

### 2. Verify API Key

Make sure `server/.env` exists with your API key:
```bash
cat server/.env
# Should show:
# OPENAI_API_KEY=sk-...
# LLM_PROVIDER=openai
# LLM_MODEL=gpt-4o-mini
```

### 3. Start the Server

```bash
cd server
python app.py
```

You should see:
```
✅ LLM Service initialized with model: gpt-4o-mini
 * Running on http://0.0.0.0:5001
```

### 4. Test LLM Connection

In another terminal:
```bash
cd server
python test_llm.py
```

Or test manually:
```bash
curl http://localhost:5001/api/llm/test
```

Expected response:
```json
{
  "status": "success",
  "response": "Ahoy, matey! The LLM be workin'!",
  "model": "gpt-4o-mini",
  "api_key_configured": true
}
```

## Testing Skeleton NPC Conversation

### Using the Test Script

```bash
python server/test_llm.py
```

This will:
1. Test LLM connection
2. Have multiple conversations with a skeleton NPC
3. Generate a pirate riddle clue

### Using curl

```bash
curl -X POST http://localhost:5001/api/npcs/skeleton-1/interact \
  -H "Content-Type: application/json" \
  -d '{
    "device_uuid": "test-device",
    "message": "Where should I dig for the treasure?",
    "npc_name": "Captain Bones",
    "npc_type": "skeleton",
    "is_skeleton": true
  }'
```

Expected response:
```json
{
  "npc_id": "skeleton-1",
  "npc_name": "Captain Bones",
  "response": "Arr, me bones remember the old ways, matey! Dead men tell no tales, but I be already dead, so I can speak! Two hundred years ago, we buried the treasure where the river flows past the ancient oak. Dig where the water meets the land, beneath the old tree's shadow at noon, shiver me timbers!"
}
```

### Using Python

```python
import requests

response = requests.post(
    "http://localhost:5001/api/npcs/skeleton-1/interact",
    json={
        "device_uuid": "test-device",
        "message": "Tell me about the 200-year-old treasure",
        "npc_name": "Captain Bones",
        "npc_type": "skeleton",
        "is_skeleton": True
    }
)

result = response.json()
print(f"Skeleton says: {result['response']}")
```

## Testing Clue Generation

```bash
curl -X POST http://localhost:5001/api/llm/generate-clue \
  -H "Content-Type: application/json" \
  -d '{
    "target_location": {
      "latitude": 37.7749,
      "longitude": -122.4194
    },
    "map_features": [
      "San Francisco Bay",
      "Golden Gate Park trees",
      "Ferry Building"
    ]
  }'
```

Expected response:
```json
{
  "clue": "Arr, me hearty! Where the bay flows swift and true,\nAnd the old trees stand guard for ye,\nLook for the stone where the water meets land,\nAnd dig where the ancient grove doth stand!",
  "target_location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}
```

## Testing from iOS App

Once the server is running, you can test from your iOS app:

```swift
// Test LLM connection
let url = URL(string: "http://your-server-ip:5001/api/llm/test")!
let (data, _) = try await URLSession.shared.data(from: url)
let result = try JSONDecoder().decode(LLMTestResponse.self, from: data)
print("LLM Status: \(result.status)")

// Talk to skeleton
let response = try await APIService.shared.interactWithNPC(
    npcId: "skeleton-1",
    message: "Where should I dig?",
    deviceUUID: deviceUUID
)
print("Skeleton: \(response.response)")
```

## Troubleshooting

### Error: "LLM service not available"
- Check that `llm_service.py` exists in `server/` directory
- Check that `openai` package is installed: `pip install openai`
- Restart the server

### Error: "OPENAI_API_KEY not configured"
- Check that `server/.env` file exists
- Verify the API key is correct
- Make sure `python-dotenv` is installed: `pip install python-dotenv`

### Error: "Rate limit exceeded"
- You've hit OpenAI's rate limit
- Wait a few minutes and try again
- Check your usage at https://platform.openai.com/usage

### Error: "Insufficient quota"
- Your free tier credits may be exhausted
- Check usage at https://platform.openai.com/usage
- Add billing info if needed

## Cost Monitoring

Each test uses tokens:
- **Test connection**: ~10 tokens (~$0.000001)
- **Skeleton conversation**: ~100-200 tokens (~$0.00001-0.00002)
- **Clue generation**: ~150-300 tokens (~$0.000015-0.00003)

Monitor usage at: https://platform.openai.com/usage

## Next Steps

Once testing works:
1. Implement full quest generation (`/api/llm-quests/generate`)
2. Add database integration for NPCs
3. Implement treasure map generation
4. Add skeleton spawning when users get stuck



