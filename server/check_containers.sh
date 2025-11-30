#!/bin/bash

# Script to check all Docker containers and display their IPs and port numbers

echo "=========================================="
echo "Docker Container IPs and Ports"
echo "=========================================="
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "Error: Docker is not running or not accessible"
    exit 1
fi

# Get all running containers
containers=$(docker ps --format "{{.Names}}")

if [ -z "$containers" ]; then
    echo "No running containers found."
    exit 0
fi

# Loop through each container
for container in $containers; do
    echo "----------------------------------------"
    echo "Container: $container"
    echo "----------------------------------------"
    
    # Get container IP address
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null)
    
    if [ -z "$ip" ]; then
        echo "  IP Address: Not assigned or container not found"
    else
        echo "  IP Address: $ip"
    fi
    
    # Get port mappings
    ports=$(docker port "$container" 2>/dev/null)
    
    if [ -z "$ports" ]; then
        echo "  Ports: No exposed ports"
    else
        echo "  Port Mappings:"
        echo "$ports" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                echo "    $line"
            fi
        done
    fi
    
    # Get exposed ports from container config
    exposed_ports=$(docker inspect -f '{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$container" 2>/dev/null)
    
    if [ -n "$exposed_ports" ]; then
        echo "  Exposed Ports (internal): $exposed_ports"
    fi
    
    # Get network information
    networks=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}} {{end}}' "$container" 2>/dev/null)
    
    if [ -n "$networks" ]; then
        echo "  Networks: $networks"
    fi
    
    echo ""
done

echo "=========================================="
echo "Ollama Model Information"
echo "=========================================="

# Check if Ollama container is running
ollama_container=$(docker ps --filter "name=cache-raiders-ollama" --format "{{.Names}}")

if [ -z "$ollama_container" ]; then
    echo "Ollama container is not running."
    echo ""
else
    # Get Ollama container IP
    ollama_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ollama_container" 2>/dev/null)
    ollama_host_port=$(docker port "$ollama_container" 2>/dev/null | grep "11434/tcp" | awk '{print $3}' | cut -d: -f1)
    
    echo "Ollama Container: $ollama_container"
    if [ -n "$ollama_ip" ]; then
        echo "Ollama IP: $ollama_ip"
    fi
    if [ -n "$ollama_host_port" ]; then
        echo "Ollama Host Port: $ollama_host_port"
    fi
    echo ""
    
    # Query Ollama API for available models
    echo "Available Models:"
    echo "-----------------"
    
    # Try to query from within the container using ollama CLI (most reliable)
    models_list=$(docker exec "$ollama_container" ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v "^$" || true)
    
    # Convert to JSON format for compatibility with existing code
    if [ -n "$models_list" ]; then
        models_json="{\"models\":["
        first=true
        for model in $models_list; do
            if [ "$first" = true ]; then
                first=false
            else
                models_json="${models_json},"
            fi
            models_json="${models_json}{\"name\":\"$model\"}"
        done
        models_json="${models_json}]}"
    fi
    
    # If that fails, try from host using curl
    if [ -z "$models_json" ] || [ "$models_json" = "null" ]; then
        if [ -n "$ollama_host_port" ]; then
            models_json=$(curl -s http://localhost:$ollama_host_port/api/tags 2>/dev/null)
        fi
    fi
    
    if [ -z "$models_json" ] || [ "$models_json" = "null" ]; then
        echo "  Unable to query Ollama API. Container may still be starting up."
    else
        # Check if jq is available for pretty parsing
        if command -v jq > /dev/null 2>&1; then
            echo "$models_json" | jq -r '.models[]? | "  - \(.name) (size: \(.size // "unknown"), modified: \(.modified_at // "unknown"))"' 2>/dev/null
            model_count=$(echo "$models_json" | jq '.models | length' 2>/dev/null)
            if [ -n "$model_count" ] && [ "$model_count" != "null" ]; then
                echo ""
                echo "Total models available: $model_count"
            fi
        else
            # Fallback: basic parsing without jq
            echo "$models_json" | grep -o '"name":"[^"]*"' | sed 's/"name":"\([^"]*\)"/  - \1/' || echo "  (Install 'jq' for better model listing)"
            echo ""
            echo "Raw response:"
            echo "$models_json" | head -20
        fi
    fi
    
    echo ""
    
    # Check API container's configured model
    api_container=$(docker ps --filter "name=api" --format "{{.Names}}" | head -1)
    if [ -z "$api_container" ]; then
        # Try to find API container by pattern
        api_container=$(docker ps --format "{{.Names}}" | grep -i "api\|cache-raiders" | head -1)
    fi
    
    if [ -n "$api_container" ]; then
        # Try to get LLM_MODEL from container environment
        configured_model=$(docker exec "$api_container" printenv LLM_MODEL 2>/dev/null)
        
        if [ -z "$configured_model" ]; then
            # Try using docker inspect with proper JSON parsing
            if command -v jq > /dev/null 2>&1; then
                configured_model=$(docker inspect "$api_container" 2>/dev/null | jq -r '.[0].Config.Env[] | select(startswith("LLM_MODEL=")) | sub("LLM_MODEL="; "")' 2>/dev/null)
            else
                # Fallback: grep and sed
                configured_model=$(docker inspect "$api_container" 2>/dev/null | grep -o 'LLM_MODEL=[^"]*' | head -1 | sed 's/LLM_MODEL=//')
            fi
        fi
        
        if [ -n "$configured_model" ]; then
            echo "Configured Model (API container): $configured_model"
        else
            # Try reading from docker-compose.yml in current directory
            script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$script_dir/docker-compose.yml" ]; then
                configured_model=$(grep "LLM_MODEL" "$script_dir/docker-compose.yml" | head -1 | sed 's/.*LLM_MODEL=\([^ ]*\).*/\1/')
                if [ -n "$configured_model" ]; then
                    echo "Configured Model (from docker-compose.yml): $configured_model"
                fi
            fi
        fi
        
        # Check if configured model is available in Ollama
        if [ -n "$configured_model" ] && [ -n "$models_json" ] && [ "$models_json" != "null" ]; then
            if command -v jq > /dev/null 2>&1; then
                model_available=$(echo "$models_json" | jq -r --arg model "$configured_model" '.models[]? | select(.name == $model) | .name' 2>/dev/null)
                if [ -n "$model_available" ]; then
                    echo "  ✓ Model '$configured_model' is available in Ollama"
                else
                    echo "  ⚠ Warning: Model '$configured_model' is configured but not found in Ollama"
                    echo "    Available models:"
                    echo "$models_json" | jq -r '.models[]? | "      - \(.name)"' 2>/dev/null
                fi
            fi
        fi
    fi
fi

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Total running containers: $(docker ps -q | wc -l | tr -d ' ')"
echo ""
echo "Quick reference:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

