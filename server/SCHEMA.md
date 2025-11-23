# Database Schema

The CacheRaiders API uses SQLite with two main tables to track objects and who found them.

## Tables

### `objects`
Stores all loot box objects with their locations.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | Unique identifier for the object (UUID) |
| `name` | TEXT | NOT NULL | Display name (e.g., "Chalice", "Treasure Chest") |
| `type` | TEXT | NOT NULL | Object type (e.g., "Chalice", "Temple Relic", "Treasure Chest") |
| `latitude` | REAL | NOT NULL | GPS latitude coordinate |
| `longitude` | REAL | NOT NULL | GPS longitude coordinate |
| `radius` | REAL | NOT NULL | Radius in meters (how close user needs to be) |
| `created_at` | TEXT | NOT NULL | ISO 8601 timestamp when object was created |
| `created_by` | TEXT | | User ID who created the object (optional) |

**Example:**
```sql
INSERT INTO objects VALUES (
    '550e8400-e29b-41d4-a716-446655440000',
    'Ancient Chalice',
    'Chalice',
    37.7749,
    -122.4194,
    5.0,
    '2025-11-23T13:00:00',
    'user123'
);
```

### `finds`
Tracks who found which objects and when.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | Auto-incrementing find record ID |
| `object_id` | TEXT | NOT NULL, FOREIGN KEY | References `objects.id` |
| `found_by` | TEXT | NOT NULL | User ID who found the object |
| `found_at` | TEXT | NOT NULL | ISO 8601 timestamp when object was found |

**Example:**
```sql
INSERT INTO finds VALUES (
    NULL,  -- auto-increment
    '550e8400-e29b-41d4-a716-446655440000',
    'user456',
    '2025-11-23T14:30:00'
);
```

## Indexes

- `idx_object_id` on `finds(object_id)` - Speeds up lookups of finds by object ID

## Relationships

- **One-to-Many**: One `object` can have multiple `finds` (if you allow re-finding, though currently the API prevents duplicate finds)
- **Foreign Key**: `finds.object_id` → `objects.id`

## Query Examples

### Get all objects with their found status:
```sql
SELECT 
    o.id,
    o.name,
    o.type,
    o.latitude,
    o.longitude,
    o.radius,
    CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as collected,
    f.found_by,
    f.found_at
FROM objects o
LEFT JOIN finds f ON o.id = f.object_id;
```

### Get all objects found by a specific user:
```sql
SELECT 
    o.id,
    o.name,
    o.type,
    f.found_at
FROM finds f
JOIN objects o ON f.object_id = o.id
WHERE f.found_by = 'user123'
ORDER BY f.found_at DESC;
```

### Get statistics:
```sql
-- Total objects
SELECT COUNT(*) FROM objects;

-- Found objects
SELECT COUNT(DISTINCT object_id) FROM finds;

-- Top finders
SELECT found_by, COUNT(*) as count
FROM finds
GROUP BY found_by
ORDER BY count DESC
LIMIT 10;
```

## Data Types

- **TEXT**: Used for IDs, names, types, timestamps (ISO 8601 strings), and user IDs
- **REAL**: Used for GPS coordinates (latitude/longitude) and radius (meters)
- **INTEGER**: Used for auto-incrementing primary keys

## Notes

- Timestamps are stored as ISO 8601 strings (e.g., `2025-11-23T13:00:00`)
- Object IDs should be UUIDs to ensure uniqueness
- The API prevents duplicate finds for the same object (enforced in application logic)
- User IDs are currently simple strings (device UUIDs in iOS app)



