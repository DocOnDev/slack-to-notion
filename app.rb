require "sinatra"
require "json"
require "net/http"
require "uri"
require "openssl"
require "dotenv/load" if ENV["RACK_ENV"] != "production"

set :port, ENV["PORT"] || 4567

# Verify Slack requests are legitimate
def verify_slack_request(request)
  timestamp = request.env["HTTP_X_SLACK_REQUEST_TIMESTAMP"]
  signature = request.env["HTTP_X_SLACK_SIGNATURE"]

  # Reject requests older than 5 minutes
  return false if (Time.now.to_i - timestamp.to_i).abs > 300

  body = request.env["rack.input"].read
  request.env["rack.input"].rewind

  sig_basestring = "v0:#{timestamp}:#{body}"
  my_signature = "v0=" + OpenSSL::HMAC.hexdigest(
    "SHA256",
    ENV["SLACK_SIGNING_SECRET"],
    sig_basestring
  )

  Rack::Utils.secure_compare(my_signature, signature)
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

  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
end

def get_permalink(channel_id, message_ts)
  uri = URI("https://slack.com/api/chat.getPermalink?channel=#{channel_id}&message_ts=#{message_ts}")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{ENV["SLACK_BOT_TOKEN"]}"

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
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

  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
end

# --- Routes ---

post "/slack/actions" do
  # Verify signature
  halt 403, "Unauthorized" unless verify_slack_request(request)

  payload = JSON.parse(params["payload"])

  case payload["type"]

  when "message_action"
    # Shortcut was triggered -- grab message context and open modal
    message = payload["message"]
    channel_id = payload["channel"]["id"]
    message_ts = message["ts"]
    message_text = message["text"] || ""

    permalink = get_permalink(channel_id, message_ts)
    open_task_name_modal(payload["trigger_id"], message_ts, channel_id, message_text, permalink)

    status 200
    body ""

  when "view_submission"
    # Modal submitted -- create Notion page
    if payload.dig("view", "callback_id") == "task_name_modal"
      task_name = payload.dig("view", "state", "values", "task_name_block", "task_name_input", "value")
      metadata = JSON.parse(payload.dig("view", "private_metadata"))

      create_notion_page(task_name, metadata["permalink"], metadata["message_text"])

      status 200
      content_type :json
      JSON.generate({ response_action: "clear" })
    end

  end
end