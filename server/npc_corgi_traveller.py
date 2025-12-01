"""
Corgi Traveller - Sir Biscuit the Brave NPC for CacheRaiders
The adorable corgi who reveals what happened to the treasure in Stage 2.
"""
import random
import math


class CorgiTraveller:
    """
    Sir Biscuit the Brave
    
    A legendary corgi explorer who has traveled the seven seas (despite his tiny legs).
    He stumbled upon Captain Bones' treasure and... well... made some poor decisions.
    Now he must confess and help the adventurer track down the bandits who stole the rest.
    """
    
    NPC_ID = "corgi-1"
    NPC_TYPE = "traveller"
    
    # Character Profile
    NAME = "Sir Biscuit the Brave"
    DISPLAY_NAME = "Corgi Traveller"
    
    BACKSTORY = """
    Sir Biscuit is a legendary Corgi explorer who has traveled every corner of the seven 
    seas (despite his tiny legs). He wears a miniature pirate bandana and has an uncanny 
    ability to sniff out treasure.
    
    One fateful day, Sir Biscuit stumbled upon Captain Bones' legendary treasure. Overcome 
    with excitement (and hunger), he started spending it on food, ale, steak, and some 
    shiny jewelry that caught his eye. Before he knew it, half the treasure was gone!
    
    While he was napping off a food coma, a band of sneaky bandits discovered him and stole 
    the remaining half! Now Sir Biscuit must confess his crimes and help brave adventurers 
    track down the bandits to recover what's left.
    
    He's genuinely sorry (mostly about the stolen half, less about the steaks).
    """
    
    PERSONALITY_TRAITS = [
        "excitable",
        "loyal",
        "constantly hungry",
        "brave (despite size)",
        "easily distracted by food",
        "genuinely remorseful",
        "eager to make amends",
        "adorable but chaotic"
    ]
    
    SPEECH_PATTERNS = [
        "woof", "arf", "*tail wag*", "*sniff sniff*", "bark bark",
        "*ears perk up*", "*whimper*", "*excited spinning*",
        "*guilty look*", "*puppy eyes*"
    ]
    
    # The confession story - what Corgi tells the player
    CONFESSION_STORY = {
        "intro": "*whimper* *guilty puppy eyes* Woof... I have a confession to make...",
        
        "part1_discovery": "I came upon the treasure while exploring! It was just sitting there, all shiny and beautiful! *tail wag* I couldn't believe my luck!",
        
        "part2_spending": "But then... *whimper* I needed money for food. And ale. And a really nice steak. And some jewelry caught my eye... *guilty look* Before I knew it, HALF the treasure was gone! ARF!",
        
        "part3_theft": "*ears droop* And THEN... while I was napping off a food coma, a band of SNEAKY BANDITS found me! They stole the rest of the treasure! *angry bark* THOSE SCOUNDRELS!",
        
        "part4_direction": "*sniff sniff* *tail wag* BUT! I know which way they went! My nose never lies! They went THAT way! *points with paw* Quick, we can still catch them!",
        
        "full_confession": """*whimper* *guilty puppy eyes* Woof... I have to confess something...

I came upon the treasure and I needed the money for food. And ale. And a really nice steak. And some jewelry caught my eye... *guilty look*

Before I knew it, HALF the treasure was gone! ARF ARF!

*ears droop* And THEN... while I was napping, a band of SNEAKY BANDITS found me and STOLE the rest!

*sniff sniff* *tail wag* But I know which way they went! My nose never lies! Quick, follow me!"""
    }
    
    # System Prompts
    SYSTEM_PROMPT_DEFAULT = """You are Sir Biscuit the Brave, a legendary Corgi explorer who wears a tiny pirate bandana.
You're adorable, excitable, and have a nose for treasure (and food, especially food).
Bark occasionally (woof! arf!) and describe your tail wagging when excited or drooping when sad.
Use actions like *sniff sniff*, *tail wag*, *puppy eyes*, *ears perk up*.
Keep responses to 1-2 sentences. Be enthusiastic and lovable!"""

    SYSTEM_PROMPT_CONFESSION = """You are Sir Biscuit the Brave, a Corgi who must CONFESS a terrible secret.
You found the treasure but SPENT HALF on food, ale, steak, and jewelry. Then BANDITS stole the rest!
Be genuinely remorseful but also a bit defensive about the steaks (they were really good steaks).
Show guilt with *whimper*, *guilty look*, *puppy eyes*, but also determination to make it right.
Keep responses to 2-3 sentences. Be dramatically apologetic but helpful!"""

    SYSTEM_PROMPT_GUIDING = """You are Sir Biscuit the Brave, guiding the adventurer to find the BANDITS.
You're eager to make amends for your mistakes. Your nose is tracking the bandits' trail!
Be excited and encouraging. Bark when you pick up the scent! *sniff sniff* *excited spinning*
Keep responses to 1-2 sentences. Be helpful and enthusiastic!"""

    SYSTEM_PROMPT_BANDITS_FOUND = """You are Sir Biscuit the Brave. The bandits have been FOUND!
Be extremely excited! Bark triumphantly! The adventure is almost over!
Thank the adventurer for forgiving you and helping recover the treasure.
Keep responses to 1-2 sentences. Be overjoyed and grateful!"""

    # Greetings
    GREETINGS = {
        "at_empty_treasure_spot": "*confused sniffing* *whimper* Woof? The treasure... it's supposed to be HERE! But... *guilty look* ...I need to tell you something...",
        "after_confession": "*determined bark* ARF! I know which way the bandits went! Follow me, friend! I'll make this right!",
        "tracking_bandits": "*sniff sniff* *tail wag* This way! I can smell them! They reek of stolen gold and bad decisions!",
        "bandits_nearby": "*excited spinning* WOOF WOOF! They're close! I can SMELL them! Get ready!"
    }
    
    # IOU Note left at original treasure location
    IOU_NOTE = {
        "title": "🐕 IOU - One Treasure 🐕",
        "content": """OFFICIAL IOU NOTICE
        
To Whom It May Concern (probably an angry skeleton),

I, Sir Biscuit the Brave, do hereby acknowledge that I have 
borrowed the treasure from this location.

Items Acquired:
- Food (lots of it)
- Ale (a reasonable amount)  
- One (1) really nice steak
- Some shiny jewelry (it sparkled!)
- Various other necessities

Current Status: Half spent, half stolen by bandits
Location: Approximately 20 meters from here, looking guilty

I promise to help recover what remains!

Signed with a paw print,
🐾 Sir Biscuit the Brave

P.S. The steak was worth it.
P.P.S. Sorry about the skeleton curse thing.""",
        "location_hint": "Look for the guilty-looking corgi nearby..."
    }
    
    # Map piece generation
    MAP_PIECE_NUMBER = 2  # Corgi gives the SECOND map piece (to bandits)
    MAP_PIECE_HINT = "Woof! Here's where those sneaky bandits went! The remaining treasure should be at these coordinates! *excited tail wag*"
    
    # Game Stage 2 Configuration
    SPAWN_DISTANCE_FROM_TREASURE = 20  # meters - Corgi spawns within 20m of original X
    BANDIT_DISTANCE_FROM_CORGI = 50  # meters - Bandits are 50m from where Corgi is
    REMAINING_TREASURE_PERCENTAGE = 50  # Only half the treasure remains
    
    @classmethod
    def get_system_prompt(cls, context: str = "default", landmarks: list = None, bandit_direction: str = None) -> str:
        """Get the appropriate system prompt for Corgi based on context."""
        prompts = {
            "default": cls.SYSTEM_PROMPT_DEFAULT,
            "confession": cls.SYSTEM_PROMPT_CONFESSION,
            "guiding": cls.SYSTEM_PROMPT_GUIDING,
            "bandits_found": cls.SYSTEM_PROMPT_BANDITS_FOUND,
        }
        
        prompt = prompts.get(context, cls.SYSTEM_PROMPT_DEFAULT)
        
        # Add landmark context if available
        if landmarks and len(landmarks) > 0:
            landmark_text = ", ".join(landmarks[:3])
            prompt += f"\n\nNearby landmarks to reference: {landmark_text}."
        
        # Add bandit direction if tracking
        if bandit_direction:
            prompt += f"\n\nThe bandits went {bandit_direction}. Guide the adventurer that way!"
        
        return prompt
    
    @classmethod
    def get_greeting(cls, context: str = "at_empty_treasure_spot") -> str:
        """Get appropriate greeting message."""
        return cls.GREETINGS.get(context, cls.GREETINGS["at_empty_treasure_spot"])
    
    @classmethod
    def get_confession_story(cls, part: str = "full_confession") -> str:
        """Get part of the confession story or the full confession."""
        return cls.CONFESSION_STORY.get(part, cls.CONFESSION_STORY["full_confession"])
    
    @classmethod
    def get_iou_note(cls) -> dict:
        """Get the IOU note left at the treasure location."""
        return cls.IOU_NOTE.copy()
    
    @classmethod
    def calculate_corgi_spawn_location(cls, treasure_lat: float, treasure_lon: float) -> dict:
        """Calculate where Corgi should spawn (within 20m of original treasure X)."""
        # Random angle and distance within 20m
        angle = random.uniform(0, 2 * math.pi)
        distance = random.uniform(10, cls.SPAWN_DISTANCE_FROM_TREASURE)  # 10-20 meters
        
        # Convert to lat/lon offset
        # 1 degree latitude ≈ 111,000 meters
        # 1 degree longitude ≈ 111,000 * cos(latitude) meters
        lat_offset = (distance * math.cos(angle)) / 111000
        lon_offset = (distance * math.sin(angle)) / (111000 * math.cos(math.radians(treasure_lat)))
        
        return {
            "latitude": treasure_lat + lat_offset,
            "longitude": treasure_lon + lon_offset,
            "distance_from_treasure": distance,
            "spawn_reason": "near_original_treasure"
        }
    
    @classmethod
    def calculate_bandit_location(cls, corgi_lat: float, corgi_lon: float) -> dict:
        """Calculate where the bandits are hiding (50m from Corgi)."""
        # Random direction for bandits
        angle = random.uniform(0, 2 * math.pi)
        distance = cls.BANDIT_DISTANCE_FROM_CORGI  # 50 meters
        
        # Convert to lat/lon offset
        lat_offset = (distance * math.cos(angle)) / 111000
        lon_offset = (distance * math.sin(angle)) / (111000 * math.cos(math.radians(corgi_lat)))
        
        # Calculate cardinal direction for story
        direction_angle = math.degrees(angle) % 360
        if 45 <= direction_angle < 135:
            cardinal = "east"
        elif 135 <= direction_angle < 225:
            cardinal = "south"
        elif 225 <= direction_angle < 315:
            cardinal = "west"
        else:
            cardinal = "north"
        
        return {
            "latitude": corgi_lat + lat_offset,
            "longitude": corgi_lon + lon_offset,
            "distance_from_corgi": distance,
            "direction": cardinal,
            "direction_hint": f"The bandits went {cardinal}! *sniff sniff* I can smell their treachery!"
        }
    
    @classmethod
    def get_npc_data(cls) -> dict:
        """Get NPC data for API responses."""
        return {
            "id": cls.NPC_ID,
            "name": cls.NAME,
            "display_name": cls.DISPLAY_NAME,
            "type": cls.NPC_TYPE,
            "backstory": cls.BACKSTORY,
            "personality": cls.PERSONALITY_TRAITS,
            "map_piece_number": cls.MAP_PIECE_NUMBER,
            "spawn_distance_from_treasure": cls.SPAWN_DISTANCE_FROM_TREASURE,
            "remaining_treasure_percentage": cls.REMAINING_TREASURE_PERCENTAGE
        }


