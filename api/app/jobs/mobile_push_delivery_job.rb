# Delivers one mobile push to one device. Transient transport failures retry
# with backoff (OutboundDeliveryJob pattern); a dead token (uninstalled app)
# deletes the device row and never retries — re-registering recreates it.
class MobilePushDeliveryJob < ApplicationJob
  class TransientDeliveryError < StandardError; end

  queue_as :default

  retry_on TransientDeliveryError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(push_device_id, spec)
    device = PushDevice.find_by(id: push_device_id)
    return unless device # token deregistered/pruned since enqueue
    return unless device.user&.push_enabled?

    live = spec["kind"] == MobilePushSender::KIND_LIVE_ACTIVITY
    result =
      if live then deliver_live_activity(device, spec)
      elsif device.ios? then deliver_apns(device, spec)
      else deliver_fcm(device, spec)
      end
    return if result.nil? || result.ok?

    if result.unregistered? && live
      # A dead ACTIVITY token (the card ended/was dismissed before the app
      # could tell us) — not a dead device. Forget the token; the next push
      # starts a fresh card.
      device.update(live_activity_token: nil)
    elsif result.unregistered?
      device.destroy
      Rails.logger.info("[MobilePushDeliveryJob] removed dead #{device.platform} token #{device.key}")
    elsif result.transient?
      raise TransientDeliveryError, "#{device.platform} #{result.status} #{result.reason}"
    else
      Rails.logger.warn("[MobilePushDeliveryJob] permanent failure for #{device.key}: #{result.status} #{result.reason}")
    end
  end

  private

  # nil = platform not configured: no-op quietly (the other platform may be live).
  def deliver_apns(device, spec)
    return nil unless MobilePushConfig.apns_configured?
    # Stamp the absolute app-icon badge per device (domain unread + the device's
    # reported channel unread) so a closed app shows the right count. FCM has no
    # app-icon badge, so this rides the APNs path only.
    badge_spec = spec.merge("badge" => MobilePushSender.badge_count(device))
    ApnsClient.deliver(
      token: device.token,
      environment: device.environment,
      headers: MobilePushPayloadBuilder.apns_headers(badge_spec),
      body: MobilePushPayloadBuilder.apns_body(badge_spec)
    )
  end

  # Update the running card when the device has one, else push-to-start. An
  # update that bounces off a dead activity token (card gone, never reported)
  # forgets the token and starts a fresh card in the same run.
  def deliver_live_activity(device, spec)
    return nil unless device.ios? && MobilePushConfig.apns_configured?
    if device.live_activity_token.present?
      result = send_live_activity(device, spec, device.live_activity_token, "update")
      return result unless result.unregistered? && device.live_activity_start_token.present?
      device.update(live_activity_token: nil)
    end
    return nil if device.live_activity_start_token.blank?
    send_live_activity(device, spec, device.live_activity_start_token, "start")
  end

  def send_live_activity(device, spec, token, event)
    ApnsClient.deliver(
      token: token,
      environment: device.environment,
      headers: MobilePushPayloadBuilder.apns_live_activity_headers,
      body: MobilePushPayloadBuilder.apns_live_activity_body(spec, event: event, unread: MobilePushSender.badge_count(device))
    )
  end

  def deliver_fcm(device, spec)
    return nil unless MobilePushConfig.fcm_configured?
    # Badge refreshes are APNs-only: Android has no app-icon badge here (its
    # launcher badge follows the notification tray), so the push would wake the
    # device to do nothing.
    return nil if spec["kind"] == MobilePushSender::KIND_BADGE
    FcmClient.deliver(message: MobilePushPayloadBuilder.fcm_message(spec, token: device.token))
  end
end
