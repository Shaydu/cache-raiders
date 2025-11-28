# Environment Variables Setup

## ⚠️ IMPORTANT: API Key Security

Your OpenAI API key is stored in `server/.env` which is **NOT committed to git** (it's in `.gitignore`).

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

