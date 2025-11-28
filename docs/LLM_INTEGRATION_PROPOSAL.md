# LLM Integration Architecture for CacheRaiders

## Executive Summary

This proposal outlines an LLM-driven quest system that transforms CacheRaiders into an interactive treasure hunting adventure. The system uses Large Language Models to dynamically generate storylines, create riddles based on real geographic features, and spawn skeleton NPCs that guide players to buried treasures. 

**"Dead Men Tell No Tales"** is the flagship game mode where players must first find a treasure map showing "X marks the spot" for a 200-year-old buried treasure. The LLM analyzes actual map features (water, trees, buildings, elevation) to generate location-specific pirate riddles. Skeletons appear dynamically when players get stuck, providing progressively helpful clues in pirate speak. GPS navigation is disabled, forcing players to rely on the map, riddles, and skeleton guidance. 

The architecture is server-side for shared quest state, consistent clues, and centralized API key management. The system includes treasure map objects, clue objects, skeleton NPCs using `Curious_skeleton.usdz`, and a custom map UI. All interactions use pirate language, creating an immersive experience where only the dead can reveal where the treasure was buried 200 years ago.

## Overview
This document proposes an architecture for integrating Large Language Models (LLMs) into CacheRaiders to enable:
1. **LLM-Driven Quest Generation** - LLM creates storylines, selects target objects, and generates quests dynamically
2. **NPC Guide Characters** - Non-findable characters that users can chat with for guidance
3. **Clue Objects** - Findable objects that reveal information leading to hidden treasures
4. **Dynamic Object Hiding** - Target objects are hidden until clues are found
5. **Interactive Conversations** with findable objects and NPCs
6. **Quest Chains** where finding clues and talking to NPCs leads to the final treasure

### LLM-Driven Quest Flow
When LLM mode is enabled, the system:
1. **Storyline Generation**: LLM creates a storyline/theme (e.g., "The Lost Temple of Anubis")
2. **Object Selection**: LLM selects a relevant object from available treasures to be the quest target
3. **Object Hiding**: The target object is hidden (not visible/findable in AR)
4. **Map Generation**: LLM creates a custom map with landmarks, paths, and areas (GPS navigation disabled)
5. **Clue Generation**: LLM generates 3-5 clues as findable objects placed in the world
6. **NPC Placement**: LLM creates and places NPCs that know about the quest
7. **Progressive Revelation**: As users find clues and talk to NPCs, they get closer to the hidden object
8. **Object Unlocking**: Once all clues are found, the target object becomes visible and findable

### Map System
- **LLM-Generated Maps**: Custom maps created by the LLM with thematic landmarks and areas
- **GPS Navigation Disabled**: Users cannot see exact GPS coordinates or navigate directly to objects
- **Real Map Feature Analysis**: LLM analyzes actual geographic features (water, trees, elevation, mountains, buildings) to create location-based riddles
- **Riddle-Based Clues**: Clues are poetic riddles that reference real map features (e.g., "Where the river meets the old oak tree")
- **Pirate Speak**: All NPCs and clues use pirate language and terminology
- **Visual Map UI**: Custom map interface showing quest areas, landmarks, and discovered clues

### Game Modes

#### "Dead Men Tell No Tales" Mode
A special game mode where skeleton NPCs (using `Curious_skeleton.usdz`) appear dynamically to guide users:
- **200-Year-Old Treasure**: The quest centers around finding a treasure buried 200 years ago
- **Treasure Map**: Users must first find a treasure map (findable object) that reveals "X marks the spot"
- **Map Reveals Location**: Once the map is found, users can open it to see where to dig (X marks the spot)
- **Dynamic Skeleton Appearances**: Skeletons appear randomly in AR when users get stuck (no progress for X minutes)
- **Digging Riddles**: Skeletons give riddles in pirate speak that tell users where to "dig" (find the treasure)
- **Stuck Detection**: System detects when user hasn't found clues/objects in a while, triggers skeleton spawn
- **Progressive Hints**: Each skeleton appearance gives progressively more helpful riddles if user is still stuck
- **Thematic Integration**: Skeletons reference being 200 years old and knowing where the treasure was buried
- **Visual**: Skeleton model appears in AR near user's current location when stuck, can be tapped to interact

## Architecture Decision: Server-Side LLM

**Rationale:**
- Quest chains require shared state across users
- Clues should be consistent and persistent
- Centralized API key management
- Better for multi-user coordination
- Can cache responses for performance

## Database Schema Extensions

### New Tables

```sql
-- Quest chains: Links objects together in a sequence
CREATE TABLE quest_chains (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    created_at TEXT NOT NULL,
    created_by TEXT
);

-- Quest chain steps: Defines the order of objects in a quest
CREATE TABLE quest_chain_steps (
    id TEXT PRIMARY KEY,
    chain_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    step_order INTEGER NOT NULL,
    clue_text TEXT,  -- LLM-generated clue for this step
    created_at TEXT NOT NULL,
    FOREIGN KEY (chain_id) REFERENCES quest_chains(id),
    FOREIGN KEY (object_id) REFERENCES objects(id),
    UNIQUE(chain_id, step_order)
);

-- Object interactions: Stores conversation history with objects
CREATE TABLE object_interactions (
    id TEXT PRIMARY KEY,
    object_id TEXT NOT NULL,
    device_uuid TEXT NOT NULL,
    interaction_type TEXT NOT NULL,  -- 'conversation', 'clue_request', 'hint'
    message TEXT NOT NULL,
    response TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (object_id) REFERENCES objects(id)
);

-- Object metadata: Extended properties for LLM context
CREATE TABLE object_metadata (
    object_id TEXT PRIMARY KEY,
    backstory TEXT,  -- LLM-generated backstory for this object
    personality TEXT,  -- Personality traits for conversation
    clue_hints TEXT,  -- Pre-generated hints
    quest_context TEXT,  -- Context about this object's role in quests
    FOREIGN KEY (object_id) REFERENCES objects(id)
);

-- User quest progress: Tracks which quest steps users have completed
CREATE TABLE user_quest_progress (
    id TEXT PRIMARY KEY,
    device_uuid TEXT NOT NULL,
    chain_id TEXT NOT NULL,
    current_step INTEGER NOT NULL,  -- Last completed step
    completed_at TEXT,
    FOREIGN KEY (chain_id) REFERENCES quest_chains(id),
    UNIQUE(device_uuid, chain_id)
);

-- NPC Characters: Non-findable guide characters that users can interact with
CREATE TABLE npc_characters (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    character_type TEXT NOT NULL,  -- 'guide', 'historian', 'guardian', 'merchant', 'skeleton', etc.
    appearance_description TEXT,  -- Description for AR visualization
    personality TEXT NOT NULL,  -- Personality traits for LLM
    backstory TEXT,  -- Character backstory
    model_name TEXT,  -- USDZ model name (e.g., 'Curious_skeleton' for skeleton NPCs)
    latitude REAL,  -- GPS location (optional, can be AR-only)
    longitude REAL,
    ar_offset_x REAL,  -- AR offset if placed manually
    ar_offset_y REAL,
    ar_offset_z REAL,
    ar_origin_latitude REAL,
    ar_origin_longitude REAL,
    radius REAL DEFAULT 50.0,  -- Interaction radius
    is_active BOOLEAN DEFAULT 1,
    game_mode TEXT,  -- 'dead_men_tell_no_tales', 'standard', etc.
    created_at TEXT NOT NULL,
    created_by TEXT
);

-- NPC knowledge: What objects/quests this NPC knows about
CREATE TABLE npc_knowledge (
    id TEXT PRIMARY KEY,
    npc_id TEXT NOT NULL,
    object_id TEXT,  -- NULL if knowledge is about a quest
    quest_chain_id TEXT,  -- NULL if knowledge is about an object
    knowledge_type TEXT NOT NULL,  -- 'hint', 'clue', 'backstory', 'location_hint'
    knowledge_text TEXT,  -- LLM-generated knowledge
    unlock_condition TEXT,  -- When this knowledge becomes available (e.g., "after_finding_object:obj123")
    created_at TEXT NOT NULL,
    FOREIGN KEY (npc_id) REFERENCES npc_characters(id),
    FOREIGN KEY (object_id) REFERENCES objects(id),
    FOREIGN KEY (quest_chain_id) REFERENCES quest_chains(id)
);

-- NPC interactions: Conversation history with NPCs
CREATE TABLE npc_interactions (
    id TEXT PRIMARY KEY,
    npc_id TEXT NOT NULL,
    device_uuid TEXT NOT NULL,
    message TEXT NOT NULL,
    response TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (npc_id) REFERENCES npc_characters(id)
);
```

### Extensions to Existing Tables

```sql
-- Add to objects table
ALTER TABLE objects ADD COLUMN quest_chain_id TEXT;
ALTER TABLE objects ADD COLUMN quest_step_order INTEGER;
ALTER TABLE objects ADD COLUMN is_interactive BOOLEAN DEFAULT 0;  -- Can be talked to
ALTER TABLE objects ADD COLUMN interaction_prompt TEXT;  -- Custom prompt for LLM
ALTER TABLE objects ADD COLUMN is_hidden BOOLEAN DEFAULT 0;  -- Hidden until clues found
ALTER TABLE objects ADD COLUMN is_clue BOOLEAN DEFAULT 0;  -- This object is a clue, not a treasure
ALTER TABLE objects ADD COLUMN clue_text TEXT;  -- Text revealed when clue is found
ALTER TABLE objects ADD COLUMN target_object_id TEXT;  -- For clues: which object this leads to
ALTER TABLE objects ADD COLUMN unlock_condition TEXT;  -- When this object becomes visible (e.g., "clues_found:3")
ALTER TABLE objects ADD COLUMN is_treasure_map BOOLEAN DEFAULT 0;  -- This object is a treasure map
ALTER TABLE objects ADD COLUMN map_target_latitude REAL;  -- For treasure maps: where X marks the spot
ALTER TABLE objects ADD COLUMN map_target_longitude REAL;  -- For treasure maps: where X marks the spot
```

### LLM Quest Generation Tables

