"""
Map Feature Service for CacheRaiders
Handles fetching real-world map features (landmarks) from OpenStreetMap Overpass API
Used for generating treasure maps with real landmarks (ponds, trees, roads, etc.)

CRITICAL: This service ONLY returns REAL features from OpenStreetMap.
- All features come from actual OSM data via the Overpass API
- No fake, placeholder, or imaginary features are ever generated
- If no features are found, returns empty list (never generates fake ones)
- All coordinates are validated to ensure they're real OSM data
"""
import os
import json
import logging
import time
from typing import Dict, List, Optional

# Set up file logging for Overpass API calls
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
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False
    print("⚠️ requests package not installed. Run: pip install requests")


class MapFeatureService:
    """Service to fetch real map features from geographic data using OpenStreetMap Overpass API."""
    
    def __init__(self):
        # Uses OpenStreetMap Overpass API (free, no API key needed)
        self.overpass_url = "https://overpass-api.de/api/interpreter"
    
    def get_features_near_location(
        self,
        latitude: float,
        longitude: float,
        radius: float = 25.0,  # Default 25m radius to minimize OSM data
        return_coordinates: bool = False,  # If True, returns dicts with coordinates
        request_id: Optional[str] = None  # Request ID for logging correlation
    ) -> List:
        """Get REAL map features near a location using OpenStreetMap Overpass API.
        
        CRITICAL: Only returns REAL features from OpenStreetMap. Never generates fake features.
        If no features are found in OSM, returns empty list (never creates placeholders).
        
        Returns a list of feature names/descriptions, or dicts with coordinates if return_coordinates=True.
        Uses nodes only (not ways) to avoid geometry complexity and keep data size small.
        
        Args:
            latitude: Center latitude
            longitude: Center longitude
            radius: Search radius in meters (default 25m)
            return_coordinates: If True, returns list of dicts with 'name', 'type', 'latitude', 'longitude'
                              If False, returns list of feature name strings
        
        Returns:
            List of REAL features from OSM (strings or dicts depending on return_coordinates).
            Empty list if no features found (never returns fake/placeholder features).
        """
        req_id = request_id or f"overpass_{int(time.time() * 1000)}"
        
        if not REQUESTS_AVAILABLE:
            map_logger.error(f"[{req_id}] [Overpass] requests library not installed")
            print("⚠️ requests not installed. Install with: pip install requests")
            return []
        
        map_logger.info(f"[{req_id}] [Overpass] ========== OVERPASS API CALL STARTED ==========")
        map_logger.info(f"[{req_id}] [Overpass] Location: lat={latitude}, lon={longitude}, radius={radius}m")
        map_logger.info(f"[{req_id}] [Overpass] Return coordinates: {return_coordinates}")
        map_logger.info(f"[{req_id}] [Overpass] URL: {self.overpass_url}")
        
        # Overpass QL query - Get 2-3 real landmarks (pond, tree, roads, buildings, etc.) within radius
        # Query both NODES (points) and WAYS (roads/buildings) - use center points for ways to avoid geometry complexity
        # CRITICAL: Query specific amenity types to avoid matching thousands of elements
        # Use small radius (25m) and limit the total results to minimize OSM data
        # maxsize:53687091 = 51MB (reduced from 128MB to stay well under Overpass limits)
        # Added: parks, bridges, places of worship, roads, and buildings for more map features
        query = f"""
        [out:json][timeout:10][maxsize:53687091];
        (
          node["natural"="water"](around:{radius},{latitude},{longitude});
          node["natural"="tree"](around:{radius},{latitude},{longitude});
          node["amenity"="fountain"](around:{radius},{latitude},{longitude});
          node["amenity"="bench"](around:{radius},{latitude},{longitude});
          node["amenity"="monument"](around:{radius},{latitude},{longitude});
          node["leisure"="park"](around:{radius},{latitude},{longitude});
          node["leisure"="playground"](around:{radius},{latitude},{longitude});
          node["man_made"="bridge"](around:{radius},{latitude},{longitude});
          node["bridge"="yes"](around:{radius},{latitude},{longitude});
          node["amenity"="place_of_worship"](around:{radius},{latitude},{longitude});
          way["highway"~"^(primary|secondary|tertiary|residential|path|footway|track)$"](around:{radius},{latitude},{longitude});
          way["building"](around:{radius},{latitude},{longitude});
        );
        out center;
        """
        
        map_logger.debug(f"[{req_id}] [Overpass] Query: {query[:200]}...")  # Log first 200 chars
        
        try:
            request_start = time.time()
            # Timeout set to 5 seconds (increased from 3) to allow more time for Overpass API
            # If Overpass API is slow, we'll fail fast and continue without features
            # This prevents the iOS app from timing out while waiting for map piece
            map_logger.info(f"[{req_id}] [Overpass] Sending POST request (timeout=5s)...")
            response = requests.post(self.overpass_url, data=query, timeout=5)
            request_duration = time.time() - request_start
            map_logger.info(f"[{req_id}] [Overpass] Request completed in {request_duration:.2f}s")
            map_logger.info(f"[{req_id}] [Overpass] Response status: {response.status_code}")
            map_logger.info(f"[{req_id}] [Overpass] Response size: {len(response.content)} bytes")
            
            # Check for errors in response
            if response.status_code != 200:
                map_logger.error(f"[{req_id}] [Overpass] HTTP error: {response.status_code}")
                map_logger.error(f"[{req_id}] [Overpass] Response text: {response.text[:500]}")
                print(f"⚠️ Overpass API error: {response.status_code} - {response.text[:200]}")
                return []
            
            # Check response text for error messages before parsing JSON
            response_text = response.text.lower()
            if 'too large' in response_text or 'exceeded' in response_text or 'maximum size' in response_text or 'resource' in response_text:
                map_logger.error(f"[{req_id}] [Overpass] Resource limit error in response text")
                map_logger.error(f"[{req_id}] [Overpass] Response preview: {response.text[:500]}")
                print(f"⚠️ Overpass API returned 'too large' or similar error in response text")
                print(f"   Response preview: {response.text[:300]}")
                # Return empty list instead of error - better UX than showing error to user
                return []
            
            # Try to parse JSON, but handle decode errors gracefully
            parse_start = time.time()
            try:
                map_logger.info(f"[{req_id}] [Overpass] Parsing JSON response...")
                data = response.json()
                parse_duration = time.time() - parse_start
                map_logger.info(f"[{req_id}] [Overpass] JSON parsed in {parse_duration:.3f}s")
                map_logger.info(f"[{req_id}] [Overpass] Response has {len(data.get('elements', []))} elements")
            except (ValueError, json.JSONDecodeError) as e:
                parse_duration = time.time() - parse_start
                map_logger.error(f"[{req_id}] [Overpass] JSON parse failed after {parse_duration:.3f}s")
                map_logger.error(f"[{req_id}] [Overpass] Parse error: {str(e)}")
                # If JSON parsing fails, check if it's an error message
                if 'too large' in response.text.lower() or 'exceeded' in response.text.lower():
                    map_logger.error(f"[{req_id}] [Overpass] Non-JSON error response: {response.text[:500]}")
                    print(f"⚠️ Overpass API error (non-JSON response): {response.text[:200]}")
                    return []
                raise  # Re-raise if it's a different JSON error
            
            # Check for Overpass API errors (resource exceeded, timeout, etc.)
            if 'remark' in data:
                remark = data['remark'].lower()
                map_logger.info(f"[{req_id}] [Overpass] Response remark: {data['remark']}")
                if 'exceeded' in remark or 'timeout' in remark or 'maximum' in remark or 'size' in remark or 'too large' in remark:
                    error_message = data['remark']
                    map_logger.error(f"[{req_id}] [Overpass] Resource limit exceeded: {error_message}")
                    print(f"⚠️ Overpass API limit exceeded: {error_message}")
                    print(f"   Reducing radius from {radius}m and retrying with smaller area...")
                    # Retry with smaller radius if we hit limits
                    if radius > 50:
                        map_logger.info(f"[{req_id}] [Overpass] Retrying with radius=50m...")
                        result = self.get_features_near_location(latitude, longitude, radius=50.0, return_coordinates=return_coordinates, request_id=req_id)
                        # If retry also failed, return empty list (not error)
                        if isinstance(result, dict) and 'error' in result:
                            return []
                        return result
                    elif radius > 25:
                        map_logger.info(f"[{req_id}] [Overpass] Retrying with radius=25m...")
                        result = self.get_features_near_location(latitude, longitude, radius=25.0, return_coordinates=return_coordinates, request_id=req_id)
                        # If retry also failed, return empty list (not error)
                        if isinstance(result, dict) and 'error' in result:
                            return []
                        return result
                    else:
                        map_logger.warning(f"[{req_id}] [Overpass] Even with 25m radius, query too large - returning empty results")
                        print(f"   ⚠️ Even with 25m radius, query too large. Returning empty results instead of error.")
                        # Return empty list instead of error - better UX than showing error to user
                        return []
            
            # Check for error field in response
            if 'error' in data:
                error_msg = data.get('error', 'Unknown error')
                error_msg_lower = str(error_msg).lower()
                if 'too large' in error_msg_lower or 'exceeded' in error_msg_lower or 'maximum' in error_msg_lower:
                    print(f"⚠️ Overpass API error: {error_msg}")
                    # Return empty list instead of error - better UX
                    return []
                # Try with smaller radius for other errors
                if radius > 75:
                    result = self.get_features_near_location(latitude, longitude, radius=75.0, return_coordinates=return_coordinates)
                    if isinstance(result, dict) and 'error' in result:
                        return []
                    return result
                elif radius > 50:
                    result = self.get_features_near_location(latitude, longitude, radius=50.0, return_coordinates=return_coordinates)
                    if isinstance(result, dict) and 'error' in result:
                        return []
                    return result
                # Return empty list instead of error - better UX
                print(f"   ⚠️ Could not fetch features even with smaller radius. Returning empty results.")
                return []
            
            features = []
            seen_names = set()
            
            # CRITICAL: Only use REAL features from OpenStreetMap - never generate fake/placeholder features
            # All features must come from actual OSM data with valid coordinates
            for element in data.get('elements', []):
                tags = element.get('tags', {})
                feature_type = self._classify_feature(element)
                
                # Get coordinates from element - MUST have valid coordinates from OSM
                # Nodes have direct lat/lon, Ways (roads/buildings) have center points
                element_lat = None
                element_lon = None
                if 'lat' in element and 'lon' in element:
                    # Node has direct lat/lon from OSM
                    element_lat = element['lat']
                    element_lon = element['lon']
                elif 'center' in element:
                    # Way (road/building) has center point (from "out center" query)
                    element_lat = element['center'].get('lat')
                    element_lon = element['center'].get('lon')
                elif element.get('type') == 'way' and 'geometry' in element:
                    # Fallback: calculate center from way geometry if center not provided
                    # This shouldn't happen with "out center" but just in case
                    geometry = element.get('geometry', [])
                    if geometry:
                        lats = [point.get('lat') for point in geometry if 'lat' in point]
                        lons = [point.get('lon') for point in geometry if 'lon' in point]
                        if lats and lons:
                            element_lat = sum(lats) / len(lats)
                            element_lon = sum(lons) / len(lons)
                
                # VALIDATION: Only include features with valid coordinates from OSM
                # Reject any features without coordinates (shouldn't happen, but safety check)
                if return_coordinates:
                    if not element_lat or not element_lon:
                        map_logger.warning(f"[{req_id}] [Overpass] Skipping feature without coordinates: {tags.get('name', feature_type)}")
                        continue
                    # Validate coordinates are reasonable (not 0,0 or invalid)
                    if abs(element_lat) > 90 or abs(element_lon) > 180:
                        map_logger.warning(f"[{req_id}] [Overpass] Skipping feature with invalid coordinates: {tags.get('name', feature_type)}")
                        continue
                
                # Get feature name or use type
                name = tags.get('name', '')
                feature_key = name if name else feature_type
                
                if return_coordinates and element_lat and element_lon:
                    # Return dict with coordinates (REAL coordinates from OSM only)
                    if feature_key not in seen_names:
                        features.append({
                            'name': name or feature_type,
                            'type': feature_type,
                            'latitude': element_lat,  # REAL OSM coordinate
                            'longitude': element_lon  # REAL OSM coordinate
                        })
                        seen_names.add(feature_key)
                        map_logger.debug(f"[{req_id}] [Overpass] Added REAL feature: {name or feature_type} at ({element_lat}, {element_lon})")
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
                
                # Limit to 2-3 features total to minimize OSM data and keep map simple
                if len(features) >= 3:
                    break
            
            total_duration = time.time() - request_start
            map_logger.info(f"[{req_id}] [Overpass] ========== OVERPASS API CALL SUCCESS ==========")
            map_logger.info(f"[{req_id}] [Overpass] Total duration: {total_duration:.2f}s")
            map_logger.info(f"[{req_id}] [Overpass] Returning {len(features)} features")
            return features
        except requests.exceptions.Timeout as e:
            total_duration = time.time() - request_start if 'request_start' in locals() else 0
            map_logger.error(f"[{req_id}] [Overpass] ========== OVERPASS API TIMEOUT ==========")
            map_logger.error(f"[{req_id}] [Overpass] Timeout after {total_duration:.2f}s")
            map_logger.error(f"[{req_id}] [Overpass] Error: {str(e)}")
            print(f"⚠️ Error fetching map features (timeout): {e}")
            return []
        except requests.exceptions.RequestException as e:
            total_duration = time.time() - request_start if 'request_start' in locals() else 0
            map_logger.error(f"[{req_id}] [Overpass] ========== OVERPASS API NETWORK ERROR ==========")
            map_logger.error(f"[{req_id}] [Overpass] Duration before error: {total_duration:.2f}s")
            map_logger.error(f"[{req_id}] [Overpass] Error type: {type(e).__name__}")
            map_logger.error(f"[{req_id}] [Overpass] Error: {str(e)}")
            print(f"⚠️ Error fetching map features (network): {e}")
            return []
        except Exception as e:
            total_duration = time.time() - request_start if 'request_start' in locals() else 0
            map_logger.error(f"[{req_id}] [Overpass] ========== OVERPASS API UNEXPECTED ERROR ==========")
            map_logger.error(f"[{req_id}] [Overpass] Duration before error: {total_duration:.2f}s")
            map_logger.error(f"[{req_id}] [Overpass] Error type: {type(e).__name__}")
            map_logger.error(f"[{req_id}] [Overpass] Error: {str(e)}")
            import traceback
            map_logger.error(f"[{req_id}] [Overpass] Traceback: {traceback.format_exc()}")
            print(f"⚠️ Error fetching map features: {e}")
            return []
    
    def _classify_feature(self, element: Dict) -> str:
        """Classify an OSM element into a feature type.
        
        Args:
            element: OSM element dict with 'tags' field
        
        Returns:
            Feature type string (water, tree, building, path, park, bridge, place_of_worship, landmark, etc.)
        """
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
        elif tags.get('leisure') == 'park' or tags.get('leisure') == 'playground':
            return 'park'
        elif tags.get('man_made') == 'bridge' or tags.get('bridge') == 'yes':
            return 'bridge'
        elif tags.get('amenity') == 'place_of_worship':
            return 'place_of_worship'
        elif tags.get('amenity') == 'fountain':
            return 'fountain'
        elif tags.get('amenity') == 'monument' or tags.get('historic') == 'monument':
            return 'monument'
        else:
            return 'landmark'

