# Meta webhook relay runtime config — see docs/Cloud-Push.md (Meta).
#
# BYOK customers point their own Meta app's webhook callback at our single public URL
# (`<base>/api/v1/push/meta`) and set its verify token to ours. The verify token only
# authenticates the subscription handshake; real per-tenant authenticity is the
# X-Hub-Signature-256 HMAC, verified ON-DEVICE against each customer's app_secret.
module MetaConfig
  module_function

  WEBHOOK_PATH = "/api/v1/push/meta".freeze

  # Shared verify token echoed during the GET subscription handshake. When unset
  # (dev/test) the handshake is accepted without a token (mirrors GmailPushVerifier).
  def verify_token
    ENV["META_WEBHOOK_VERIFY_TOKEN"].presence
  end

  # Public HTTPS base providers POST to (reuses the cloud-push tunnel/base).
  def webhook_base_url
    PushConfig.webhook_base_url
  end

  def notification_url
    return nil unless webhook_base_url
    "#{webhook_base_url.chomp('/')}#{WEBHOOK_PATH}"
  end
end
