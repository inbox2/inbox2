require "net/http"
require "json"

module DeliveryProviders
  # Shared scaffolding for provider adapters: holds the channel's config and a
  # small JSON-over-HTTPS helper. Subclasses implement #deliver(context) and
  # return a DeliveryProviders::Result.
  class Base
    class ProviderError < StandardError; end

    def initialize(channel)
      @channel = channel
      @config = (channel.config || {}).with_indifferent_access
    end

    # @param context [DeliveryProviders::Context]
    # @return [DeliveryProviders::Result]
    def deliver(_context)
      raise NotImplementedError, "#{self.class} must implement #deliver"
    end

    # Cheap credential pre-flight for the "Test connection" button. Adapters
    # override with a no-cost auth call; the default just reports that the config
    # was saved but couldn't be verified without sending.
    def verify
      Result.ok
    end

    private

    def http_get(url, headers: {}, basic_auth: nil)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req.basic_auth(*basic_auth) if basic_auth
      headers.each { |k, v| req[k] = v }

      http.request(req)
    end

    def cfg(key)
      @config[key].presence
    end

    # HTTP status families that no retry will fix (auth, malformed request,
    # forbidden). 429 + 5xx are transient.
    def permanent_status?(code)
      code = code.to_i
      (code == 400 || code == 401 || code == 403 || code == 404 || code == 422)
    end

    # POST a JSON body and hand the parsed response back. Network errors raise so
    # the adapter can map them to a transient Result.
    def post_json(url, body:, headers: {})
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      headers.each { |k, v| req[k] = v }
      req.body = JSON.generate(body)

      http.request(req)
    end

    # POST a form-encoded body (Mailgun). Supports HTTP basic auth.
    def post_form(url, form:, basic_auth: nil, headers: {})
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.request_uri)
      req.basic_auth(*basic_auth) if basic_auth
      headers.each { |k, v| req[k] = v }
      req.set_form_data(form)

      http.request(req)
    end

    def parse_json(response)
      body = response.body.to_s
      body.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end
end
