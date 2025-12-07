# Environment Variables Setup

## ⚠️ IMPORTANT: API Key Security

Your OpenAI API key is stored in `server/.env` which is **NOT committed to git** (it's in `.gitignore`).

## 🍎 Apple MapKit JS Setup (for Admin Panel)

The admin panel now uses Apple Maps instead of OpenStreetMap to match the iOS app experience.

### Required Environment Variables

Add these to your `server/.env` file:

```bash
# Apple MapKit JS Configuration
MAPKIT_TEAM_ID=your_team_id_here
MAPKIT_KEY_ID=your_key_id_here
MAPKIT_PRIVATE_KEY_PATH=/path/to/AuthKey_XXXXXXX.p8
```

### Setup Steps

1. **Create Apple Developer Account**
   - Go to [Apple Developer](https://developer.apple.com/account/)
   - Join the Apple Developer Program if not already a member

2. **Create Maps Identifier**
   - In your developer account, go to "Certificates, Identifiers & Profiles"
   - Click "+" → "Maps IDs"
   - Enter a description and identifier (e.g., `com.yourdomain.cacheraiders.maps`)
   - Click "Continue" and "Register"

3. **Generate Private Key**
   - In the Maps Identifier details, click "Create Key"
   - Give it a name and check the Maps Services box
   - Download the `.p8` file and store it securely
   - Note the Key ID (something like `ABC123DEF4`)

4. **Get Team ID**
   - In your developer account, go to "Membership"
   - Copy your Team ID (10-character string)

5. **Configure Environment**
   - Set `MAPKIT_TEAM_ID` to your Team ID
   - Set `MAPKIT_KEY_ID` to your Key ID
   - Set `MAPKIT_PRIVATE_KEY_PATH` to the full path of your `.p8` file

### Security Notes

- The `.p8` private key file should be stored securely and not committed to git
- The server generates JWT tokens that expire after 1 hour
- MapKit JS requests are authenticated server-side to protect your credentials

## Setup Instructions

1. **The `.env` file is already created** with your API key
2. **Never commit `.env` to git** - it's already in `.gitignore`
3. **Use `.env.example`** as a template for other developers (no real keys)

## Using the API Key

The server automatically loads the API key from `.env` when it starts.

To use it in code:
```python
import os
api_key = os.getenv('OPENAI_API_KEY')
```

## Free Tier Usage

OpenAI provides $5 free credit for new accounts. To check your usage:

1. Go to https://platform.openai.com/usage
2. Monitor your spending
3. Set up billing alerts at https://platform.openai.com/account/billing/overview

## If You Need to Rotate the Key

If this key was ever shared publicly, rotate it:
1. Go to https://platform.openai.com/api-keys
2. Delete the old key
3. Create a new key
4. Update `server/.env` with the new key

## For Other Developers

Other developers should:
1. Copy `.env.example` to `.env`
2. Add their own API key
3. Never commit `.env`



