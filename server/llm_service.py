"""
LLM Service for CacheRaiders
Handles all LLM interactions: conversations, clue generation, quest creation
Supports OpenAI, Anthropic, and local Ollama models
"""
import os
import json
import random
from typing import Optional, Dict, List

try:
    from openai import OpenAI
    OPENAI_AVAILABLE = True
except ImportError:
    OPENAI_AVAILABLE = False
    print("⚠️ openai package not installed. Run: pip install openai")

try:
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False
    print("⚠️ requests package not installed. Run: pip install requests")

class MapFeatureService:
    """Service to detect real map features from geographic data using OpenStreetMap."""
    
    def __init__(self):
        # Uses OpenStreetMap Overpass API (free, no API key needed)
        self.overpass_url = "https://overpass-api.de/api/interpreter"
    
    def get_features_near_location(
        self,
        latitude: float,
        longitude: float,
        radius: float = 500.0  # meters
    ) -> List[str]:
        """Get real map features near a location using OpenStreetMap Overpass API.
        Returns a list of feature names/descriptions."""
        try:
            import requests
        except ImportError:
            print("⚠️ requests not installed. Install with: pip install requests")
            return []
        
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
            seen_names = set()
            
            for element in data.get('elements', []):
                tags = element.get('tags', {})
                feature_type = self._classify_feature(element)
                
                # Get feature name or use type
                name = tags.get('name', '')
                if name and name not in seen_names:
                    features.append(f"{name} ({feature_type})")
                    seen_names.add(name)
                elif not name and feature_type not in seen_names:
                    # Use type if no name
                    if feature_type not in ['path']:  # Skip generic paths
                        features.append(feature_type)
                        seen_names.add(feature_type)
                
                # Limit to 5 features
                if len(features) >= 5:
                    break
            
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

