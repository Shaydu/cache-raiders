# Real Map Features for Clue Generation

## How It Works

**Yes!** Clues are now generated based on **REAL map data** from **OpenStreetMap** (not Google Maps, but similar data).

### The Process

1. **You provide coordinates** (latitude, longitude) for where the treasure is
2. **System fetches real features** from OpenStreetMap within 500 meters
3. **LLM generates clues** that reference those actual features
4. **Clues are location-specific** - different locations get different clues!

## What Features Are Detected

The system looks for:
- **Water**: Rivers, lakes, streams, bays
- **Trees**: Individual trees, tree rows, parks
- **Buildings**: Structures, landmarks, named buildings
- **Mountains**: Peaks, elevation features
- **Paths**: Roads, trails, walkways
- **Landmarks**: Named places, points of interest

## Example

### San Francisco (37.7749, -122.4194)
**Real features found:**
- Trees
- Fulton Street (path)
- Colton Street (path)
- Buildings nearby

**Generated clue:**
> "Arr, dig where the trees stand tall, near Fulton's path where shadows fall!"

### New York (40.7128, -74.0060)
**Real features found:**
- Different streets
- Different buildings
- Different water features

**Generated clue:**
> (Different clue based on NY features)

## API Usage

### Automatic (Recommended)
```bash
curl -X POST http://localhost:5001/api/llm/generate-clue \
  -H "Content-Type: application/json" \
  -d '{
    "target_location": {
      "latitude": 37.7749,
      "longitude": -122.4194
    },
    "fetch_real_features": true
  }'
```

The system will:
1. Fetch real features from OpenStreetMap
2. Generate a clue using those features
3. Return the clue

### Manual Features (Optional)
```bash
curl -X POST http://localhost:5001/api/llm/generate-clue \
  -H "Content-Type: application/json" \
  -d '{
    "target_location": {
      "latitude": 37.7749,
      "longitude": -122.4194
    },
    "map_features": ["Golden Gate Park", "San Francisco Bay"],
    "fetch_real_features": false
  }'
```

## Data Source: OpenStreetMap

- **Free**: No API key needed
- **Public**: Open source map data
- **Accurate**: Used by many apps
- **Global**: Works worldwide

### Why OpenStreetMap, Not Google Maps?

1. **Free**: No API key or billing required
2. **No limits**: No rate limiting for reasonable use
3. **Open data**: Community-maintained
4. **Similar data**: Has the same features (water, trees, buildings, etc.)

## Testing

```bash
cd server
python3 -c "
from dotenv import load_dotenv
load_dotenv()
from llm_service import llm_service

# Test with your location
target = {'latitude': YOUR_LAT, 'longitude': YOUR_LON}
clue = llm_service.generate_clue(target, fetch_real_features=True)
print(clue)
"
```

## How It Works Technically

1. **Overpass API Query**: Sends a query to OpenStreetMap's Overpass API
2. **Feature Detection**: Finds water, trees, buildings, paths within 500m radius
3. **Feature Naming**: Gets actual names (e.g., "Fulton Street") when available
4. **LLM Prompt**: Sends features to LLM with location context
5. **Clue Generation**: LLM creates pirate riddle referencing real features

## Benefits

✅ **Location-specific**: Clues match actual geography  
✅ **Realistic**: References real landmarks users can see  
✅ **Dynamic**: Different locations = different clues  
✅ **Free**: No additional API costs  
✅ **Accurate**: Based on real map data  

## Limitations

- **500m radius**: Only features within 500 meters
- **OpenStreetMap coverage**: Some areas have more data than others
- **Feature names**: Not all features have names (uses type instead)
- **Response time**: ~1-2 seconds to fetch features

## Future Enhancements

- Cache features to reduce API calls
- Support for elevation data
- Integration with Google Maps Places API (if you want to add it)
- Custom feature types for your game



