# Contributing

Thanks for helping improve this project.

## Prerequisites

- Ruby `3.2.2` (see `.ruby-version`)
- Bundler

## Setup

```bash
bundle install
cp .env.example .env
# fill in your values
ruby app.rb
```

For local Slack testing, expose your server and point the Slack Request URL at the tunnel:

```bash
ngrok http 4567
```

## Useful commands

- Run the app: `ruby app.rb`
- Check health: `curl http://localhost:4567/health`