class LLMService:
    def __init__(self):
        """Initialize LLM service with configuration from environment."""
        self.provider = os.getenv("LLM_PROVIDER", "openai").lower()
        self.model = os.getenv("LLM_MODEL", "gpt-4o-mini")
        self.temperature = 0.7
        self.max_tokens = 150  # Reduced from 500 to save tokens
        
        # Ollama configuration
        self.ollama_base_url = os.getenv("LLM_BASE_URL", "http://localhost:11434")
        
        # Initialize based on provider
        if self.provider == "ollama" or self.provider == "local":
            # Ollama doesn't need API key
            self.client = None
            self.api_key = None
            print(f"✅ LLM Service initialized with Ollama")
            print(f"   Model: {self.model}")
            print(f"   Base URL: {self.ollama_base_url}")
        else:
            # OpenAI or other cloud providers need API key
            self.api_key = os.getenv("OPENAI_API_KEY")
            if not self.api_key:
                print("⚠️ OPENAI_API_KEY not found in environment variables!")
                print("   Make sure server/.env file exists with your API key")
                self.client = None
            else:
                if OPENAI_AVAILABLE:
                    self.client = OpenAI(api_key=self.api_key)
                    print(f"✅ LLM Service initialized with {self.provider}")
                    print(f"   Model: {self.model}")
                else:
                    print("⚠️ OpenAI package not available")
                    self.client = None
        
        # Initialize map feature service (uses OpenStreetMap, no API key needed)
        self.map_feature_service = MapFeatureService()
    
    def _call_llm(self, prompt: str = None, messages: List[Dict] = None, max_tokens: int = None) -> str:
        """Internal method to call the LLM API (supports OpenAI and Ollama)."""
        # Use provided max_tokens or default
        tokens = max_tokens if max_tokens is not None else self.max_tokens
        
        # Route to appropriate provider
        if self.provider == "ollama" or self.provider == "local":
            return self._call_ollama(prompt=prompt, messages=messages, max_tokens=tokens)
        else:
            return self._call_openai(prompt=prompt, messages=messages, max_tokens=tokens)
    
    def _call_ollama(self, prompt: str = None, messages: List[Dict] = None, max_tokens: int = None) -> str:
        """Call Ollama API (local model)."""
        if not REQUESTS_AVAILABLE:
            return "Error: requests package not installed. Run: pip install requests"
        
        # Ollama API endpoint
        url = f"{self.ollama_base_url}/api/chat"
        
        # Convert messages to Ollama format
        if messages:
            # Ollama supports system/user/assistant roles, but we'll convert to its format
            ollama_messages = []
            for msg in messages:
                role = msg["role"]
                # Ollama uses "system", "user", "assistant" - same as OpenAI
                if role in ["system", "user", "assistant"]:
                    ollama_messages.append({
                        "role": role,
                        "content": msg["content"]
                    })
        else:
            # Single prompt - convert to user message
            ollama_messages = [{
                "role": "user",
                "content": prompt or ""
            }]
        
        # Ollama request format
        payload = {
            "model": self.model,
            "messages": ollama_messages,
            "options": {
                "temperature": self.temperature,
                "num_predict": tokens  # Ollama uses num_predict instead of max_tokens
            },
            "stream": False
        }
        
        try:
            response = requests.post(url, json=payload, timeout=60)
            response.raise_for_status()
            data = response.json()
            return data.get("message", {}).get("content", "").strip()
        except requests.exceptions.ConnectionError:
            return f"Error: Cannot connect to Ollama at {self.ollama_base_url}. Make sure Ollama is running: ollama serve"
        except requests.exceptions.Timeout:
            return "Error: Ollama request timed out. The model might be too slow or not loaded."
        except Exception as e:
            return f"Error calling Ollama: {str(e)}"
    
    def _call_openai(self, prompt: str = None, messages: List[Dict] = None, max_tokens: int = None) -> str:
        """Call OpenAI API."""
        if not OPENAI_AVAILABLE:
            return "Error: OpenAI package not installed. Run: pip install openai"
        
        if not self.client:
            return "Error: OPENAI_API_KEY not configured or client not initialized"
        
        try:
            if messages:
                # For conversations (system + user messages)
                response = self.client.chat.completions.create(
                    model=self.model,
                    messages=messages,
                    temperature=self.temperature,
                    max_tokens=max_tokens
                )
            else:
                # For simple prompts
                response = self.client.chat.completions.create(
                    model=self.model,
                    messages=[{"role": "user", "content": prompt}],
                    temperature=self.temperature,
                    max_tokens=max_tokens
                )
            return response.choices[0].message.content
        except Exception as e:
            return f"Error calling LLM: {str(e)}"
    
    def generate_npc_response(
        self,
        npc_name: str,
        npc_type: str,
        user_message: str,
        is_skeleton: bool = False,
        include_placement: bool = False,
        user_location: Optional[Dict] = None
    ) -> Dict:
        """Generate a conversational response from an NPC (skeleton, corgi, etc.).
        
        Args:
            include_placement: If True, also generate structured placement instructions for AR objects
        
        Returns:
            Dict with 'response' (text) and optionally 'placement' (structured instructions)
        """
        
        # Fetch real OSM features from user location if provided (for findable clues)
        map_features = []
        if user_location and user_location.get('latitude') and user_location.get('longitude'):
            try:
                map_features = self.map_feature_service.get_features_near_location(
                    user_location['latitude'],
                    user_location['longitude'],
                    radius=100.0  # 100 meters - ensure treasure is winnable
                )
            except Exception as e:
                print(f"⚠️ Could not fetch OSM features: {e}")
        
        # Build system prompt with real map features if available
        if is_skeleton:
            base_prompt = f"""Ye be {npc_name}, a SKELETON pirate from 200 years ago. Ye be dead, so ye can speak. Help players find the 200-year-old treasure. Speak ONLY in pirate speak (arr, ye, matey). Keep responses SHORT - 1-2 sentences max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:5])}. Use these actual features in your clues so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        elif npc_type.lower() == "traveller" or "corgi" in npc_name.lower():
            # Corgi Traveller - friendly, helpful, gives hints
            base_prompt = f"""You are {npc_name}, a friendly Corgi Traveller who loves exploring and helping adventurers. You're cheerful, helpful, and give hints about where to find treasures. Speak in a friendly, enthusiastic way (woof, tail wags, etc.). Keep responses SHORT - 1-2 sentences max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:5])}. Use these actual features in your hints so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        else:
            base_prompt = f"""Ye be {npc_name}, a {npc_type} pirate. Help players find treasures. Speak ONLY in pirate speak. Keep responses SHORT - 1-2 sentences max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:5])}. Use these actual features in your clues so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        
        system_prompt = base_prompt
        
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message}
        ]
        
        response_text = self._call_llm(messages=messages)
        
        result = {
            "response": response_text.strip()
        }
        
        # Generate placement instructions if requested
        if include_placement:
            placement = self._extract_placement_instructions(response_text, user_message)
            if placement:
                result["placement"] = placement
        
        return result
    
    def _extract_placement_instructions(self, npc_response: str, user_message: str) -> Optional[Dict]:
        """Extract placement instructions from NPC response using LLM.
        
        Returns structured data like:
        {
            "objects": [
                {"type": "tree", "count": 3, "description": "three palm trees"}
            ],
            "treasure_location": {
                "object_index": 1,  # Which tree (0-indexed)
                "description": "at the base of the second palm tree"
            }
        }
        """
        # Use LLM to extract structured placement data from the conversation
        extraction_prompt = f"""Extract AR object placement instructions from this NPC conversation.

NPC Response: "{npc_response}"
User Message: "{user_message}"

If the NPC mentions placing objects (like trees, rocks, etc.) or hiding treasure at a specific location, return JSON with:
{{
    "objects": [
        {{"type": "tree", "count": 3, "description": "three palm trees"}}
    ],
    "treasure_location": {{
        "object_index": 1,
        "description": "at the base of the second palm tree"
    }}
}}

If no placement instructions are mentioned, return: {{"objects": [], "treasure_location": null}}

