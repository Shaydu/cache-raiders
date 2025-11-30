# Vision-Based Map Analysis for Treasure Maps

## Overview

The LLM service now supports **vision-based map analysis** to extract real-world landmarks from map/satellite imagery. This complements the existing OpenStreetMap (OSM) data and can identify features that aren't in OSM databases.

## How It Works

1. **Capture Map Image**: Get a satellite/map image of the treasure location area
2. **Vision Analysis**: Send image to vision-capable LLM (GPT-4 Vision, Claude 3 Vision, or Ollama vision models)
3. **Extract Landmarks**: LLM identifies structural elements (trees, roads, water, buildings, etc.)
4. **Generate Map & Clues**: Use extracted landmarks in treasure maps and pirate riddles

## Supported Vision Models

### OpenAI (Cloud)
- `gpt-4o` - Recommended, best quality
- `gpt-4o-mini` - Faster, lower cost
- `gpt-4-vision-preview` - Legacy vision model

### Ollama (Local)
- `llava` / `llava:latest` - Most common, good quality
- `llava:7b` - Smaller, faster
- `llava:13b` - Better quality
- `llava:34b` - Best quality (requires more RAM)
- `bakllava` - Alternative vision model
- `moondream` - Smallest, fastest

## Installation (Ollama Vision Models)

If using Ollama, install a vision model:

```bash
# Install LLaVA (recommended)
ollama pull llava

# Or install a specific size
ollama pull llava:7b
ollama pull llava:13b
```

## Usage

### 1. Analyze Map Image Directly

```python
from llm_service import llm_service

# Analyze a map image
result = llm_service.analyze_map_image(
    image_path="/path/to/map_image.png",  # Local file
    # OR
    image_base64="base64_encoded_string",  # Base64 encoded
    # OR
    image_url="https://example.com/map.png",  # URL
    center_latitude=37.7749,
    center_longitude=-122.4194,
    radius_meters=50.0
)

# Result contains:
# {
#     "landmarks": [
#         {
#             "name": "Large oak tree",
#             "type": "tree",
#             "description": "Large oak tree in center of clearing",
#             "estimated_latitude": 37.7749,
#             "estimated_longitude": -122.4194,
#             "relative_position": "center",
#             "confidence": "high"
#         }
#     ],
#     "analysis_summary": "Found 3 trees, 1 path, 1 water feature...",
#     "provider": "openai" or "ollama"
# }
```

### 2. Generate Map Piece with Vision Analysis

```python
# Generate treasure map piece using vision analysis
map_piece = llm_service.generate_map_piece(
    target_location={
        "latitude": 37.7749,
        "longitude": -122.4194
    },
    piece_number=1,
    npc_type="skeleton",
    map_image_path="/path/to/satellite_image.png",  # Optional
    use_vision_analysis=True  # Enable vision analysis
)

# Map piece will include landmarks from both:
# - Vision analysis (if image provided)
# - OpenStreetMap (fallback or supplement)
```

### 3. Generate Clues with Vision Landmarks

```python
# First analyze the map image
vision_result = llm_service.analyze_map_image(
    image_path="/path/to/map.png",
    center_latitude=37.7749,
    center_longitude=-122.4194
)

# Generate clue using vision landmarks
clue = llm_service.generate_clue(
    target_location={"latitude": 37.7749, "longitude": -122.4194},
    vision_landmarks=vision_result.get("landmarks", [])
)
```

## API Endpoint Integration

### Enhanced Map Piece Endpoint

The existing `/api/treasure-hunt/generate-map-piece` endpoint now supports vision analysis:

```bash
# POST request with map image
curl -X POST http://localhost:5001/api/treasure-hunt/generate-map-piece \
  -H "Content-Type: application/json" \
  -d '{
    "npc_id": "skeleton-1",
    "target_location": {
      "latitude": 37.7749,
      "longitude": -122.4194
    },
    "piece_number": 1,
    "use_vision_analysis": true,
    "map_image_base64": "base64_encoded_image_here"
  }'
```

## Workflow: Vision + OSM Hybrid Approach

The system uses a **hybrid approach** that combines both methods:

