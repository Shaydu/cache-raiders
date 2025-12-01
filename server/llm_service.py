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
import base64
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
        self.provider = os.getenv("LLM_PROVIDER", "ollama").lower()
        
        # Set default model based on provider
        # Validate that LLM_MODEL matches the provider, otherwise use provider-specific default
        env_model = os.getenv("LLM_MODEL")
        
        if self.provider == "ollama" or self.provider == "local":
            # For Ollama, check if env model is valid (not an OpenAI model)
            if env_model and not env_model.startswith("gpt-") and not env_model.startswith("o1-"):
                # Valid Ollama model name
                self.model = env_model
            else:
                # Use Ollama default (granite4:350m is smallest and fastest, fallback to llama3.2:1b)
                self.model = env_model if env_model and not env_model.startswith("gpt-") else "granite4:350m"
        else:
            # For OpenAI/other providers, use env model or default
            if env_model:
                self.model = env_model
            else:
                # Default OpenAI model
                self.model = "gpt-4o-mini"
        
        self.temperature = 0.7
        self.max_tokens = 100  # Optimized for quick responses (conversations are short)
        self.map_max_tokens = 150  # Slightly more for map generation if needed
        
        # Ollama configuration
        # The Python server connects to Ollama. When running in Docker, use the container name
        # (http://ollama:11434). When running locally, use localhost (http://localhost:11434).
        # The iOS app does NOT connect directly to Ollama - it goes through the Python API server.
        # Check if we're in Docker first, then use environment variable, then default
        if os.getenv("DOCKER_CONTAINER"):
            # In Docker, default to container service name
            self.ollama_base_url = os.getenv("LLM_BASE_URL", "http://ollama:11434")
        else:
            # Running locally, default to localhost
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
        # CRITICAL: Normalize provider (lowercase, strip whitespace)
        provider = str(provider).lower().strip() if provider else None
        
        if not provider or provider not in ["openai", "ollama", "local"]:
            return {"error": f"Invalid provider: {provider}. Must be 'openai', 'ollama', or 'local'"}
        
        old_provider = self.provider
        old_model = self.model
        
        # CRITICAL: Set provider FIRST before any model validation
        self.provider = provider
        print(f"🔧 [LLM Service] Provider set to: '{self.provider}' (was: '{old_provider}')")
        
        # Set model - validate it matches the provider
        # CRITICAL: Provider is already set above, so validation won't affect it
        if model:
            print(f"🔄 [LLM Service] Setting model to: {model} (provider: {self.provider})")
            # Validate model matches provider
            if self.provider in ["ollama", "local"]:
                # For Ollama, reject OpenAI model names
                if model.startswith("gpt-") or model.startswith("o1-"):
                    # Invalid model for Ollama, use default
                    if self.provider == "ollama":
                        self.model = "granite4:350m"  # Default Ollama model (smallest)
                        print(f"⚠️ [LLM Service] Invalid model '{model}' for Ollama, using default: {self.model}")
                        print(f"🔧 [LLM Service] Provider remains: {self.provider} (unchanged)")
                    else:
                        self.model = "llama2:latest"
                        print(f"⚠️ [LLM Service] Invalid model '{model}' for local, using default: {self.model}")
                        print(f"🔧 [LLM Service] Provider remains: {self.provider} (unchanged)")
                else:
                    self.model = model
                    print(f"✅ [LLM Service] Model set to: {self.model}")
            else:
                # For OpenAI, accept any model name (could be gpt-4o-mini, gpt-4o, etc.)
                self.model = model
                print(f"✅ [LLM Service] Model set to: {self.model}")
        else:
            # No model specified - use provider-specific default
            if self.provider in ["ollama", "local"]:
                self.model = "llama3:8b"  # Default Ollama model
            else:
                self.model = "gpt-4o-mini"  # Default OpenAI model
            print(f"ℹ️ [LLM Service] No model specified, using default: {self.model} for provider: {self.provider}")
        
        # Re-initialize client for new provider
        # CRITICAL: Verify provider is still correct before initializing
        if self.provider != provider:
            print(f"❌ [LLM Service] ERROR: Provider mismatch! Expected {provider}, got {self.provider}")
            # Force correct provider
            self.provider = provider
            print(f"🔧 [LLM Service] Forced provider to: {self.provider}")
        
        self._initialize_provider()
        
        # Final verification
        print(f"✅ [LLM Service] Provider updated: {old_provider} → {self.provider}, Model: {old_model} → {self.model}")
        print(f"🔍 [LLM Service] Final state - Provider: {self.provider}, Model: {self.model}")
        
        return {
            "status": "success",
            "provider": self.provider,
            "model": self.model,
            "previous_provider": old_provider
        }
    
    def get_provider_info(self):
        """Get current provider configuration."""
        # Normalize provider for consistent output
        provider = str(self.provider).lower().strip() if self.provider else "ollama"
        return {
            "provider": provider,
            "model": self.model,
            "api_key_configured": bool(self.api_key) if provider not in ["ollama", "local"] else None,
            "client_initialized": self.client is not None if provider not in ["ollama", "local"] else None,
            "ollama_base_url": self.ollama_base_url if provider in ["ollama", "local"] else None
        }
    
    def _call_llm(self, prompt: str = None, messages: List[Dict] = None, max_tokens: int = None) -> str:
        """Internal method to call the LLM API (supports OpenAI and Ollama)."""
        # Use provided max_tokens or default
        tokens = max_tokens if max_tokens is not None else self.max_tokens
        
        # CRITICAL: Normalize provider to ensure consistent comparison
        if self.provider:
            self.provider = str(self.provider).lower().strip()
        
        # Log current provider and model for debugging
        print(f"🔍 [LLM Service] _call_llm called with provider: '{self.provider}', model: '{self.model}'")
        
        # CRITICAL: Verify provider is valid before routing
        if not self.provider:
            print(f"❌ [LLM Service] ERROR: Provider is None or empty! Defaulting to Ollama")
            self.provider = "ollama"
            self.model = "llama3:8b"
            self._initialize_provider()
        
        # Route to appropriate provider (normalized comparison)
        if self.provider in ["ollama", "local"]:
            print(f"✅ [LLM Service] Routing to Ollama with model: {self.model}")
            return self._call_ollama(prompt=prompt, messages=messages, max_tokens=tokens)
        else:
            print(f"✅ [LLM Service] Routing to OpenAI with model: {self.model}")
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
        
        # Log which model is being used
        print(f"🤖 [LLM Service] Calling Ollama with model: {self.model}")
        
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
                "num_predict": tokens,  # Ollama uses num_predict instead of max_tokens
                "num_ctx": 2048,  # Reduce context window for faster processing
                "num_thread": 4,  # Limit threads to prevent CPU overload
            },
            "stream": False,
            "keep_alive": -1  # Keep model in memory permanently (matches docker-compose OLLAMA_KEEP_ALIVE)
        }
        
        try:
            # Timeout: 180 seconds (3 minutes) for initial load of small models
            # llama3.2:1b should load quickly, but first request may take 30-60s
            # The keepalive thread should keep the model warm, so subsequent requests should be <5s
            import time
            start_time = time.time()
            response = requests.post(url, json=payload, timeout=180)
            elapsed = time.time() - start_time
            if elapsed > 1.0:
                print(f"⏱️ Ollama request took {elapsed:.2f}s (model may have loaded)")
            response.raise_for_status()
            data = response.json()
            return data.get("message", {}).get("content", "").strip()
        except requests.exceptions.ConnectionError as e:
            return f"Error: Cannot connect to Ollama at {self.ollama_base_url}. Make sure Ollama is running: ollama serve. Connection error: {str(e)}"
        except requests.exceptions.Timeout:
            return "Error: Ollama request timed out after 180 seconds. The model might be loading for the first time. Try warming up the model first: curl http://localhost:5001/api/llm/warmup or wait a moment and try again. For granite4:350m, first load should take 10-30 seconds."
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
        
        # Log which model is being used
        print(f"🤖 [LLM Service] Calling OpenAI with model: {self.model}")
        
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
        # OPTIMIZED: Shorter prompts for faster processing
        if is_skeleton:
            base_prompt = f"""Ye be {npc_name}, a SKELETON pirate from 200 years ago. Speak ONLY pirate (arr, ye, matey). Responses: 1 sentence max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:3])}. Use these actual features in your clues so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        elif npc_type.lower() == "traveller" or "corgi" in npc_name.lower():
            # Corgi Traveller - friendly, helpful, gives hints
            base_prompt = f"""You are {npc_name}, a friendly Corgi Traveller. Help adventurers. Speak friendly (woof!). Responses: 1 sentence max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:5])}. Use these actual features in your hints so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        else:
            base_prompt = f"""Ye be {npc_name}, a {npc_type} pirate. Speak ONLY pirate. Responses: 1 sentence max."""
            if map_features:
                base_prompt += f"\n\nIMPORTANT: Reference REAL landmarks near the player: {', '.join(map_features[:3])}. Use these actual features in your clues so the treasure is findable. The treasure must be within 100 meters of the player's current location."""
        
        system_prompt = base_prompt
        
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message}
        ]
        
        # Use shorter max_tokens for conversations (faster responses)
        import time
        start_time = time.time()
        response_text = self._call_llm(messages=messages, max_tokens=80)  # Very short for quick responses
        elapsed = time.time() - start_time
        if elapsed > 2.0:
            print(f"⏱️ NPC response generation took {elapsed:.2f}s")
        
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
    
    def analyze_map_image(
        self,
        image_path: str = None,
        image_base64: str = None,
        image_url: str = None,
        center_latitude: float = None,
        center_longitude: float = None,
        radius_meters: float = 50.0
    ) -> Dict:
        """Generate a treasure map piece (half of the map) for an NPC.
        
        Args:
            target_location: Dict with 'latitude' and 'longitude' (where X marks the spot)
            piece_number: Which piece this is (1 or 2)
            total_pieces: Total number of pieces (default 2)
            npc_type: Type of NPC giving this piece (skeleton, corgi, etc.)
            map_image_path: Optional path to map/satellite image for vision analysis
            map_image_base64: Optional base64-encoded map image for vision analysis
            map_image_url: Optional URL to map image for vision analysis
            use_vision_analysis: If True, analyze map image with vision LLM to extract landmarks
        
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
            """Create map piece data with landmarks.
            
            CRITICAL: Only uses REAL landmarks from OpenStreetMap.
            Never generates fake, placeholder, or imaginary features.
            If no landmarks are available, returns empty list (no fake features).
            """
            map_landmarks = []
            if isinstance(landmarks_list, list):
                for landmark in landmarks_list:
                    # VALIDATION: Only include landmarks with valid coordinates from OSM
                    if isinstance(landmark, dict) and 'latitude' in landmark and 'longitude' in landmark:
                        lat = landmark['latitude']
                        lon = landmark['longitude']
                        # Validate coordinates are real (not 0,0 or invalid)
                        if abs(lat) <= 90 and abs(lon) <= 180 and (lat != 0 or lon != 0):
                            map_landmarks.append({
                                'name': landmark.get('name', landmark.get('type', 'landmark')),
                                'type': landmark.get('type', 'landmark'),
                                'latitude': lat,  # REAL OSM coordinate
                                'longitude': lon  # REAL OSM coordinate
                            })
                        else:
                            map_logger.warning(f"[{request_id}] [Map Piece] Skipping landmark with invalid coordinates: {landmark.get('name', 'unknown')}")
                    else:
                        map_logger.warning(f"[{request_id}] [Map Piece] Skipping landmark without coordinates: {landmark}")
            
            # If no real landmarks found, return empty list (never generate fake ones)
            if not map_landmarks:
                map_logger.info(f"[{request_id}] [Map Piece] No real OSM landmarks found - map will show without landmarks (this is expected)")
            
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
            vision_landmarks = []
            
            if npc_type.lower() == "skeleton":
                # Option 1: Vision-based landmark extraction from map image
                if use_vision_analysis and (map_image_path or map_image_base64 or map_image_url):
                    print(f"👁️ [Captain Bones] Using vision LLM to analyze map image for landmarks...")
                    map_logger.info(f"[{request_id}] [LLM Service] Starting vision analysis for landmarks...")
                    
                    try:
                        vision_start = time.time()
                        vision_result = self.analyze_map_image(
                            image_path=map_image_path,
                            image_base64=map_image_base64,
                            image_url=map_image_url,
                            center_latitude=lat,
                            center_longitude=lon,
                            radius_meters=50.0
                        )
                        vision_duration = time.time() - vision_start
                        map_logger.info(f"[{request_id}] [LLM Service] Vision analysis completed in {vision_duration:.2f}s")
                        
                        if "error" not in vision_result and "landmarks" in vision_result:
                            vision_landmarks = vision_result["landmarks"]
                            print(f"   [Captain Bones] Vision found {len(vision_landmarks)} landmarks from image")
                            map_logger.info(f"[{request_id}] [LLM Service] Vision extracted {len(vision_landmarks)} landmarks")
                            
                            # Convert vision landmarks to same format as OSM landmarks
                            for v_landmark in vision_landmarks:
                                if "estimated_latitude" in v_landmark and "estimated_longitude" in v_landmark:
                                    landmarks.append({
                                        'name': v_landmark.get('name', v_landmark.get('type', 'landmark')),
                                        'type': v_landmark.get('type', 'landmark'),
                                        'latitude': v_landmark['estimated_latitude'],
                                        'longitude': v_landmark['estimated_longitude'],
                                        'description': v_landmark.get('description', ''),
                                        'source': 'vision'  # Mark as vision-extracted
                                    })
                        else:
                            error_msg = vision_result.get('error', 'Unknown vision error')
                            map_logger.warning(f"[{request_id}] [LLM Service] Vision analysis failed: {error_msg}")
                            print(f"⚠️ [Captain Bones] Vision analysis failed: {error_msg}")
                    except Exception as e:
                        vision_duration = time.time() - vision_start if 'vision_start' in locals() else 0
                        map_logger.error(f"[{request_id}] [LLM Service] Vision analysis exception after {vision_duration:.2f}s: {str(e)}")
                        print(f"⚠️ [Captain Bones] Vision analysis error: {e}")
                        # Continue with OSM fallback
                
                # Option 2: OpenStreetMap-based landmark extraction (fallback or primary)
                # If vision didn't find enough landmarks, or vision is disabled, use OSM
                if len(landmarks) < 2:
                    print(f"🗺️ [Captain Bones Game Mode] Fetching OSM landmarks within 50m of {lat}, {lon} for crude treasure map...")
                    map_logger.info(f"[{request_id}] [LLM Service] Starting Overpass API call for landmarks...")
                    map_logger.info(f"[{request_id}] [LLM Service] Location: lat={lat}, lon={lon}, radius=50m")
                    
                    try:
                        overpass_start = time.time()
                        # Get 2-3 landmarks with coordinates for a minimal crude map
                        # Use 50m radius to keep OSM data to absolute minimum
                        osm_landmarks = self.map_feature_service.get_features_near_location(
                            latitude=lat,
                            longitude=lon,
                            radius=50.0,  # 50 meters - minimal radius to reduce OSM data
                            return_coordinates=True,  # Get coordinates for map display
                            request_id=request_id  # Pass request ID for logging
                        )
                        overpass_duration = time.time() - overpass_start
                        map_logger.info(f"[{request_id}] [LLM Service] Overpass API call completed in {overpass_duration:.2f}s")
                        map_logger.info(f"[{request_id}] [LLM Service] Received {len(osm_landmarks) if isinstance(osm_landmarks, list) else 0} OSM landmarks")

                        # Ensure landmarks is a list (get_features_near_location should always return a list)
                        if not isinstance(osm_landmarks, list):
                            print(f"⚠️ [Captain Bones] get_features_near_location returned non-list: {type(osm_landmarks)}")
                            osm_landmarks = []

                        # Filter landmarks to be within 50m and limit to 3 for minimal map
                        filtered_landmarks = []
                        import math
                        for landmark in osm_landmarks:
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
                                    landmark['source'] = 'osm'  # Mark as OSM-extracted
                                    filtered_landmarks.append(landmark)
                                    if len(filtered_landmarks) >= 3:  # Max 3 landmarks for minimal map
                                        break

                        # Combine vision and OSM landmarks (prioritize vision if available)
                        if vision_landmarks:
                            # Use vision landmarks first, then fill with OSM if needed
                            landmarks = [l for l in landmarks if l.get('source') == 'vision']
                            # Add OSM landmarks that don't duplicate vision landmarks
                            for osm_lm in filtered_landmarks:
                                if len(landmarks) >= 3:
                                    break
                                # Check if similar landmark already exists from vision
                                is_duplicate = False
                                for existing in landmarks:
                                    if existing.get('type') == osm_lm.get('type'):
                                        # Calculate distance between landmarks
                                        dist = math.sqrt(
                                            (existing['latitude'] - osm_lm['latitude'])**2 +
                                            (existing['longitude'] - osm_lm['longitude'])**2
                                        ) * 111000  # Rough conversion to meters
                                        if dist < 10:  # Within 10m = likely same feature
                                            is_duplicate = True
                                            break
                                if not is_duplicate:
                                    landmarks.append(osm_lm)
                        else:
                            landmarks = filtered_landmarks
                        
                        print(f"   [Captain Bones] Found {len(landmarks)} total landmarks ({len(vision_landmarks)} from vision, {len(filtered_landmarks)} from OSM)")
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
                        # Keep vision landmarks if we have them
                        if not vision_landmarks:
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
    
    def analyze_map_image(
        self,
        image_path: str = None,
        image_base64: str = None,
        image_url: str = None,
        center_latitude: float = None,
        center_longitude: float = None,
        radius_meters: float = 50.0
    ) -> Dict:
        """Analyze a map/satellite image using vision LLM to extract structural landmarks.
        
        This method uses vision-capable LLMs (GPT-4 Vision, Claude 3 Vision, or local vision models)
        to identify structural elements in map imagery like trees, roads, water bodies, buildings, etc.
        These can be used as landmarks alongside or instead of OpenStreetMap data.
        
        Args:
            image_path: Path to local image file (PNG, JPEG)
            image_base64: Base64-encoded image string (alternative to image_path)
            image_url: URL to image (alternative to image_path/image_base64)
            center_latitude: Center latitude of the map area (for coordinate calculation)
            center_longitude: Center longitude of the map area (for coordinate calculation)
            radius_meters: Approximate radius of the map area in meters (for coordinate estimation)
        
        Returns:
            Dict with:
            {
                "landmarks": [
                    {
                        "name": "Large oak tree",
                        "type": "tree",
                        "description": "Large oak tree in center of clearing",
                        "estimated_latitude": 37.7749,  # If center_lat/lon provided
                        "estimated_longitude": -122.4194,
                        "relative_position": "center",  # center, north, south, east, west, etc.
                        "confidence": "high"  # high, medium, low
                    }
                ],
                "analysis_summary": "Found 3 trees, 1 path, 1 water feature...",
                "provider": "openai" or "ollama"
            }
        """
        request_id = f"vision_{int(time.time() * 1000)}"
        map_logger.info(f"[{request_id}] [Vision] analyze_map_image() called")
        
        # Validate image input
        if not any([image_path, image_base64, image_url]):
            return {"error": "Must provide image_path, image_base64, or image_url"}
        
        # Check if provider supports vision
        vision_supported = False
        vision_model = None
        
        if self.provider == "openai":
            # OpenAI Vision models: gpt-4o, gpt-4o-mini, gpt-4-vision-preview
            if "gpt-4o" in self.model.lower() or "gpt-4-vision" in self.model.lower():
                vision_supported = True
                vision_model = self.model
            elif "gpt-4" in self.model.lower():
                # Try to use gpt-4o-mini for vision if current model doesn't support it
                vision_supported = True
                vision_model = "gpt-4o-mini"  # Fallback to vision-capable model
        elif self.provider in ["ollama", "local"]:
            # Check if Ollama model supports vision (llava, bakllava, etc.)
            if "llava" in self.model.lower() or "bakllava" in self.model.lower() or "vision" in self.model.lower():
                vision_supported = True
                vision_model = self.model
            else:
                # Try common vision models
                vision_model = "llava:latest"  # Common Ollama vision model
                vision_supported = True  # Assume it's available
        
        if not vision_supported:
            return {
                "error": f"Current provider/model ({self.provider}/{self.model}) does not support vision. "
                        f"For OpenAI, use gpt-4o or gpt-4-vision-preview. "
                        f"For Ollama, use llava or bakllava models."
            }
        
        map_logger.info(f"[{request_id}] [Vision] Using vision model: {vision_model}")
        
        # Prepare image for API
        image_data = None
        if image_path:
            try:
                with open(image_path, 'rb') as f:
                    image_bytes = f.read()
                    image_data = base64.b64encode(image_bytes).decode('utf-8')
                map_logger.info(f"[{request_id}] [Vision] Loaded image from path: {image_path}")
            except Exception as e:
                return {"error": f"Failed to load image from path: {str(e)}"}
        elif image_base64:
            image_data = image_base64
            map_logger.info(f"[{request_id}] [Vision] Using provided base64 image")
        elif image_url:
            # For URL, we'll pass it directly to the API
            image_data = image_url
            map_logger.info(f"[{request_id}] [Vision] Using image URL: {image_url}")
        
        # Build analysis prompt
        location_context = ""
        if center_latitude and center_longitude:
            location_context = f"\n\nLocation context: Center at ({center_latitude}, {center_longitude}), radius approximately {radius_meters}m."
        
        analysis_prompt = f"""Analyze this map or satellite image and identify structural elements that could be used as landmarks for navigation.

