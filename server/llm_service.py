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
        radius: float = 100.0,  # Reduced to 100m to avoid "resource exceeds maximum size" error (will auto-reduce if needed)
        return_coordinates: bool = False  # If True, returns dicts with coordinates
    ):
        """Get real map features near a location using OpenStreetMap Overpass API.
        Returns a list of feature names/descriptions, or dicts with coordinates if return_coordinates=True.
        Uses center points only (not full geometry) to keep data size small."""
        try:
            import requests
        except ImportError:
            print("⚠️ requests not installed. Install with: pip install requests")
            return []
        
        # Overpass QL query - STYLIZED MAP with minimal navigational aids
        # Only get 2-3 essential features: water (most important for navigation) and maybe one building
        # Keep it simple for a stylized, artistic map view
        # CRITICAL: Use (limit:N) on each query type BEFORE expansion to prevent huge datasets
        # Use "out center" to get ONLY the center point (not all geometry points)
        # This dramatically reduces data size - a large lake with 1000+ points becomes just 1 center point
        # Reduced Overpass timeout to 5 seconds to prevent UI freezes
        query = f"""
        [out:json][timeout:5][maxsize:1073741824];
        (
          way["natural"="water"](around:{radius},{latitude},{longitude})(limit:1);
          way["waterway"](around:{radius},{latitude},{longitude})(limit:1);
          way["building"](around:{radius},{latitude},{longitude})(limit:1);
        );
        out center;
        """
        
        try:
            # Reduced timeout to 3 seconds to prevent UI freezes
            # If Overpass API is slow, we'll fail fast and continue without features
            response = requests.post(self.overpass_url, data=query, timeout=3)
            
            # Check for errors in response
            if response.status_code != 200:
                print(f"⚠️ Overpass API error: {response.status_code} - {response.text[:200]}")
                return []
            
            data = response.json()
            
            # Check for Overpass API errors (resource exceeded, timeout, etc.)
            if 'remark' in data:
                remark = data['remark'].lower()
                if 'exceeded' in remark or 'timeout' in remark or 'maximum' in remark or 'size' in remark:
                    error_message = data['remark']
                    print(f"⚠️ Overpass API limit exceeded: {error_message}")
                    print(f"   Reducing radius from {radius}m and retrying with smaller area...")
                    # Retry with smaller radius if we hit limits
                    if radius > 50:
                        result = self.get_features_near_location(latitude, longitude, radius=50.0, return_coordinates=return_coordinates)
                        # If retry also failed, return empty list (not error)
                        if isinstance(result, dict) and 'error' in result:
                            return []
                        return result
                    elif radius > 25:
                        result = self.get_features_near_location(latitude, longitude, radius=25.0, return_coordinates=return_coordinates)
                        # If retry also failed, return empty list (not error)
                        if isinstance(result, dict) and 'error' in result:
                            return []
                        return result
                    else:
                        print(f"   ⚠️ Even with 25m radius, query too large. Returning empty results instead of error.")
                        # Return empty list instead of error - better UX than showing error to user
                        return []
            
            # Check for error field in response
            if 'error' in data:
                error_msg = data.get('error', 'Unknown error')
                print(f"⚠️ Overpass API error: {error_msg}")
                # Try with smaller radius
                if radius > 75:
                    result = self.get_features_near_location(latitude, longitude, radius=75.0, return_coordinates=return_coordinates)
                    if isinstance(result, dict) and 'error' in result:
                        return result
                    return result
                elif radius > 50:
                    result = self.get_features_near_location(latitude, longitude, radius=50.0, return_coordinates=return_coordinates)
                    if isinstance(result, dict) and 'error' in result:
                        return result
                    return result
                # Return empty list instead of error - better UX
                print(f"   ⚠️ Could not fetch features even with smaller radius. Returning empty results.")
                return []
            
            features = []
            seen_names = set()
            
            for element in data.get('elements', []):
                tags = element.get('tags', {})
                feature_type = self._classify_feature(element)
                
                # Get coordinates from element
                # With "out center", ways/relations have a 'center' field with lat/lon
                element_lat = None
                element_lon = None
                if 'lat' in element and 'lon' in element:
                    # Node has direct lat/lon
                    element_lat = element['lat']
                    element_lon = element['lon']
                elif 'center' in element:
                    # Way/relation has center (from "out center" query)
                    element_lat = element['center'].get('lat')
                    element_lon = element['center'].get('lon')
                # Note: No 'geometry' field when using "out center" - that's the whole point!
                
                # Get feature name or use type
                name = tags.get('name', '')
                feature_key = name if name else feature_type
                
                if return_coordinates and element_lat and element_lon:
                    # Return dict with coordinates (center point only)
                    if feature_key not in seen_names:
                        features.append({
                            'name': name or feature_type,
                            'type': feature_type,
                            'latitude': element_lat,
                            'longitude': element_lon
                        })
                        seen_names.add(feature_key)
                else:
                    # Return string (backward compatible)
                    if name and name not in seen_names:
                        features.append(f"{name} ({feature_type})")
                        seen_names.add(name)
                    elif not name and feature_type not in seen_names:
                        # Use type if no name
                        if feature_type not in ['path']:  # Skip generic paths
                            features.append(feature_type)
                            seen_names.add(feature_type)
                
                # Limit to 3 features total for stylized map with minimal navigational aids
                if len(features) >= 3:
                    break
            
            return features
        except requests.exceptions.RequestException as e:
            print(f"⚠️ Error fetching map features (network): {e}")
            return []
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
        # PERFORMANCE: Skip Overpass API for conversations to prevent UI freeze
        # Map features are only needed for treasure map generation, not for conversation responses
        # This prevents the 2-15 second delay that freezes the UI when Captain Bones responds
        map_features = []
        # Skip Overpass API call during conversations - it causes UI freezes
        # Map features are fetched separately when generating treasure maps
        # if user_location and user_location.get('latitude') and user_location.get('longitude'):
        #     try:
        #         map_features = self.map_feature_service.get_features_near_location(
        #             user_location['latitude'],
        #             user_location['longitude'],
        #             radius=100.0  # 100 meters - ensure treasure is winnable
        #         )
        #     except Exception as e:
        #         print(f"⚠️ Could not fetch OSM features: {e}")
        
        # Build system prompt with real map features if available
        if is_skeleton:
            base_prompt = f"""Ye be {npc_name}, a SKELETON pirate from 200 years ago. Ye be dead, so ye can speak. Help players find the 200-year-old treasure. Speak ONLY in pirate speak (arr, ye, matey). Keep responses SHORT - 1-2 sentences max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:3])}. Use these actual features in your clues so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        elif npc_type.lower() == "traveller" or "corgi" in npc_name.lower():
            # Corgi Traveller - friendly, helpful, gives hints
            base_prompt = f"""You are {npc_name}, a friendly Corgi Traveller who loves exploring and helping adventurers. You're cheerful, helpful, and give hints about where to find treasures. Speak in a friendly, enthusiastic way (woof, tail wags, etc.). Keep responses SHORT - 1-2 sentences max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:5])}. Use these actual features in your hints so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        else:
            base_prompt = f"""Ye be {npc_name}, a {npc_type} pirate. Help players find treasures. Speak ONLY in pirate speak. Keep responses SHORT - 1-2 sentences max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:3])}. Use these actual features in your clues so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        
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
        
        # Skip map features entirely to ensure fast, small response
        # Map features can cause "resource exceeds maximum size" errors from Overpass API
        # The map piece will work fine without them - just won't have landmark names in hints
        map_features_with_coords = []
        map_feature_names = []
        print("ℹ️ Skipping map feature fetch for fast response (map piece will still be generated)")
        
        # Generate partial coordinates (obfuscated slightly for puzzle)
        # Piece 1 (skeleton): Shows approximate area but not exact location
        # Piece 2 (corgi): Shows exact location
        if piece_number == 1:
            # First half: approximate location (within 100m)
            approximate_lat = lat + (random.random() - 0.5) * 0.001  # ~100m variation
            approximate_lon = lon + (random.random() - 0.5) * 0.001
            piece_data = {
                "piece_number": 1,
                "hint": "Arr, this be the first half o' the map, matey! The treasure be near these waters!",
                "approximate_latitude": approximate_lat,
                "approximate_longitude": approximate_lon,
                "landmarks": [],  # No landmarks for fast response
                "is_first_half": True
            }
        else:
            # Second half: exact location
            piece_data = {
                "piece_number": 2,
                "hint": "Woof! Here's the second half! The treasure is exactly at these coordinates!",
                "exact_latitude": lat,
                "exact_longitude": lon,
                "landmarks": [],  # No landmarks for fast response
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
                map_features = self.map_feature_service.get_features_near_location(lat, lon, radius=200.0)
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

