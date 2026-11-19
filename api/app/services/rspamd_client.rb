# HTTP client for the Rspamd spam filtering service (spec 11.1.2, 11.1.3).
#
# Rspamd runs as a Docker service on the inbox2_net network. This client
# calls its HTTP API to score inbound messages and train on user feedback.
#
# Usage:
#   client = RspamdClient.new
#   result = client.check(raw_message, client_ip: "203.0.113.42", from: "sender@example.com")
#   result.score    # => 5.3
#   result.action   # => "add header"
#   result.symbols  # => [{"name" => "DKIM_SIGNED", "score" => -0.1}, ...]
#   result.spam?    # => false (depends on threshold)
#
#   client.train_spam(raw_message)
#   client.train_ham(raw_message)
class RspamdClient
  ACTIONS = %w[no\ action greylist add\ header rewrite\ subject soft\ reject reject].freeze

  CheckResult = Struct.new(:score, :action, :symbols, :required_score, keyword_init: true) do
    def spam?(threshold = nil)
      threshold ||= required_score || 7.0
      score >= threshold
    end
  end

  def initialize(url: nil)
    @url = url || ENV.fetch("RSPAMD_URL", "http://localhost:4334")
  end

  # Score a raw RFC 5322 message.
  # Returns a CheckResult with score, action, and matched symbols.
  def check(raw_message, client_ip: nil, from: nil, rcpt: nil)
    uri = URI.join(@url, "/checkv2")
    request = Net::HTTP::Post.new(uri)
    request.body = raw_message
    request["Content-Type"] = "application/octet-stream"

    # Optional headers for Rspamd context
    request["IP"] = client_ip if client_ip.present?
    request["From"] = from if from.present?
    request["Rcpt"] = rcpt if rcpt.present?

    response = execute_request(uri, request)
    parse_check_response(response)
  rescue => e
    Rails.logger.warn("[RspamdClient] Check failed: #{e.message}")
    # Return a neutral result on failure — don't block mail delivery
    CheckResult.new(score: 0.0, action: "no action", symbols: [], required_score: 15.0)
  end

  # Train Rspamd that this message is spam (spec 11.1.3).
  def train_spam(raw_message)
    train(raw_message, "spam")
  end

  # Train Rspamd that this message is ham (not spam) (spec 11.1.3).
  def train_ham(raw_message)
    train(raw_message, "ham")
  end

  # Check if Rspamd is reachable.
  def healthy?
    uri = URI.join(@url, "/ping")
    request = Net::HTTP::Get.new(uri)
    response = execute_request(uri, request)
    response.code == "200"
  rescue
    false
  end

  private

  def train(raw_message, classification)
    uri = URI.join(@url, "/learn#{classification}")
    request = Net::HTTP::Post.new(uri)
    request.body = raw_message
    request["Content-Type"] = "application/octet-stream"

    response = execute_request(uri, request)
    success = response.code.start_with?("2")

    unless success
      Rails.logger.warn("[RspamdClient] Train #{classification} failed: #{response.code} #{response.body}")
    end

    success
  rescue => e
    Rails.logger.warn("[RspamdClient] Train #{classification} error: #{e.message}")
    false
  end

  def execute_request(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = 30
    http.use_ssl = uri.scheme == "https"
    http.request(request)
  end

  def parse_check_response(response)
    unless response.code.start_with?("2")
      Rails.logger.warn("[RspamdClient] Unexpected response: #{response.code}")
      return CheckResult.new(score: 0.0, action: "no action", symbols: [], required_score: 15.0)
    end

    data = JSON.parse(response.body)

    symbols = extract_symbols(data)

    CheckResult.new(
      score: data["score"]&.to_f || 0.0,
      action: data["action"] || "no action",
      symbols: symbols,
      required_score: data["required_score"]&.to_f || 15.0
    )
  end

  def extract_symbols(data)
    return [] unless data["symbols"].is_a?(Hash)

    data["symbols"].map do |name, info|
      {
        "name" => name,
        "score" => info["score"]&.to_f || 0.0,
        "description" => info["description"]
      }
    end
  end
end
