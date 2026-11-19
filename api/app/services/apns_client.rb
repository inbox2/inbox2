# Thin wrapper around Apnotic for APNs deliveries. Maintains one HTTP/2
# connection pool per APNs environment (debug builds register sandbox tokens,
# which the production gateway rejects as BadDeviceToken — they're separate
# worlds). Token (p8) auth: Apnotic signs and refreshes the JWT itself.
class ApnsClient
  Result = Struct.new(:ok, :status, :reason) do
    def ok? = ok

    # The token is dead (uninstalled app / wrong env): delete the device row.
    def unregistered?
      status == 410 || %w[BadDeviceToken Unregistered].include?(reason)
    end

    # Worth retrying: APNs hiccup, throttling, or connection trouble.
    def transient?
      return false if ok? || unregistered?
      status.nil? || status == 429 || status >= 500
    end
  end

  POOL_SIZE = 2

  # Apnotic knows content-state/timestamp/event but not the two push-to-start
  # keys; add them on the aps dictionary it assembles.
  class Notification < Apnotic::Notification
    attr_accessor :attributes_type, :attributes

    private

    def aps
      super.tap do |result|
        result["attributes-type"] = attributes_type if attributes_type
        result["attributes"] = attributes if attributes
      end
    end
  end

  class << self
    def deliver(token:, environment:, headers:, body:)
      pool = pool_for(environment)
      notification = build_notification(token, headers, body)

      response = nil
      pool.with { |connection| response = connection.push(notification) }
      return Result.new(false, nil, "timeout") unless response

      reason = response.body.is_a?(Hash) ? response.body["reason"] : nil
      Result.new(response.ok?, response.status.to_i, reason)
    rescue StandardError => e
      Result.new(false, nil, e.message)
    end

    # Drop the memoized pools (used by tests; also lets a config rotation
    # take effect without a process restart).
    def reset!
      @pools&.each_value(&:shutdown)
      @pools = nil
    end

    private

    # Translate the canonical payload (MobilePushPayloadBuilder.apns_body /
    # apns_headers) onto Apnotic's accessors — it assembles `aps` itself.
    def build_notification(token, headers, body)
      notification = Notification.new(token)
      notification.topic = headers["apns-topic"]
      notification.apns_collapse_id = headers["apns-collapse-id"]
      notification.priority = headers["apns-priority"]
      notification.push_type = headers["apns-push-type"]

      aps = body["aps"] || {}
      if aps["content-available"]
        notification.content_available = 1
      end
      if (alert = aps["alert"])
        notification.alert = alert
        notification.sound = aps["sound"]
        notification.thread_id = aps["thread-id"]
        notification.category = aps["category"]
      end
      if aps["content-state"]
        notification.content_state = aps["content-state"]
        notification.timestamp = aps["timestamp"]
        notification.event = aps["event"]
        notification.attributes_type = aps["attributes-type"]
        notification.attributes = aps["attributes"]
      end
      custom = body.except("aps")
      notification.custom_payload = custom if custom.any?
      notification
    end

    def pool_for(environment)
      @pools ||= {}
      @pools[environment] ||= begin
        sandbox = environment == PushDevice::ENV_SANDBOX
        options = {
          auth_method: :token,
          cert_path: StringIO.new(sandbox ? MobilePushConfig.apns_sandbox_key_p8 : MobilePushConfig.apns_key_p8),
          key_id: sandbox ? MobilePushConfig.apns_sandbox_key_id : MobilePushConfig.apns_key_id,
          team_id: MobilePushConfig.apns_team_id
        }
        # Apnotic requires a setup block; use it to log connection-level errors
        # (socket death etc. — request-level errors come back as responses).
        on_error = proc do |connection|
          connection.on(:error) do |e|
            Rails.logger.warn("[ApnsClient] #{environment} connection error: #{e.message}")
          end
        end
        if environment == PushDevice::ENV_SANDBOX
          Apnotic::ConnectionPool.development(options, size: POOL_SIZE, &on_error)
        else
          Apnotic::ConnectionPool.new(options, size: POOL_SIZE, &on_error)
        end
      end
    end
  end
end
