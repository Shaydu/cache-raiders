# Quick Start: Using Llama 3 with Ollama (No API Key Needed!)

This guide will get you running with Llama 3 locally in about 5 minutes.

## Step 1: Install Ollama

**macOS:**
```bash
brew install ollama
# OR download from https://ollama.ai/download
```

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Windows:**
Download from https://ollama.ai/download

## Step 2: Start Ollama

```bash
ollama serve
```

Keep this terminal open! Ollama needs to keep running.

## Step 3: Download Llama 3

In a **new terminal window**, run:

```bash
ollama pull llama3
```

This downloads ~4.7GB. The first time takes a few minutes, but it's a one-time download.

**Alternative models** (if you want to try others):
- `ollama pull llama3:8b` - Smaller, faster (recommended for testing)
- `ollama pull mistral` - Alternative model
- `ollama pull phi3` - Very small, fast

## Step 4: Configure Your Server

Create or update `server/.env`:

```bash
cd server
```

Create `.env` file with:
```bash
LLM_PROVIDER=ollama
LLM_MODEL=llama3
LLM_BASE_URL=http://localhost:11434
# No API key needed!
```

## Step 5: Test It!

**Start your server:**
```bash
cd server
python app.py
```

You should see:
```
✅ LLM Service initialized with Ollama
   Model: llama3
   Base URL: http://localhost:11434
```

**Test the connection:**
```bash
curl http://localhost:5001/api/llm/test
```

**Or use the test script:**
```bash
python test_llm.py
```

## That's It! 🎉

You're now running Llama 3 locally with no API costs!

## Performance Tips

- **First request is slow** (~5-10 seconds) - Ollama needs to load the model
- **Subsequent requests are faster** (~1-3 seconds)
- **Use GPU if available** - Much faster! Ollama will auto-detect
- **Smaller models are faster** - Try `llama3:8b` if `llama3` is too slow

## Troubleshooting

### "Cannot connect to Ollama"
- Make sure `ollama serve` is running
- Check the URL: `http://localhost:11434`
- Test with: `curl http://localhost:11434/api/tags` (should list models)

### "Model not found"
- Run: `ollama pull llama3`
- Check available models: `ollama list`

### "Request timed out"
- Model might be loading (first request is slow)
- Try a smaller model: `ollama pull llama3:8b`
- Update `.env`: `LLM_MODEL=llama3:8b`

### "Too slow"
- Use GPU if available (Ollama auto-detects)
- Try smaller model: `llama3:8b` instead of `llama3`
- Reduce `max_tokens` in `llm_service.py` (already optimized)

## Switching Back to OpenAI

Just update `server/.env`:
```bash
LLM_PROVIDER=openai
LLM_MODEL=gpt-4o-mini
OPENAI_API_KEY=sk-...
```

No code changes needed! The service automatically switches.

## What Works?

✅ **NPC Conversations** - Pirate speak responses  
✅ **Clue Generation** - Short pirate riddles  
✅ **All existing features** - Everything that worked with OpenAI

## Quality Comparison

- **OpenAI GPT-4o-mini**: Slightly more consistent, faster
- **Llama 3**: Very good quality, free, local (privacy!)
- **For your use case**: Both work great! Llama 3 is perfect for testing and development.


