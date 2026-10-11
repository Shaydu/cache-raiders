"""
Treasure Map Service for CacheRaiders
Handles treasure map creation, vision-based landmark extraction, and map annotation.
Uses LLM service for vision analysis and MapFeatureService for OSM data.
"""
import os
import json
import random
import logging
import time
import base64
import math
from typing import Optional, Dict, List

# Set up file logging for treasure map generation
log_dir = os.path.join(os.path.dirname(__file__), 'logs')
os.makedirs(log_dir, exist_ok=True)
map_log_file = os.path.join(log_dir, 'map_requests.log')

# Configure map logger (reuse same file as app.py and llm_service.py)
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
    from PIL import Image, ImageDraw, ImageFont
    PILLOW_AVAILABLE = True
except ImportError:
    PILLOW_AVAILABLE = False
    print("⚠️ Pillow package not installed. Run: pip install Pillow")

try:
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False
    print("⚠️ requests package not installed. Run: pip install requests")

# Import services
from map_feature_service import MapFeatureService
from llm_service import llm_service


class TreasureMapService:
    """Service for creating treasure maps with vision-analyzed landmarks and annotations."""
    
    def __init__(self):
        """Initialize treasure map service."""
        self.map_feature_service = MapFeatureService()
        self.llm_service = llm_service
        print("✅ Treasure Map Service initialized")
    
    def generate_map_piece(
        self, 
        target_location: Dict, 
        piece_number: int, 
        total_pieces: int = 2, 
        npc_type: str = "skeleton",
        map_image_path: str = None,
        map_image_base64: str = None,
        map_image_url: str = None,
        use_vision_analysis: bool = False
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
        map_logger.info(f"[{request_id}] [Treasure Map] generate_map_piece() called")
        map_logger.info(f"[{request_id}] [Treasure Map] Parameters: piece_number={piece_number}, npc_type={npc_type}, total_pieces={total_pieces}")
        
        # Extract coordinates first
        lat = target_location.get('latitude')
        lon = target_location.get('longitude')
        
        map_logger.info(f"[{request_id}] [Treasure Map] Target location: lat={lat}, lon={lon}")
        
        if not lat or not lon:
            map_logger.error(f"[{request_id}] [Treasure Map] Missing coordinates in target_location")
            return {"error": "target_location must include latitude and longitude"}
        
        # Helper function to create map piece data (used in both success and error cases)
        def create_map_piece_data(landmarks_list):
            """Create map piece data with landmarks.
            
            CRITICAL: Only uses REAL landmarks from OpenStreetMap or vision analysis.
            Never generates fake, placeholder, or imaginary features.
            If no landmarks are available, returns empty list (no fake features).
            """
            map_landmarks = []
            if isinstance(landmarks_list, list):
                for landmark in landmarks_list:
                    # VALIDATION: Only include landmarks with valid coordinates
                    if isinstance(landmark, dict) and 'latitude' in landmark and 'longitude' in landmark:
                        lat = landmark['latitude']
                        lon = landmark['longitude']
                        # Validate coordinates are real (not 0,0 or invalid)
                        if abs(lat) <= 90 and abs(lon) <= 180 and (lat != 0 or lon != 0):
                            map_landmarks.append({
                                'name': landmark.get('name', landmark.get('type', 'landmark')),
                                'type': landmark.get('type', 'landmark'),
                                'latitude': lat,  # REAL coordinate
                                'longitude': lon  # REAL coordinate
                            })
                        else:
                            map_logger.warning(f"[{request_id}] [Map Piece] Skipping landmark with invalid coordinates: {landmark.get('name', 'unknown')}")
                    else:
                        map_logger.warning(f"[{request_id}] [Map Piece] Skipping landmark without coordinates: {landmark}")
            
            # If no real landmarks found, return empty list (never generate fake ones)
            if not map_landmarks:
                map_logger.info(f"[{request_id}] [Map Piece] No real landmarks found - map will show without landmarks (this is expected)")
            
            # Generate partial coordinates (obfuscated slightly for puzzle)
            if piece_number == 1:
                approximate_lat = lat + (random.random() - 0.5) * 0.001  # ~100m variation
                approximate_lon = lon + (random.random() - 0.5) * 0.001
                return {
                    "piece_number": 1,
                    "hint": "Arr, here be the treasure map, matey! X marks the spot where me gold be buried!",
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
                    map_logger.info(f"[{request_id}] [Treasure Map] Starting vision analysis for landmarks...")
                    
                    try:
                        vision_start = time.time()
                        vision_result = self.llm_service.analyze_map_image(
                            image_path=map_image_path,
                            image_base64=map_image_base64,
                            image_url=map_image_url,
                            center_latitude=lat,
                            center_longitude=lon,
                            radius_meters=50.0
                        )
                        vision_duration = time.time() - vision_start
                        map_logger.info(f"[{request_id}] [Treasure Map] Vision analysis completed in {vision_duration:.2f}s")
                        
                        if "error" not in vision_result and "landmarks" in vision_result:
                            vision_landmarks = vision_result["landmarks"]
                            print(f"   [Captain Bones] Vision found {len(vision_landmarks)} landmarks from image")
                            map_logger.info(f"[{request_id}] [Treasure Map] Vision extracted {len(vision_landmarks)} landmarks")
                            
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
                            map_logger.warning(f"[{request_id}] [Treasure Map] Vision analysis failed: {error_msg}")
                            print(f"⚠️ [Captain Bones] Vision analysis failed: {error_msg}")
                    except Exception as e:
                        vision_duration = time.time() - vision_start if 'vision_start' in locals() else 0
                        map_logger.error(f"[{request_id}] [Treasure Map] Vision analysis exception after {vision_duration:.2f}s: {str(e)}")
                        print(f"⚠️ [Captain Bones] Vision analysis error: {e}")
                        # Continue with OSM fallback
                
                # Option 2: OpenStreetMap-based landmark extraction (fallback or primary)
                # If vision didn't find enough landmarks, or vision is disabled, use OSM
                if len(landmarks) < 2:
                    print(f"🗺️ [Captain Bones Game Mode] Fetching OSM landmarks within 50m of {lat}, {lon} for crude treasure map...")
                    map_logger.info(f"[{request_id}] [Treasure Map] Starting Overpass API call for landmarks...")
                    map_logger.info(f"[{request_id}] [Treasure Map] Location: lat={lat}, lon={lon}, radius=50m")
                    
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
                        map_logger.info(f"[{request_id}] [Treasure Map] Overpass API call completed in {overpass_duration:.2f}s")
                        map_logger.info(f"[{request_id}] [Treasure Map] Received {len(osm_landmarks) if isinstance(osm_landmarks, list) else 0} OSM landmarks")

                        # Ensure landmarks is a list (get_features_near_location should always return a list)
                        if not isinstance(osm_landmarks, list):
                            print(f"⚠️ [Captain Bones] get_features_near_location returned non-list: {type(osm_landmarks)}")
                            osm_landmarks = []

                        # Filter landmarks to be within 50m and limit to 3 for minimal map
                        filtered_landmarks = []
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
                        map_logger.error(f"[{request_id}] [Treasure Map] Overpass API call failed after {overpass_duration:.2f}s")
                        map_logger.error(f"[{request_id}] [Treasure Map] Error type: {type(e).__name__}")
                        map_logger.error(f"[{request_id}] [Treasure Map] Error message: {str(e)}")
                        
                        # If landmark fetch fails, continue without landmarks (map still works)
                        if 'too large' in error_msg or 'exceeded' in error_msg or 'maximum' in error_msg or 'resource' in error_msg:
                            map_logger.warning(f"[{request_id}] [Treasure Map] Overpass API resource limit exceeded - continuing without landmarks")
                            print(f"⚠️ [Captain Bones] Overpass API resource limit exceeded: {e}")
                            print("   Continuing with map piece without landmarks (this is expected and safe)")
                        else:
                            map_logger.warning(f"[{request_id}] [Treasure Map] Overpass API error - continuing without landmarks")
                            print(f"⚠️ [Captain Bones] Could not fetch landmarks: {e}")
                        # Keep vision landmarks if we have them
                        if not vision_landmarks:
                            landmarks = []
            else:
                # For other NPCs (like corgi), skip Overpass API calls
                print(f"ℹ️ Skipping Overpass API for {npc_type} NPC (not Captain Bones game mode)")
            
            # Generate and return map piece
            map_logger.info(f"[{request_id}] [Treasure Map] Creating map piece data with {len(landmarks) if isinstance(landmarks, list) else 0} landmarks")
            result = create_map_piece_data(landmarks)
            map_logger.info(f"[{request_id}] [Treasure Map] Map piece created successfully")
            return result
            
        except Exception as e:
            # Catch any errors (including Overpass API errors if somehow called)
            error_msg = str(e).lower()
            map_logger.error(f"[{request_id}] [Treasure Map] Exception in generate_map_piece: {type(e).__name__}")
            map_logger.error(f"[{request_id}] [Treasure Map] Exception message: {str(e)}")
            import traceback
            map_logger.error(f"[{request_id}] [Treasure Map] Traceback: {traceback.format_exc()}")
            
            if 'too large' in error_msg or 'exceeded' in error_msg or 'maximum' in error_msg or 'resource' in error_msg:
                map_logger.warning(f"[{request_id}] [Treasure Map] Resource exceeded error - returning map piece without landmarks")
                print(f"⚠️ Caught 'resource exceeded' error in generate_map_piece: {e}")
                print("   Returning map piece without features (this is expected and safe)")
                # Return a valid map piece even if there was an error
                # This ensures the user gets the map, just without landmark features
                return create_map_piece_data([])  # Empty landmarks if fetch failed
            else:
                # For other errors, return error dict
                map_logger.error(f"[{request_id}] [Treasure Map] Returning error response")
                print(f"⚠️ Error in generate_map_piece: {e}")
                return {"error": f"Failed to generate map piece: {str(e)}"}
    
    def create_annotated_treasure_map(
        self,
        image_path: str = None,
        image_base64: str = None,
        image_url: str = None,
        landmarks: List[Dict] = None,
        treasure_location: Dict = None,
        user_location: Dict = None,
        output_path: str = None
    ) -> Dict:
        """Create an annotated treasure map with boxes, arrows, and icons for vision-recognized landmarks.
        
        This is the main method that:
        1. Analyzes the map image with vision LLM to extract landmarks
        2. Overlays visual annotations (boxes, arrows, icons) on the map
        3. Marks the treasure location with a red X
        4. Shows path from user location to treasure
        
        Args:
            image_path: Path to original map image
            image_base64: Base64-encoded original image
            image_url: URL to original image
            landmarks: Optional pre-analyzed landmarks (if not provided, will analyze image)
            treasure_location: Dict with 'latitude' and 'longitude' (where X marks the spot)
            user_location: Optional dict with 'latitude' and 'longitude' (user's current location)
            output_path: Optional path to save annotated image (if not provided, returns base64)
        
        Returns:
            Dict with:
            {
                "annotated_image_base64": "base64_string",
                "annotated_image_path": "/path/to/saved/image.png" (if output_path provided),
                "landmarks": [list of analyzed landmarks],
                "landmarks_annotated": count
            }
        """
        request_id = f"annotate_{int(time.time() * 1000)}"
        map_logger.info(f"[{request_id}] [Treasure Map] create_annotated_treasure_map() called")
        
        # If landmarks not provided, analyze the image
        if not landmarks:
            if not any([image_path, image_base64, image_url]):
                return {"error": "Must provide landmarks or image for analysis"}
            
            map_logger.info(f"[{request_id}] [Treasure Map] Analyzing image to extract landmarks...")
            vision_result = self.llm_service.analyze_map_image(
                image_path=image_path,
                image_base64=image_base64,
                image_url=image_url,
                center_latitude=treasure_location.get('latitude') if treasure_location else None,
                center_longitude=treasure_location.get('longitude') if treasure_location else None,
                radius_meters=50.0
            )
            
            if "error" in vision_result:
                return {"error": f"Vision analysis failed: {vision_result['error']}"}
            
            landmarks = vision_result.get("landmarks", [])
            map_logger.info(f"[{request_id}] [Treasure Map] Extracted {len(landmarks)} landmarks from image")
        
        # Now annotate the map
        annotation_result = self._annotate_map_image(
            image_path=image_path,
            image_base64=image_base64,
            image_url=image_url,
            landmarks=landmarks,
            treasure_location=treasure_location,
            user_location=user_location,
            output_path=output_path,
            request_id=request_id
        )
        
        # Combine results
        if "error" in annotation_result:
            return annotation_result
        
        annotation_result["landmarks"] = landmarks
        return annotation_result
    
    def _annotate_map_image(
        self,
        image_path: str = None,
        image_base64: str = None,
        image_url: str = None,
        landmarks: List[Dict] = None,
        treasure_location: Dict = None,
        user_location: Dict = None,
        output_path: str = None,
        request_id: str = None
    ) -> Dict:
        """Internal method to annotate a map image with boxes, arrows, and icons."""
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
        landmark_positions = {}  # Store positions for arrow drawing
        if landmarks:
            for landmark in landmarks:
                landmark_type = landmark.get('type', 'other').lower()
                relative_pos = landmark.get('relative_position', 'center')
                name = landmark.get('name', landmark_type)
                
                # Get position in image
                x, y = relative_to_pixel(relative_pos, width, height)
                landmark_positions[name] = (x, y)
                
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
        treasure_x = None
        treasure_y = None
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
        user_x = None
        user_y = None
        if user_location:
            user_x = width // 4  # Place user at bottom-left
            user_y = 3 * height // 4
            
            # Draw blue circle for user (icon only, no text label to avoid duplication)
            user_size = min(width, height) // 25
            draw.ellipse(
                [user_x - user_size, user_y - user_size,
                 user_x + user_size, user_y + user_size],
                fill=(0, 100, 255), outline=(255, 255, 255), width=3
            )
            
            # Draw arrow from user to treasure
            if treasure_x and treasure_y:
                arrow_color = (0, 200, 255)
                arrow_width = max(3, width // 150)
                
                # Draw arrow line
                draw.line(
                    [(user_x, user_y), (treasure_x, treasure_y)],
                    fill=arrow_color, width=arrow_width
                )
                
                # Draw arrowhead
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
            
            # No text label for user location - the blue circle icon is sufficient
            # This avoids duplication where both icon and text say "YOU"
        
        # Draw arrows from landmarks to treasure
        if landmarks and treasure_x and treasure_y:
            for landmark in landmarks:
                name = landmark.get('name', '')
                if name in landmark_positions:
                    landmark_x, landmark_y = landmark_positions[name]
                    
                    # Draw arrow from landmark to treasure
                    arrow_color = (255, 165, 0)  # Orange
                    arrow_width = max(2, width // 200)
                    
                    # Draw arrow line
                    draw.line(
                        [(landmark_x, landmark_y), (treasure_x, treasure_y)],
                        fill=arrow_color, width=arrow_width
                    )
                    
                    # Draw small arrowhead
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


# Global instance
treasure_map_service = TreasureMapService()