1. **Primary**: Vision analysis extracts landmarks from map imagery
2. **Fallback**: If vision finds < 2 landmarks, supplement with OSM data
3. **Deduplication**: Removes duplicate landmarks (same type within 10m)
4. **Result**: Rich set of landmarks from both sources

### Example Flow

```
1. User requests treasure map at location (37.7749, -122.4194)
2. System captures/retrieves satellite image of area
3. Vision LLM analyzes image → finds: "large oak tree", "dirt path", "small pond"
4. OSM API queries area → finds: "park bench", "fountain"
5. System combines: ["large oak tree" (vision), "dirt path" (vision), "small pond" (vision), "park bench" (OSM)]
6. Map piece generated with these landmarks
7. Clue generated: "Arr, seek the oak where paths cross, near waters still!"
```

## Getting Map Images

### Option 1: Static Map API
Use services like:
- **Mapbox Static Images API**
- **Google Maps Static API**
- **OpenStreetMap Static Maps**

### Option 2: Satellite Imagery
- **Mapbox Satellite Tiles**
- **Google Earth Engine**
- **USGS EarthExplorer** (free, requires account)

### Option 3: Screenshot from Map App
Capture screenshot from:
- Apple Maps
- Google Maps
- Any mapping application

## Configuration

### For OpenAI Vision
```bash
# Set in .env or environment
LLM_PROVIDER=openai
LLM_MODEL=gpt-4o  # or gpt-4o-mini
OPENAI_API_KEY=your_key_here
```

### For Ollama Vision
```bash
# Set in .env or environment
LLM_PROVIDER=ollama
LLM_MODEL=llava  # or llava:7b, llava:13b, etc.
LLM_BASE_URL=http://localhost:11434
```

## Benefits

1. **More Landmarks**: Vision can identify features not in OSM (trees, natural features, temporary structures)
2. **Visual Context**: Understands spatial relationships (e.g., "tree near path")
3. **Better Clues**: Can reference visual features that are actually visible
4. **Hybrid Approach**: Combines best of both OSM (structured data) and vision (visual analysis)

## Limitations

1. **Coordinate Estimation**: Vision landmarks have estimated coordinates (based on relative position in image)
2. **Image Quality**: Requires clear, high-resolution map/satellite imagery
3. **Processing Time**: Vision analysis takes longer than OSM queries (2-10 seconds)
4. **Model Availability**: Requires vision-capable LLM (not all models support vision)

## Troubleshooting

### "Provider does not support vision"
- **OpenAI**: Use `gpt-4o` or `gpt-4-vision-preview`
- **Ollama**: Install a vision model: `ollama pull llava`

### "Failed to analyze image"
- Check image format (PNG, JPEG supported)
- Verify image is accessible (if using path/URL)
- Check base64 encoding (if using base64)

### "No landmarks found"
- Try larger radius (increase `radius_meters`)
- Use higher resolution image
- Check image actually shows the area (verify coordinates)

## Example: Complete Treasure Hunt Flow

```python
# 1. Get user location
user_location = {"latitude": 37.7749, "longitude": -122.4194}

# 2. Get satellite image (from Mapbox, Google, etc.)
map_image_url = get_satellite_image_url(user_location, zoom=18)

# 3. Analyze image with vision LLM
vision_result = llm_service.analyze_map_image(
    image_url=map_image_url,
    center_latitude=user_location["latitude"],
    center_longitude=user_location["longitude"],
    radius_meters=50.0
)

# 4. Generate map piece with vision landmarks
map_piece = llm_service.generate_map_piece(
    target_location=user_location,
    piece_number=1,
    npc_type="skeleton",
    map_image_url=map_image_url,
    use_vision_analysis=True
)

# 5. Generate clue referencing vision landmarks
clue = llm_service.generate_clue(
    target_location=user_location,
    vision_landmarks=vision_result.get("landmarks", [])
)

print(f"Map Piece: {map_piece}")
print(f"Clue: {clue}")
```

## Next Steps

1. **Integrate Map Image Capture**: Add functionality to capture/retrieve satellite images
2. **Cache Vision Results**: Store analyzed landmarks to avoid re-analyzing same images
3. **Improve Coordinate Estimation**: Use georeferencing for more accurate landmark positions
4. **AR Integration**: Use vision landmarks to place AR objects at real-world features