```sql
-- LLM-generated quests: Storylines with hidden target objects
CREATE TABLE llm_quests (
    id TEXT PRIMARY KEY,
    storyline TEXT NOT NULL,  -- LLM-generated storyline/theme
    target_object_id TEXT NOT NULL,  -- The hidden treasure object
    status TEXT NOT NULL DEFAULT 'active',  -- 'active', 'completed', 'expired'
    created_at TEXT NOT NULL,
    created_by TEXT,
    FOREIGN KEY (target_object_id) REFERENCES objects(id)
);

-- Clue objects: Findable objects that reveal information
CREATE TABLE clue_objects (
    id TEXT PRIMARY KEY,
    quest_id TEXT NOT NULL,
    clue_order INTEGER NOT NULL,  -- Order in which clues should be found
    clue_text TEXT NOT NULL,  -- LLM-generated clue text
    object_id TEXT NOT NULL,  -- The findable clue object
    latitude REAL,
    longitude REAL,
    ar_offset_x REAL,
    ar_offset_y REAL,
    ar_offset_z REAL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (quest_id) REFERENCES llm_quests(id),
    FOREIGN KEY (object_id) REFERENCES objects(id),
    UNIQUE(quest_id, clue_order)
);

-- Quest NPCs: NPCs created for a specific quest
CREATE TABLE quest_npcs (
    id TEXT PRIMARY KEY,
    quest_id TEXT NOT NULL,
    npc_id TEXT NOT NULL,
    role TEXT NOT NULL,  -- 'guide', 'historian', 'guardian', etc.
    created_at TEXT NOT NULL,
    FOREIGN KEY (quest_id) REFERENCES llm_quests(id),
    FOREIGN KEY (npc_id) REFERENCES npc_characters(id)
);

-- User quest clue progress: Tracks which clues users have found
CREATE TABLE user_quest_clues (
    id TEXT PRIMARY KEY,
    device_uuid TEXT NOT NULL,
    quest_id TEXT NOT NULL,
    clue_id TEXT NOT NULL,
    found_at TEXT NOT NULL,
    FOREIGN KEY (quest_id) REFERENCES llm_quests(id),
    FOREIGN KEY (clue_id) REFERENCES clue_objects(id),
    UNIQUE(device_uuid, quest_id, clue_id)
);

-- LLM-generated maps: Custom maps for quests with landmarks and areas
CREATE TABLE llm_maps (
    id TEXT PRIMARY KEY,
    quest_id TEXT NOT NULL,
    map_name TEXT NOT NULL,
    map_description TEXT,  -- LLM-generated description
    center_latitude REAL NOT NULL,
    center_longitude REAL NOT NULL,
    zoom_level REAL DEFAULT 15.0,
    map_style TEXT DEFAULT 'thematic',  -- 'thematic', 'ancient', 'treasure', etc.
    created_at TEXT NOT NULL,
    FOREIGN KEY (quest_id) REFERENCES llm_quests(id)
);

-- Map landmarks: Points of interest on the LLM-generated map
CREATE TABLE map_landmarks (
    id TEXT PRIMARY KEY,
    map_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,  -- LLM-generated description
    landmark_type TEXT NOT NULL,  -- 'landmark', 'area', 'path', 'clue_location', 'npc_location'
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    icon_type TEXT,  -- 'temple', 'cave', 'tree', 'statue', etc.
    is_visible BOOLEAN DEFAULT 1,  -- Whether landmark is visible on map
    unlock_condition TEXT,  -- When this landmark becomes visible
    created_at TEXT NOT NULL,
    FOREIGN KEY (map_id) REFERENCES llm_maps(id)
);

-- Map areas: Regions/zones on the map
CREATE TABLE map_areas (
    id TEXT PRIMARY KEY,
    map_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    area_type TEXT NOT NULL,  -- 'forest', 'desert', 'ruins', 'village', etc.
    boundary_coordinates TEXT,  -- JSON array of lat/lon points defining polygon
    fill_color TEXT,  -- Hex color for area fill
    stroke_color TEXT,  -- Hex color for area border
    is_visible BOOLEAN DEFAULT 1,
    created_at TEXT NOT NULL,
    FOREIGN KEY (map_id) REFERENCES llm_maps(id)
);

-- Real map features: Actual geographic features detected from map data
CREATE TABLE map_features (
    id TEXT PRIMARY KEY,
    quest_id TEXT NOT NULL,
    feature_type TEXT NOT NULL,  -- 'water', 'tree', 'building', 'mountain', 'elevation', 'path', 'bridge', etc.
    feature_name TEXT,  -- Name if available (e.g., "Oak Tree", "Main Street")
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    elevation REAL,  -- Elevation in meters
    description TEXT,  -- LLM-generated description
    metadata TEXT,  -- JSON with additional feature data
    created_at TEXT NOT NULL,
    FOREIGN KEY (quest_id) REFERENCES llm_quests(id)
);
```

## Server-Side Implementation

### 1. LLM Service (`server/llm_service.py`)

