require "sinatra"
require "json"
require "logger"
require "net/http"
require "uri"
require "openssl"
require "dotenv/load" if ENV["RACK_ENV"] != "production"

APP_LOGGER = Logger.new($stdout)
APP_LOGGER.level = Logger::INFO

set :port, ENV["PORT"] || 4567
# Railway sends a Host header that Rack::Protection blocks by default.
# We disable only the host header check to allow the public Railway domain.
set :protection, except: :host_header

allowed_hosts = ENV.fetch("ALLOWED_HOSTS", "")
  .split(",")
  .map(&:strip)
  .reject(&:empty?)
if allowed_hosts.empty?
  allowed_hosts = [".up.railway.app", "localhost", "127.0.0.1", "::1"]
end
set :host_authorization, { permitted_hosts: allowed_hosts }
APP_LOGGER.info("Host authorization permitted_hosts=#{allowed_hosts}")

before do
  if request.path_info == "/slack/actions"
    APP_LOGGER.info("Incoming Slack request: #{request.request_method} #{request.path_info}")
  end
end

# Verify Slack requests are legitimate
def verify_slack_request(request)
  timestamp = request.env["HTTP_X_SLACK_REQUEST_TIMESTAMP"]
  signature = request.env["HTTP_X_SLACK_SIGNATURE"]

  slack_debug = ENV["SLACK_DEBUG"].to_s.strip == "true"
  if slack_debug
    APP_LOGGER.info("Slack headers: timestamp=#{timestamp.inspect} signature=#{signature.inspect}")
  end

  if timestamp.nil? || signature.nil?
    APP_LOGGER.warn("Missing Slack signature headers")
    return false
  end

  if ENV["SLACK_SIGNING_SECRET"].to_s.strip.empty?
    APP_LOGGER.error("SLACK_SIGNING_SECRET is not set")
    return false
  end

  # Reject requests older than 5 minutes
  if (Time.now.to_i - timestamp.to_i).abs > 300
    APP_LOGGER.warn("Slack request timestamp too old")
    return false
  end

  # Slack signs the raw request body. For form-encoded requests,
  # Rack stores the original string in rack.request.form_vars.
  body = request.env["rack.request.form_vars"].to_s
  if body.empty?
    body = request.body.read.to_s
    request.body.rewind
  end
  if slack_debug
    APP_LOGGER.info("Slack body length=#{body.bytesize}")
  end

  sig_basestring = "v0:#{timestamp}:#{body}"
  my_signature = "v0=" + OpenSSL::HMAC.hexdigest(
    "SHA256",
    ENV["SLACK_SIGNING_SECRET"],
    sig_basestring
  )

  unless Rack::Utils.secure_compare(my_signature, signature)
    if slack_debug
      APP_LOGGER.warn("Slack signature verification failed: computed=#{my_signature[0, 14]}... received=#{signature[0, 14]}...")
    else
      APP_LOGGER.warn("Slack signature verification failed")
    end
    return false
  end

  true
end

def open_task_name_modal(trigger_id, message_ts, channel_id, message_text, permalink)
  payload = {
    trigger_id: trigger_id,
    view: {
      type: "modal",
      callback_id: "task_name_modal",
      title: { type: "plain_text", text: "Add to Notion" },
      submit: { type: "plain_text", text: "Save" },
      close: { type: "plain_text", text: "Cancel" },
      private_metadata: JSON.generate({
        permalink: permalink,
        message_text: message_text
      }),
      blocks: [
        {
          type: "input",
          block_id: "task_name_block",
          label: { type: "plain_text", text: "Task Name" },
          element: {
            type: "plain_text_input",
            action_id: "task_name_input",
            placeholder: { type: "plain_text", text: "What do you need to do?" }
          }
        }
      ]
    }
  }

  uri = URI("https://slack.com/api/views.open")
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{ENV["SLACK_BOT_TOKEN"]}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(payload)

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  ok = begin
    JSON.parse(res.body)["ok"]
  rescue JSON::ParserError
    nil
  end
  APP_LOGGER.info("Slack views.open response: status=#{res.code} ok=#{ok}")
  res
end

def get_permalink(channel_id, message_ts)
  uri = URI("https://slack.com/api/chat.getPermalink?channel=#{channel_id}&message_ts=#{message_ts}")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{ENV["SLACK_BOT_TOKEN"]}"

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  APP_LOGGER.info("Slack chat.getPermalink response: status=#{res.code}")
  JSON.parse(res.body)["permalink"]
end

def create_notion_page(task_name, permalink, message_text)
  payload = {
    parent: { database_id: ENV["NOTION_DATABASE_ID"] },
    properties: {
      "Task Name" => {
        title: [{ text: { content: task_name } }]
      },
      "Source" => {
        url: permalink
      },
      "Status" => {
        status: { name: "Incoming" }
      }
    },
    children: [
      {
        object: "block",
        type: "paragraph",
        paragraph: {
          rich_text: [{ type: "text", text: { content: message_text } }]
        }
      }
    ]
  }

  uri = URI("https://api.notion.com/v1/pages")
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{ENV["NOTION_TOKEN"]}"
  req["Content-Type"] = "application/json"
  req["Notion-Version"] = "2022-06-28"
  req.body = JSON.generate(payload)

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  APP_LOGGER.info("Notion create page response: status=#{res.code}")
  res
end

# --- Routes ---

get "/health" do
  content_type :json
  JSON.generate({ status: "ok" })
end

post "/slack/actions" do
  # Verify signature
  halt 403, "Unauthorized" unless verify_slack_request(request)

  raw_payload = params["payload"]
  unless raw_payload
    APP_LOGGER.warn("Missing payload param")
    halt 400, "Bad Request"
  end

  payload = begin
    JSON.parse(raw_payload)
  rescue JSON::ParserError
    APP_LOGGER.warn("Failed to parse payload JSON")
    halt 400, "Bad Request"
  end

  case payload["type"]

  when "message_action"
    # Shortcut was triggered -- grab message context and open modal
    message = payload["message"]
    channel_id = payload["channel"]["id"]
    message_ts = message["ts"]
    message_text = message["text"] || ""
    APP_LOGGER.info("message_action received: channel=#{channel_id} ts=#{message_ts}")

    permalink = get_permalink(channel_id, message_ts)
    open_task_name_modal(payload["trigger_id"], message_ts, channel_id, message_text, permalink)

    status 200
    body ""

  when "view_submission"
    # Modal submitted -- create Notion page
    if payload.dig("view", "callback_id") == "task_name_modal"
      task_name = payload.dig("view", "state", "values", "task_name_block", "task_name_input", "value")
      metadata = JSON.parse(payload.dig("view", "private_metadata"))
      APP_LOGGER.info("view_submission received: task_name_present=#{!task_name.to_s.strip.empty?}")

      create_notion_page(task_name, metadata["permalink"], metadata["message_text"])

      status 200
      content_type :json
      JSON.generate({ response_action: "clear" })
    end

  end
end
