require "net/http"
require "json"

module Jev
  # TypeSafe's System One endpoint (docs/Triage.md "The Jev call"). One POST per
  # thread: a `state` plus typed `questions` in, one typed answer per question out.
  #
  # Errors are classified so callers can act on them: AuthError (401, the key is
  # bad — retrying won't help), RequestError (422, a bug in our request — logged
  # with the body, never retried) and TransientError (429/529/5xx/timeouts —
  # retry with backoff).
  class Client
    ENDPOINT = "https://api.typesafe.ai/v1/systemone".freeze
    # Pinned: the thresholds in JevTriage were set on this model, and
    # `jev-latest` moves on every release.
    DEFAULT_MODEL = "jev-1.13.0".freeze

    class Error < StandardError; end
    class AuthError < Error; end
    class RequestError < Error; end
    class TransientError < Error; end

    def self.default
      new(api_key: ENV["TYPESAFE_API_KEY"].presence, model: ENV["TYPESAFE_MODEL"].presence || DEFAULT_MODEL)
    end

    attr_reader :model

    def initialize(api_key:, model: DEFAULT_MODEL)
      @api_key = api_key
      @model = model
    end

    def configured?
      @api_key.present?
    end

    # Returns the parsed response: {"model" => "...", "answers" => {...}, ...}.
    def ask(state:, questions:)
      uri = URI(ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 20

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body = JSON.generate(model: @model, state: state, questions: questions)

      res = http.request(req)
      code = res.code.to_i
      case code
      when 200..299 then JSON.parse(res.body)
      when 401, 403 then raise AuthError, "Jev rejected the API key (#{code})"
      when 422
        Rails.logger.error("[Jev] 422 — request rejected: #{res.body.to_s[0, 2000]}")
        raise RequestError, "Jev rejected the request (422)"
      when 429, 500..599 then raise TransientError, "Jev #{code}"
      else raise RequestError, "Jev unexpected #{code}: #{res.body.to_s[0, 500]}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError,
           OpenSSL::SSL::SSLError, EOFError, JSON::ParserError => e
      raise TransientError, "Jev #{e.class}: #{e.message}"
    end
  end
end