```python
"""
LLM Service for CacheRaiders
Handles all LLM interactions: conversations, clue generation, quest creation
"""

import os
import openai
from typing import Optional, Dict, List
from dataclasses import dataclass

@dataclass
class LLMConfig:
    provider: str = "openai"  # or "anthropic", "local"
    model: str = "gpt-4o-mini"  # or "claude-3-haiku", etc.
    api_key: Optional[str] = None
    temperature: float = 0.7
    max_tokens: int = 500

class MapFeatureService:
    """Service to detect real map features from geographic data."""
    
    def __init__(self):
        # Could use OpenStreetMap Overpass API, Google Maps API, or other services
        self.overpass_url = "https://overpass-api.de/api/interpreter"
    
    def get_features_near_location(
        self,
        latitude: float,
        longitude: float,
        radius: float = 500.0  # meters
    ) -> List[Dict]:
        """Get real map features near a location using Overpass API."""
        import requests
        
        # Overpass QL query to get features
        query = f"""
        [out:json][timeout:25];
        (
          way["natural"="water"](around:{radius},{latitude},{longitude});
          way["waterway"](around:{radius},{latitude},{longitude});
          node["natural"="tree"](around:{radius},{latitude},{longitude});
          way["natural"="tree_row"](around:{radius},{latitude},{longitude});
          way["building"](around:{radius},{latitude},{longitude});
          way["highway"](around:{radius},{latitude},{longitude});
          relation["natural"="mountain"](around:{radius},{latitude},{longitude});
          way["natural"="peak"](around:{radius},{latitude},{longitude});
        );
        out body;
        >;
        out skel qt;
        """
        
        try:
            response = requests.post(self.overpass_url, data=query, timeout=30)
            data = response.json()
            
            features = []
            for element in data.get('elements', []):
                feature = {
                    'type': self._classify_feature(element),
                    'latitude': element.get('lat', latitude),
                    'longitude': element.get('lon', longitude),
                    'tags': element.get('tags', {}),
                    'name': element.get('tags', {}).get('name', '')
                }
                features.append(feature)
            
            return features
        except Exception as e:
            print(f"⚠️ Error fetching map features: {e}")
            return []
    
    def _classify_feature(self, element: Dict) -> str:
        """Classify an OSM element into a feature type."""
        tags = element.get('tags', {})
        
        if 'waterway' in tags or tags.get('natural') == 'water':
            return 'water'
        elif tags.get('natural') == 'tree' or tags.get('natural') == 'tree_row':
            return 'tree'
        elif 'building' in tags:
            return 'building'
        elif tags.get('natural') == 'peak' or tags.get('natural') == 'mountain':
            return 'mountain'
        elif 'highway' in tags:
            return 'path'
        else:
            return 'landmark'
    
    def get_elevation(self, latitude: float, longitude: float) -> Optional[float]:
        """Get elevation at a location using Open-Elevation API."""
        import requests
        try:
            response = requests.post(
                "https://api.open-elevation.com/api/v1/lookup",
                json={"locations": [{"latitude": latitude, "longitude": longitude}]},
                timeout=10
            )
            data = response.json()
            if data.get('results'):
                return data['results'][0].get('elevation')
        except Exception as e:
            print(f"⚠️ Error fetching elevation: {e}")
        return None

class LLMService:
    def __init__(self, config: LLMConfig):
        self.config = config
        if config.provider == "openai":
            openai.api_key = config.api_key or os.getenv("OPENAI_API_KEY")
        self.map_feature_service = MapFeatureService()
    
    def generate_clue(
        self,
        current_object: Dict,
        next_object: Dict,
        quest_context: Optional[str] = None
    ) -> str:
        """Generate a clue for finding the next object in a quest chain."""
        prompt = f"""You are a treasure hunting guide. Generate a creative, engaging clue that helps a player find the next treasure.

Current object found: {current_object.get('name', 'Unknown')} ({current_object.get('type', 'Unknown')})
Next object to find: {next_object.get('name', 'Unknown')} ({next_object.get('type', 'Unknown')})
Next object location: {next_object.get('latitude', 0)}, {next_object.get('longitude', 0)}

{quest_context or ''}

Generate a clue that:
- Is mysterious but solvable
- References the current object
- Hints at the location or nature of the next object
- Is 1-2 sentences long
- Doesn't directly give away the location

Clue:"""
        
        response = self._call_llm(prompt)
        return response.strip()
    
    def generate_conversation_response(
        self,
        object_data: Dict,
        user_message: str,
        conversation_history: List[Dict] = None
    ) -> str:
        """Generate a conversational response from an object."""
        object_name = object_data.get('name', 'Treasure')
        object_type = object_data.get('type', 'Unknown')
        backstory = object_data.get('backstory', 'A mysterious artifact')
        personality = object_data.get('personality', 'mysterious and wise')
        
        system_prompt = f"""You are {object_name}, a {object_type} with a rich history. 
Your personality: {personality}
Your backstory: {backstory}

Respond to the player's questions and comments in character. Be helpful but mysterious. 
You can provide hints about other treasures, share your history, or engage in conversation.
Keep responses to 1-3 sentences."""
        
        messages = [{"role": "system", "content": system_prompt}]
        
        # Add conversation history
        if conversation_history:
            for msg in conversation_history[-5:]:  # Last 5 messages for context
                messages.append({
                    "role": "user" if msg['from_user'] else "assistant",
                    "content": msg['message']
                })
        
        messages.append({"role": "user", "content": user_message})
        
        response = self._call_llm(messages=messages)
        return response.strip()
    
    def generate_npc_response(
        self,
        npc_data: Dict,
        user_message: str,
        available_knowledge: List[Dict] = None,
        user_progress: Dict = None,
        conversation_history: List[Dict] = None
    ) -> str:
        """Generate a conversational response from an NPC character."""
        npc_name = npc_data.get('name', 'Guide')
        character_type = npc_data.get('character_type', 'guide')
        personality = npc_data.get('personality', 'helpful and friendly')
        backstory = npc_data.get('backstory', 'A knowledgeable guide')
        
        # Build knowledge context
        knowledge_context = ""
        if available_knowledge:
            knowledge_context = "\n\nYou know about these treasures and quests:\n"
            for knowledge in available_knowledge:
                if knowledge.get('unlocked', True):  # Only include unlocked knowledge
                    knowledge_context += f"- {knowledge.get('knowledge_text', '')}\n"
        
        # Build progress context
        progress_context = ""
        if user_progress:
            found_objects = user_progress.get('found_objects', [])
            if found_objects:
                progress_context = f"\n\nThe player has found: {', '.join(found_objects[:5])}"
            active_quests = user_progress.get('active_quests', [])
            if active_quests:
                progress_context += f"\nActive quests: {', '.join(active_quests)}"
        
        system_prompt = f"""Ye be {npc_name}, a {character_type} pirate in a treasure huntin' game!
Your personality: {personality}
Your backstory: {backstory}

Yer role be to help players find treasures by providin' hints, clues, and guidance - ALL IN PIRATE SPEAK!
Ye must ALWAYS speak like a pirate (use: "arr", "ye", "matey", "ahoy", "shiver me timbers", "booty", "treasure", etc.)
Be helpful but don't give away solutions too easily. Encourage exploration like a true pirate!
{knowledge_context}
{progress_context}

Respond naturally to the player's questions IN PIRATE SPEAK. Ye can:
- Give hints about nearby treasures (in pirate speak)
- Share information about quest chains (like a pirate storyteller)
- Provide location clues referencing real map features (water, trees, buildings, etc.)
- Tell stories about the area (pirate tales)
- Encourage the player to explore (like a pirate captain)

Keep responses to 2-4 sentences. Be engaging, in character, and ALWAYS use pirate speak!"""
        
        messages = [{"role": "system", "content": system_prompt}]
        
        # Add conversation history
        if conversation_history:
            for msg in conversation_history[-5:]:  # Last 5 messages for context
                messages.append({
                    "role": "user" if msg['from_user'] else "assistant",
                    "content": msg['message']
                })
        
        messages.append({"role": "user", "content": user_message})
        
        response = self._call_llm(messages=messages)
        return response.strip()
    
    def generate_object_backstory(self, object_data: Dict) -> str:
        """Generate a backstory for an object to make it more interesting."""
        prompt = f"""Create a brief, engaging backstory (2-3 sentences) for this treasure:

Name: {object_data.get('name', 'Unknown')}
Type: {object_data.get('type', 'Unknown')}
Location: {object_data.get('latitude', 0)}, {object_data.get('longitude', 0)}

Make it mysterious, historical, and intriguing. Connect it to a treasure hunting theme.

Backstory:"""
        
        response = self._call_llm(prompt)
        return response.strip()
    
    def generate_llm_quest(
        self,
        available_objects: List[Dict],
        user_location: Optional[Dict] = None,
        context: Optional[str] = None
    ) -> Dict:
        """Generate a complete LLM-driven quest: storyline, select object, create clues, place NPCs."""
        
        # Step 1: Generate storyline and select target object
        is_dead_men_mode = context and ("dead men" in context.lower() or "skeleton" in context.lower() or "tales" in context.lower())
        
        storyline_context = ""
        if is_dead_men_mode:
            storyline_context = "\nIMPORTANT: This is a 'Dead Men Tell No Tales' quest. The treasure is 200 years old and was buried long ago. The storyline should reference this age and the fact that only the dead (skeletons) know where it's buried."
        
        storyline_prompt = f"""You are creating a treasure hunting quest. Given these available treasure objects:
{chr(10).join([f"- {obj.get('name', 'Unknown')} ({obj.get('type', 'Unknown')}) at {obj.get('latitude', 0)}, {obj.get('longitude', 0)}" for obj in available_objects])}

{context or ''}
{storyline_context}

Create an engaging treasure hunting storyline (2-3 sentences) and select ONE object that fits the story best.
The selected object will be hidden until players find clues leading to it.
{storyline_context}

Respond in JSON format:
{{
    "storyline": "The storyline text (mention 200 years old if dead men mode)",
    "selected_object_id": "object_id",
    "selected_object_name": "object name",
    "theme": "theme description"
}}"""
        
        storyline_response = self._call_llm(storyline_prompt)
        # Parse JSON response
        import json
        try:
            quest_data = json.loads(storyline_response)
        except:
            # Fallback if JSON parsing fails
            quest_data = {
                "storyline": storyline_response[:200],
                "selected_object_id": available_objects[0].get('id'),
                "selected_object_name": available_objects[0].get('name'),
                "theme": "Mysterious treasure hunt"
            }
        
        target_object = next((obj for obj in available_objects if obj.get('id') == quest_data['selected_object_id']), available_objects[0])
        
        # Step 2: Get real map features near target location
        target_lat = target_object.get('latitude', 0)
        target_lon = target_object.get('longitude', 0)
        map_features = self.map_feature_service.get_features_near_location(
            target_lat, target_lon, radius=1000.0
        )
        
        # Get elevation
        elevation = self.map_feature_service.get_elevation(target_lat, target_lon)
        
        # Build feature description for LLM
        feature_description = "Nearby features:\n"
        feature_types = {}
        for feature in map_features:
            ftype = feature['type']
            if ftype not in feature_types:
                feature_types[ftype] = []
            if feature.get('name'):
                feature_types[ftype].append(feature['name'])
            else:
                feature_types[ftype].append(ftype)
        
        for ftype, names in feature_types.items():
            feature_description += f"- {ftype}: {', '.join(names[:3])}\n"
        
        if elevation:
            feature_description += f"- Elevation: {elevation:.0f} meters\n"
        
        # Step 3: Generate pirate-style riddle clues based on real map features
        clues_prompt = f"""Ye be a pirate treasure huntin' guide! Create 3-5 riddle clues in PIRATE SPEAK that lead to findin' this treasure:

Target: {target_object.get('name', 'Unknown')} ({target_object.get('type', 'Unknown')})
Location: {target_object.get('latitude', 0)}, {target_object.get('longitude', 0)}
Storyline: {quest_data['storyline']}
Theme: {quest_data.get('theme', 'Treasure hunting')}

{feature_description}

Generate riddle clues that:
- Be written in PIRATE SPEAK (use words like: "ye", "arr", "matey", "treasure", "booty", "shiver me timbers", "ahoy", etc.)
- Be poetic riddles that reference REAL map features (water, trees, buildings, mountains, elevation, paths)
- Progressively reveal information about the location
- Reference the storyline and theme
- Don't directly give away the exact location
- Be 2-4 lines each (like a pirate poem/riddle)
- Use the actual features listed above in creative ways

Example style:
"Where the river flows and the old oak grows,
Ye'll find the first clue, me hearty knows.
Look for the stone where the water meets land,
And dig where the ancient tree doth stand."

Respond in JSON format:
{{
    "clues": [
        {{"order": 1, "text": "pirate riddle clue 1"}},
        {{"order": 2, "text": "pirate riddle clue 2"}},
        {{"order": 3, "text": "pirate riddle clue 3"}}
    ]
}}"""
        
        clues_response = self._call_llm(clues_prompt)
        try:
            clues_data = json.loads(clues_response)
            clues = clues_data.get('clues', [])
        except:
            clues = [
                {"order": 1, "text": f"Seek the {target_object.get('name', 'treasure')} where ancient secrets lie."},
                {"order": 2, "text": f"The {target_object.get('type', 'artifact')} awaits those who follow the path."},
                {"order": 3, "text": f"Your journey ends where the {target_object.get('name', 'treasure')} is hidden."}
            ]
        
        # Add treasure map as the first clue (order 0)
        treasure_map_clue = {
            "order": 0,
            "text": map_clue,
            "is_treasure_map": True,
            "map_target_latitude": target_object.get('latitude', 0),
            "map_target_longitude": target_object.get('longitude', 0)
        }
        clues.insert(0, treasure_map_clue)
        
        # Step 4: Generate pirate NPCs for the quest
        npcs_prompt = f"""Create 2-3 PIRATE NPC characters for this treasure huntin' quest:

Storyline: {quest_data['storyline']}
Target: {target_object.get('name', 'Unknown')}
Theme: {quest_data.get('theme', 'Treasure hunting')}
Map Features: {feature_description}

Each NPC should:
- Be a PIRATE character (use pirate names like "Captain Blackbeard", "One-Eyed Jack", "Madame Fortune", etc.)
{f"- Be a SKELETON (dead pirate) if 'dead men tell no tales' mode is active" if use_skeletons else ""}
- Speak ONLY in PIRATE SPEAK (use: "arr", "ye", "matey", "ahoy", "shiver me timbers", "booty", etc.)
- Have a unique pirate personality and role (captain, first mate, navigator, old salt, skeleton guardian, etc.)
- Know different pieces of information about WHERE TO DIG for the treasure
- Give riddles in pirate speak that reference the real map features and tell where to dig
- Reference the 200-year-old treasure and where it was buried
- Be helpful but not give away everything - use riddles
- Fit the storyline theme
{f"- Reference being dead/undead, being 200 years old, and the 'dead men tell no tales' theme" if use_skeletons else ""}
{f"- Give riddles about WHERE TO DIG using real map features (e.g., 'dig where the river meets the oak')" if use_skeletons else ""}

Respond in JSON format:
{{
    "npcs": [
        {{
            "name": "Pirate NPC name",
            "character_type": "captain/first_mate/navigator/skeleton/etc",
            "personality": "pirate personality description",
            "backstory": "brief pirate backstory",
            "knowledge": ["pirate hint 1", "pirate hint 2"],
            "is_skeleton": {str(use_skeletons).lower()}
        }}
    ]
}}"""
        
        npcs_response = self._call_llm(npcs_prompt)
        try:
            npcs_data = json.loads(npcs_response)
            npcs = npcs_data.get('npcs', [])
        except:
            npcs = [
                {
                    "name": "Ancient Guide",
                    "character_type": "guide",
                    "personality": "wise and mysterious",
                    "backstory": "A guardian of ancient secrets",
                    "knowledge": ["The treasure lies hidden", "Follow the clues carefully"]
                }
            ]
        
        # Step 5: Generate map with landmarks and areas (pirate-themed)
        map_prompt = f"""Create a PIRATE treasure huntin' map for this quest:

Storyline: {quest_data['storyline']}
Target Location: {target_object.get('latitude', 0)}, {target_object.get('longitude', 0)}
Theme: {quest_data.get('theme', 'Treasure hunting')}
Clues: {len(clues)} clues will be placed
Real Map Features: {feature_description}

Create a PIRATE-THEMED treasure map with:
- 5-8 landmarks based on REAL map features (use the actual features listed above)
- 3-5 named areas (cove, bay, grove, ruins, etc.) - pirate-themed names
- Paths connecting important locations
- A pirate map name and description

The map should:
- Use PIRATE terminology (cove, bay, grove, lookout point, etc.)
- Reference the real map features (water, trees, buildings, elevation)
- Fit the storyline theme
- Not reveal exact treasure location, but create landmarks that clues can reference

Respond in JSON format:
{{
    "map_name": "Pirate map name",
    "map_description": "Pirate description of the map",
    "landmarks": [
        {{"name": "Pirate landmark name", "type": "cove/cave/tree/etc", "description": "pirate description", "latitude": 0.0, "longitude": 0.0}},
        ...
    ],
    "areas": [
        {{"name": "Pirate area name", "type": "cove/bay/grove/etc", "description": "pirate description", "boundary": [[lat, lon], ...]}},
        ...
    ]
}}"""
        
        map_response = self._call_llm(map_prompt)
        try:
            map_data = json.loads(map_response)
        except:
            # Fallback map
            map_data = {
                "map_name": f"{quest_data.get('theme', 'Treasure')} Map",
                "map_description": "A mysterious map of the treasure hunting area",
                "landmarks": [
                    {"name": "Ancient Temple", "type": "temple", "description": "An old temple", "latitude": target_object.get('latitude', 0) + 0.001, "longitude": target_object.get('longitude', 0) + 0.001},
                    {"name": "Hidden Cave", "type": "cave", "description": "A secret cave", "latitude": target_object.get('latitude', 0) - 0.001, "longitude": target_object.get('longitude', 0) - 0.001}
                ],
                "areas": [
                    {"name": "Mysterious Forest", "type": "forest", "description": "A dense forest", "boundary": []}
                ]
            }
        
        return {
            "storyline": quest_data['storyline'],
            "target_object": target_object,
            "clues": clues,
            "npcs": npcs,
            "map": map_data,
            "map_features": map_features,  # Include real map features
            "elevation": elevation,
            "theme": quest_data.get('theme', 'Treasure hunting')
        }
    
    def create_quest_chain(
        self,
        object_ids: List[str],
        quest_name: str,
        theme: Optional[str] = None
    ) -> Dict:
        """Generate a complete quest chain with clues connecting objects."""
        # This would fetch object data and generate clues for each step
        # Implementation details...
        pass
    
    def _call_llm(self, prompt: str = None, messages: List[Dict] = None) -> str:
        """Internal method to call the LLM API."""
        if self.config.provider == "openai":
            if messages:
                response = openai.ChatCompletion.create(
                    model=self.config.model,
                    messages=messages,
                    temperature=self.config.temperature,
                    max_tokens=self.config.max_tokens
                )
            else:
                response = openai.ChatCompletion.create(
                    model=self.config.model,
                    messages=[{"role": "user", "content": prompt}],
                    temperature=self.config.temperature,
                    max_tokens=self.config.max_tokens
                )
            return response.choices[0].message.content
        # Add other providers (Anthropic, local models, etc.)
        raise NotImplementedError(f"Provider {self.config.provider} not implemented")
```

