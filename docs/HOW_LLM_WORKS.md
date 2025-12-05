# How the LLM Integration Works

## Overview

Yes, the code **prompts the model**! The LLM integration works by:
1. **Building text prompts** (instructions) that tell the LLM what to generate
2. **Sending prompts** to OpenAI's API
3. **Receiving responses** from the LLM
4. **Parsing and using** the generated content

## The Flow

```
Your Code → Builds Prompt → Sends to OpenAI API → Gets Response → Uses in App
```

## Example: Generating a Clue

### Step 1: Code Builds a Prompt

When you want to generate a clue, the code creates a text prompt like this:

```python
prompt = f"""Ye be a pirate treasure huntin' guide! Create 3-5 riddle clues in PIRATE SPEAK that lead to findin' this treasure:

Target: Golden Chalice (chalice)
Location: 37.7749, -122.4194
Storyline: A 200-year-old treasure buried by pirates
Theme: Dead men tell no tales

Nearby features:
- water: San Francisco Bay, Mission Creek
- tree: Golden Gate Park trees
- building: Ferry Building, Coit Tower
- elevation: 52 meters

Generate riddle clues that:
- Be written in PIRATE SPEAK (use: "ye", "arr", "matey", etc.)
- Tell users WHERE TO DIG using real map features
- Reference the 200-year-old treasure
- Be 2-4 lines each (like a pirate poem/riddle)

Respond in JSON format:
{{
    "clues": [
        {{"order": 1, "text": "pirate riddle clue 1"}},
        {{"order": 2, "text": "pirate riddle clue 2"}}
    ]
}}"""
```

### Step 2: Code Sends Prompt to OpenAI

```python
def _call_llm(self, prompt: str) -> str:
    """Sends the prompt to OpenAI API"""
    response = openai.ChatCompletion.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
        temperature=0.7,  # Creativity level
        max_tokens=500     # Max response length
    )
    return response.choices[0].message.content
```

### Step 3: LLM Generates Response

The LLM reads your prompt and generates something like:

```json
{
    "clues": [
        {
            "order": 1,
            "text": "Arr, me hearty! Where the bay flows swift and true,\nAnd the old trees stand guard for ye,\nLook for the stone where the water meets land,\nAnd dig where the ancient grove doth stand!"
        },
        {
            "order": 2,
            "text": "Shiver me timbers! Two hundred years ago we buried the gold,\nBeneath the tower where the city's story's told,\nDig where the ferry meets the shore,\nAnd ye'll find the booty ye be lookin' for!"
        }
    ]
}
```

### Step 4: Code Uses the Response

```python
clues_data = json.loads(response)
# Now clues_data contains the generated riddles
# Store them in database, show to user, etc.
```

## Real Examples from the Code

### Example 1: NPC Conversation

**When user chats with a skeleton NPC:**

```python
# Code builds this prompt:
system_prompt = """Ye be Captain Bones, a skeleton pirate from 200 years ago!
Your personality: mysterious and helpful
Your backstory: You were there when the treasure was buried

Yer role be to help players find treasures by providin' hints - ALL IN PIRATE SPEAK!
Ye must ALWAYS speak like a pirate (use: "arr", "ye", "matey", etc.)

The player has found: Golden Chalice
Active quests: Dead Men Tell No Tales

Respond naturally to the player's questions IN PIRATE SPEAK."""

# User's message
user_message = "Where should I dig for the treasure?"

# Code sends to LLM:
messages = [
    {"role": "system", "content": system_prompt},
    {"role": "user", "content": user_message}
]
response = openai.ChatCompletion.create(model="gpt-4o-mini", messages=messages)

# LLM responds:
"Arr, me bones remember the old ways, matey! Dead men tell no tales, 
but I be already dead, so I can speak! Two hundred years ago, we buried 
the treasure where the river flows past the ancient oak. Dig where the 
water meets the land, beneath the old tree's shadow at noon, shiver me timbers!"
```

### Example 2: Quest Generation

**When generating a complete quest:**

```python
# Step 1: Generate storyline
storyline_prompt = """You are creating a treasure hunting quest. 
Given these available treasure objects:
- Golden Chalice (chalice) at 37.7749, -122.4194
- Treasure Chest (chest) at 37.7849, -122.4094

Create an engaging treasure hunting storyline (2-3 sentences) and select ONE object.

Respond in JSON format:
{
    "storyline": "...",
    "selected_object_id": "...",
    "theme": "..."
}"""

# LLM responds with storyline and selected object

# Step 2: Get real map features (not LLM, uses OpenStreetMap API)
map_features = get_features_near_location(latitude, longitude)
# Returns: water, trees, buildings, etc.

# Step 3: Generate clues using map features
clues_prompt = f"""Create pirate riddles that reference these REAL features:
- water: San Francisco Bay
- tree: Golden Gate Park
- building: Ferry Building

Generate riddles telling where to dig..."""

# LLM generates location-specific riddles
```

## Key Points

1. **Prompts are Instructions**: The code writes detailed instructions telling the LLM what to do
2. **Context is Important**: The code includes:
   - Object information (name, type, location)
   - Real map features (water, trees, buildings)
   - User progress (what they've found)
   - Conversation history (previous messages)
   - Game mode (pirate speak, 200-year-old treasure, etc.)

3. **Structured Outputs**: Prompts often ask for JSON so responses are parseable:
   ```python
   "Respond in JSON format: { ... }"
   ```

4. **Temperature Controls Creativity**: 
   - `temperature=0.7` = Creative but consistent
   - `temperature=0.0` = Very deterministic
   - `temperature=1.0` = Very creative/random

5. **System vs User Messages**:
   - **System message**: Sets the character/personality ("You are a pirate...")
   - **User message**: The actual question/request

## The `_call_llm()` Method

This is the core method that sends prompts to OpenAI:

```python
def _call_llm(self, prompt: str = None, messages: List[Dict] = None) -> str:
    """Internal method to call the LLM API."""
    if self.config.provider == "openai":
        if messages:
            # For conversations (system + user messages)
            response = openai.ChatCompletion.create(
                model=self.config.model,
                messages=messages,
                temperature=self.config.temperature,
                max_tokens=self.config.max_tokens
            )
        else:
            # For simple prompts
            response = openai.ChatCompletion.create(
                model=self.config.model,
                messages=[{"role": "user", "content": prompt}],
                temperature=self.config.temperature,
                max_tokens=self.config.max_tokens
            )
        return response.choices[0].message.content
```

## Cost Per Request

Each prompt/response uses tokens:
- **Input tokens**: Your prompt (usually 200-1000 tokens)
- **Output tokens**: LLM's response (usually 100-500 tokens)
- **Cost**: ~$0.0001-0.0002 per quest generation

## Summary

**Yes, the code prompts the model!** The LLM integration is essentially:
1. Your code writes detailed instructions (prompts)
2. Sends them to OpenAI's API
3. Gets back generated text
4. Uses that text in your app (riddles, conversations, storylines)

The "magic" is in how you **craft the prompts** - the better the prompt, the better the LLM's output!



