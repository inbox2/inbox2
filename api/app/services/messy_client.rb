require "net/http"
require "json"

# Thin client for the Messy messaging platform (https://api.messy.sh) — the
# transactional-email transport (ported from lalaaji-v3, trimmed to email only).
# Sends are fire-and-forget off the request thread via MessyTriggerJob; never
# call this synchronously from a controller. Templates ("triggers") and the
# sending identity (from-address) live on the Messy account the API key belongs to.
class MessyClient
  class MessyError < StandardError; end

  # The Messy endpoint is fixed; only the API key needs configuring (secret_env).
  DEFAULT_API_URL = "https://api.messy.sh".freeze

  def initialize
    @base_url = ENV.fetch("MESSY_API_URL", DEFAULT_API_URL)
    @api_key = ENV.fetch("MESSY_API_KEY")
  end

  # Trigger a template-based message.
  #
  # @param trigger [String] template trigger name (e.g. "password.reset")
  # @param to [String] recipient email
  # @param data [Hash] template variables for Liquid rendering
  # @param channel [String] "email" (default)
  # @param cc / bcc [String] optional
  def trigger(trigger:, to:, data: {}, channel: "email", cc: nil, bcc: nil)
    message = { to: to }
    message[:cc] = cc if cc.present?
    message[:bcc] = bcc if bcc.present?

    post("/messages/trigger", { trigger: trigger, channel: channel, message: message, data: data })
  end

  # Send a raw (non-templated) message. Subject/body supplied by the caller; the
  # from-address is still fixed on the Messy side.
  def send_message(type: "email", to:, body:, subject: nil, cc: nil, bcc: nil)
    message = { to: to, body: body }
    message[:subject] = subject if subject.present?
    message[:cc] = cc if cc.present?
    message[:bcc] = bcc if bcc.present?

    post("/messages", { type: type, message: message })
  end

  private

  def post(path, payload)
    request(Net::HTTP::Post, path, payload)
  end

  def request(verb_class, path, payload = nil)
    uri = URI("#{@base_url}#{path}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"

    req = verb_class.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{@api_key}"
    req.body = payload.as_json.to_json unless payload.nil?

    response = http.request(req)

    case response.code.to_i
    when 200..299
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    when 401
      raise MessyError, "Unauthorized: Invalid API key"
    when 422
      error_data = JSON.parse(response.body)
      raise MessyError, "Validation error: #{error_data['error'] || error_data['errors'] || error_data}"
    else
      raise MessyError, "HTTP #{response.code}: #{response.body}"
    end
  rescue JSON::ParserError => e
    raise MessyError, "Invalid JSON response: #{e.message}"
  end
end