### 2. New API Endpoints (`server/app.py` additions)

```python
# Add to app.py

from llm_service import LLMService, LLMConfig

# Initialize LLM service
llm_service = LLMService(LLMConfig(
    provider=os.getenv("LLM_PROVIDER", "openai"),
    model=os.getenv("LLM_MODEL", "gpt-4o-mini"),
    api_key=os.getenv("OPENAI_API_KEY"),
    temperature=0.7
))

@app.route('/api/objects/<object_id>/interact', methods=['POST'])
def interact_with_object(object_id: str):
    """Interact with an object via LLM conversation."""
    data = request.json
    device_uuid = data.get('device_uuid')
    message = data.get('message')
    
    if not device_uuid or not message:
        return jsonify({'error': 'device_uuid and message required'}), 400
    
    # Get object data
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute('SELECT * FROM objects WHERE id = ?', (object_id,))
    object_row = cursor.fetchone()
    
    if not object_row:
        conn.close()
        return jsonify({'error': 'Object not found'}), 404
    
    # Get object metadata
    cursor.execute('SELECT * FROM object_metadata WHERE object_id = ?', (object_id,))
    metadata_row = cursor.fetchone()
    
    object_data = {
        'name': object_row['name'],
        'type': object_row['type'],
        'backstory': metadata_row['backstory'] if metadata_row else None,
        'personality': metadata_row['personality'] if metadata_row else 'mysterious'
    }
    
    # Get conversation history (last 10 messages)
    cursor.execute('''
        SELECT message, response, created_at
        FROM object_interactions
        WHERE object_id = ? AND device_uuid = ?
        ORDER BY created_at DESC
        LIMIT 10
    ''', (object_id, device_uuid))
    history = cursor.fetchall()
    
    conversation_history = [
        {
            'from_user': True,
            'message': row['message'],
            'timestamp': row['created_at']
        }
        for row in reversed(history)
    ]
    
    # Generate response using LLM
    try:
        response = llm_service.generate_conversation_response(
            object_data,
            message,
            conversation_history
        )
    except Exception as e:
        conn.close()
        return jsonify({'error': f'LLM error: {str(e)}'}), 500
    
    # Save interaction
    interaction_id = str(uuid.uuid4())
    cursor.execute('''
        INSERT INTO object_interactions 
        (id, object_id, device_uuid, interaction_type, message, response, created_at)
        VALUES (?, ?, ?, 'conversation', ?, ?, ?)
    ''', (interaction_id, object_id, device_uuid, message, response, datetime.utcnow().isoformat()))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'interaction_id': interaction_id,
        'response': response,
        'object_id': object_id
    }), 200

@app.route('/api/objects/<object_id>/clue', methods=['GET'])
def get_object_clue(object_id: str):
    """Get a clue for finding this object (if it's part of a quest chain)."""
    device_uuid = request.args.get('device_uuid')
    
    if not device_uuid:
        return jsonify({'error': 'device_uuid required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if object is part of a quest chain
    cursor.execute('''
        SELECT quest_chain_id, quest_step_order
        FROM objects
        WHERE id = ?
    ''', (object_id,))
    object_row = cursor.fetchone()
    
    if not object_row or not object_row['quest_chain_id']:
        conn.close()
        return jsonify({'error': 'Object is not part of a quest chain'}), 404
    
    chain_id = object_row['quest_chain_id']
    step_order = object_row['quest_step_order']
    
    # Check user's progress
    cursor.execute('''
        SELECT current_step
        FROM user_quest_progress
        WHERE device_uuid = ? AND chain_id = ?
    ''', (device_uuid, chain_id))
    progress = cursor.fetchone()
    
    if not progress or progress['current_step'] < step_order - 1:
        conn.close()
        return jsonify({'error': 'Previous quest steps not completed'}), 403
    
    # Get clue from quest_chain_steps
    cursor.execute('''
        SELECT clue_text
        FROM quest_chain_steps
        WHERE chain_id = ? AND step_order = ?
    ''', (chain_id, step_order))
    clue_row = cursor.fetchone()
    
    conn.close()
    
    if clue_row and clue_row['clue_text']:
        return jsonify({
            'clue': clue_row['clue_text'],
            'object_id': object_id,
            'chain_id': chain_id,
            'step': step_order
        }), 200
    else:
        return jsonify({'error': 'Clue not found'}), 404

@app.route('/api/objects/<object_id>/found', methods=['POST'])
def mark_found_with_quest_check(object_id: str):
    """Enhanced mark_found that handles quest chain progression."""
    # ... existing mark_found logic ...
    
    # After marking as found, check if this unlocks a quest step
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT quest_chain_id, quest_step_order
        FROM objects
        WHERE id = ?
    ''', (object_id,))
    object_row = cursor.fetchone()
    
    if object_row and object_row['quest_chain_id']:
        chain_id = object_row['quest_chain_id']
        step_order = object_row['quest_step_order']
        found_by = request.json.get('found_by')
        
        # Update user quest progress
        cursor.execute('''
            INSERT INTO user_quest_progress (id, device_uuid, chain_id, current_step, completed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(device_uuid, chain_id) DO UPDATE SET
                current_step = MAX(current_step, ?),
                completed_at = ?
        ''', (
            str(uuid.uuid4()),
            found_by,
            chain_id,
            step_order,
            datetime.utcnow().isoformat(),
            step_order,
            datetime.utcnow().isoformat()
        ))
        
        # Check if there's a next step and generate clue
        cursor.execute('''
            SELECT o.id, o.name, o.type, o.latitude, o.longitude
            FROM objects o
            JOIN quest_chain_steps qcs ON o.id = qcs.object_id
            WHERE qcs.chain_id = ? AND qcs.step_order = ?
        ''', (chain_id, step_order + 1))
        next_object = cursor.fetchone()
        
        if next_object:
            # Generate clue for next object
            current_object = {
                'name': object_row['name'],
                'type': object_row['type']
            }
            next_object_data = {
                'name': next_object['name'],
                'type': next_object['type'],
                'latitude': next_object['latitude'],
                'longitude': next_object['longitude']
            }
            
            try:
                clue = llm_service.generate_clue(current_object, next_object_data)
                
                # Store clue in quest_chain_steps
                cursor.execute('''
                    UPDATE quest_chain_steps
                    SET clue_text = ?
                    WHERE chain_id = ? AND step_order = ?
                ''', (clue, chain_id, step_order + 1))
                
                conn.commit()
                
                # Broadcast clue to user via WebSocket
                socketio.emit('quest_clue_unlocked', {
                    'chain_id': chain_id,
                    'step': step_order + 1,
                    'clue': clue,
                    'next_object_id': next_object['id']
                }, room=found_by)
                
            except Exception as e:
                print(f"⚠️ Error generating clue: {e}")
        
        conn.commit()
    
    conn.close()
    
    # ... return existing response ...

@app.route('/api/npcs', methods=['GET'])
def get_npcs():
    """Get all NPCs, optionally filtered by location."""
    try:
        latitude = request.args.get('latitude', type=float)
        longitude = request.args.get('longitude', type=float)
        radius = request.args.get('radius', type=float, default=10000.0)
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        query = 'SELECT * FROM npc_characters WHERE is_active = 1'
        params = []
        
        if latitude is not None and longitude is not None:
            lat_range = radius / 111000.0
            lon_range = radius / (111000.0 * abs(math.cos(math.radians(latitude))))
            query += ' AND (latitude BETWEEN ? AND ?) AND (longitude BETWEEN ? AND ?)'
            params.extend([latitude - lat_range, latitude + lat_range,
                          longitude - lon_range, longitude + lon_range])
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        conn.close()
        
        npcs = [{
            'id': row['id'],
            'name': row['name'],
            'character_type': row['character_type'],
            'personality': row['personality'],
            'backstory': row['backstory'],
            'latitude': row['latitude'],
            'longitude': row['longitude'],
            'ar_offset_x': row['ar_offset_x'],
            'ar_offset_y': row['ar_offset_y'],
            'ar_offset_z': row['ar_offset_z'],
            'radius': row['radius']
        } for row in rows]
        
        return jsonify(npcs), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/npcs/<npc_id>/interact', methods=['POST'])
def interact_with_npc(npc_id: str):
    """Interact with an NPC character via LLM conversation."""
    data = request.json
    device_uuid = data.get('device_uuid')
    message = data.get('message')
    
    if not device_uuid or not message:
        return jsonify({'error': 'device_uuid and message required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Get NPC data
    cursor.execute('SELECT * FROM npc_characters WHERE id = ? AND is_active = 1', (npc_id,))
    npc_row = cursor.fetchone()
    
    if not npc_row:
        conn.close()
        return jsonify({'error': 'NPC not found'}), 404
    
    npc_data = {
        'name': npc_row['name'],
        'character_type': npc_row['character_type'],
        'personality': npc_row['personality'],
        'backstory': npc_row['backstory']
    }
    
    # Get NPC's knowledge (what they know about)
    cursor.execute('''
        SELECT nk.*, 
               CASE 
                   WHEN nk.unlock_condition IS NULL THEN 1
                   WHEN nk.unlock_condition LIKE 'after_finding_object:%' THEN
                       CASE WHEN EXISTS (
                           SELECT 1 FROM finds f 
                           WHERE f.object_id = SUBSTR(nk.unlock_condition, 24)
                           AND f.found_by = ?
                       ) THEN 1 ELSE 0 END
                   ELSE 1
               END as unlocked
        FROM npc_knowledge nk
        WHERE nk.npc_id = ?
    ''', (device_uuid, npc_id))
    knowledge_rows = cursor.fetchall()
    
    available_knowledge = [
        {
            'knowledge_text': row['knowledge_text'],
            'knowledge_type': row['knowledge_type'],
            'unlocked': bool(row['unlocked'])
        }
        for row in knowledge_rows if row['unlocked']
    ]
    
    # Get user's progress
    cursor.execute('''
        SELECT o.name
        FROM finds f
        JOIN objects o ON f.object_id = o.id
        WHERE f.found_by = ?
        ORDER BY f.found_at DESC
        LIMIT 10
    ''', (device_uuid,))
    found_objects = [row['name'] for row in cursor.fetchall()]
    
    cursor.execute('''
        SELECT DISTINCT qc.name
        FROM user_quest_progress uqp
        JOIN quest_chains qc ON uqp.chain_id = qc.id
        WHERE uqp.device_uuid = ?
    ''', (device_uuid,))
    active_quests = [row['name'] for row in cursor.fetchall()]
    
    user_progress = {
        'found_objects': found_objects,
        'active_quests': active_quests
    }
    
    # Get conversation history
    cursor.execute('''
        SELECT message, response, created_at
        FROM npc_interactions
        WHERE npc_id = ? AND device_uuid = ?
        ORDER BY created_at DESC
        LIMIT 10
    ''', (npc_id, device_uuid))
    history = cursor.fetchall()
    
    conversation_history = [
        {
            'from_user': True,
            'message': row['message'],
            'timestamp': row['created_at']
        }
        for row in reversed(history)
    ]
    
    # Generate response using LLM
    try:
        response = llm_service.generate_npc_response(
            npc_data,
            message,
            available_knowledge,
            user_progress,
            conversation_history
        )
    except Exception as e:
        conn.close()
        return jsonify({'error': f'LLM error: {str(e)}'}), 500
    
    # Save interaction
    interaction_id = str(uuid.uuid4())
    cursor.execute('''
        INSERT INTO npc_interactions 
        (id, npc_id, device_uuid, message, response, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
    ''', (interaction_id, npc_id, device_uuid, message, response, datetime.utcnow().isoformat()))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'interaction_id': interaction_id,
        'response': response,
        'npc_id': npc_id,
        'npc_name': npc_data['name']
    }), 200

@app.route('/api/npcs', methods=['POST'])
def create_npc():
    """Create a new NPC character."""
    data = request.json
    
    required_fields = ['name', 'character_type', 'personality']
    for field in required_fields:
        if field not in data:
            return jsonify({'error': f'Missing required field: {field}'}), 400
    
    npc_id = str(uuid.uuid4())
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        INSERT INTO npc_characters 
        (id, name, character_type, personality, backstory, latitude, longitude,
         ar_offset_x, ar_offset_y, ar_offset_z, ar_origin_latitude, ar_origin_longitude,
         radius, is_active, created_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', (
        npc_id,
        data['name'],
        data['character_type'],
        data['personality'],
        data.get('backstory'),
        data.get('latitude'),
        data.get('longitude'),
        data.get('ar_offset_x'),
        data.get('ar_offset_y'),
        data.get('ar_offset_z'),
        data.get('ar_origin_latitude'),
        data.get('ar_origin_longitude'),
        data.get('radius', 50.0),
        data.get('is_active', True),
        datetime.utcnow().isoformat(),
        data.get('created_by', 'system')
    ))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'id': npc_id,
        'message': 'NPC created successfully'
    }), 201

@app.route('/api/npcs/<npc_id>/knowledge', methods=['POST'])
def add_npc_knowledge(npc_id: str):
    """Add knowledge to an NPC about objects or quests."""
    data = request.json
    
    if 'knowledge_text' not in data or 'knowledge_type' not in data:
        return jsonify({'error': 'knowledge_text and knowledge_type required'}), 400
    
    knowledge_id = str(uuid.uuid4())
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Verify NPC exists
    cursor.execute('SELECT id FROM npc_characters WHERE id = ?', (npc_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'NPC not found'}), 404
    
    cursor.execute('''
        INSERT INTO npc_knowledge
        (id, npc_id, object_id, quest_chain_id, knowledge_type, knowledge_text, unlock_condition, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', (
        knowledge_id,
        npc_id,
        data.get('object_id'),
        data.get('quest_chain_id'),
        data['knowledge_type'],
        data['knowledge_text'],
        data.get('unlock_condition'),
        datetime.utcnow().isoformat()
    ))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'id': knowledge_id,
        'message': 'Knowledge added to NPC'
    }), 201

@app.route('/api/llm-quests/generate', methods=['POST'])
def generate_llm_quest():
    """Generate a complete LLM-driven quest: storyline, hide object, create clues, place NPCs, generate map."""
    data = request.json
    user_location = data.get('user_location')  # {latitude, longitude}
    context = data.get('context')  # Optional context for quest generation
    
    if not user_location:
        return jsonify({'error': 'user_location required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Get available unfound objects near user
    lat = user_location['latitude']
    lon = user_location['longitude']
    radius = 5000.0  # 5km radius
    
    cursor.execute('''
        SELECT o.*
        FROM objects o
        LEFT JOIN finds f ON o.id = f.object_id
        WHERE f.id IS NULL
        AND o.is_hidden = 0
        AND o.is_clue = 0
        AND (o.latitude BETWEEN ? AND ?)
        AND (o.longitude BETWEEN ? AND ?)
        LIMIT 20
    ''', (
        lat - (radius / 111000.0),
        lat + (radius / 111000.0),
        lon - (radius / (111000.0 * abs(math.cos(math.radians(lat))))),
        lon + (radius / (111000.0 * abs(math.cos(math.radians(lat)))))
    ))
    
    available_objects = [dict(row) for row in cursor.fetchall()]
    
    if len(available_objects) < 1:
        conn.close()
        return jsonify({'error': 'No available objects for quest generation'}), 404
    
    # Generate quest using LLM
    try:
        quest_data = llm_service.generate_llm_quest(
            available_objects,
            user_location,
            context
        )
    except Exception as e:
        conn.close()
        return jsonify({'error': f'LLM quest generation failed: {str(e)}'}), 500
    
    # Create quest record
    quest_id = str(uuid.uuid4())
    target_object = quest_data['target_object']
    
    cursor.execute('''
        INSERT INTO llm_quests (id, storyline, target_object_id, status, created_at, created_by)
        VALUES (?, ?, ?, 'active', ?, ?)
    ''', (quest_id, quest_data['storyline'], target_object['id'], 
          datetime.utcnow().isoformat(), data.get('created_by', 'system')))
    
    # Hide target object
    cursor.execute('''
        UPDATE objects
        SET is_hidden = 1
        WHERE id = ?
    ''', (target_object['id'],))
    
    # Create map
    map_id = str(uuid.uuid4())
    map_data = quest_data['map']
    cursor.execute('''
        INSERT INTO llm_maps (id, quest_id, map_name, map_description, center_latitude, center_longitude, map_style, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', (map_id, quest_id, map_data['map_name'], map_data['map_description'],
          user_location['latitude'], user_location['longitude'], 'thematic',
          datetime.utcnow().isoformat()))
    
    # Add landmarks to map
    for landmark in map_data.get('landmarks', []):
        landmark_id = str(uuid.uuid4())
        cursor.execute('''
            INSERT INTO map_landmarks (id, map_id, name, description, landmark_type, latitude, longitude, icon_type, created_at)
            VALUES (?, ?, ?, ?, 'landmark', ?, ?, ?, ?)
        ''', (landmark_id, map_id, landmark['name'], landmark.get('description', ''),
              landmark.get('latitude', user_location['latitude']),
              landmark.get('longitude', user_location['longitude']),
              landmark.get('type', 'landmark'),
              datetime.utcnow().isoformat()))
    
    # Add areas to map
    for area in map_data.get('areas', []):
        area_id = str(uuid.uuid4())
        boundary_json = json.dumps(area.get('boundary', []))
        cursor.execute('''
            INSERT INTO map_areas (id, map_id, name, description, area_type, boundary_coordinates, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', (area_id, map_id, area['name'], area.get('description', ''),
              area.get('type', 'area'), boundary_json,
              datetime.utcnow().isoformat()))
    
    # Store real map features
    map_features_data = quest_data.get('map_features', [])
    for feature in map_features_data:
        feature_id = str(uuid.uuid4())
        cursor.execute('''
            INSERT INTO map_features (id, quest_id, feature_type, feature_name, latitude, longitude, elevation, description, metadata, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (feature_id, quest_id, feature.get('type', 'unknown'), feature.get('name'),
              feature.get('latitude', user_location['latitude']),
              feature.get('longitude', user_location['longitude']),
              feature.get('elevation'),
              feature.get('description', ''),
              json.dumps(feature.get('tags', {})),
              datetime.utcnow().isoformat()))
    
    # Create clue objects (including treasure map as first clue)
    clue_object_ids = []
    for clue in quest_data['clues']:
        clue_object_id = str(uuid.uuid4())
        clue_object_ids.append(clue_object_id)
        
        is_treasure_map = clue.get('is_treasure_map', False)
        object_name = "Treasure Map" if is_treasure_map else f"Clue #{clue['order']}"
        object_type = "treasure_map" if is_treasure_map else "clue"
        
        # Create a clue object (or treasure map)
        if is_treasure_map:
            cursor.execute('''
                INSERT INTO objects (id, name, type, latitude, longitude, radius, created_at, is_clue, is_treasure_map, clue_text, target_object_id, map_target_latitude, map_target_longitude)
                VALUES (?, ?, ?, ?, ?, 50.0, ?, 1, 1, ?, ?, ?, ?)
            ''', (clue_object_id, object_name, object_type,
                  user_location['latitude'] + (clue['order'] * 0.001),
                  user_location['longitude'] + (clue['order'] * 0.001),
                  datetime.utcnow().isoformat(), clue['text'], target_object['id'],
                  clue.get('map_target_latitude', target_object['latitude']),
                  clue.get('map_target_longitude', target_object['longitude'])))
        else:
            cursor.execute('''
                INSERT INTO objects (id, name, type, latitude, longitude, radius, created_at, is_clue, clue_text, target_object_id)
                VALUES (?, ?, 'clue', ?, ?, 50.0, ?, 1, ?, ?)
            ''', (clue_object_id, object_name, 
                  user_location['latitude'] + (clue['order'] * 0.001),
                  user_location['longitude'] + (clue['order'] * 0.001),
                  datetime.utcnow().isoformat(), clue['text'], target_object['id']))
        
        # Create clue_objects record
        clue_record_id = str(uuid.uuid4())
        cursor.execute('''
            INSERT INTO clue_objects (id, quest_id, clue_order, clue_text, object_id, latitude, longitude, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', (clue_record_id, quest_id, clue['order'], clue['text'], clue_object_id,
              user_location['latitude'] + (clue['order'] * 0.001),
              user_location['longitude'] + (clue['order'] * 0.001),
              datetime.utcnow().isoformat()))
    
    # Create NPCs
    npc_ids = []
    for npc_data in quest_data['npcs']:
        npc_id = str(uuid.uuid4())
        npc_ids.append(npc_id)
        
        cursor.execute('''
            INSERT INTO npc_characters (id, name, character_type, personality, backstory, latitude, longitude, radius, is_active, created_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, 50.0, 1, ?, ?)
        ''', (npc_id, npc_data['name'], npc_data['character_type'], npc_data['personality'],
              npc_data.get('backstory', ''), user_location['latitude'], user_location['longitude'],
              datetime.utcnow().isoformat(), 'llm'))
        
        # Link NPC to quest
        quest_npc_id = str(uuid.uuid4())
        cursor.execute('''
            INSERT INTO quest_npcs (id, quest_id, npc_id, role, created_at)
            VALUES (?, ?, ?, ?, ?)
        ''', (quest_npc_id, quest_id, npc_id, npc_data['character_type'],
              datetime.utcnow().isoformat()))
        
        # Add NPC knowledge about the quest
        for knowledge_text in npc_data.get('knowledge', []):
            knowledge_id = str(uuid.uuid4())
            cursor.execute('''
                INSERT INTO npc_knowledge (id, npc_id, quest_chain_id, knowledge_type, knowledge_text, created_at)
                VALUES (?, ?, ?, 'hint', ?, ?)
            ''', (knowledge_id, npc_id, quest_id, knowledge_text,
                  datetime.utcnow().isoformat()))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'quest_id': quest_id,
        'storyline': quest_data['storyline'],
        'target_object_id': target_object['id'],
        'target_object_name': target_object['name'],
        'map_id': map_id,
        'clues_count': len(quest_data['clues']),
        'npcs_count': len(quest_data['npcs']),
        'message': 'LLM quest generated successfully'
    }), 201

@app.route('/api/llm-quests/<quest_id>/map', methods=['GET'])
def get_quest_map(quest_id: str):
    """Get the LLM-generated map for a quest."""
    device_uuid = request.args.get('device_uuid')
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Get map
    cursor.execute('SELECT * FROM llm_maps WHERE quest_id = ?', (quest_id,))
    map_row = cursor.fetchone()
    
    if not map_row:
        conn.close()
        return jsonify({'error': 'Map not found'}), 404
    
    # Get landmarks
    cursor.execute('''
        SELECT * FROM map_landmarks
        WHERE map_id = ? AND is_visible = 1
        ORDER BY name
    ''', (map_row['id'],))
    landmarks = [dict(row) for row in cursor.fetchall()]
    
    # Get areas
    cursor.execute('''
        SELECT * FROM map_areas
        WHERE map_id = ? AND is_visible = 1
        ORDER BY name
    ''', (map_row['id'],))
    areas = [dict(row) for row in cursor.fetchall()]
    
    # Get user's clue progress
    clues_found = []
    if device_uuid:
        cursor.execute('''
            SELECT co.clue_order, co.clue_text
            FROM user_quest_clues uqc
            JOIN clue_objects co ON uqc.clue_id = co.id
            WHERE uqc.quest_id = ? AND uqc.device_uuid = ?
        ''', (quest_id, device_uuid))
        clues_found = [dict(row) for row in cursor.fetchall()]
    
    # Get real map features
    cursor.execute('''
        SELECT * FROM map_features
        WHERE quest_id = ?
        ORDER BY feature_type
    ''', (quest_id,))
    map_features = [dict(row) for row in cursor.fetchall()]
    
    conn.close()
    
    return jsonify({
        'map_id': map_row['id'],
        'map_name': map_row['map_name'],
        'map_description': map_row['map_description'],
        'center': {
            'latitude': map_row['center_latitude'],
            'longitude': map_row['center_longitude']
        },
        'zoom_level': map_row['zoom_level'],
        'landmarks': landmarks,
        'areas': areas,
        'map_features': map_features,  # Real geographic features
        'clues_found': clues_found,
        'gps_navigation_disabled': True  # GPS navigation is disabled for LLM quests
    }), 200

@app.route('/api/objects/<object_id>/treasure-map', methods=['GET'])
def get_treasure_map(object_id: str):
    """Get treasure map data when user finds the map object."""
    device_uuid = request.args.get('device_uuid')
    
    if not device_uuid:
        return jsonify({'error': 'device_uuid required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if object is a treasure map
    cursor.execute('''
        SELECT o.*, 
               CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as is_found
        FROM objects o
        LEFT JOIN finds f ON o.id = f.object_id AND f.found_by = ?
        WHERE o.id = ? AND o.is_treasure_map = 1
    ''', (device_uuid, object_id))
    
    map_object = cursor.fetchone()
    
    if not map_object:
        conn.close()
        return jsonify({'error': 'Treasure map not found'}), 404
    
    if not map_object['is_found']:
        conn.close()
        return jsonify({'error': 'Treasure map must be found first'}), 403
    
    # Get the target location (X marks the spot)
    x_latitude = map_object.get('map_target_latitude')
    x_longitude = map_object.get('map_target_longitude')
    
    if not x_latitude or not x_longitude:
        conn.close()
        return jsonify({'error': 'Map target location not set'}), 500
    
    conn.close()
    
    return jsonify({
        'map_id': object_id,
        'map_name': map_object['name'],
        'x_marks_the_spot': {
            'latitude': x_latitude,
            'longitude': x_longitude
        },
        'map_description': f"X marks the spot where the 200-year-old treasure is buried!",
        'is_found': True
    }), 200

@app.route('/api/quests', methods=['POST'])
def create_quest_chain():
    """Create a new quest chain linking objects together."""
    data = request.json
    object_ids = data.get('object_ids', [])
    quest_name = data.get('name', 'Mystery Quest')
    theme = data.get('theme')
    
    if len(object_ids) < 2:
        return jsonify({'error': 'Need at least 2 objects for a quest chain'}), 400
    
    # Create quest chain
    chain_id = str(uuid.uuid4())
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        INSERT INTO quest_chains (id, name, description, created_at, created_by)
        VALUES (?, ?, ?, ?, ?)
    ''', (chain_id, quest_name, theme or '', datetime.utcnow().isoformat(), data.get('created_by', 'system')))
    
    # Get object data
    placeholders = ','.join(['?'] * len(object_ids))
    cursor.execute(f'''
        SELECT id, name, type, latitude, longitude
        FROM objects
        WHERE id IN ({placeholders})
    ''', object_ids)
    objects = cursor.fetchall()
    
    if len(objects) != len(object_ids):
        conn.rollback()
        conn.close()
        return jsonify({'error': 'Some objects not found'}), 404
    
    # Create quest steps and generate clues
    for i, obj in enumerate(objects):
        step_id = str(uuid.uuid4())
        
        # Generate clue (except for first object)
        clue_text = None
        if i > 0:
            current_obj = {
                'name': objects[i-1]['name'],
                'type': objects[i-1]['type']
            }
            next_obj = {
                'name': obj['name'],
                'type': obj['type'],
                'latitude': obj['latitude'],
                'longitude': obj['longitude']
            }
            try:
                clue_text = llm_service.generate_clue(current_obj, next_obj, theme)
            except Exception as e:
                print(f"⚠️ Error generating clue: {e}")
                clue_text = f"Find the {obj['name']}!"
        
        cursor.execute('''
            INSERT INTO quest_chain_steps (id, chain_id, object_id, step_order, clue_text, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        ''', (step_id, chain_id, obj['id'], i + 1, clue_text, datetime.utcnow().isoformat()))
        
        # Update object to reference quest chain
        cursor.execute('''
            UPDATE objects
            SET quest_chain_id = ?, quest_step_order = ?
            WHERE id = ?
        ''', (chain_id, i + 1, obj['id']))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'chain_id': chain_id,
        'name': quest_name,
        'steps': len(object_ids),
        'message': 'Quest chain created successfully'
    }), 201
```

