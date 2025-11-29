"""
LLM Service for CacheRaiders
Handles all LLM interactions: conversations, clue generation, quest creation
Supports OpenAI, Anthropic, and local Ollama models
"""
import os
import json
import random
import logging
import time
from typing import Optional, Dict, List

# Load environment variables from .env file
# But only if not running in a Docker container (container env vars take precedence)
try:
    from dotenv import load_dotenv
    # Only load .env if DOCKER_CONTAINER is not set (i.e., running locally)
    # When running in Docker, environment variables are set by docker-compose.yml
    if not os.getenv("DOCKER_CONTAINER"):
        load_dotenv()
except ImportError:
    # dotenv not available, but that's okay - environment variables might be set another way
    pass

# Set up file logging for map piece generation
log_dir = os.path.join(os.path.dirname(__file__), 'logs')
os.makedirs(log_dir, exist_ok=True)
map_log_file = os.path.join(log_dir, 'map_requests.log')

# Configure map logger (reuse same file as app.py)
map_logger = logging.getLogger('map_requests')
if not map_logger.handlers:  # Only add handler if not already added
    map_handler = logging.FileHandler(map_log_file, mode='a')
    map_handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    map_handler.setFormatter(formatter)
    map_logger.addHandler(map_handler)
    map_logger.setLevel(logging.DEBUG)
    map_logger.propagate = False

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

# Import MapFeatureService from separate module
from map_feature_service import MapFeatureService

def get_local_ip():
    """Get the local network IP address (same logic as app.py)."""
    import socket
    
    # First, check if HOST_IP environment variable is set
    host_ip = os.environ.get('HOST_IP')
    if host_ip:
        return host_ip
    
    # Try to get IP from all network interfaces
    try:
        # Get hostname to determine local IP
        hostname = socket.gethostname()
        try:
            ip = socket.gethostbyname(hostname)
            if ip and not ip.startswith('127.'):
                return ip
        except socket.gaierror:
            pass
        
        # Fallback: Connect to a remote address to determine local IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            if ip and not ip.startswith('127.'):
                return ip
        except Exception:
            pass
        finally:
            s.close()
    except Exception:
        pass
    
    # Last resort: return localhost
    return '127.0.0.1'

