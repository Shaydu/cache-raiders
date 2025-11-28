# LLM Integration Architecture for CacheRaiders

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
4. **Clue Generation**: LLM generates 3-5 clues as findable objects placed in the world
5. **NPC Placement**: LLM creates and places NPCs that know about the quest
6. **Progressive Revelation**: As users find clues and talk to NPCs, they get closer to the hidden object
7. **Object Unlocking**: Once all clues are found, the target object becomes visible and findable

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
    character_type TEXT NOT NULL,  -- 'guide', 'historian', 'guardian', 'merchant', etc.
    appearance_description TEXT,  -- Description for AR visualization
    personality TEXT NOT NULL,  -- Personality traits for LLM
    backstory TEXT,  -- Character backstory
    latitude REAL,  -- GPS location (optional, can be AR-only)
    longitude REAL,
    ar_offset_x REAL,  -- AR offset if placed manually
    ar_offset_y REAL,
    ar_offset_z REAL,
    ar_origin_latitude REAL,
    ar_origin_longitude REAL,
    radius REAL DEFAULT 50.0,  -- Interaction radius
    is_active BOOLEAN DEFAULT 1,
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

class LLMService:
    def __init__(self, config: LLMConfig):
        self.config = config
        if config.provider == "openai":
            openai.api_key = config.api_key or os.getenv("OPENAI_API_KEY")
    
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
        
        system_prompt = f"""You are {npc_name}, a {character_type} in a treasure hunting game.
Your personality: {personality}
Your backstory: {backstory}

Your role is to help players find treasures by providing hints, clues, and guidance.
Be helpful but don't give away solutions too easily. Encourage exploration.
{knowledge_context}
{progress_context}

Respond naturally to the player's questions. You can:
- Give hints about nearby treasures
- Share information about quest chains
- Provide location clues
- Tell stories about the area
- Encourage the player to explore

Keep responses to 2-4 sentences. Be engaging and in character."""
        
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

## Usage Examples

### 1. Creating a Quest Chain

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

## Environment Variables

Add to `server/.env` or `requirements.txt`:

```bash
OPENAI_API_KEY=sk-...
LLM_PROVIDER=openai
LLM_MODEL=gpt-4o-mini
```

Or for Anthropic:
```bash
ANTHROPIC_API_KEY=sk-ant-...
LLM_PROVIDER=anthropic
LLM_MODEL=claude-3-haiku-20240307
```

## Cost Considerations

- **OpenAI GPT-4o-mini**: ~$0.15 per 1M input tokens, $0.60 per 1M output tokens
- **Anthropic Claude Haiku**: ~$0.25 per 1M input tokens, $1.25 per 1M output tokens
- **Caching**: Cache common responses (object backstories, quest clues) to reduce costs
- **Rate Limiting**: Implement rate limits to prevent abuse

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