## iOS Client Implementation

### 1. New Swift Models

```swift
// QuestChain.swift
struct QuestChain: Codable {
    let id: String
    let name: String
    let description: String?
    let steps: [QuestStep]
}

struct QuestStep: Codable {
    let id: String
    let objectId: String
    let stepOrder: Int
    let clueText: String?
    let isCompleted: Bool
}

struct ObjectInteraction: Codable {
    let interactionId: String
    let response: String
    let objectId: String
}

struct QuestClue: Codable {
    let clue: String
    let objectId: String
    let chainId: String
    let step: Int
}
```

### 2. Enhanced APIService

```swift
// Add to APIService.swift

func interactWithObject(objectId: String, message: String, deviceUUID: String) async throws -> ObjectInteraction {
    let url = URL(string: "\(baseURL)/api/objects/\(objectId)/interact")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body: [String: Any] = [
        "device_uuid": deviceUUID,
        "message": message
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(ObjectInteraction.self, from: data)
}

func getClueForObject(objectId: String, deviceUUID: String) async throws -> QuestClue {
    let url = URL(string: "\(baseURL)/api/objects/\(objectId)/clue?device_uuid=\(deviceUUID)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode(QuestClue.self, from: data)
}

func getNPCs(latitude: Double? = nil, longitude: Double? = nil, radius: Double = 10000.0) async throws -> [NPCCharacter] {
    var urlString = "\(baseURL)/api/npcs"
    var components = URLComponents(string: urlString)!
    var queryItems: [URLQueryItem] = []
    
    if let lat = latitude, let lon = longitude {
        queryItems.append(URLQueryItem(name: "latitude", value: String(lat)))
        queryItems.append(URLQueryItem(name: "longitude", value: String(lon)))
        queryItems.append(URLQueryItem(name: "radius", value: String(radius)))
    }
    
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    let url = components.url!
    
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode([NPCCharacter].self, from: data)
}

func interactWithNPC(npcId: String, message: String, deviceUUID: String) async throws -> NPCInteraction {
    let url = URL(string: "\(baseURL)/api/npcs/\(npcId)/interact")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body: [String: Any] = [
        "device_uuid": deviceUUID,
        "message": message
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(NPCInteraction.self, from: data)
}

func generateLLMQuest(userLocation: CLLocationCoordinate2D, context: String? = nil) async throws -> LLMQuest {
    let url = URL(string: "\(baseURL)/api/llm-quests/generate")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    var body: [String: Any] = [
        "user_location": [
            "latitude": userLocation.latitude,
            "longitude": userLocation.longitude
        ]
    ]
    if let context = context {
        body["context"] = context
    }
    
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(LLMQuest.self, from: data)
}

func getQuestMap(questId: String, deviceUUID: String) async throws -> QuestMap {
    let url = URL(string: "\(baseURL)/api/llm-quests/\(questId)/map?device_uuid=\(deviceUUID)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode(QuestMap.self, from: data)
}

func spawnSkeletonWhenStuck(questId: String, deviceUUID: String, userLocation: CLLocationCoordinate2D, timeSinceLastFind: TimeInterval) async throws -> SkeletonSpawnResponse {
    let url = URL(string: "\(baseURL)/api/llm-quests/\(questId)/spawn-skeleton")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body: [String: Any] = [
        "device_uuid": deviceUUID,
        "user_location": [
            "latitude": userLocation.latitude,
            "longitude": userLocation.longitude
        ],
        "time_since_last_find": timeSinceLastFind / 60.0  // Convert to minutes
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(SkeletonSpawnResponse.self, from: data)
}

struct SkeletonSpawnResponse: Codable {
    let npcId: String
    let name: String
    let riddle: String
    let message: String
    let arLocation: MapCoordinate
}
```