Identify and describe:
- Trees (individual trees, tree clusters, tree lines)
- Roads/Paths (paved roads, dirt paths, trails, sidewalks)
- Water features (ponds, streams, rivers, fountains, pools)
- Buildings (houses, sheds, structures)
- Natural features (rocks, clearings, hills)
- Other distinctive landmarks

For each landmark found, provide:
1. Type (tree, road, water, building, etc.)
2. Description (size, position, distinctive features)
3. Relative position in the image (center, top-left, bottom-right, etc.)
4. Estimated confidence (high/medium/low)

Return your analysis as JSON with this structure:
{{
    "landmarks": [
        {{
            "name": "Descriptive name",
            "type": "tree|road|water|building|natural|other",
            "description": "Detailed description",
            "relative_position": "center|north|south|east|west|northeast|northwest|southeast|southwest",
            "confidence": "high|medium|low"
        }}
    ],
    "analysis_summary": "Brief summary of what was found"
}}

{location_context}

Return ONLY valid JSON, no other text."""
        
        try:
            if self.provider == "openai":
                return self._analyze_image_openai_vision(
                    image_data=image_data,
                    image_url=image_url,
                    prompt=analysis_prompt,
                    vision_model=vision_model,
                    center_latitude=center_latitude,
                    center_longitude=center_longitude,
                    radius_meters=radius_meters,
                    request_id=request_id
                )
            elif self.provider in ["ollama", "local"]:
                return self._analyze_image_ollama_vision(
                    image_data=image_data,
                    image_path=image_path,
                    image_url=image_url,
                    prompt=analysis_prompt,
                    vision_model=vision_model,
                    center_latitude=center_latitude,
                    center_longitude=center_longitude,
                    radius_meters=radius_meters,
                    request_id=request_id
                )
        except Exception as e:
            map_logger.error(f"[{request_id}] [Vision] Error analyzing image: {str(e)}")
            return {"error": f"Failed to analyze image: {str(e)}"}
    
    def _analyze_image_openai_vision(
        self,
        image_data: str = None,
        image_url: str = None,
        prompt: str = None,
        vision_model: str = None,
        center_latitude: float = None,
        center_longitude: float = None,
        radius_meters: float = 50.0,
        request_id: str = None
    ) -> Dict:
        """Analyze image using OpenAI Vision API."""
        if not OPENAI_AVAILABLE or not self.client:
            return {"error": "OpenAI client not available"}
        
        map_logger.info(f"[{request_id}] [Vision] Calling OpenAI Vision API with model: {vision_model}")
        
        # Prepare image content
        image_content = []
        if image_url:
            image_content.append({
                "type": "image_url",
                "image_url": {"url": image_url}
            })
        elif image_data:
            # Determine image format from base64 or use default
            image_format = "png"  # Default
            if image_data.startswith("data:image"):
                # Extract format from data URL
                if "jpeg" in image_data or "jpg" in image_data:
                    image_format = "jpeg"
                elif "png" in image_data:
                    image_format = "png"
            image_content.append({
                "type": "image_url",
                "image_url": {"url": f"data:image/{image_format};base64,{image_data}"}
            })
        
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    *image_content
                ]
            }
        ]
        
        try:
            start_time = time.time()
            response = self.client.chat.completions.create(
                model=vision_model,
                messages=messages,
                temperature=0.3,  # Lower temperature for more consistent analysis
                max_tokens=2000  # More tokens for detailed landmark descriptions
            )
            elapsed = time.time() - start_time
            map_logger.info(f"[{request_id}] [Vision] OpenAI Vision API call completed in {elapsed:.2f}s")
            
            response_text = response.choices[0].message.content
            
            # Parse JSON response
            json_str = response_text.strip()
            # Remove markdown code blocks if present
            if json_str.startswith("```"):
                json_str = json_str.split("```")[1]
                if json_str.startswith("json"):
                    json_str = json_str[4:]
                json_str = json_str.strip()
            if json_str.endswith("```"):
                json_str = json_str[:-3].strip()
            
            result = json.loads(json_str)
            
            # Add estimated coordinates if center location provided
            if center_latitude and center_longitude and "landmarks" in result:
                result["landmarks"] = self._estimate_landmark_coordinates(
                    landmarks=result["landmarks"],
                    center_lat=center_latitude,
                    center_lon=center_longitude,
                    radius_m=radius_meters
                )
            
            result["provider"] = "openai"
            result["model"] = vision_model
            map_logger.info(f"[{request_id}] [Vision] Extracted {len(result.get('landmarks', []))} landmarks")
            return result
            
        except json.JSONDecodeError as e:
            map_logger.error(f"[{request_id}] [Vision] Failed to parse JSON response: {str(e)}")
            map_logger.error(f"[{request_id}] [Vision] Response text: {response_text[:500]}")
            return {"error": f"Failed to parse LLM response as JSON: {str(e)}"}
        except Exception as e:
            map_logger.error(f"[{request_id}] [Vision] OpenAI Vision API error: {str(e)}")
            return {"error": f"OpenAI Vision API error: {str(e)}"}
    
    def _analyze_image_ollama_vision(
        self,
        image_data: str = None,
        image_path: str = None,
        image_url: str = None,
        prompt: str = None,
        vision_model: str = None,
        center_latitude: float = None,
        center_longitude: float = None,
        radius_meters: float = 50.0,
        request_id: str = None
    ) -> Dict:
        """Analyze image using Ollama vision model (llava, bakllava, etc.)."""
        if not REQUESTS_AVAILABLE:
            return {"error": "requests package not installed"}
        
        map_logger.info(f"[{request_id}] [Vision] Calling Ollama Vision API with model: {vision_model}")
        
        # Ollama vision API endpoint
        url = f"{self.ollama_base_url}/api/chat"
        
        # Prepare image - Ollama needs base64 or file path
        images = []
        if image_path:
            # Read image and encode to base64
            try:
                with open(image_path, 'rb') as f:
                    image_bytes = f.read()
                    image_base64 = base64.b64encode(image_bytes).decode('utf-8')
                    images.append(image_base64)
            except Exception as e:
                return {"error": f"Failed to read image file: {str(e)}"}
        elif image_data:
            images.append(image_data)
        elif image_url:
            # Download image from URL
            try:
                response = requests.get(image_url, timeout=10)
                response.raise_for_status()
                image_base64 = base64.b64encode(response.content).decode('utf-8')
                images.append(image_base64)
            except Exception as e:
                return {"error": f"Failed to download image from URL: {str(e)}"}
        
        payload = {
            "model": vision_model,
            "messages": [
                {
                    "role": "user",
                    "content": prompt,
                    "images": images
                }
            ],
            "options": {
                "temperature": 0.3,
                "num_predict": 2000
            },
            "stream": False
        }
        
        try:
            start_time = time.time()
            response = requests.post(url, json=payload, timeout=180)  # 3 minutes for vision (longer due to image processing)
            elapsed = time.time() - start_time
            map_logger.info(f"[{request_id}] [Vision] Ollama Vision API call completed in {elapsed:.2f}s")
            
            response.raise_for_status()
            data = response.json()
            response_text = data.get("message", {}).get("content", "").strip()
            
            # Parse JSON response
            json_str = response_text.strip()
            if json_str.startswith("```"):
                json_str = json_str.split("```")[1]
                if json_str.startswith("json"):
                    json_str = json_str[4:]
                json_str = json_str.strip()
            if json_str.endswith("```"):
                json_str = json_str[:-3].strip()
            
            result = json.loads(json_str)
            
            # Add estimated coordinates if center location provided
            if center_latitude and center_longitude and "landmarks" in result:
                result["landmarks"] = self._estimate_landmark_coordinates(
                    landmarks=result["landmarks"],
                    center_lat=center_latitude,
                    center_lon=center_longitude,
                    radius_m=radius_meters
                )
            
            result["provider"] = "ollama"
            result["model"] = vision_model
            map_logger.info(f"[{request_id}] [Vision] Extracted {len(result.get('landmarks', []))} landmarks")
            return result
            
        except requests.exceptions.ConnectionError:
            return {"error": f"Cannot connect to Ollama at {self.ollama_base_url}. Make sure Ollama is running."}
        except requests.exceptions.Timeout:
            return {"error": "Ollama vision request timed out after 180 seconds. The model might be loading, processing a large image, or the server is overloaded. Try again in a moment or use a smaller/faster vision model."}
        except json.JSONDecodeError as e:
            map_logger.error(f"[{request_id}] [Vision] Failed to parse JSON response: {str(e)}")
            return {"error": f"Failed to parse LLM response as JSON: {str(e)}"}
        except Exception as e:
            map_logger.error(f"[{request_id}] [Vision] Ollama Vision API error: {str(e)}")
            return {"error": f"Ollama Vision API error: {str(e)}"}
    
    def _estimate_landmark_coordinates(
        self,
        landmarks: List[Dict],
        center_lat: float,
        center_lon: float,
        radius_m: float
    ) -> List[Dict]:
        """Estimate GPS coordinates for landmarks based on their relative position in the image.
        
        This is a rough estimation - actual coordinates would require precise image georeferencing.
        """
        import math
        
        # Convert meters to degrees (rough approximation)
        # 1 degree latitude ≈ 111,000 meters
        # 1 degree longitude ≈ 111,000 * cos(latitude) meters
        lat_offset_per_meter = 1.0 / 111000.0
        lon_offset_per_meter = 1.0 / (111000.0 * math.cos(math.radians(center_lat)))
        
        for landmark in landmarks:
            relative_pos = landmark.get("relative_position", "center").lower()
            
            # Estimate offset based on relative position
            lat_offset = 0.0
            lon_offset = 0.0
            
            if "north" in relative_pos:
                lat_offset = radius_m * 0.5 * lat_offset_per_meter
            elif "south" in relative_pos:
                lat_offset = -radius_m * 0.5 * lat_offset_per_meter
            
            if "east" in relative_pos:
                lon_offset = radius_m * 0.5 * lon_offset_per_meter
            elif "west" in relative_pos:
                lon_offset = -radius_m * 0.5 * lon_offset_per_meter
            
            # Add some randomness for landmarks not at exact center
            if relative_pos != "center":
                lat_offset += (random.random() - 0.5) * radius_m * 0.3 * lat_offset_per_meter
                lon_offset += (random.random() - 0.5) * radius_m * 0.3 * lon_offset_per_meter
            
            landmark["estimated_latitude"] = center_lat + lat_offset
            landmark["estimated_longitude"] = center_lon + lon_offset
        
        return landmarks
    
    def annotate_map_with_landmarks(
        self,
        image_path: str = None,
        image_base64: str = None,
        image_url: str = None,
        landmarks: List[Dict] = None,
        treasure_location: Dict = None,
        user_location: Dict = None,
        output_path: str = None
    ) -> Dict:
        """Annotate a map image with boxes, arrows, and icons for vision-recognized landmarks.
        
        Creates a treasure map with:
        - Colored boxes around recognized landmarks
        - Icons for different landmark types (tree, water, road, etc.)
        - Arrows pointing from landmarks to treasure location
        - Red X marking the treasure spot
        - User location marker (optional)
        
        Args:
            image_path: Path to original map image
            image_base64: Base64-encoded original image
            image_url: URL to original image
            landmarks: List of landmark dicts with 'type', 'relative_position', 'name', etc.
            treasure_location: Dict with 'latitude' and 'longitude' (where X marks the spot)
            user_location: Optional dict with 'latitude' and 'longitude' (user's current location)
            output_path: Optional path to save annotated image (if not provided, returns base64)
        
        Returns:
            Dict with:
            {
                "annotated_image_base64": "base64_string",
                "annotated_image_path": "/path/to/saved/image.png" (if output_path provided),
                "landmarks_annotated": count
            }
        """
        request_id = f"annotate_{int(time.time() * 1000)}"
        map_logger.info(f"[{request_id}] [Annotation] Starting map annotation...")
        
        if not PILLOW_AVAILABLE:
            return {"error": "Pillow not installed. Run: pip install Pillow"}
        
        # Load image
        img = None
        if image_path:
            try:
                img = Image.open(image_path)
                map_logger.info(f"[{request_id}] [Annotation] Loaded image from path: {image_path}")
            except Exception as e:
                return {"error": f"Failed to load image from path: {str(e)}"}
        elif image_base64:
            try:
                # Remove data URL prefix if present
                if image_base64.startswith("data:image"):
                    image_base64 = image_base64.split(",")[1]
                
                import io
                image_bytes = base64.b64decode(image_base64)
                img = Image.open(io.BytesIO(image_bytes))
                map_logger.info(f"[{request_id}] [Annotation] Loaded image from base64")
            except Exception as e:
                return {"error": f"Failed to load image from base64: {str(e)}"}
        elif image_url:
            try:
                response = requests.get(image_url, timeout=10)
                response.raise_for_status()
                import io
                img = Image.open(io.BytesIO(response.content))
                map_logger.info(f"[{request_id}] [Annotation] Loaded image from URL: {image_url}")
            except Exception as e:
                return {"error": f"Failed to load image from URL: {str(e)}"}
        else:
            return {"error": "Must provide image_path, image_base64, or image_url"}
        
        # Convert to RGB if needed (for PNG with transparency)
        if img.mode != 'RGB':
            img = img.convert('RGB')
        
        # Create drawing context
        draw = ImageDraw.Draw(img)
        width, height = img.size
        
        # Try to load a font, fallback to default if not available
        try:
            # Try to use a system font
            font_size = max(16, width // 40)  # Scale font with image size
            try:
                font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
                font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size - 4)
            except:
                try:
                    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", font_size)
                    font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", font_size - 4)
                except:
                    font = ImageFont.load_default()
                    font_small = ImageFont.load_default()
        except:
            font = ImageFont.load_default()
            font_small = ImageFont.load_default()
        
        # Color scheme
        colors = {
            'tree': (34, 139, 34),  # Forest green
            'water': (30, 144, 255),  # Dodger blue
            'road': (105, 105, 105),  # Dim gray
            'path': (139, 69, 19),  # Saddle brown
            'building': (128, 128, 128),  # Gray
            'landmark': (255, 140, 0),  # Dark orange
            'natural': (34, 139, 34),  # Forest green
            'other': (255, 165, 0),  # Orange
        }
        
        # Icon symbols (using text since we don't have icon images)
        icons = {
            'tree': '🌳',
            'water': '💧',
            'road': '🛣️',
            'path': '🚶',
            'building': '🏠',
            'landmark': '📍',
            'natural': '⛰️',
            'other': '📍',
        }
        
        landmarks_annotated = 0
        
        # Convert relative positions to pixel coordinates
        def relative_to_pixel(relative_pos: str, width: int, height: int) -> tuple:
            """Convert relative position string to pixel coordinates."""
            pos = relative_pos.lower()
            x, y = width // 2, height // 2  # Default to center
            
            if "north" in pos:
                y = height // 4
            elif "south" in pos:
                y = 3 * height // 4
            
            if "east" in pos:
                x = 3 * width // 4
            elif "west" in pos:
                x = width // 4
            
            # Handle combined directions
            if "northeast" in pos or ("north" in pos and "east" in pos):
                x = 3 * width // 4
                y = height // 4
            elif "northwest" in pos or ("north" in pos and "west" in pos):
                x = width // 4
                y = height // 4
            elif "southeast" in pos or ("south" in pos and "east" in pos):
                x = 3 * width // 4
                y = 3 * height // 4
            elif "southwest" in pos or ("south" in pos and "west" in pos):
                x = width // 4
                y = 3 * height // 4
            
            return (x, y)
        
        # Draw landmarks with boxes and labels
        if landmarks:
            for landmark in landmarks:
                landmark_type = landmark.get('type', 'other').lower()
                relative_pos = landmark.get('relative_position', 'center')
                name = landmark.get('name', landmark_type)
                
                # Get position in image
                x, y = relative_to_pixel(relative_pos, width, height)
                
                # Get color and icon
                color = colors.get(landmark_type, colors['other'])
                icon = icons.get(landmark_type, icons['other'])
                
                # Draw box around landmark (approximate size)
                box_size = min(width, height) // 15
                box_half = box_size // 2
                
                # Draw colored box
                box_coords = [
                    x - box_half, y - box_half,
                    x + box_half, y + box_half
                ]
                draw.rectangle(box_coords, outline=color, width=3)
                
                # Draw filled box with transparency (using a second rectangle)
                overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
                overlay_draw = ImageDraw.Draw(overlay)
                overlay_draw.rectangle(box_coords, fill=(*color, 50))  # Semi-transparent fill
                img = Image.alpha_composite(img.convert('RGBA'), overlay).convert('RGB')
                draw = ImageDraw.Draw(img)  # Recreate draw after conversion
                
                # Draw icon (as text/emoji)
                try:
                    # Try to draw emoji (may not work on all systems)
                    icon_text = icon
                    bbox = draw.textbbox((0, 0), icon_text, font=font)
                    icon_width = bbox[2] - bbox[0]
                    icon_height = bbox[3] - bbox[1]
                    draw.text((x - icon_width // 2, y - icon_height // 2), icon_text, font=font, fill=color)
                except:
                    # Fallback: draw a circle
                    draw.ellipse([x - 10, y - 10, x + 10, y + 10], fill=color, outline=(255, 255, 255), width=2)
                
                # Draw label
                label = f"{name}"
                try:
                    bbox = draw.textbbox((0, 0), label, font=font_small)
                    label_width = bbox[2] - bbox[0]
                    label_height = bbox[3] - bbox[1]
                    
                    # Draw label background
                    label_bg = [
                        x - label_width // 2 - 5, y + box_half + 5,
                        x + label_width // 2 + 5, y + box_half + label_height + 10
                    ]
                    draw.rectangle(label_bg, fill=(0, 0, 0, 200), outline=color, width=2)
                    
                    # Draw label text
                    draw.text((x - label_width // 2, y + box_half + 7), label, font=font_small, fill=(255, 255, 255))
                except:
                    pass
                
                landmarks_annotated += 1
        
        # Draw treasure location (red X)
        if treasure_location:
            # For now, place X at center (could be improved with actual GPS-to-pixel conversion)
            treasure_x = width // 2
            treasure_y = height // 2
            
            # Draw large red X
            x_size = min(width, height) // 20
            line_width = max(5, width // 100)
            
            # Draw X lines
            draw.line(
                [(treasure_x - x_size, treasure_y - x_size), 
                 (treasure_x + x_size, treasure_y + x_size)],
                fill=(255, 0, 0), width=line_width
            )
            draw.line(
                [(treasure_x - x_size, treasure_y + x_size), 
                 (treasure_x + x_size, treasure_y - x_size)],
                fill=(255, 0, 0), width=line_width
            )
            
            # Draw circle around X
            circle_size = x_size * 2
            draw.ellipse(
                [treasure_x - circle_size, treasure_y - circle_size,
                 treasure_x + circle_size, treasure_y + circle_size],
                outline=(255, 0, 0), width=line_width
            )
            
            # Label
            label = "X MARKS THE SPOT"
            try:
                bbox = draw.textbbox((0, 0), label, font=font)
                label_width = bbox[2] - bbox[0]
                draw.text(
                    (treasure_x - label_width // 2, treasure_y + circle_size + 10),
                    label, font=font, fill=(255, 0, 0)
                )
            except:
                pass
        
        # Draw user location (optional, blue marker)
        if user_location:
            user_x = width // 4  # Place user at bottom-left
            user_y = 3 * height // 4
            
            # Draw blue circle for user
            user_size = min(width, height) // 25
            draw.ellipse(
                [user_x - user_size, user_y - user_size,
                 user_x + user_size, user_y + user_size],
                fill=(0, 100, 255), outline=(255, 255, 255), width=3
            )
            
            # Draw arrow from user to treasure
            if treasure_location:
                arrow_color = (0, 200, 255)
                arrow_width = max(3, width // 150)
                
                # Draw arrow line
                draw.line(
                    [(user_x, user_y), (treasure_x, treasure_y)],
                    fill=arrow_color, width=arrow_width
                )
                
                # Draw arrowhead
                import math
                angle = math.atan2(treasure_y - user_y, treasure_x - user_x)
                arrow_size = min(width, height) // 30
                arrow_x1 = treasure_x - arrow_size * math.cos(angle - math.pi / 6)
                arrow_y1 = treasure_y - arrow_size * math.sin(angle - math.pi / 6)
                arrow_x2 = treasure_x - arrow_size * math.cos(angle + math.pi / 6)
                arrow_y2 = treasure_y - arrow_size * math.sin(angle + math.pi / 6)
                
                draw.polygon(
                    [(treasure_x, treasure_y), (arrow_x1, arrow_y1), (arrow_x2, arrow_y2)],
                    fill=arrow_color
                )
            
            # Label
            label = "YOU"
            try:
                bbox = draw.textbbox((0, 0), label, font=font_small)
                label_width = bbox[2] - bbox[0]
                draw.text(
                    (user_x - label_width // 2, user_y + user_size + 5),
                    label, font=font_small, fill=(0, 100, 255)
                )
            except:
                pass
        
        # Draw arrows from landmarks to treasure
        if landmarks and treasure_location:
            for landmark in landmarks:
                relative_pos = landmark.get('relative_position', 'center')
                landmark_x, landmark_y = relative_to_pixel(relative_pos, width, height)
                
                # Draw arrow from landmark to treasure
                arrow_color = (255, 165, 0)  # Orange
                arrow_width = max(2, width // 200)
                
                # Draw arrow line
                draw.line(
                    [(landmark_x, landmark_y), (treasure_x, treasure_y)],
                    fill=arrow_color, width=arrow_width
                )
                
                # Draw small arrowhead
                import math
                angle = math.atan2(treasure_y - landmark_y, treasure_x - landmark_x)
                arrow_size = min(width, height) // 40
                arrow_x1 = treasure_x - arrow_size * math.cos(angle - math.pi / 6)
                arrow_y1 = treasure_y - arrow_size * math.sin(angle - math.pi / 6)
                arrow_x2 = treasure_x - arrow_size * math.cos(angle + math.pi / 6)
                arrow_y2 = treasure_y - arrow_size * math.sin(angle + math.pi / 6)
                
                draw.polygon(
                    [(treasure_x, treasure_y), (arrow_x1, arrow_y1), (arrow_x2, arrow_y2)],
                    fill=arrow_color
                )
        
        # Save or return image
        result = {
            "landmarks_annotated": landmarks_annotated
        }
        
        if output_path:
            try:
                img.save(output_path)
                result["annotated_image_path"] = output_path
                map_logger.info(f"[{request_id}] [Annotation] Saved annotated image to: {output_path}")
            except Exception as e:
                return {"error": f"Failed to save image: {str(e)}"}
        
        # Convert to base64
        try:
            import io
            buffer = io.BytesIO()
            img.save(buffer, format='PNG')
            image_base64 = base64.b64encode(buffer.getvalue()).decode('utf-8')
            result["annotated_image_base64"] = image_base64
            map_logger.info(f"[{request_id}] [Annotation] Generated annotated image (base64)")
        except Exception as e:
            return {"error": f"Failed to encode image: {str(e)}"}
        
        map_logger.info(f"[{request_id}] [Annotation] Completed - annotated {landmarks_annotated} landmarks")
        return result
    
    def generate_clue(
        self, 
        target_location: Dict, 
        map_features: List[str] = None, 
        fetch_real_features: bool = True,
        vision_landmarks: List[Dict] = None
    ) -> str:
        """Generate a SHORT pirate riddle clue for finding a treasure.
        
        Args:
            target_location: Dict with 'latitude' and 'longitude'
            map_features: Optional list of feature names (if not provided and fetch_real_features=True, will fetch from OpenStreetMap)
            fetch_real_features: If True and map_features not provided, fetch real features from OpenStreetMap
            vision_landmarks: Optional list of vision-extracted landmarks (from analyze_map_image)
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
        
        # Combine OSM features and vision landmarks for richer clues
        features_text = ""
        if map_features:
            features_text = f"Real features: {', '.join(map_features[:3])}"  # Only 3 features
        
        # Add vision-extracted landmarks if available
        if vision_landmarks:
            vision_features = []
            for v_lm in vision_landmarks[:3]:  # Max 3 vision landmarks
                name = v_lm.get('name', v_lm.get('type', 'landmark'))
                desc = v_lm.get('description', '')
                if desc:
                    vision_features.append(f"{name} ({desc})")
                else:
                    vision_features.append(name)
            
            if vision_features:
                if features_text:
                    features_text += f" | Vision landmarks: {', '.join(vision_features)}"
                else:
                    features_text = f"Vision landmarks: {', '.join(vision_features)}"
        
        prompt = f"""Create a SHORT pirate riddle (1-2 lines max) telling where to dig. Use pirate speak. Reference: {features_text}

Keep it SHORT - 1-2 lines only. Riddle:"""
        
        response = self._call_llm(prompt=prompt, max_tokens=50)  # Limit to 50 tokens
        return response.strip()
    
    def warmup_model(self) -> Dict:
        """Warm up the model by making a quick test request (pre-loads model into memory)."""
        if self.provider != "ollama" and self.provider != "local":
            return {"status": "skipped", "message": "Warmup only needed for Ollama"}
        
        test_prompt = "Hi"  # Minimal prompt
        try:
            import time
            start_time = time.time()
            response = self._call_llm(prompt=test_prompt, max_tokens=5)  # Minimal response to warm up
            elapsed = time.time() - start_time
            return {
                "status": "success",
                "message": f"Model warmed up in {elapsed:.2f}s",
                "elapsed_seconds": elapsed
            }
        except Exception as e:
            return {
                "status": "error",
                "error": str(e)
            }
    
    def test_connection(self) -> Dict:
        """Test if LLM service is working."""
        # CRITICAL: Log current state before test
        print(f"🧪 [LLM Service] test_connection called - Current provider: {self.provider}, model: {self.model}")
        
        test_prompt = "Say 'Ahoy!' in pirate speak."  # Shorter prompt
        try:
            import time
            start_time = time.time()
            
            # CRITICAL: Capture provider/model BEFORE the call to ensure we report what was actually attempted
            attempted_provider = self.provider
            attempted_model = self.model
            
            print(f"🧪 [LLM Service] test_connection - Attempting with provider: '{attempted_provider}', model: '{attempted_model}'")
            
            response = self._call_llm(prompt=test_prompt, max_tokens=10)  # Very short response
            elapsed = time.time() - start_time
            
            # CRITICAL: Verify provider/model after call (should not have changed)
            actual_provider = self.provider
            actual_model = self.model
            print(f"🧪 [LLM Service] test_connection completed - Provider: '{actual_provider}', model: '{actual_model}', response length: {len(response)}")
            
            # Check if response indicates an error (Ollama returns error strings)
            # Check for various error patterns
            is_error = (response.startswith("Error:") or 
                       response.startswith("Error calling") or
                       "timed out" in response.lower() or
                       "cannot connect" in response.lower() or
                       "not found" in response.lower() or
                       "connection error" in response.lower())
            
            if is_error:
                print(f"❌ [LLM Service] test_connection detected error response from {actual_provider}/{actual_model}")
                return {
                    "status": "error",
                    "error": response,
                    "model": actual_model,
                    "provider": actual_provider,
                    "api_key_configured": bool(self.api_key) if actual_provider not in ["ollama", "local"] else None
                }
            
            print(f"✅ [LLM Service] test_connection success - Provider: '{actual_provider}', model: '{actual_model}'")
            return {
                "status": "success",
                "response": response,
                "model": actual_model,
                "provider": actual_provider,
                "api_key_configured": bool(self.api_key) if actual_provider not in ["ollama", "local"] else None,
                "elapsed_seconds": elapsed
            }
        except Exception as e:
            print(f"❌ [LLM Service] test_connection error: {e}")
            return {
                "status": "error",
                "error": str(e),
                "model": self.model,
                "provider": self.provider,
                "api_key_configured": bool(self.api_key) if self.provider != "ollama" else None
            }

# Global instance
llm_service = LLMService()

