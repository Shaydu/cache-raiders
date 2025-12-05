# Token Optimization Guide

## Why Short Clues Matter

**Cost per token:**
- GPT-4o-mini: $0.15 per 1M input tokens, $0.60 per 1M output tokens
- Each clue generation: ~50-100 tokens = $0.00001-0.00002
- But it adds up quickly!

## What We Changed

### Before (Long Prompts)
```
System prompt: 200+ tokens
User prompt: 100+ tokens
Response: 100-200 tokens
Total: ~400-500 tokens per interaction
```

### After (Short Prompts)
```
System prompt: 30-50 tokens
User prompt: 20-30 tokens  
Response: 20-50 tokens
Total: ~70-130 tokens per interaction
```

**Savings: ~70% reduction in token usage!**

## Optimizations Made

### 1. Shorter System Prompts
**Before:**
```
Ye be {npc_name}, a SKELETON pirate from 200 years ago!
Ye be already dead, so ye can speak (dead men tell no tales, but ye be dead already)!

Yer personality: mysterious, helpful, and ancient
Yer backstory: Ye were there when the 200-year-old treasure was buried

Yer role be to help players find treasures by providin' hints - ALL IN PIRATE SPEAK!
...
```

**After:**
```
Ye be {npc_name}, a SKELETON pirate from 200 years ago. Ye be dead, so ye can speak. 
Help players find the 200-year-old treasure. Speak ONLY in pirate speak. 
Keep responses SHORT - 1-2 sentences max.
```

### 2. Shorter Clue Prompts
**Before:**
```
Ye be a pirate treasure huntin' guide! Create a riddle clue in PIRATE SPEAK that tells where to dig:

Target location: {lat}, {lon}
Nearby features: {features}

Generate a riddle that:
- Be written in PIRATE SPEAK (use: "ye", "arr", "matey", etc.)
- Tells users WHERE TO DIG using the features
- References the 200-year-old treasure
- Be 2-4 lines (like a pirate poem/riddle)
- Use the actual features listed above

Riddle:
```

**After:**
```
Create a SHORT pirate riddle (1-2 lines max) telling where to dig. 
Use pirate speak. Reference: {features}

Keep it SHORT - 1-2 lines only. Riddle:
```

### 3. Reduced Max Tokens
- **Before**: 500 tokens max per response
- **After**: 150 tokens max (50 for clues)
- **Savings**: Prevents long responses

### 4. Fewer Map Features
- **Before**: 5+ features listed
- **After**: 3 features max
- **Savings**: Less input tokens

## Token Usage Estimates

### Per Interaction Type

| Interaction | Input Tokens | Output Tokens | Total Cost |
|------------|--------------|---------------|------------|
| Test connection | ~10 | ~5 | $0.000001 |
| Skeleton chat | ~50 | ~30 | $0.00001 |
| Clue generation | ~40 | ~20 | $0.000008 |
| Quest generation | ~200 | ~100 | $0.00004 |

### Free Tier ($5) Capacity

With optimizations:
- **Test connections**: ~500,000
- **Skeleton chats**: ~100,000
- **Clue generations**: ~125,000
- **Quest generations**: ~25,000

**Enough for extensive testing and development!**

## Best Practices

### 1. Keep Prompts Short
✅ **Good:**
```
"Create a 1-line pirate riddle about digging near the oak tree."
```

❌ **Bad:**
```
"Ye be a pirate treasure huntin' guide! Create an engaging, mysterious riddle 
that tells players where to dig for the 200-year-old treasure. The riddle should 
be written in pirate speak using words like 'arr', 'ye', 'matey', etc. It should 
reference the nearby oak tree and be 2-4 lines long..."
```

### 2. Limit Response Length
✅ **Good:**
```python
max_tokens=50  # For clues
max_tokens=150  # For conversations
```

❌ **Bad:**
```python
max_tokens=500  # Too long, wastes tokens
```

### 3. Reuse System Prompts
Cache system prompts instead of regenerating them each time.

### 4. Batch Requests
If generating multiple clues, batch them in one request when possible.

## Monitoring Token Usage

### Check Usage
```bash
# Visit OpenAI dashboard
https://platform.openai.com/usage
```

### Set Alerts
1. Go to https://platform.openai.com/account/billing/limits
2. Set soft limit: $3 (get notified)
3. Set hard limit: $5 (stop spending)

### Track Per Request
```python
response = client.chat.completions.create(...)
print(f"Input tokens: {response.usage.prompt_tokens}")
print(f"Output tokens: {response.usage.completion_tokens}")
print(f"Total tokens: {response.usage.total_tokens}")
```

## Summary

**We haven't generated treasure maps yet** - the quota was already exceeded on the service account key you provided.

**To save tokens:**
1. ✅ Shortened all prompts
2. ✅ Reduced max_tokens to 150 (50 for clues)
3. ✅ Limited map features to 3
4. ✅ Simplified system prompts
5. ✅ Requested 1-2 sentence responses

**Result**: ~70% reduction in token usage, making the free tier last much longer!



