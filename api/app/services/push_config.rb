# Cloud-push runtime config. In dev these point at a Tailscale Funnel hostname; in
# prod the real domain. The desktop engine fetches these via GET /channel-push-subscriptions/config
# so it can build the Gmail watch topicName and the Microsoft notificationUrl.
# See docs/Cloud-Push.md.
module PushConfig
  module_function

  GMAIL_WEBHOOK_PATH = "/api/v1/push/gmail".freeze
  MICROSOFT_WEBHOOK_PATH = "/api/v1/push/microsoft".freeze

  # Public HTTPS base that providers POST webhooks to (e.g. https://host.tailnet.ts.net).
  def webhook_base_url
    ENV["PUSH_WEBHOOK_BASE_URL"].presence
  end

  # Cloud Pub/Sub topic the Gmail watch publishes to (projects/<proj>/topics/<topic>).
  def gmail_topic
    ENV["GMAIL_PUBSUB_TOPIC"].presence
  end

  # Shared verification token appended to the Pub/Sub push subscription URL (?token=...).
  # When unset (dev/test), the Gmail webhook accepts unverified requests.
  def gmail_verification_token
    ENV["GMAIL_PUBSUB_VERIFICATION_TOKEN"].presence
  end

  # Service-account email expected in the Pub/Sub OIDC push token (TODO 45.6).
  # When unset, the OIDC layer is skipped (dev/test).
  def gmail_push_service_account
    ENV["GMAIL_PUBSUB_SERVICE_ACCOUNT"].presence
  end

  # The `aud` claim Pub/Sub stamps into the OIDC token — our Gmail webhook URL
  # unless overridden (the subscription can pin a custom audience).
  def gmail_push_audience
    ENV["GMAIL_PUBSUB_AUDIENCE"].presence ||
      (webhook_base_url && "#{webhook_base_url.chomp('/')}#{GMAIL_WEBHOOK_PATH}")
  end

  def microsoft_notification_url
    return nil unless webhook_base_url
    "#{webhook_base_url.chomp('/')}#{MICROSOFT_WEBHOOK_PATH}"
  end

  # Push is wired up only when we have a public webhook base for providers to reach.
  def configured?
    webhook_base_url.present?
  end
end