### 3. Interaction UI Component

```swift
// ObjectInteractionView.swift
import SwiftUI

struct ObjectInteractionView: View {
    let objectId: String
    let objectName: String
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack {
            // Chat messages
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ChatBubble(message: message)
                    }
                }
                .padding()
            }
            
            // Input area
            HStack {
                TextField("Ask a question...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isLoading)
                
                Button(action: sendMessage) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(inputText.isEmpty || isLoading)
            }
            .padding()
        }
        .navigationTitle(objectName)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func sendMessage() {
        let userMessage = inputText
        inputText = ""
        isLoading = true
        
        messages.append(ChatMessage(text: userMessage, isFromUser: true))
        
        Task {
            do {
                let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
                let interaction = try await APIService.shared.interactWithObject(
                    objectId: objectId,
                    message: userMessage,
                    deviceUUID: deviceUUID
                )
                
                await MainActor.run {
                    messages.append(ChatMessage(text: interaction.response, isFromUser: false))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(
                        text: "Sorry, I couldn't process that. Please try again.",
                        isFromUser: false
                    ))
                    isLoading = false
                }
            }
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isFromUser: Bool
}

struct ChatBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()
            }
            
            Text(message.text)
                .padding()
                .background(message.isFromUser ? Color.blue : Color.gray.opacity(0.2))
                .foregroundColor(message.isFromUser ? .white : .primary)
                .cornerRadius(12)
            
            if !message.isFromUser {
                Spacer()
            }
        }
    }
}
```

