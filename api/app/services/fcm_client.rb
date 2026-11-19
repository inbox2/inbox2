# FCM HTTP v1 sender. Auth is a service-account OAuth token (googleauth caches
# and refreshes it); transport is plain Net::HTTP — FCM speaks HTTP/1.1 fine.
class FcmClient
  Result = Struct.new(:ok, :status, :reason) do
    def ok? = ok

    # Token no longer valid (app uninstalled / data cleared): delete the row.
    def unregistered?
      reason == "UNREGISTERED" || status == 404
    end

    def transient?
      return false if ok? || unregistered?
      status.nil? || status == 429 || (status && status >= 500)
    end
  end

  SCOPE = "https://www.googleapis.com/auth/firebase.messaging".freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  class << self
    def deliver(message:)
      uri = URI("https://fcm.googleapis.com/v1/projects/#{MobilePushConfig.fcm_project_id}/messages:send")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(message)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end

      status = response.code.to_i
      Result.new(status == 200, status, error_code(response))
    rescue StandardError => e
      Result.new(false, nil, e.message)
    end

    def reset!
      @credentials = nil
    end

    private

    def access_token
      @credentials ||= Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(MobilePushConfig.fcm_service_account_json),
        scope: SCOPE
      )
      # Fresh credentials have no token yet (and expires_within? is false on
      # them) — fetch on first use, then refresh shortly before expiry.
      if @credentials.access_token.nil? || @credentials.expires_within?(60)
        @credentials.fetch_access_token!
      end
      @credentials.access_token
    end

    # FCM error details carry a stable errorCode (e.g. UNREGISTERED) — dig it
    # out of the v1 error envelope; fall back to the top-level status string.
    def error_code(response)
      return nil if response.code.to_i == 200
      body = JSON.parse(response.body)
      details = body.dig("error", "details") || []
      fcm_error = details.find { |d| d["@type"].to_s.include?("FcmError") }
      fcm_error&.dig("errorCode") || body.dig("error", "status")
    rescue JSON::ParserError
      nil
    end
  end
end
