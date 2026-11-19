require "net/http"
require "json"

module Llm
  # Minimal provider-agnostic chat client speaking the OpenAI /chat/completions
  # shape. Today this points at OpenAI; later we swap to on-site Ollama by setting
  # LLM_BASE_URL (Ollama exposes an OpenAI-compatible endpoint) — no code change.
  #
  # Gated on an API key: when unconfigured, `configured?` is false and callers
  # skip the LLM path entirely (classification falls back to the holding pen).
  class Client
    DEFAULT_BASE_URL = "https://api.openai.com/v1".freeze
    DEFAULT_MODEL = "gpt-4o-mini".freeze

    def self.default
      new(
        api_key: ENV["OPENAI_API_KEY"].presence || ENV["LLM_API_KEY"].presence,
        base_url: ENV["LLM_BASE_URL"].presence || DEFAULT_BASE_URL,
        model: ENV["LLM_CLASSIFY_MODEL"].presence || DEFAULT_MODEL
      )
    end

    def initialize(api_key:, base_url:, model:)
      @api_key = api_key
      @base_url = base_url.chomp("/")
      @model = model
    end

    def configured?
      @api_key.present?
    end

    # Returns the assistant's text content, or nil on any error/timeout.
    # `response_format` (e.g. a json_schema) is passed through when given; the
    # read timeout grows with it, since a structured answer is long.
    def complete(system:, user:, max_tokens: 16, temperature: 0, response_format: nil)
      return nil unless configured?

      uri = URI("#{@base_url}/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = response_format ? 60 : 15

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      body = {
        model: @model,
        temperature: temperature,
        max_tokens: max_tokens,
        messages: [
          { role: "system", content: system },
          { role: "user", content: user }
        ]
      }
      body[:response_format] = response_format if response_format
      req.body = JSON.generate(body)

      res = http.request(req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      data.dig("choices", 0, "message", "content")&.strip
    rescue StandardError => e
      Rails.logger.warn("Llm::Client #{e.class}: #{e.message}")
      nil
    end
  end
end