class LLMService:
    def __init__(self):
        """Initialize LLM service with configuration from environment."""
        self.provider = os.getenv("LLM_PROVIDER", "openai").lower()
        
        # Set default model based on provider
        # If LLM_MODEL is explicitly set, use it; otherwise use provider-specific default
        if os.getenv("LLM_MODEL"):
            self.model = os.getenv("LLM_MODEL")
        elif self.provider == "ollama" or self.provider == "local":
            # Default Ollama model (user should have llama2 or llama3 installed)
            # Use "llama2:latest" to match the format returned by Ollama
            self.model = os.getenv("LLM_MODEL", "llama2:latest")
        else:
            # Default OpenAI model
            self.model = os.getenv("LLM_MODEL", "gpt-4o-mini")
        
        self.temperature = 0.7
        self.max_tokens = 150  # Reduced from 500 to save tokens
        
        # Ollama configuration
        # The Python server connects to Ollama. When running in Docker, use the container name
        # (http://ollama:11434). When running locally, use localhost (http://localhost:11434).
        # The iOS app does NOT connect directly to Ollama - it goes through the Python API server.
        self.ollama_base_url = os.getenv("LLM_BASE_URL", "http://localhost:11434")
        
        # Store original API key from environment
        self._original_api_key = os.getenv("OPENAI_API_KEY")
        
        # Initialize based on provider
        self._initialize_provider()
        
        # Initialize map feature service (uses OpenStreetMap, no API key needed)
        self.map_feature_service = MapFeatureService()
    
    def _initialize_provider(self):
        """Initialize client based on current provider setting."""
        if self.provider == "ollama" or self.provider == "local":
            # Ollama doesn't need API key
            self.client = None
            self.api_key = None
            print(f"✅ LLM Service initialized with Ollama")
            print(f"   Model: {self.model}")
            print(f"   Base URL: {self.ollama_base_url}")
        else:
            # OpenAI or other cloud providers need API key
            self.api_key = self._original_api_key
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
    
    def set_provider(self, provider: str, model: str = None):
        """Switch LLM provider dynamically."""
        provider = provider.lower()
        if provider not in ["openai", "ollama", "local"]:
            return {"error": f"Invalid provider: {provider}. Must be 'openai', 'ollama', or 'local'"}
        
        old_provider = self.provider
        self.provider = provider
        
        if model:
            self.model = model
        
        # Re-initialize client for new provider
        self._initialize_provider()
        
        return {
            "status": "success",
            "provider": self.provider,
            "model": self.model,
            "previous_provider": old_provider
        }
    
    def get_provider_info(self):
        """Get current provider configuration."""
        return {
            "provider": self.provider,
            "model": self.model,
            "api_key_configured": bool(self.api_key) if self.provider != "ollama" else None,
            "client_initialized": self.client is not None if self.provider != "ollama" else None,
            "ollama_base_url": self.ollama_base_url if self.provider == "ollama" else None
        }
    
    def _call_llm(self, prompt: str = None, messages: List[Dict] = None, max_tokens: int = None) -> str:
        """Internal method to call the LLM API (supports OpenAI and Ollama)."""
        # Use provided max_tokens or default
        tokens = max_tokens if max_tokens is not None else self.max_tokens
        
        # Route to appropriate provider
        if self.provider == "ollama" or self.provider == "local":
            return self._call_ollama(prompt=prompt, messages=messages, max_tokens=tokens)
        else:
            return self._call_openai(prompt=prompt, messages=messages, max_tokens=tokens)
    
    def _get_available_models(self) -> str:
        """Get list of available Ollama models."""
        try:
            response = requests.get(f"{self.ollama_base_url}/api/tags", timeout=5)
            if response.status_code == 200:
                data = response.json()
                models = [m.get('name', 'unknown') for m in data.get('models', [])]
                return ', '.join(models) if models else 'No models installed'
            return 'Unable to fetch models'
        except Exception:
            return 'Unable to fetch models'
    
    def _call_ollama(self, prompt: str = None, messages: List[Dict] = None, max_tokens: int = None) -> str:
        """Call Ollama API (local model)."""
        if not REQUESTS_AVAILABLE:
            return "Error: requests package not installed. Run: pip install requests"
        
        # Use provided max_tokens or default
        tokens = max_tokens if max_tokens is not None else self.max_tokens
        
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
            # Increased timeout to 120 seconds for Ollama (local models can be slow, especially on first request)
            response = requests.post(url, json=payload, timeout=120)
            response.raise_for_status()
            data = response.json()
            return data.get("message", {}).get("content", "").strip()
        except requests.exceptions.ConnectionError as e:
            return f"Error: Cannot connect to Ollama at {self.ollama_base_url}. Make sure Ollama is running: ollama serve. Connection error: {str(e)}"
        except requests.exceptions.Timeout:
            return "Error: Ollama request timed out after 120 seconds. The model might be too slow, not loaded, or the server is overloaded. Try again in a moment."
        except requests.exceptions.HTTPError as e:
            # Handle HTTP errors (like 404 for missing model) separately
            if e.response.status_code == 404:
                try:
                    error_data = e.response.json() if e.response.text else {}
                    error_msg = error_data.get('error', 'Model not found')
                except:
                    error_msg = 'Model not found'
                available = self._get_available_models()
                return f"Error: {error_msg}. Available models: {available}. Install a model with: ollama pull <model-name>"
            return f"Error calling Ollama: HTTP {e.response.status_code} - {e.response.text[:200] if e.response.text else 'Unknown error'}"
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
        request_id = f"map_{int(time.time() * 1000)}"
        map_logger.info(f"[{request_id}] [LLM Service] generate_map_piece() called")
        map_logger.info(f"[{request_id}] [LLM Service] Parameters: piece_number={piece_number}, npc_type={npc_type}, total_pieces={total_pieces}")
        
        # Extract coordinates first
        lat = target_location.get('latitude')
        lon = target_location.get('longitude')
        
        map_logger.info(f"[{request_id}] [LLM Service] Target location: lat={lat}, lon={lon}")
        
        if not lat or not lon:
            map_logger.error(f"[{request_id}] [LLM Service] Missing coordinates in target_location")
            return {"error": "target_location must include latitude and longitude"}
        
        # Helper function to create map piece data (used in both success and error cases)
        def create_map_piece_data(landmarks_list):
            map_landmarks = []
            if isinstance(landmarks_list, list):
                for landmark in landmarks_list:
                    if isinstance(landmark, dict) and 'latitude' in landmark and 'longitude' in landmark:
                        map_landmarks.append({
                            'name': landmark.get('name', landmark.get('type', 'landmark')),
                            'type': landmark.get('type', 'landmark'),
                            'latitude': landmark['latitude'],
                            'longitude': landmark['longitude']
                        })
            
            # Generate partial coordinates (obfuscated slightly for puzzle)
            if piece_number == 1:
                approximate_lat = lat + (random.random() - 0.5) * 0.001  # ~100m variation
                approximate_lon = lon + (random.random() - 0.5) * 0.001
                return {
                    "piece_number": 1,
                    "hint": "Arr, this be the first half o' the map, matey! The treasure be near these waters!",
                    "approximate_latitude": approximate_lat,
                    "approximate_longitude": approximate_lon,
                    "landmarks": map_landmarks,
                    "is_first_half": True
                }
            else:
                return {
                    "piece_number": 2,
                    "hint": "Woof! Here's the second half! The treasure is exactly at these coordinates!",
                    "exact_latitude": lat,
                    "exact_longitude": lon,
                    "landmarks": map_landmarks,
                    "is_second_half": True
                }
        
        try:
            # Fetch nearby landmarks (within 50m) ONLY for Captain Bones game mode (skeleton NPC)
            # This is the Dead Men's Secrets game mode that uses crude treasure maps
            # OPTIMIZATION: Keep OSM data minimal - 50m radius, max 3 landmarks
            landmarks = []
            if npc_type.lower() == "skeleton":
                # Only fetch Overpass landmarks for Captain Bones (skeleton) game mode
                print(f"🗺️ [Captain Bones Game Mode] Fetching landmarks within 50m of {lat}, {lon} for crude treasure map...")
                map_logger.info(f"[{request_id}] [LLM Service] Starting Overpass API call for landmarks...")
                map_logger.info(f"[{request_id}] [LLM Service] Location: lat={lat}, lon={lon}, radius=50m")
                
                try:
                    overpass_start = time.time()
                    # Get 2-3 landmarks with coordinates for a minimal crude map
                    # Use 50m radius to keep OSM data to absolute minimum
                    landmarks = self.map_feature_service.get_features_near_location(
                        latitude=lat,
                        longitude=lon,
                        radius=50.0,  # 50 meters - minimal radius to reduce OSM data
                        return_coordinates=True,  # Get coordinates for map display
                        request_id=request_id  # Pass request ID for logging
                    )
                    overpass_duration = time.time() - overpass_start
                    map_logger.info(f"[{request_id}] [LLM Service] Overpass API call completed in {overpass_duration:.2f}s")
                    map_logger.info(f"[{request_id}] [LLM Service] Received {len(landmarks) if isinstance(landmarks, list) else 0} landmarks")

                    # Ensure landmarks is a list (get_features_near_location should always return a list)
                    if not isinstance(landmarks, list):
                        print(f"⚠️ [Captain Bones] get_features_near_location returned non-list: {type(landmarks)}")
                        landmarks = []

                    # Filter landmarks to be within 50m and limit to 3 for minimal map
                    filtered_landmarks = []
                    import math
                    for landmark in landmarks:
                        if isinstance(landmark, dict) and 'latitude' in landmark and 'longitude' in landmark:
                            # Calculate distance from treasure location
                            landmark_lat = landmark['latitude']
                            landmark_lon = landmark['longitude']

                            # Simple distance calculation (Haversine approximation for small distances)
                            lat_diff = math.radians(landmark_lat - lat)
                            lon_diff = math.radians(landmark_lon - lon)
                            a = math.sin(lat_diff/2)**2 + math.cos(math.radians(lat)) * math.cos(math.radians(landmark_lat)) * math.sin(lon_diff/2)**2
                            distance_m = 6371000 * 2 * math.asin(math.sqrt(a))  # Earth radius in meters

                            # Keep landmarks within 50m only
                            if distance_m <= 50.0:
                                filtered_landmarks.append(landmark)
                                if len(filtered_landmarks) >= 3:  # Max 3 landmarks for minimal map
                                    break

                    landmarks = filtered_landmarks
                    print(f"   [Captain Bones] Found {len(landmarks)} landmarks within 50m range")
                except Exception as e:
                    overpass_duration = time.time() - overpass_start if 'overpass_start' in locals() else 0
                    error_msg = str(e).lower()
                    map_logger.error(f"[{request_id}] [LLM Service] Overpass API call failed after {overpass_duration:.2f}s")
                    map_logger.error(f"[{request_id}] [LLM Service] Error type: {type(e).__name__}")
                    map_logger.error(f"[{request_id}] [LLM Service] Error message: {str(e)}")
                    
                    # If landmark fetch fails, continue without landmarks (map still works)
                    if 'too large' in error_msg or 'exceeded' in error_msg or 'maximum' in error_msg or 'resource' in error_msg:
                        map_logger.warning(f"[{request_id}] [LLM Service] Overpass API resource limit exceeded - continuing without landmarks")
                        print(f"⚠️ [Captain Bones] Overpass API resource limit exceeded: {e}")
                        print("   Continuing with map piece without landmarks (this is expected and safe)")
                    else:
                        map_logger.warning(f"[{request_id}] [LLM Service] Overpass API error - continuing without landmarks")
                        print(f"⚠️ [Captain Bones] Could not fetch landmarks: {e}")
                    landmarks = []
            else:
                # For other NPCs (like corgi), skip Overpass API calls
                print(f"ℹ️ Skipping Overpass API for {npc_type} NPC (not Captain Bones game mode)")
            
            # Generate and return map piece
            map_logger.info(f"[{request_id}] [LLM Service] Creating map piece data with {len(landmarks) if isinstance(landmarks, list) else 0} landmarks")
            result = create_map_piece_data(landmarks)
            map_logger.info(f"[{request_id}] [LLM Service] Map piece created successfully")
            return result
            
        except Exception as e:
            # Catch any errors (including Overpass API errors if somehow called)
            error_msg = str(e).lower()
            map_logger.error(f"[{request_id}] [LLM Service] Exception in generate_map_piece: {type(e).__name__}")
            map_logger.error(f"[{request_id}] [LLM Service] Exception message: {str(e)}")
            import traceback
            map_logger.error(f"[{request_id}] [LLM Service] Traceback: {traceback.format_exc()}")
            
            if 'too large' in error_msg or 'exceeded' in error_msg or 'maximum' in error_msg or 'resource' in error_msg:
                map_logger.warning(f"[{request_id}] [LLM Service] Resource exceeded error - returning map piece without landmarks")
                print(f"⚠️ Caught 'resource exceeded' error in generate_map_piece: {e}")
                print("   Returning map piece without features (this is expected and safe)")
                # Return a valid map piece even if there was an error
                # This ensures the user gets the map, just without landmark features
                return create_map_piece_data([])  # Empty landmarks if fetch failed
            else:
                # For other errors, return error dict
                map_logger.error(f"[{request_id}] [LLM Service] Returning error response")
                print(f"⚠️ Error in generate_map_piece: {e}")
                return {"error": f"Failed to generate map piece: {str(e)}"}
    
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

