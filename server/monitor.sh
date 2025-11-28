#!/bin/bash
# Monitor CacheRaiders API server - database changes and API activity

DB_PATH="cache_raiders.db"
API_URL="http://localhost:5001"

echo "🔍 CacheRaiders API Monitor"
echo "============================"
echo ""

# Function to show current database state
show_db_state() {
    echo "📊 Database State:"
    echo "-----------------"
    
    # Count objects
    OBJECT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM objects;" 2>/dev/null || echo "0")
    echo "Total Objects: $OBJECT_COUNT"
    
    # Count finds
    FIND_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM finds;" 2>/dev/null || echo "0")
    echo "Total Finds: $FIND_COUNT"
    
    # Recent objects
    echo ""
    echo "Recent Objects (last 5):"
    sqlite3 "$DB_PATH" -header -column "
        SELECT id, name, type, latitude, longitude, created_at 
        FROM objects 
        ORDER BY created_at DESC 
        LIMIT 5;
    " 2>/dev/null || echo "No objects yet"
    
    # Recent finds
    echo ""
    echo "Recent Finds (last 5):"
    sqlite3 "$DB_PATH" -header -column "
        SELECT f.object_id, o.name, f.found_by, f.found_at 
        FROM finds f 
        JOIN objects o ON f.object_id = o.id 
        ORDER BY f.found_at DESC 
        LIMIT 5;
    " 2>/dev/null || echo "No finds yet"
    
    echo ""
}

# Function to check API health
check_api() {
    if curl -s "$API_URL/health" > /dev/null 2>&1; then
        echo "✅ API Server: Running on $API_URL"
    else
        echo "❌ API Server: Not responding"
    fi
}

# Function to watch database file for changes
watch_database() {
    echo "👀 Monitoring database for changes..."
    echo "Press Ctrl+C to stop"
    echo ""
    
    LAST_OBJECT_COUNT=0
    LAST_FIND_COUNT=0
    
    while true; do
        CURRENT_OBJECT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM objects;" 2>/dev/null || echo "0")
        CURRENT_FIND_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM finds;" 2>/dev/null || echo "0")
        
        # Check for new objects
        if [ "$CURRENT_OBJECT_COUNT" -gt "$LAST_OBJECT_COUNT" ]; then
            NEW_COUNT=$((CURRENT_OBJECT_COUNT - LAST_OBJECT_COUNT))
            echo "🆕 $(date '+%H:%M:%S') - $NEW_COUNT new object(s) created!"
            sqlite3 "$DB_PATH" -header -column "
                SELECT id, name, type, latitude, longitude 
                FROM objects 
                ORDER BY created_at DESC 
                LIMIT $NEW_COUNT;
            "
            LAST_OBJECT_COUNT=$CURRENT_OBJECT_COUNT
            echo ""
        fi
        
        # Check for new finds
        if [ "$CURRENT_FIND_COUNT" -gt "$LAST_FIND_COUNT" ]; then
            NEW_FINDS=$((CURRENT_FIND_COUNT - LAST_FIND_COUNT))
            echo "🎉 $(date '+%H:%M:%S') - $NEW_FINDS new find(s)!"
            sqlite3 "$DB_PATH" -header -column "
                SELECT o.name, f.found_by, f.found_at 
                FROM finds f 
                JOIN objects o ON f.object_id = o.id 
                ORDER BY f.found_at DESC 
                LIMIT $NEW_FINDS;
            "
            LAST_FIND_COUNT=$CURRENT_FIND_COUNT
            echo ""
        fi
        
        sleep 1
    done
}

# Main menu
case "${1:-}" in
    watch)
        show_db_state
        check_api
        echo ""
        watch_database
        ;;
    stats)
        show_db_state
        check_api
        ;;
    *)
        echo "Usage: $0 [watch|stats]"
        echo ""
        echo "Commands:"
        echo "  watch  - Continuously monitor database for changes"
        echo "  stats  - Show current database statistics"
        echo ""
        show_db_state
        check_api
        ;;
esac











