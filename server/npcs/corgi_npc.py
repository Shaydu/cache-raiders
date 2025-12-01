"""
Corgi Traveller NPC - The Treasure Thief

The Corgi Traveller is a friendly but mischievous character who appears
in Stage 2 of the treasure hunt. When the player reaches the original
treasure X location, they find an IOU note instead of treasure.

The Corgi is found nearby (within 20 meters) and confesses to taking
the treasure, spending half on food/ale/steak/jewelry, and reveals
that bandits stole the rest.

Game Role:
- Stage 2: Appears near the original treasure X (within 20m)
- Confesses to taking the treasure (IOU note)
- Provides the story about spending half and bandits stealing the rest
- Updates the map with the new bandit X location
- Stage 3: Directs player to catch the bandits for the remaining treasure
"""

import random
import time
import math
import logging
from typing import Dict, List, Optional, Tuple

# Set up logging
logger = logging.getLogger('corgi_npc')


class CorgiNPC:
    """Corgi Traveller - The Mischievous Treasure Taker.
    
    A friendly Corgi who stumbled upon the treasure and couldn't resist
    spending some of it. He's remorseful and helps the player track down
    the bandits who stole the rest.
    """
    
    # Character attributes
    NPC_ID = "corgi_traveller"
    NPC_NAME = "Barnaby the Corgi"
    NPC_TYPE = "traveller"
    
    # The confession story - the main Stage 2 dialogue
    CONFESSION_STORY = """*wags tail nervously* Woof! Oh dear, oh dear... 

I came upon the treasure while wandering through these parts. I was SO hungry! 
I needed money for food... and ale... and a nice juicy steak... and maybe some 
shiny jewelry caught my eye too... 

*hangs head in shame*

Before I knew it, half the treasure was gone! But I swear, I was going to put 
it back! Then those BANDITS showed up! They took everything that was left and 
ran off that way!

*points with paw*

Please, you have to catch them! They went toward the old ruins! If you hurry, 
you can still get the remaining half of the treasure back!"""

    # Shorter version for subsequent interactions
    CONFESSION_SHORT = """*whimpers* I already told you... I spent half on food and ale and shiny things. 
The bandits stole the rest! They went THAT way! *points urgently*"""

    # IOU Note content (found at original treasure X)
    IOU_NOTE = """═══════════════════════════════════════════
           I.O.U. - TREASURE RECEIPT
═══════════════════════════════════════════

To whom it may concern:

I, Barnaby the Corgi, do hereby acknowledge 
that I have borrowed the contents of this 
treasure chest for... um... essential 
supplies.

I promise to return it! Eventually!
Maybe!

Signed with a paw print: 🐾

P.S. - I'm probably somewhere nearby if 
you want to discuss this further. Just 
follow the smell of ale and steak!

═══════════════════════════════════════════"""

    # Greetings (before confession)
    GREETINGS_GUILTY = [
        "*jumps back* Woof! Oh! You startled me! I wasn't doing anything suspicious!",
        "*nervous tail wag* H-hello there! Lovely day for a walk, isn't it? No reason to ask questions!",
        "*avoids eye contact* Oh, a treasure hunter! How... interesting. I don't know anything about any treasure!",
        "*gulps audibly* Woof! You look like someone who just found an IOU note...",
    ]
    
    # Greetings (after confession)
    GREETINGS_HELPFUL = [
        "*wags tail* You're back! Did you catch those bandits yet?",
        "Woof! Any luck with the treasure? I feel SO bad about all this!",
        "*hopeful eyes* Please tell me you got the gold back!",
        "The bandits went that way! I can smell them from here! *sniff sniff*",
    ]
    
    # Directions to bandits
    BANDIT_HINTS = [
        "They smelled like campfire smoke and bad decisions!",
        "I heard them mention something about hiding in the ruins!",
        "One of them dropped a coin - follow the trail!",
        "They were arguing about splitting the loot. Typical bandits!",
        "I think their hideout is near that old structure over there!",
    ]
    
    # Victory messages (when player catches bandits)
    VICTORY_MESSAGES = [
        "*jumps with joy* WOOF WOOF! You did it! You got the treasure back!",
        "*happy dance* I knew you could do it! You're a real hero!",
        "*licks your hand* Thank you for not being mad at me! Here, take this gold!",
        "*proud bark* Justice has been served! And the treasure is yours!",
    ]
    
    def __init__(self, llm_service=None):
        """Initialize Corgi NPC.
        
        Args:
            llm_service: Optional LLM service for dynamic conversation.
        """
        self.llm_service = llm_service
        self.user_states: Dict[str, Dict] = {}  # Track confession state per user
        
    def get_iou_note(self) -> str:
        """Get the IOU note content that's found at the original treasure X."""
        return self.IOU_NOTE
    
    def get_greeting(self, has_confessed: bool = False) -> str:
        """Get a greeting based on confession state."""
        if has_confessed:
            return random.choice(self.GREETINGS_HELPFUL)
        return random.choice(self.GREETINGS_GUILTY)
    
    def get_confession_story(self, short: bool = False) -> str:
        """Get the confession story.
        
        Args:
            short: If True, returns shorter version for repeat interactions
        """
        if short:
            return self.CONFESSION_SHORT
        return self.CONFESSION_STORY
    
    def get_bandit_hint(self) -> str:
        """Get a random hint about the bandits' location."""
        return random.choice(self.BANDIT_HINTS)
    
    def get_victory_message(self) -> str:
        """Get a victory celebration message."""
        return random.choice(self.VICTORY_MESSAGES)
    
    def generate_corgi_location(
        self,
        treasure_latitude: float,
        treasure_longitude: float,
        max_distance_meters: float = 20.0
    ) -> Tuple[float, float]:
        """Generate a location for Corgi within specified distance of treasure.
        
        The Corgi appears near the original treasure X, so the player
        can find him after discovering the IOU note.
        
        Args:
            treasure_latitude: Original treasure X latitude
            treasure_longitude: Original treasure X longitude
            max_distance_meters: Maximum distance from treasure (default 20m)
            
        Returns:
            Tuple of (latitude, longitude) for Corgi's position
        """
        # Convert meters to approximate degrees
        # 1 degree latitude ≈ 111,000 meters
        # 1 degree longitude ≈ 111,000 * cos(latitude) meters
        lat_offset_per_meter = 1.0 / 111000.0
        lon_offset_per_meter = 1.0 / (111000.0 * math.cos(math.radians(treasure_latitude)))
        
        # Generate random distance (between 10m and max_distance)
        distance = random.uniform(10.0, max_distance_meters)
        
        # Generate random angle
        angle = random.uniform(0, 2 * math.pi)
        
        # Calculate offset
        lat_offset = distance * math.cos(angle) * lat_offset_per_meter
        lon_offset = distance * math.sin(angle) * lon_offset_per_meter
        
        corgi_lat = treasure_latitude + lat_offset
        corgi_lon = treasure_longitude + lon_offset
        
        logger.info(f"Generated Corgi location: ({corgi_lat}, {corgi_lon}) - {distance:.1f}m from treasure")
        
        return (corgi_lat, corgi_lon)
    
    def generate_bandit_location(
        self,
        treasure_latitude: float,
        treasure_longitude: float,
        min_distance_meters: float = 50.0,
        max_distance_meters: float = 150.0
    ) -> Tuple[float, float]:
        """Generate a location for the bandits' hideout.
        
        The bandits are further away from the original treasure,
        creating the Stage 3 objective.
        
        Args:
            treasure_latitude: Original treasure X latitude
            treasure_longitude: Original treasure X longitude
            min_distance_meters: Minimum distance from original treasure
            max_distance_meters: Maximum distance from original treasure
            
        Returns:
            Tuple of (latitude, longitude) for bandit hideout
        """
        # Convert meters to approximate degrees
        lat_offset_per_meter = 1.0 / 111000.0
        lon_offset_per_meter = 1.0 / (111000.0 * math.cos(math.radians(treasure_latitude)))
        
        # Generate random distance
        distance = random.uniform(min_distance_meters, max_distance_meters)
        
        # Generate random angle
        angle = random.uniform(0, 2 * math.pi)
        
        # Calculate offset
        lat_offset = distance * math.cos(angle) * lat_offset_per_meter
        lon_offset = distance * math.sin(angle) * lon_offset_per_meter
        
        bandit_lat = treasure_latitude + lat_offset
        bandit_lon = treasure_longitude + lon_offset
        
        logger.info(f"Generated bandit location: ({bandit_lat}, {bandit_lon}) - {distance:.1f}m from treasure")
        
        return (bandit_lat, bandit_lon)
    
    def interact(
        self,
        user_message: str,
        device_uuid: str,
        user_location: Optional[Dict] = None,
        treasure_hunt_stage: str = "stage_2"
    ) -> Dict:
        """Handle an interaction with the Corgi.
        
        Args:
            user_message: The user's message
            device_uuid: Unique identifier for the user's device
            user_location: Optional dict with latitude/longitude
            treasure_hunt_stage: Current stage of the treasure hunt
            
        Returns:
            Dict with response, story progression, and metadata
        """
        request_id = f"corgi_{int(time.time() * 1000)}"
        logger.info(f"[{request_id}] Corgi interaction from device {device_uuid[:8]}... (stage: {treasure_hunt_stage})")
        
        # Initialize user state if needed
        if device_uuid not in self.user_states:
            self.user_states[device_uuid] = {
                "has_confessed": False,
                "interaction_count": 0,
                "first_interaction_time": time.time()
            }
        
        user_state = self.user_states[device_uuid]
        user_state["interaction_count"] += 1
        
        result = {
            "npc_id": self.NPC_ID,
            "npc_name": self.NPC_NAME,
            "npc_type": self.NPC_TYPE,
            "request_id": request_id,
            "treasure_hunt_stage": treasure_hunt_stage
        }
        
        # First interaction - deliver the confession
        if not user_state["has_confessed"]:
            user_state["has_confessed"] = True
            result["response"] = self.get_confession_story(short=False)
            result["story_event"] = "confession"
            result["should_update_map"] = True  # Trigger map update with bandit X
            result["bandit_hint"] = self.get_bandit_hint()
            
        # Subsequent interactions - provide helpful info
        else:
            # Check if asking about bandits
            message_lower = user_message.lower()
            
            if any(word in message_lower for word in ["bandit", "thief", "thieves", "where", "direction"]):
                result["response"] = f"*sniffs the air* {self.get_bandit_hint()} Follow the new X on your map!"
            elif any(word in message_lower for word in ["sorry", "forgive", "okay", "fine"]):
                result["response"] = "*tail wags happily* Thank you for understanding! I really am sorry! Now go catch those bandits!"
            elif any(word in message_lower for word in ["treasure", "gold", "money"]):
                result["response"] = self.get_confession_story(short=True)
            else:
                result["response"] = self.get_greeting(has_confessed=True)
                result["bandit_hint"] = self.get_bandit_hint()
        
        return result
    
    def handle_iou_discovery(
        self,
        device_uuid: str,
        treasure_location: Dict
    ) -> Dict:
        """Handle when a player discovers the IOU note at the treasure X.
        
        This triggers Stage 2 of the treasure hunt.
        
        Args:
            device_uuid: User's device identifier
            treasure_location: Dict with original treasure latitude/longitude
            
        Returns:
            Dict with IOU content, Corgi location, and bandit location
        """
        request_id = f"iou_{int(time.time() * 1000)}"
        logger.info(f"[{request_id}] IOU discovery by device {device_uuid[:8]}...")
        
        treasure_lat = treasure_location.get('latitude')
        treasure_lon = treasure_location.get('longitude')
        
        if not treasure_lat or not treasure_lon:
            return {"error": "treasure_location must include latitude and longitude"}
        
        # Generate Corgi location (within 20m of treasure)
        corgi_lat, corgi_lon = self.generate_corgi_location(
            treasure_lat, treasure_lon,
            max_distance_meters=20.0
        )
        
        # Generate bandit hideout location (50-150m away)
        bandit_lat, bandit_lon = self.generate_bandit_location(
            treasure_lat, treasure_lon,
            min_distance_meters=50.0,
            max_distance_meters=150.0
        )
        
        return {
            "request_id": request_id,
            "stage": "stage_2",
            "event": "iou_discovered",
            
            # The IOU note content
            "iou_note": self.get_iou_note(),
            
            # Corgi's location (player should go here next)
            "corgi_location": {
                "latitude": corgi_lat,
                "longitude": corgi_lon,
                "npc_id": self.NPC_ID,
                "npc_name": self.NPC_NAME,
                "hint": "The one who wrote this IOU is nearby... follow the smell of ale!"
            },
            
            # Bandit hideout (revealed after talking to Corgi)
            "bandit_location": {
                "latitude": bandit_lat,
                "longitude": bandit_lon,
                "name": "Bandit Hideout",
                "hint": "The bandits' hideout - recover the remaining treasure!",
                "treasure_amount": "half"  # Player gets half the original treasure
            },
            
            # Updated map marker info
            "new_map_marker": {
                "type": "bandit",
                "icon": "skull_crossbones",
                "label": "Bandit Hideout",
                "latitude": bandit_lat,
                "longitude": bandit_lon
            }
        }
    
    def handle_bandit_capture(self, device_uuid: str) -> Dict:
        """Handle when player catches the bandits and recovers treasure.
        
        This completes Stage 3 and ends the treasure hunt.
        
        Args:
            device_uuid: User's device identifier
            
        Returns:
            Dict with victory message and rewards
        """
        request_id = f"victory_{int(time.time() * 1000)}"
        logger.info(f"[{request_id}] Bandit capture by device {device_uuid[:8]}!")
        
        return {
            "request_id": request_id,
            "stage": "completed",
            "event": "treasure_recovered",
            
            "victory_message": self.get_victory_message(),
            
            "corgi_message": "*bounces excitedly* WOOF! You did it! You actually did it! "
                           "I knew you were a true treasure hunter! Here, you deserve ALL "
                           "of this treasure! Consider my debt repaid!",
            
            "rewards": {
                "treasure_recovered": "half",
                "description": "You recovered the remaining half of the treasure from the bandits!",
                "bonus": "Corgi's gratitude and a new furry friend",
            },
            
            "game_complete": True,
            "completion_message": "🎉 CONGRATULATIONS! 🎉\n\n"
                                "You've completed the treasure hunt!\n"
                                "The bandits have been caught and justice is served!\n\n"
                                "Rewards:\n"
                                "💰 Half the original treasure (the other half was... well, spent on ale)\n"
                                "🐕 Barnaby the Corgi's eternal friendship\n"
                                "⭐ Master Treasure Hunter status!"
        }
    
    def get_character_info(self) -> Dict:
        """Get character information for AR display and UI."""
        return {
            "id": self.NPC_ID,
            "name": self.NPC_NAME,
            "type": self.NPC_TYPE,
            "model_file": "Corgi_Traveller.usdz",
            "description": "A mischievous but lovable Corgi who accidentally spent half the treasure.",
            "personality": "Guilty but friendly, eager to help make things right",
            "role": "Stage 2 NPC - reveals treasure was moved, directs to bandits",
            "dialogue_style": "friendly_dog",
            "sample_greeting": self.get_greeting(has_confessed=False)
        }
    
    def get_stage_2_map_update(
        self,
        original_treasure_location: Dict,
        bandit_location: Dict
    ) -> Dict:
        """Get map update data for Stage 2 (treasure moved to bandit location).
        
        Args:
            original_treasure_location: Original X marks the spot
            bandit_location: New bandit hideout location
            
        Returns:
            Dict with map update instructions for the iOS app
        """
        return {
            "map_update_type": "treasure_moved",
            "stage": "stage_2",
            
            # Mark original location as "empty" or "IOU found"
            "original_marker": {
                "latitude": original_treasure_location.get('latitude'),
                "longitude": original_treasure_location.get('longitude'),
                "status": "iou_found",
                "icon": "scroll",  # IOU note icon
                "label": "IOU Found Here",
                "crossed_out": True  # Visual indication treasure isn't here
            },
            
            # New marker for bandit hideout
            "new_marker": {
                "latitude": bandit_location.get('latitude'),
                "longitude": bandit_location.get('longitude'),
                "status": "active",
                "icon": "skull_crossbones",  # Bandit/danger icon
                "label": "Bandit Hideout - X",
                "is_treasure_location": True,
                "pulsing": True  # Draw attention to new location
            },
            
            # Path/trail from original to bandit location
            "trail": {
                "show_path": True,
                "path_style": "dotted",
                "path_color": "red",
                "label": "Bandits fled this way!"
            },
            
            # Story context for UI
            "story_context": {
                "title": "The Treasure Has Moved!",
                "message": "Barnaby the Corgi spent half the treasure. "
                          "Bandits stole the rest! Track them down!",
                "objective": "Find the bandit hideout and recover the remaining treasure!"
            }
        }


# Singleton instance for easy import
corgi_npc = CorgiNPC()

