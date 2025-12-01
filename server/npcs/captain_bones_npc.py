"""
Captain Bones NPC - The Skeleton Pirate

Captain Bones is the main quest-giver in CacheRaiders. He's a skeleton pirate
who died 200 years ago and now guards the secrets of buried treasure.

He speaks exclusively in pirate dialect and gives players the first half
of the treasure map when they interact with him.

Game Role:
- Stage 1: Gives the first map piece with approximate treasure coordinates
- Provides pirate-themed clues and riddles
- Sets the tone for the treasure hunt adventure
"""

import random
import time
import logging
from typing import Dict, List, Optional

# Set up logging
logger = logging.getLogger('captain_bones')


class CaptainBonesNPC:
    """Captain Bones - The Skeleton Pirate NPC.
    
    A 200-year-old skeleton pirate who guards treasure secrets
    and speaks only in authentic pirate dialect.
    """
    
    # Character attributes
    NPC_ID = "captain_bones"
    NPC_NAME = "Captain Bones"
    NPC_TYPE = "skeleton"
    
    # Pirate greetings for variety
    GREETINGS = [
        "Ahoy, landlubber! Ye've found ol' Captain Bones!",
        "Arrr! What brings ye to these cursed waters, matey?",
        "Shiver me timbers! A living soul approaches!",
        "Yo ho ho! Welcome to me domain, ye scurvy dog!",
        "Blimey! Ye've got the look of a treasure hunter about ye!",
    ]
    
    # Map piece introduction phrases
    MAP_PIECE_INTROS = [
        "I've got somethin' for ye, matey - half o' me old treasure map!",
        "Arr, take this torn piece o' map. It be showin' where X marks the spot!",
        "Here be the first half o' the map, ye swashbuckler!",
        "This weathered parchment shows the way to me buried gold!",
        "Guard this map piece with yer life, or ye'll never find the booty!",
    ]
    
    # Farewell phrases
    FAREWELLS = [
        "Now be off with ye! Find that treasure before the tide turns!",
        "May the winds be at yer back, treasure hunter!",
        "Don't let them scallywags beat ye to the gold!",
        "Remember - X marks the spot, or me name ain't Captain Bones!",
        "Arr, good luck to ye! Ye'll be needin' it!",
    ]
    
    # Clue templates for treasure hints (uses real landmarks)
    CLUE_TEMPLATES = [
        "The treasure be buried near {landmark}, where the {feature} meets the earth!",
        "Seek the {landmark}! {distance} paces from there, ye'll find the gold!",
        "When ye see the {landmark}, dig where the shadow falls at noon!",
        "The {feature} guards me treasure! Look for {landmark} nearby!",
        "Follow the path past {landmark}. The X be waitin' for ye!",
    ]
    
    def __init__(self, llm_service=None):
        """Initialize Captain Bones NPC.
        
        Args:
            llm_service: Optional LLM service for dynamic conversation generation.
                        If not provided, uses pre-written responses.
        """
        self.llm_service = llm_service
        self.conversation_history: Dict[str, List[Dict]] = {}  # Per-user conversation history
        
    def get_greeting(self) -> str:
        """Get a random pirate greeting."""
        return random.choice(self.GREETINGS)
    
    def get_map_piece_intro(self) -> str:
        """Get a random map piece introduction."""
        return random.choice(self.MAP_PIECE_INTROS)
    
    def get_farewell(self) -> str:
        """Get a random farewell message."""
        return random.choice(self.FAREWELLS)
    
    def generate_clue(self, landmarks: List[str] = None, distance_hint: str = None) -> str:
        """Generate a pirate-themed clue for the treasure location.
        
        Args:
            landmarks: List of real landmark names from OSM/vision analysis
            distance_hint: Optional distance hint (e.g., "50 paces", "a stone's throw")
            
        Returns:
            A pirate-themed clue string
        """
        if not landmarks:
            landmarks = ["the old oak", "the crooked stone", "the mossy rock"]
        
        landmark = random.choice(landmarks)
        feature = random.choice(["shadow", "wind", "ancient spirits", "setting sun"])
        distance = distance_hint or f"{random.randint(10, 50)} paces"
        
        template = random.choice(self.CLUE_TEMPLATES)
        return template.format(landmark=landmark, feature=feature, distance=distance)
    
    def interact(
        self,
        user_message: str,
        device_uuid: str,
        user_location: Optional[Dict] = None,
        include_map_piece: bool = False
    ) -> Dict:
        """Handle an interaction with Captain Bones.
        
        Args:
            user_message: The user's message
            device_uuid: Unique identifier for the user's device
            user_location: Optional dict with latitude/longitude
            include_map_piece: Whether to include map piece generation
            
        Returns:
            Dict with response, optional map_piece, and metadata
        """
        request_id = f"bones_{int(time.time() * 1000)}"
        logger.info(f"[{request_id}] Captain Bones interaction from device {device_uuid[:8]}...")
        
        # Initialize conversation history for new users
        if device_uuid not in self.conversation_history:
            self.conversation_history[device_uuid] = []
        
        # Build response
        result = {
            "npc_id": self.NPC_ID,
            "npc_name": self.NPC_NAME,
            "npc_type": self.NPC_TYPE,
            "request_id": request_id
        }
        
        # Generate response using LLM if available
        if self.llm_service:
            try:
                llm_result = self.llm_service.generate_npc_response(
                    npc_name=self.NPC_NAME,
                    npc_type=self.NPC_TYPE,
                    user_message=user_message,
                    is_skeleton=True,
                    include_placement=False,
                    user_location=user_location
                )
                result["response"] = llm_result.get("response", self.get_greeting())
            except Exception as e:
                logger.error(f"[{request_id}] LLM error: {e}")
                result["response"] = self._get_fallback_response(user_message)
        else:
            result["response"] = self._get_fallback_response(user_message)
        
        # Add conversation to history
        self.conversation_history[device_uuid].append({
            "role": "user",
            "content": user_message,
            "timestamp": time.time()
        })
        self.conversation_history[device_uuid].append({
            "role": "assistant",
            "content": result["response"],
            "timestamp": time.time()
        })
        
        # Include map piece if requested
        if include_map_piece:
            result["map_piece_intro"] = self.get_map_piece_intro()
            result["should_give_map_piece"] = True
        
        return result
    
    def _get_fallback_response(self, user_message: str) -> str:
        """Generate a fallback response without LLM.
        
        Args:
            user_message: The user's message to respond to
            
        Returns:
            A pre-written pirate response
        """
        message_lower = user_message.lower()
        
        # Check for common phrases and respond appropriately
        if any(word in message_lower for word in ["hello", "hi", "hey", "greetings"]):
            return self.get_greeting()
        
        if any(word in message_lower for word in ["treasure", "gold", "map", "hunt"]):
            return f"{self.get_map_piece_intro()} Arr, the X marks the spot, matey!"
        
        if any(word in message_lower for word in ["bye", "goodbye", "farewell", "leave"]):
            return self.get_farewell()
        
        if any(word in message_lower for word in ["who", "name", "you"]):
            return "I be Captain Bones, the most fearsome skeleton pirate to ever sail the seven seas! I died 200 years ago, but me spirit guards the treasure still!"
        
        if any(word in message_lower for word in ["clue", "hint", "help", "where"]):
            return self.generate_clue()
        
        # Default response
        return "Arr, speak up matey! I be hard of hearin' after 200 years in Davy Jones' locker!"
    
    def get_map_piece_data(
        self,
        target_location: Dict,
        landmarks: List[Dict] = None
    ) -> Dict:
        """Generate the first half of the treasure map.
        
        Args:
            target_location: Dict with 'latitude' and 'longitude' of treasure
            landmarks: Optional list of landmark dicts from OSM/vision
            
        Returns:
            Dict with map piece data (piece 1 of 2)
        """
        lat = target_location.get('latitude')
        lon = target_location.get('longitude')
        
        if not lat or not lon:
            return {"error": "target_location must include latitude and longitude"}
        
        # Generate approximate coordinates (obfuscated for puzzle)
        # First piece shows rough area, not exact location
        approximate_lat = lat + (random.random() - 0.5) * 0.001  # ~100m variation
        approximate_lon = lon + (random.random() - 0.5) * 0.001
        
        # Format landmarks for the map
        map_landmarks = []
        if landmarks:
            for landmark in landmarks[:3]:  # Max 3 landmarks
                if isinstance(landmark, dict) and 'latitude' in landmark and 'longitude' in landmark:
                    map_landmarks.append({
                        'name': landmark.get('name', landmark.get('type', 'landmark')),
                        'type': landmark.get('type', 'landmark'),
                        'latitude': landmark['latitude'],
                        'longitude': landmark['longitude']
                    })
        
        return {
            "piece_number": 1,
            "total_pieces": 2,
            "npc_name": self.NPC_NAME,
            "hint": self.get_map_piece_intro(),
            "approximate_latitude": approximate_lat,
            "approximate_longitude": approximate_lon,
            "landmarks": map_landmarks,
            "is_first_half": True,
            "clue": self.generate_clue(
                landmarks=[lm.get('name', 'the old marker') for lm in map_landmarks] if map_landmarks else None
            )
        }
    
    def get_character_info(self) -> Dict:
        """Get character information for AR display and UI."""
        return {
            "id": self.NPC_ID,
            "name": self.NPC_NAME,
            "type": self.NPC_TYPE,
            "model_file": "Curious_skeleton.usdz",
            "description": "A skeleton pirate from 200 years ago who guards treasure secrets.",
            "personality": "Gruff but helpful, speaks only in pirate dialect",
            "role": "Quest giver - provides first half of treasure map",
            "dialogue_style": "pirate",
            "sample_greeting": self.get_greeting()
        }


# Singleton instance for easy import
captain_bones = CaptainBonesNPC()

