# Fixing Docker Desktop "Not Responding" Issue

## Current Issue
Docker Desktop is stuck and showing "not responding" error.

## Solution Steps

### Step 1: Force Quit Docker Completely
1. **Open Activity Monitor**:
   - Press `Cmd + Space`, type "Activity Monitor", press Enter
   - OR: Applications → Utilities → Activity Monitor

2. **Find and Quit all Docker processes**:
   - Search for "Docker" in Activity Monitor
   - Select ALL Docker processes
   - Click "Force Quit" button
   - Confirm

### Step 2: Clean Up Docker Files
Run these commands in Terminal:
```bash
# Remove lock files
rm -f ~/.docker/run/docker.sock.lock
rm -f ~/Library/Containers/com.docker.docker/Data/*.lock

# Remove Docker socket if corrupted
rm -f ~/.docker/run/docker.sock
```

### Step 3: Restart Docker Desktop
1. Wait 10 seconds after force quitting
2. Try starting Docker Desktop again:
   - **Method 1**: Cmd+Space → "Docker" → Enter
   - **Method 2**: Finder → Applications → Docker → Double-click

### Step 4: If Still Not Working - Reinstall Docker Desktop

If Docker Desktop still won't start:

1. **Uninstall Docker Desktop**:
   ```bash
   # Remove Docker Desktop app
   sudo rm -rf /Applications/Docker.app
   
   # Remove Docker data (optional - this deletes all containers/images)
   # rm -rf ~/Library/Containers/com.docker.docker
   # rm -rf ~/.docker
   ```

2. **Download Fresh Install**:
   - Go to: https://www.docker.com/products/docker-desktop
   - Download Docker Desktop for Mac (Apple Silicon or Intel)
   - Install the new version

3. **Start Docker Desktop** and wait for it to initialize

## Alternative: Use Docker via Homebrew

If Docker Desktop continues to have issues, you can try installing via Homebrew:

```bash
# Install Docker via Homebrew
brew install --cask docker

# Start Docker Desktop
open -a Docker
```

## Quick Test After Fix

Once Docker Desktop is running:

```bash
# Test Docker
docker info

# If that works, start your containers
cd /Users/shaydu/dev/CacheRaiders/server
docker-compose up -d

# Run tests
python3 test_ollama_docker.py
```

## Common Causes

- **Corrupted lock files**: Fixed by removing lock files
- **Stuck processes**: Fixed by force quitting
- **Corrupted installation**: Fixed by reinstalling
- **Permission issues**: May need to check System Preferences → Security & Privacy

## Still Having Issues?

If Docker Desktop still won't start after these steps:
1. Check System Preferences → Security & Privacy for any blocked permissions
2. Check Console.app for error messages (Applications → Utilities → Console)
3. Consider restarting your Mac
4. Check Docker Desktop system requirements

