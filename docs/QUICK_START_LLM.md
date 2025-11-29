# Quick Start: Testing LLM Integration

## Step-by-Step Guide

### 1. Install Dependencies

```bash
cd server
pip install -r requirements.txt
```

This installs `openai` and `python-dotenv`.

### 2. Verify API Key

```bash
    cd server
    cat .env
```

Should show:
```
OPENAI_API_KEY=sk-...
LLM_PROVIDER=openai
LLM_MODEL=gpt-4o-mini
```

### 3. Start the Server

**Option A: Use the start script**
```bash
cd server
./start_server.sh
```

**Option B: Manual start**
```bash
cd server
python app.py
```

You should see:
```
✅ LLM Service initialized with model: gpt-4o-mini
🚀 Starting CacheRaiders API server...
🌐 Server running on:
   - Local: http://localhost:5001
```

**Keep this terminal open!** The server needs to keep running.

### 4. Test in a New Terminal

Open a **new terminal window** and run:

```bash
cd server
python test_llm.py
```

### 5. Expected Output

```
============================================================
🧪 LLM Integration Test Suite
============================================================
🧪 Testing LLM Connection...
✅ LLM Service is working!
   Model: gpt-4o-mini
   Response: Ahoy, matey! The LLM be workin'!

💀 Testing Skeleton NPC Conversation...

👤 You: Where should I dig for the treasure?
💀 Captain Bones: Arr, me bones remember the old ways, matey! ...

👤 You: Tell me about the 200-year-old treasure
💀 Captain Bones: ...

🗺️  Testing Clue Generation...
✅ Generated Clue:
   Arr, me hearty! Where the bay flows swift and true...
```

## Troubleshooting

### "Connection refused"
- **Server not running**: Start it with `python app.py` in the `server/` directory
- **Wrong port**: Make sure server is on port 5001

### "LLM service not available"
- Check that `llm_service.py` exists in `server/` directory
- Restart the server after creating `llm_service.py`

### "OPENAI_API_KEY not configured"
- Check that `server/.env` file exists
- Verify the API key is correct
- Make sure `python-dotenv` is installed

### "Module not found: openai"
```bash
cd server
pip install openai
```

## Quick Test Commands

**Test connection:**
```bash
curl http://localhost:5001/api/llm/test
```

**Talk to skeleton:**
```bash
curl -X POST http://localhost:5001/api/npcs/skeleton-1/interact \
  -H "Content-Type: application/json" \
  -d '{
    "device_uuid": "test",
    "message": "Where should I dig?",
    "npc_name": "Captain Bones",
    "npc_type": "skeleton",
    "is_skeleton": true
  }'
```

## Next Steps

Once testing works:
1. Integrate into iOS app
2. Add database for NPCs
3. Implement full quest generation
4. Add treasure map generation