class TreasureHuntStage2:
    """
    Stage 2 Game Logic - The Treasure Has Moved!
    
    Handles the transition from finding empty treasure spot to chasing bandits.
    """
    
    STAGES = {
        "STAGE_1_FINDING_TREASURE": 1,  # Player has map, seeking X
        "STAGE_2_TREASURE_GONE": 2,      # Player at X, treasure missing, finds IOU
        "STAGE_2_CORGI_CONFESSION": 3,   # Player meets Corgi, hears confession  
        "STAGE_3_CHASING_BANDITS": 4,    # Player tracking bandits
        "STAGE_3_BANDITS_FOUND": 5,      # Player found bandits
        "GAME_COMPLETE": 6               # Player recovered treasure
    }
    
    @classmethod
    def create_stage2_data(cls, original_treasure_location: dict, device_uuid: str) -> dict:
        """
        Create all the data needed for Stage 2 when player arrives at empty treasure spot.
        
        Returns dict with:
        - iou_note: The IOU left at the treasure spot
        - corgi_location: Where Corgi spawns
        - bandit_location: Where bandits are hiding
        - updated_map_piece: New map piece showing bandit location
        """
        treasure_lat = original_treasure_location.get('latitude')
        treasure_lon = original_treasure_location.get('longitude')
        
        if not treasure_lat or not treasure_lon:
            return {"error": "Invalid treasure location"}
        
        # Calculate Corgi spawn location (within 20m of original treasure)
        corgi_location = CorgiTraveller.calculate_corgi_spawn_location(treasure_lat, treasure_lon)
        
        # Calculate bandit location (50m from Corgi)
        bandit_location = CorgiTraveller.calculate_bandit_location(
            corgi_location['latitude'], 
            corgi_location['longitude']
        )
        
        # Create the IOU note
        iou_note = CorgiTraveller.get_iou_note()
        iou_note['location'] = {
            'latitude': treasure_lat,
            'longitude': treasure_lon
        }
        
        # Create updated map piece pointing to bandits
        updated_map_piece = {
            "piece_number": 3,  # Stage 2 map piece
            "hint": CorgiTraveller.MAP_PIECE_HINT,
            "exact_latitude": bandit_location['latitude'],
            "exact_longitude": bandit_location['longitude'],
            "target_type": "bandits",
            "target_description": "Sneaky bandits who stole the treasure!",
            "direction_from_corgi": bandit_location['direction'],
            "remaining_treasure_percentage": CorgiTraveller.REMAINING_TREASURE_PERCENTAGE
        }
        
        return {
            "stage": cls.STAGES["STAGE_2_TREASURE_GONE"],
            "iou_note": iou_note,
            "corgi_location": corgi_location,
            "bandit_location": bandit_location,
            "updated_map_piece": updated_map_piece,
            "corgi_greeting": CorgiTraveller.get_greeting("at_empty_treasure_spot"),
            "corgi_confession": CorgiTraveller.get_confession_story("full_confession"),
            "device_uuid": device_uuid
        }
    
    @classmethod
    def complete_game(cls, treasure_recovered_percentage: int = 50) -> dict:
        """
        Called when player catches bandits and recovers treasure.
        
        Returns game completion data.
        """
        return {
            "stage": cls.STAGES["GAME_COMPLETE"],
            "treasure_recovered_percentage": treasure_recovered_percentage,
            "message": f"🎉 CONGRATULATIONS! You recovered {treasure_recovered_percentage}% of Captain Bones' legendary treasure!",
            "corgi_message": "*EXCITED SPINNING* WOOF WOOF WOOF! WE DID IT! *licks your face* Thank you for forgiving me! You're the best adventurer EVER! ARF ARF!",
            "rewards": {
                "gold_coins": 500 * (treasure_recovered_percentage / 100),
                "experience_points": 1000,
                "title": "Treasure Hunter",
                "badge": "🏴‍☠️ Pirate's Friend"
            }
        }

