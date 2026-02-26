# Slack to Notion Task Shortcut

Right-click any Slack message, choose "Add to Notion", type a task name, done.

## Prerequisites

- A Railway account (railway.app)
- A Slack workspace where you can create apps
- A Notion integration token and database ID

## Setup

### 1. Deploy to Railway

1. Go to [railway.app](https://railway.app) and create a new project
2. Choose **GitHub repository** and connect this repository
3. Ensure your repo includes:
  - `Gemfile.lock` (must be committed)
  - `.ruby-version` (with your Ruby version, e.g. `3.2.2`)
  - `Procfile` (with `web: bundle exec puma -b tcp://0.0.0.0:${PORT:-4567} config.ru`)
4. Railway will detect the Gemfile and build automatically
5. Once deployed, go to **Settings > Networking** and click **Generate Domain** -- this gives you your public URL (e.g. `https://your-app.up.railway.app`)

### 2. Set environment variables in Railway

Under your service's **Variables** tab, add:

| Key | Value |
|-----|-------|
| `SLACK_BOT_TOKEN` | `xoxb-...` (from Slack app, see below) |
| `SLACK_SIGNING_SECRET` | From Slack app Basic Information |
| `NOTION_TOKEN` | Your Notion integration token |
| `NOTION_DATABASE_ID` | Your Notion database ID |

Railway sets `RACK_ENV=production` automatically -- dotenv will not run in production, which is correct.

### 3. Create a Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App > From scratch**
2. Name it (e.g. "Notion Tasks") and pick your workspace

#### Bot Token Scopes

Under **OAuth & Permissions > Bot Token Scopes**, add:
- `chat:write`
- `channels:history`
- `groups:history`
- `im:history`
- `mpim:history`
- `commands`

Install the app to your workspace. Copy the **Bot User OAuth Token** into `SLACK_BOT_TOKEN` in Railway.

#### Signing Secret

Under **Basic Information**, copy the **Signing Secret** into `SLACK_SIGNING_SECRET` in Railway.

#### Interactivity & Shortcut

Under **Interactivity & Shortcuts**:
- Toggle Interactivity **on**
- Set Request URL to: `https://your-app.up.railway.app/slack/actions`
- Under Shortcuts, click **Create New Shortcut**
  - Choose **On messages**
  - Name: "Add to Notion"
  - Callback ID: `add_to_notion`

### 4. Notion setup

Your integration token goes in `NOTION_TOKEN`.

For `NOTION_DATABASE_ID`: open your task database in Notion and copy the URL. The ID is the 32-character string before the `?`:
`https://notion.so/yourworkspace/abc123...?v=...` -- ID is `abc123...`

Make sure your integration is shared with the database: open the database in Notion > **...** menu > **Connections** > add your integration.

#### Required database fields

| Field | Type |
|-------|------|
| Task name | Title |
| Source | URL |
| Status | Status (must have an "Incoming" option) |

The Slack message body is written to the page content, not a property.

### 5. Health check (optional)

Your app exposes `GET /health` and returns `{"status":"ok"}` when healthy. This is useful to verify your Railway deploy is reachable.

## Local development

```bash
bundle install
cp .env.example .env
# fill in your values
ruby app.rb
```

For local development you will need a tunnel to expose localhost to Slack. [ngrok](https://ngrok.com) works:

```bash
ngrok http 4567
```

Point the Slack app's Request URL at the ngrok HTTPS URL while developing. Switch it back to your Railway URL when done.

For more details, see `CONTRIBUTING.md`.

## Troubleshooting

If the Slack shortcut appears but fails immediately:
- Check Railway logs for `Slack signature verification failed`.
- Re-copy `SLACK_SIGNING_SECRET` from the Slack app **Basic Information** page into Railway.

If the modal opens but no Notion page appears:
- Check Railway logs for `Notion error body`.
- Confirm your Notion database property names match exactly:
  - `Task name` (Title)
  - `Source` (URL)
  - `Status` (Status with an `Incoming` option)

If the task name is left blank:
- The app will default the title to `Task from Slack`.

Transient API failures:
- The app retries Slack/Notion API calls briefly on timeouts or 5xx responses.
- If Notion still fails, the modal stays open with a friendly error message.

## Reliability

- Slack and Notion API calls include short retries for transient failures.
- Notion errors are surfaced in the modal so failures are visible to the user.
- Empty task names default to `Task from Slack`.

## Project hygiene

- Keep secrets in Railway Variables or `.env` (never commit them).
- Rotate Slack and Notion tokens if they are ever exposed.
- Use least‑privilege scopes in Slack and share only the required Notion database.
- Monitor Railway logs for errors; they include a request correlation id (`req_id`) for tracing.
