# OpenAI Free Tier Setup Guide

## Understanding the Free Tier

OpenAI provides **$5 in free credits** for new accounts:
- **Amount**: $5 USD
- **Expiration**: Credits expire after 3 months
- **Usage**: Can be used for any OpenAI API calls
- **What it covers**: 
  - GPT-4o-mini: ~333,000 tokens ($0.0015 per 1K tokens)
  - GPT-3.5-turbo: Similar pricing
  - Enough for ~400-500 quest generations

## Why You Might Have Exceeded Quota

1. **Credits Already Used**: The $5 was spent on previous API calls
2. **Credits Expired**: 3 months passed since account creation
3. **Service Account Key**: The key you're using (`sk-svcacct-...`) might be from an account that already used its credits
4. **Billing Required**: Some accounts need payment method added even for free tier

## How to Get Free Tier Credits

### Option 1: Create a New Account (Recommended)

1. **Sign up for a new OpenAI account**:
   - Go to https://platform.openai.com/signup
   - Use a different email address
   - Verify your email

2. **Get your API key**:
   - Go to https://platform.openai.com/api-keys
   - Click "Create new secret key"
   - Copy the key (starts with `sk-` not `sk-svcacct-`)

3. **Update your `.env` file**:
   ```bash
   cd server
   # Edit .env and replace the API key
   OPENAI_API_KEY=sk-your-new-key-here
   ```

4. **Check your credits**:
   - Go to https://platform.openai.com/usage
   - You should see $5.00 in credits

### Option 2: Add Billing to Current Account

If you want to keep using the same account:

1. **Add payment method**:
   - Go to https://platform.openai.com/account/billing
   - Add a credit card
   - Set up billing limits (e.g., $5/month max)

2. **Check usage**:
   - Go to https://platform.openai.com/usage
   - See if you have any remaining credits

3. **Note**: Adding billing doesn't charge you unless you exceed free credits

### Option 3: Use Local Models (No API Key Needed)

If you don't want to use OpenAI:

1. **Install Ollama**:
   ```bash
   brew install ollama  # macOS
   ```

2. **Download a model**:
   ```bash
   ollama pull llama3
   ```

3. **Update `.env`**:
   ```bash
   LLM_PROVIDER=local
   LLM_MODEL=llama3
   LLM_BASE_URL=http://localhost:11434
   # No API key needed
   ```

## Checking Your Current Account Status

### Check Usage
```bash
# Visit in browser:
https://platform.openai.com/usage
```

### Check Billing
```bash
# Visit in browser:
https://platform.openai.com/account/billing
```

### Test Your API Key
```bash
cd server
python3 -c "
from dotenv import load_dotenv
import os
from openai import OpenAI

load_dotenv()
client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))

try:
    response = client.chat.completions.create(
        model='gpt-4o-mini',
        messages=[{'role': 'user', 'content': 'Say hello'}],
        max_tokens=10
    )
    print('✅ API key works!')
    print(f'Response: {response.choices[0].message.content}')
except Exception as e:
    print(f'❌ Error: {e}')
"
```

## Cost Monitoring

### Set Up Billing Alerts

1. Go to https://platform.openai.com/account/billing/limits
2. Set **Hard limit**: $5/month (or whatever you're comfortable with)
3. Set **Soft limit**: $3/month (get notified)
4. Enable email notifications

### Monitor Usage

- **Daily**: Check https://platform.openai.com/usage
- **Per request**: Each quest generation costs ~$0.0001-0.0002
- **Free tier**: $5 = ~400-500 quest generations

## Recommended Setup for Development

1. **Create a new OpenAI account** with a fresh email
2. **Get $5 free credits**
3. **Add billing info** (won't charge unless you exceed free tier)
4. **Set hard limit to $5/month** as safety
5. **Use GPT-4o-mini** (cheapest model, good for testing)

## Troubleshooting

### "Insufficient quota" Error

**Cause**: Free credits used up or expired

**Solution**:
- Create new account for fresh $5 credits
- Or add billing to current account

### "Invalid API key" Error

**Cause**: Key is wrong or revoked

**Solution**:
- Generate new key at https://platform.openai.com/api-keys
- Update `server/.env`

### "Rate limit exceeded" Error

**Cause**: Too many requests too quickly

**Solution**:
- Wait a few minutes
- Free tier has lower rate limits
- Add billing for higher limits

## Next Steps

Once you have a working API key:

1. **Test it**:
   ```bash
   cd server
   python test_llm.py
   ```

2. **Start the server**:
   ```bash
   python app.py
   ```

3. **Talk to the skeleton**:
   ```bash
   curl -X POST http://localhost:5001/api/npcs/skeleton-1/interact \
     -H "Content-Type: application/json" \
     -d '{
       "device_uuid": "test",
       "message": "Where should I dig?",
       "npc_name": "Captain Bones",
       "npc_type": "skeleton",
       "is_skeleton": true
     }'
   ```



