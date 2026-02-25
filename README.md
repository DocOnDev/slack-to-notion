# Slack to Notion Task Shortcut

Right-click any Slack message, choose "Add to Notion", type a task name, done.

## Setup

### 1. Install dependencies

```bash
bundle install
```

### 2. Configure environment

```bash
cp .env.example .env
```

Fill in your values (see below for where to get each one).

### 3. Expose your local server

Slack needs to reach your machine. Use [ngrok](https://ngrok.com):

```bash
ngrok http 4567
```

Copy the `https://...ngrok-free.app` URL. You'll need it for the Slack app config.

### 4. Create a Slack App

1. Go to https://api.slack.com/apps and click **Create New App > From scratch**
2. Name it (e.g. "Notion Tasks"), pick your workspace

#### OAuth scopes (Bot Token Scopes)

Under **OAuth & Permissions**, add:
- `chat:write`
- `channels:history`
- `groups:history`
- `im:history`
- `mpim:history`
- `links:read`

Install the app to your workspace, copy the **Bot User OAuth Token** → `SLACK_BOT_TOKEN` in `.env`

#### Signing secret

Under **Basic Information**, copy the **Signing Secret** → `SLACK_SIGNING_SECRET` in `.env`

#### Message shortcut

Under **Interactivity & Shortcuts**:
- Toggle Interactivity **on**
- Request URL: `https://your-ngrok-url/slack/actions`
- Under Shortcuts, click **Create New Shortcut**
  - Choose **On messages**
  - Name: "Add to Notion" (or whatever you want to see in the menu)
  - Callback ID: `add_to_notion`

### 5. Notion setup

Your Notion integration token goes in `NOTION_TOKEN`.

For `NOTION_DATABASE_ID`: open your task database in Notion, copy the URL. The ID is the 32-character string before the `?`. Example:
`https://notion.so/yourworkspace/abc123def456...?v=...` → ID is `abc123def456...`

Make sure your integration has been shared with that database (open the database in Notion > ... menu > Connections > add your integration).

#### Required database fields

| Field | Type |
|-------|------|
| Task Name | Title |
| Source | URL |
| Status | Status (with an "Incoming" option) |

The message body goes into the page content, not a property.

### 6. Run it

```bash
ruby app.rb
```

Server runs on port 4567. Keep ngrok running in a separate terminal.

## Running persistently on your Mac

If you want it to survive reboots without thinking about it, create a launchd plist:

```bash
# Edit path and token values to match your setup
cat > ~/Library/LaunchAgents/com.yourname.slack-notion.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.yourname.slack-notion</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string>
    <string>/path/to/slack-to-notion/app.rb</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/slack-to-notion</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.yourname.slack-notion.plist
```

Note: ngrok free tier generates a new URL on each restart, so you'd need to update the Slack app's Request URL each time. If that's annoying, ngrok paid gives you a stable domain, or you could self-host this on a cheap VPS.