### 4. Enhanced FindableObject

```swift
// Add to FindableObject.swift

extension FindableObject {
    /// Check if this object is interactive (can be talked to)
    var isInteractive: Bool {
        return location?.isInteractive ?? false
    }
    
    /// Show interaction UI when object is tapped (if interactive)
    func showInteractionUI(in viewController: UIViewController) {
        guard isInteractive, let location = location else { return }
        
        let interactionView = ObjectInteractionView(
            objectId: locationId,
            objectName: location.name
        )
        let hostingController = UIHostingController(rootView: interactionView)
        viewController.present(hostingController, animated: true)
    }
}
```

### 5. Quest Clue Notification

```swift
// Add to ARCoordinator or ContentView

func handleQuestClueUnlocked(_ clue: QuestClue) {
    // Show notification with clue
    let alert = UIAlertController(
        title: "New Clue Unlocked!",
        message: clue.clue,
        preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    
    // Present alert
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootViewController = windowScene.windows.first?.rootViewController {
        rootViewController.present(alert, animated: true)
    }
}
```

## WebSocket Events

Add to `server/app.py`:

```python
@socketio.on('request_clue')
def handle_request_clue(data):
    """Client requests a clue for an object."""
    object_id = data.get('object_id')
    device_uuid = data.get('device_uuid')
    
    # Similar logic to GET /api/objects/<id>/clue
    # Emit clue back to client
    socketio.emit('clue_received', {
        'object_id': object_id,
        'clue': clue_text
    })
```

## Skeleton NPC Implementation

### Skeleton Model
- **Model File**: `Curious_skeleton.usdz` (added to project)
- **Usage**: Used for "Dead Men Tell No Tales" game mode
- **Placement**: Skeletons appear at key locations in AR
- **Interaction**: Tap skeleton to chat and get clues

### Skeleton NPC Swift Implementation

```swift
// SkeletonNPCView.swift
import SwiftUI
import RealityKit

struct SkeletonNPCView: View {
    let npcId: String
    let npcName: String
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    
    var body: some View {
        VStack {
            // Skeleton header with pirate theme
            HStack {
                Image(systemName: "skull")
                    .font(.title)
                    .foregroundColor(.orange)
                Text(npcName)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
            
            // Chat messages
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ChatBubble(message: message)
                    }
                }
                .padding()
            }
            
            // Input area
            HStack {
                TextField("Ask the skeleton...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isLoading)
                
                Button(action: sendMessage) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(inputText.isEmpty || isLoading)
            }
            .padding()
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color.gray.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    private func sendMessage() {
        let userMessage = inputText
        inputText = ""
        isLoading = true
        
        messages.append(ChatMessage(text: userMessage, isFromUser: true))
        
        Task {
            do {
                let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
                let interaction = try await APIService.shared.interactWithNPC(
                    npcId: npcId,
                    message: userMessage,
                    deviceUUID: deviceUUID
                )
                
                await MainActor.run {
                    messages.append(ChatMessage(text: interaction.response, isFromUser: false))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(
                        text: "Arr, me bones be too old to understand that, matey!",
                        isFromUser: false
                    ))
                    isLoading = false
                }
            }
        }
    }
}

// Treasure Map View - Shows X marks the spot
struct TreasureMapView: View {
    let mapData: TreasureMap
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            // Parchment/aged paper background
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.93, blue: 0.85),
                    Color(red: 0.92, green: 0.88, blue: 0.78),
                    Color(red: 0.89, green: 0.85, blue: 0.75)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 20) {
                // Map title with pirate font
                Text(mapData.mapName)
                    .font(.custom("Copperplate", size: 28))
                    .foregroundColor(.brown)
                    .padding(.top, 30)
                
                // Map description
                Text(mapData.mapDescription)
                    .font(.custom("Copperplate", size: 16))
                    .foregroundColor(.brown)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
                
                // Map with X marks the spot
                ZStack {
                    // Parchment map background
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(red: 0.95, green: 0.90, blue: 0.80))
                        .frame(height: 350)
                        .overlay(
                            // Aged paper texture effect
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.brown.opacity(0.3), lineWidth: 2)
                        )
                        .overlay(
                            // Map content
                            VStack {
                                // Top landmarks
                                HStack {
                                    Image(systemName: "tree.fill")
                                        .foregroundColor(.green)
                                        .font(.title2)
                                    Spacer()
                                    Image(systemName: "drop.fill")
                                        .foregroundColor(.blue)
                                        .font(.title2)
                                    Spacer()
                                    Image(systemName: "mountain.2.fill")
                                        .foregroundColor(.gray)
                                        .font(.title2)
                                }
                                .padding(.horizontal, 30)
                                .padding(.top, 20)
                                
                                Spacer()
                                
                                // X marks the spot (center of map)
                                ZStack {
                                    // Red circle around X
                                    Circle()
                                        .fill(Color.red.opacity(0.2))
                                        .frame(width: 80, height: 80)
                                    
                                    // X mark
                                    Text("✕")
                                        .font(.system(size: 50, weight: .bold))
                                        .foregroundColor(.red)
                                        .rotationEffect(.degrees(45))
                                }
                                 .padding(.bottom, 40)
                                
                                Spacer()
                                
                                // Bottom landmarks
                                HStack {
                                    Image(systemName: "building.2.fill")
                                        .foregroundColor(.brown)
                                        .font(.title2)
                                    Spacer()
                                    Image(systemName: "location.fill")
                                        .foregroundColor(.orange)
                                        .font(.title2)
                                }
                                .padding(.horizontal, 30)
                                .padding(.bottom, 20)
                            }
                        )
                        .padding()
                    
                    // Compass rose (top right)
                    VStack {
                        HStack {
                            Spacer()
                            VStack {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundColor(.brown)
                                    .font(.title)
                                Text("N")
                                    .font(.caption)
                                    .foregroundColor(.brown)
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 10)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal)
                
                // Coordinates hint (subtle)
                Text("Lat: \(mapData.xMarksTheSpot.latitude, specifier: "%.6f"), Lon: \(mapData.xMarksTheSpot.longitude, specifier: "%.6f")")
                    .font(.caption)
                    .foregroundColor(.brown.opacity(0.5))
                    .padding(.bottom, 10)
                
                // Close button
                Button(action: { dismiss() }) {
                    Text("Close Map")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(Color.brown)
                        .cornerRadius(10)
                }
                .padding(.bottom, 30)
            }
        }
        .ignoresSafeArea()
    }
}

// Handle treasure map finding - called when user finds map object
func handleTreasureMapFound(objectId: String) {
    Task {
        do {
            let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            let treasureMap = try await APIService.shared.getTreasureMap(
                objectId: objectId,
                deviceUUID: deviceUUID
            )
            
            await MainActor.run {
                // Show treasure map view
                let mapView = TreasureMapView(mapData: treasureMap)
                let hostingController = UIHostingController(rootView: mapView)
                hostingController.modalPresentationStyle = .fullScreen
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootViewController = windowScene.windows.first?.rootViewController {
                    rootViewController.present(hostingController, animated: true)
                }
            }
        } catch {
            print("⚠️ Failed to load treasure map: \(error)")
        }
    }
}

// Enhanced FindableObject to check for treasure maps
extension FindableObject {
    func findWithTreasureMapCheck(onComplete: @escaping () -> Void) {
        let objectName = itemDescription()
        
        Swift.print("🎉 Finding object: \(objectName)")
        
        // ... existing confetti and animation code ...
        
        // After animation, check if this is a treasure map
        if let location = location, location.name.lowercased().contains("treasure map") {
            // Mark as found first
            onFoundCallback?(locationId)
            
            // Then show treasure map
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                handleTreasureMapFound(objectId: self.locationId)
                onComplete()
            }
        } else {
            // Normal find behavior
            performFindAnimation(onComplete: onComplete)
        }
    }
}

// Skeleton AR Entity Creation
func createSkeletonNPC(npcData: NPCCharacter, anchor: AnchorEntity) -> ModelEntity {
    guard let modelURL = Bundle.main.url(forResource: "Curious_skeleton", withExtension: "usdz") else {
        print("⚠️ Could not find Curious_skeleton.usdz")
        // Fallback: create a simple placeholder
        let placeholder = ModelEntity(mesh: MeshResource.generateSphere(radius: 0.2))
        return placeholder
    }
    
    do {
        let skeletonEntity = try Entity.loadModel(contentsOf: modelURL)
        let wrapper = ModelEntity()
        wrapper.addChild(skeletonEntity)
        wrapper.scale = SIMD3<Float>(repeating: 1.0) // Adjust size as needed
        wrapper.name = npcData.id
        
        // Add glow effect for skeleton
        let glowMaterial = SimpleMaterial(color: .orange, roughness: 0.0, isMetallic: false)
        // Apply to skeleton if needed
        
        return wrapper
    } catch {
        print("❌ Error loading skeleton: \(error)")
        let placeholder = ModelEntity(mesh: MeshResource.generateSphere(radius: 0.2))
        return placeholder
    }
}
```

