# Delivers browser push notifications via the Web Push protocol (spec 10.4)
# Requires VAPID keys configured in Rails credentials.
class WebPushService
  def initialize(user)
    @user = user
  end

  def notify(title:, body:, url: nil, tag: nil)
    payload = {
      title: title,
      body: body,
      url: url,
      tag: tag,
      timestamp: Time.current.iso8601
    }.compact.to_json

    @user.push_subscriptions.find_each do |sub|
      deliver(sub, payload)
    end
  end

  private

  def deliver(subscription, payload)
    # Web Push delivery — requires web-push gem in production
    # Stub: logs the push for now, would use WebPush.payload_send in production
    Rails.logger.info(
      "[WebPush] Delivering to #{subscription.endpoint}: #{payload.truncate(100)}"
    )
  rescue => e
    Rails.logger.error("[WebPush] Failed: #{e.message}")
    subscription.destroy if expired_subscription?(e)
  end

  def expired_subscription?(error)
    error.respond_to?(:response) && error.response&.code.to_i == 410
  end
end
