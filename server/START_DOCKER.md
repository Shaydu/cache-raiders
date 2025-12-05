# How to Start Docker Desktop on macOS

## Quick Start Methods

### Method 1: From Applications (Easiest)
1. **Open Finder** (Cmd+N or click Finder icon)
2. Press **Cmd+Shift+A** to go to Applications folder
3. Find **"Docker"** app
4. **Double-click** to launch
5. Wait for Docker Desktop to start (look for whale icon in menu bar)

### Method 2: Using Spotlight
1. Press **Cmd + Space** (Spotlight search)
2. Type **"Docker"**
3. Press **Enter**
4. Wait for Docker Desktop to fully start

### Method 3: From Terminal (if above don't work)
```bash
open /Applications/Docker.app
```

## How to Know Docker is Ready

1. **Menu Bar Icon**: Look for the Docker whale icon in the top menu bar
   - ⏳ **Animating whale** = Docker is starting (wait)
   - ✅ **Steady whale** = Docker is running and ready

2. **Test in Terminal**:
   ```bash
   docker info
   ```
   If this works without errors, Docker is ready!

## Troubleshooting

### Docker Won't Start
1. **Check if it's already running**:
   ```bash
   ps aux | grep -i docker
   ```

2. **Force quit if stuck**:
   - Click Docker icon in menu bar → Quit Docker Desktop
   - Or: `killall "Docker Desktop"`

3. **Restart Docker Desktop**:
   - Quit completely
   - Wait 10 seconds
   - Start again from Applications

### Permission Issues
- Make sure you have admin rights
- Docker Desktop may ask for password on first launch

### Docker Desktop Not Found
- Check if Docker is installed: `ls /Applications/ | grep -i docker`
- If not found, download from: https://www.docker.com/products/docker-desktop

## Once Docker is Running

After Docker Desktop starts successfully, you can:

1. **Start your containers**:
   ```bash
   cd /Users/shaydu/dev/CacheRaiders/server
   docker-compose up -d
   ```

2. **Run the test**:
   ```bash
   python3 test_ollama_docker.py
   ```

3. **Or use the auto-test script**:
   ```bash
   ./wait_and_test.sh
   ```

## Expected Startup Time

- First launch: 30-60 seconds
- Subsequent launches: 10-20 seconds
- If it takes longer, Docker may be stuck and needs restart