## Usage Examples

### 1. Generating an LLM Quest with "Dead Men Tell No Tales" Mode

```swift
// In iOS app - Generate a new LLM quest with "Dead Men Tell No Tales" mode
let userLocation = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
let quest = try await APIService.shared.generateLLMQuest(
    userLocation: userLocation,
    context: "Dead men tell no tales - pirate treasure hunt with skeleton guides"
)

// This will create:
// - Treasure map object (first thing to find) - shows X marks the spot when opened
// - Skeleton NPCs using Curious_skeleton.usdz model
// - Skeletons speak in pirate speak
// - They give riddles based on real map features
// - Theme: "Dead men tell no tales" - only the dead can reveal secrets
// - 200-year-old treasure that needs to be dug up
```

### Quest Flow for "Dead Men Tell No Tales":
1. **Find Treasure Map**: User finds the treasure map object (first findable clue)
   - Map appears in AR as a findable object
   - User taps it to "find" it
2. **Open Map**: After finding, map automatically opens showing "X marks the spot"
   - X shows where the 200-year-old treasure is buried
   - Map has pirate-themed design with landmarks
   - GPS navigation disabled - must use map and riddles
3. **Follow Riddles**: Use riddles from skeletons and clues to navigate to X
   - Skeletons appear when stuck (no progress for 5+ minutes)
   - Each skeleton gives riddles about where to dig
   - Riddles reference real map features (water, trees, buildings, etc.)
4. **Dig at X**: Go to the X location and find the hidden treasure
   - Treasure is hidden until all clues found
   - Once at X location, treasure becomes visible in AR
5. **Skeleton Help**: Skeletons appear dynamically when stuck to give more hints
   - Spawn near user's current location
   - Give progressively more helpful riddles
   - Reference being 200 years old and knowing where treasure was buried

// Quest includes:
// - Storyline in pirate theme
// - Hidden target object
// - 3-5 riddle clues in PIRATE SPEAK referencing real map features
// - 2-3 pirate NPCs
// - Custom pirate map with landmarks based on real features
// - Real map features (water, trees, buildings, elevation) analyzed
```

### Example Pirate Riddle Clue:
```
"Arr, me hearty! Where the river flows swift and true,
And the old oak tree stands guard for ye,
Look for the stone where the water meets land,
And dig where the ancient tree doth stand!"
```

### Example Skeleton NPC Interaction (Dead Men Tell No Tales):
```
Player: "Where should I look for the treasure?"
Skeleton: "Arr, me bones remember the old ways, matey! 
           Dead men tell no tales, but I be already dead, 
           so I can speak! Two hundred years ago, we buried 
           the treasure where the river flows past the 
           ancient oak. Dig where the water meets the land, 
           beneath the old tree's shadow at noon, shiver 
           me timbers!"
```

### Example Skeleton Riddle (When User Gets Stuck):
```
"Arr, ye be lost, me hearty! Listen to me bones:
Two hundred years ago, we buried the gold,
Where the river bends and the old oak stands,
Dig beneath the stone where the water meets land.
The treasure waits where me shipmates rest,
Beneath the earth, put yer shovel to the test!"
```

### Example Regular Pirate NPC Interaction:
```
Player: "Where should I look for the treasure?"
NPC: "Arr, ye seek the booty, do ye? Listen well, matey! 
      The treasure lies where the river bends and the old 
      building's shadow falls at noon. Follow the path 
      that leads to the highest point, and ye'll find 
      what ye seek, shiver me timbers!"
```

### 1. Generating an LLM Quest (Detailed)

```swift
// In iOS app - Generate a new LLM quest
let userLocation = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
let quest = try await APIService.shared.generateLLMQuest(
    userLocation: userLocation,
    context: "Ancient Egyptian theme"
)

// Quest includes:
// - Storyline
// - Hidden target object
// - 3-5 clue objects
// - 2-3 NPCs
// - Custom map with landmarks
```

### 2. Viewing Quest Map

```swift
// Show the LLM-generated map
let map = try await APIService.shared.getQuestMap(
    questId: quest.questId,
    deviceUUID: deviceUUID
)

// Map shows:
// - Thematic landmarks (temples, caves, etc.)
// - Named areas (forests, ruins, etc.)
// - Discovered clues
// - GPS navigation is disabled
```

### 3. Finding Clues

```swift
// When user finds a clue object in AR
// The clue text is revealed
// Progress is tracked
// Map updates to show discovered clues
```

### 1. Creating a Quest Chain (Legacy)

```python
# Via API
POST /api/quests
{
    "name": "The Lost Temple",
    "theme": "Ancient Egyptian artifacts",
    "object_ids": ["obj1", "obj2", "obj3"],
    "created_by": "admin"
}
```

### 2. Interacting with an Object

```swift
// In iOS app
let interaction = try await APIService.shared.interactWithObject(
    objectId: "chalice-123",
    message: "Tell me about your history",
    deviceUUID: deviceUUID
)
print(interaction.response) // LLM-generated response
```

### 3. Getting a Clue

```swift
// After finding an object in a quest chain
let clue = try await APIService.shared.getClueForObject(
    objectId: "next-object-id",
    deviceUUID: deviceUUID
)
// Show clue to user
```

## Map Feature Detection

The system uses OpenStreetMap's Overpass API to detect real geographic features:
- **Water**: Rivers, lakes, streams
- **Trees**: Individual trees and tree rows
- **Buildings**: Structures and landmarks
- **Mountains**: Peaks and elevation data
- **Paths**: Roads, trails, and walkways
- **Elevation**: Height data from Open-Elevation API

These features are analyzed by the LLM to create location-specific riddles that reference actual landmarks.

## API Key Requirements

### Do You Need an API Key?

**Yes, for cloud-based LLM providers** (OpenAI, Anthropic):
- **OpenAI**: Requires API key from https://platform.openai.com/api-keys
- **Anthropic**: Requires API key from https://console.anthropic.com/
- Both have free tiers with usage limits

**No, for local models**:
- Run LLM models locally (e.g., Ollama, LM Studio, LocalAI)
- No API keys needed, but requires local setup
- Slower but private and free

### Getting Started Options

#### Option 1: OpenAI (Recommended for Testing)
1. Sign up at https://platform.openai.com/
2. Get API key (starts with `sk-`)
3. Add to environment: `export OPENAI_API_KEY=sk-your-key-here`
4. Cost: ~$0.15 per 1M input tokens (very cheap for testing)

#### Option 2: Anthropic Claude
1. Sign up at https://console.anthropic.com/
2. Get API key (starts with `sk-ant-`)
3. Add to environment: `export ANTHROPIC_API_KEY=sk-ant-your-key-here`
4. Cost: ~$0.25 per 1M input tokens

#### Option 3: Local Models (No API Key)
1. Install Ollama: https://ollama.ai/
2. Download a model: `ollama pull llama3` or `ollama pull mistral`
3. Configure server to use local endpoint
4. Free but requires local machine setup

### Environment Variables

Add to `server/.env` or set as environment variables:

**For OpenAI:**
```bash
OPENAI_API_KEY=sk-...
LLM_PROVIDER=openai
LLM_MODEL=gpt-4o-mini  # Cheapest option, good for testing
```

**For Anthropic:**
```bash
ANTHROPIC_API_KEY=sk-ant-...
LLM_PROVIDER=anthropic
LLM_MODEL=claude-3-haiku-20240307
```

**For Local Models (Ollama):**
```bash
LLM_PROVIDER=local
LLM_MODEL=llama3  # or mistral, etc.
LLM_BASE_URL=http://localhost:11434  # Ollama default
# No API key needed
```

**Map Feature Detection (No API Key Required):**
```bash
# Map feature detection uses free public APIs
# Overpass API is free and public
# Open-Elevation API is free and public
# No API keys required for map features
```

## Cost Considerations

### Cloud LLM Costs (Requires API Key)
- **OpenAI GPT-4o-mini**: ~$0.15 per 1M input tokens, $0.60 per 1M output tokens
  - Typical quest generation: ~500-1000 tokens = $0.0001-0.0002 per quest
  - Very affordable for testing and moderate use
- **Anthropic Claude Haiku**: ~$0.25 per 1M input tokens, $1.25 per 1M output tokens
  - Similar cost per quest
- **Free Tiers**: Both providers offer free credits to start
  - OpenAI: $5 free credit for new accounts
  - Anthropic: Free tier with usage limits

### Local LLM Costs (No API Key)
- **Free**: Run models locally with Ollama or similar
- **Hardware**: Requires decent GPU/RAM for good performance
- **Privacy**: All data stays local, no API calls

### Cost Optimization
- **Caching**: Cache common responses (object backstories, quest clues) to reduce costs
- **Rate Limiting**: Implement rate limits to prevent abuse
- **Batch Processing**: Generate multiple quests at once when possible
- **Model Selection**: Use cheaper models (gpt-4o-mini) for testing, upgrade if needed

## Security Considerations

1. **API Key Management**: Store keys in environment variables, never in code
2. **Input Sanitization**: Validate and sanitize user messages before sending to LLM
3. **Rate Limiting**: Limit interactions per user per hour
4. **Content Filtering**: Add moderation layer for inappropriate content
5. **Cost Controls**: Set daily/monthly spending limits

## Future Enhancements

1. **Voice Interaction**: Add speech-to-text and text-to-speech for voice conversations
2. **Multi-language Support**: Generate clues and conversations in multiple languages
3. **Dynamic Quest Generation**: Use LLM to generate entire quest chains automatically
4. **Personalized Hints**: Adapt clue difficulty based on user progress
5. **Collaborative Quests**: Multiple users working together on quest chains
6. **AR-Specific Clues**: Generate clues based on AR environment (e.g., "look near the red wall")

## Implementation Phases

### Phase 1: Basic Interaction (Week 1-2)
- Set up LLM service
- Add database tables
- Implement conversation endpoint
- Basic iOS interaction UI

### Phase 2: Quest Chains (Week 3-4)
- Quest chain creation
- Clue generation
- Quest progress tracking
- Clue notifications

### Phase 3: Polish (Week 5-6)
- Caching and optimization
- Error handling
- UI/UX improvements
- Testing and bug fixes

