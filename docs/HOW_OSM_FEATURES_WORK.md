# How OpenStreetMap Feature Fetching Works

## Yes, It's OSM Data!

The system uses **OpenStreetMap (OSM)** data via the **Overpass API** - a free, public API that doesn't require any API keys.

## The Process

### 1. Overpass API Query

When you provide coordinates, the system sends a query to:
```
https://overpass-api.de/api/interpreter
```

### 2. Query Language (Overpass QL)

The system uses Overpass QL to search for features:

```overpass
[out:json][timeout:25];
(
  way["natural"="water"](around:500,37.7749,-122.4194);
  way["waterway"](around:500,37.7749,-122.4194);
  node["natural"="tree"](around:500,37.7749,-122.4194);
  way["natural"="tree_row"](around:500,37.7749,-122.4194);
  way["building"](around:500,37.7749,-122.4194);
  way["highway"](around:500,37.7749,-122.4194);
  relation["natural"="mountain"](around:500,37.7749,-122.4194);
  way["natural"="peak"](around:500,37.7749,-122.4194);
);
out body;
>;
out skel qt;
```

**What this does:**
- Searches within 500 meters of the coordinates
- Looks for: water, trees, buildings, roads, mountains
- Returns JSON data with feature names and types

### 3. Feature Classification

The system classifies each feature:

```python
def _classify_feature(element):
    tags = element.get('tags', {})
    
    if 'waterway' in tags or tags.get('natural') == 'water':
        return 'water'
    elif tags.get('natural') == 'tree':
        return 'tree'
    elif 'building' in tags:
        return 'building'
    # ... etc
```

### 4. Feature Extraction

For each feature found:
- **Named features**: Uses the actual name (e.g., "Fulton Street", "Golden Gate Park")
- **Unnamed features**: Uses the type (e.g., "tree", "water", "building")

### 5. LLM Integration

The real features are then sent to the LLM:

```
Create a SHORT pirate riddle (1-2 lines max) telling where to dig. 
Use pirate speak. Reference: Real features: tree, Fulton Street (path), Colton Street (path)

Keep it SHORT - 1-2 lines only. Riddle:
```

The LLM generates clues like:
> "By the tall tree where paths do meet,  
> Dig near the cross of Colton and Fulton's greet!"

## What Features Are Detected

### Water Features
- Rivers, streams, lakes, bays
- Tagged as: `natural=water` or `waterway=*`

### Trees
- Individual trees, tree rows, forests
- Tagged as: `natural=tree` or `natural=tree_row`

### Buildings
- Structures, landmarks, named buildings
- Tagged as: `building=*`

### Paths/Roads
- Streets, trails, walkways
- Tagged as: `highway=*`
- Includes actual street names when available

### Mountains/Elevation
- Peaks, mountains, elevation features
- Tagged as: `natural=peak` or `natural=mountain`

## Example Response from OSM

```json
{
  "elements": [
    {
      "type": "way",
      "id": 12345,
      "tags": {
        "name": "Fulton Street",
        "highway": "residential"
      },
      "lat": 37.7749,
      "lon": -122.4194
    },
    {
      "type": "node",
      "id": 67890,
      "tags": {
        "natural": "tree"
      },
      "lat": 37.7750,
      "lon": -122.4195
    }
  ]
}
```

## Why OpenStreetMap?

### ✅ Advantages
- **Free**: No API key or billing
- **No rate limits**: For reasonable use
- **Global coverage**: Works worldwide
- **Open data**: Community-maintained
- **Rich data**: Includes names, types, relationships

### ⚠️ Limitations
- **Coverage varies**: Some areas have more data than others
- **Response time**: ~1-2 seconds per query
- **Not all features named**: Some features only have types

## Comparison: OSM vs Google Maps

| Feature | OpenStreetMap | Google Maps |
|---------|---------------|-------------|
| **Cost** | Free | Requires API key, billing |
| **Rate Limits** | None (reasonable use) | Strict limits |
| **Data Quality** | Good (varies by area) | Excellent |
| **Feature Names** | Yes (when available) | Yes (more complete) |
| **Setup** | None | API key required |
| **Use Case** | Perfect for this | Overkill for this |

## Code Location

The implementation is in:
- `server/llm_service.py` → `MapFeatureService` class
- Uses `requests` library to query Overpass API
- No API keys needed - completely free!

## Testing

You can test it directly:

```python
from llm_service import MapFeatureService

service = MapFeatureService()
features = service.get_features_near_location(37.7749, -122.4194)
print(features)
# Output: ['tree', 'Fulton Street (path)', 'Colton Street (path)', ...]
```

## Summary

**Yes, it's OpenStreetMap data!** The system:
1. Queries OSM's Overpass API (free, no key needed)
2. Gets real geographic features within 500m
3. Extracts names and types
4. Uses them in LLM prompts
5. Generates location-specific clues

This makes clues **realistic** and **location-specific** - different places get different clues based on what's actually there!