Return ONLY valid JSON, no other text."""

        try:
            json_response = self._call_llm(prompt=extraction_prompt, max_tokens=200)
            # Try to parse JSON from response
            json_str = json_response.strip()
            # Remove markdown code blocks if present
            if json_str.startswith("```"):
                json_str = json_str.split("```")[1]
                if json_str.startswith("json"):
                    json_str = json_str[4:]
                json_str = json_str.strip()
            if json_str.endswith("```"):
                json_str = json_str[:-3].strip()
            
            placement_data = json.loads(json_str)
            
            # Validate structure
            if isinstance(placement_data, dict):
                # Only return if there are actual objects to place
                if placement_data.get("objects") and len(placement_data.get("objects", [])) > 0:
                    return placement_data
        except (json.JSONDecodeError, Exception) as e:
            # If extraction fails, return None (no placement instructions)
            print(f"⚠️ Could not extract placement instructions: {e}")
        
        return None
    
    def generate_map_piece(self, target_location: Dict, piece_number: int, total_pieces: int = 2, npc_type: str = "skeleton") -> Dict:
        """Generate a treasure map piece (half of the map) for an NPC.
        
        Args:
            target_location: Dict with 'latitude' and 'longitude' (where X marks the spot)
            piece_number: Which piece this is (1 or 2)
            total_pieces: Total number of pieces (default 2)
            npc_type: Type of NPC giving this piece (skeleton, corgi, etc.)
        
        Returns:
            Dict with map piece data including partial coordinates and landmarks
        """
        lat = target_location.get('latitude')
        lon = target_location.get('longitude')
        
        if not lat or not lon:
            return {"error": "target_location must include latitude and longitude"}
        
        # Fetch real map features
        map_features = self.map_feature_service.get_features_near_location(lat, lon, radius=500.0)
        
        # Generate partial coordinates (obfuscated slightly for puzzle)
        # Piece 1 (skeleton): Shows approximate area but not exact location
        # Piece 2 (corgi): Shows exact location
        if piece_number == 1:
            # First half: approximate location (within 100m)
            approximate_lat = lat + (random.random() - 0.5) * 0.001  # ~100m variation
            approximate_lon = lon + (random.random() - 0.5) * 0.001
            piece_data = {
                "piece_number": 1,
                "hint": f"Arr, this be the first half o' the map, matey! The treasure be near {', '.join(map_features[:2]) if map_features else 'these waters'}.",
                "approximate_latitude": approximate_lat,
                "approximate_longitude": approximate_lon,
                "landmarks": map_features[:3] if map_features else [],
                "is_first_half": True
            }
        else:
            # Second half: exact location
            piece_data = {
                "piece_number": 2,
                "hint": f"Woof! Here's the second half! The treasure is exactly at these coordinates!",
                "exact_latitude": lat,
                "exact_longitude": lon,
                "landmarks": map_features[3:6] if len(map_features) > 3 else [],
                "is_second_half": True
            }
        
        return piece_data
    
    def generate_clue(self, target_location: Dict, map_features: List[str] = None, fetch_real_features: bool = True) -> str:
        """Generate a SHORT pirate riddle clue for finding a treasure.
        
        Args:
            target_location: Dict with 'latitude' and 'longitude'
            map_features: Optional list of feature names (if not provided and fetch_real_features=True, will fetch from OpenStreetMap)
            fetch_real_features: If True and map_features not provided, fetch real features from OpenStreetMap
        """
        # Fetch real map features if not provided
        if not map_features and fetch_real_features:
            lat = target_location.get('latitude')
            lon = target_location.get('longitude')
            if lat and lon:
                print(f"🗺️  Fetching real map features near {lat}, {lon}...")
                map_features = self.map_feature_service.get_features_near_location(lat, lon, radius=500.0)
                if map_features:
                    print(f"   Found: {', '.join(map_features[:3])}")
        
        features_text = ""
        if map_features:
            features_text = f"Real features: {', '.join(map_features[:3])}"  # Only 3 features
        
        prompt = f"""Create a SHORT pirate riddle (1-2 lines max) telling where to dig. Use pirate speak. Reference: {features_text}

Keep it SHORT - 1-2 lines only. Riddle:"""
        
        response = self._call_llm(prompt=prompt, max_tokens=50)  # Limit to 50 tokens
        return response.strip()
    
    def test_connection(self) -> Dict:
        """Test if LLM service is working."""
        test_prompt = "Say 'Ahoy!' in pirate speak."  # Shorter prompt
        try:
            response = self._call_llm(prompt=test_prompt, max_tokens=10)  # Very short response
            
            # Check if response indicates an error
            if response.startswith("Error:"):
                return {
                    "status": "error",
                    "error": response,
                    "model": self.model,
                    "provider": self.provider,
                    "api_key_configured": bool(self.api_key) if self.provider != "ollama" else None
                }
            
            return {
                "status": "success",
                "response": response,
                "model": self.model,
                "provider": self.provider,
                "api_key_configured": bool(self.api_key) if self.provider != "ollama" else None
            }
        except Exception as e:
            return {
                "status": "error",
                "error": str(e),
                "model": self.model,
                "provider": self.provider,
                "api_key_configured": bool(self.api_key) if self.provider != "ollama" else None
            }

# Global instance
llm_service = LLMService()

