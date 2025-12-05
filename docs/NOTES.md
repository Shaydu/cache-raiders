# Cache Raiders Notes

## Admin Interface

The admin interface is available at:
- **Local**: http://localhost:5001/admin
- **Network**: http://192.168.1.29:5001/admin

### Starting the Server

To start the server with Docker Compose:
```bash
cd /Users/shaydu/dev/CacheRaiders/server
bash start_server.sh
```

Or manually:
```bash
cd /Users/shaydu/dev/CacheRaiders/server
docker compose up -d
```

### Admin Features

The admin panel includes:
- Create and manage loot objects
- View statistics and leaderboard
- Player management
- Loot management
- Game mode settings (Open/Story Mode)
- Location update frequency settings
- LLM provider configuration (OpenAI/Ollama)
- Server connection QR code for iOS app
- Connection diagnostics
- Map settings (Standard/Pirate style)

### Server Status

Check server health:
```bash
curl http://localhost:5001/health
```

View logs:
```bash
cd /Users/shaydu/dev/CacheRaiders
tail -20 server/logs/map_requests.log
```