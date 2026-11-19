# Pure spec → wire-payload mapping for mobile push. The "spec" hash comes from
# MobilePushSender; these functions turn it into APNs headers/body and an FCM v1
# message without touching the network (so they're trivially unit-testable).
module MobilePushPayloadBuilder
  module_function

  # UNNotificationCategory the iOS app registers with Archive / Trash / Mark as
  # read buttons (NotificationManager.mailCategory). Stamped on every visible
  # new-message alert so a remote push gets the same buttons as a local one.
  APNS_MAIL_CATEGORY = "MAIL".freeze
  # Sign-in mail swaps Read for Copy & delete / Open & delete
  # (NotificationManager's OTP categories, docs/Notifications.md).
  APNS_OTP_CODE_CATEGORY = "OTP_CODE".freeze
  APNS_OTP_LINK_CATEGORY = "OTP_LINK".freeze

  # A badge-only refresh has no alert, but it is NOT a background push: it
  # changes something the user sees, so it belongs on the alert lane where APNs
  # delivers it promptly instead of throttling it like a wake-to-sync.
  def badge_only?(spec)
    spec["kind"] == MobilePushSender::KIND_BADGE
  end

  # APNs request headers. Silent syncs ride the background lane (priority 5 is
  # mandatory for apns-push-type background); alerts go out at full priority.
  def apns_headers(spec)
    silent = spec["alert"].nil? && !badge_only?(spec)
    headers = {
      "apns-push-type" => silent ? "background" : "alert",
      "apns-priority" => silent ? "5" : "10",
      "apns-topic" => MobilePushConfig.apns_topic
    }
    headers["apns-collapse-id"] = spec["collapse_id"] if spec["collapse_id"].present?
    headers
  end

  def apns_body(spec)
    aps =
      if badge_only?(spec)
        # Nothing but the badge merged in below — no alert (so no banner) and no
        # content-available (nothing for the app to fetch).
        {}
      elsif spec["alert"].nil?
        { "content-available" => 1 }
      else
        {
          "alert" => { "title" => spec["alert"]["title"], "body" => spec["alert"]["body"] },
          "sound" => "default"
        }.tap do |a|
          a["thread-id"] = spec["thread_id"] if spec["thread_id"].present?
          a["category"] = mail_category(spec["data"] || {}) if spec["kind"] == MobilePushSender::KIND_NEW_MESSAGE
        end
      end
    # Absolute app-icon badge (set even at 0, which clears it). Rides both alert
    # and silent pushes so the count stays right while the app is closed.
    aps["badge"] = spec["badge"] unless spec["badge"].nil?
    { "aps" => aps }.merge(spec["data"] || {})
  end

  def mail_category(data)
    return APNS_OTP_CODE_CATEGORY if data["otp_code"].present?
    return APNS_OTP_LINK_CATEGORY if data["otp_link"].present?
    APNS_MAIL_CATEGORY
  end

  # FCM v1 message. Silent syncs are data-only (no `notification` key — that
  # guarantees no system-tray entry; the app decides what to show after it
  # syncs). priority HIGH is required for delivery in Doze.
  # ActivityKit push (docs/Cloud-Push.md "Live Activity"). `event` is decided per
  # device by the delivery job: "update" to a running activity's token, "start"
  # (push-to-start, which also needs the attributes type) otherwise. The
  # `alert` is what iOS shows on the lock screen/Watch for a start; a running
  # card just re-renders. `unread` rides content-state so the card's "+N" matches
  # the app-icon badge.
  def apns_live_activity_headers
    {
      "apns-push-type" => "liveactivity",
      "apns-priority" => "10",
      "apns-topic" => "#{MobilePushConfig.apns_topic}.push-type.liveactivity"
    }
  end

  def apns_live_activity_body(spec, event:, unread:, now: Time.current)
    state = (spec["content_state"] || {}).merge("unread" => unread.to_i, "receivedAt" => now.to_f)
    aps = { "timestamp" => now.to_i, "event" => event, "content-state" => state }
    if event == "start"
      aps["attributes-type"] = LIVE_ACTIVITY_ATTRIBUTES_TYPE
      aps["attributes"] = {}
      aps["alert"] = { "title" => state["sender"], "body" => state["subject"] }
    end
    { "aps" => aps }
  end

  # The Swift ActivityAttributes type name — must match the app exactly.
  LIVE_ACTIVITY_ATTRIBUTES_TYPE = "MailActivityAttributes".freeze

  # Always data-only: a `notification` message is rendered by the system while the
  # app is backgrounded — no action buttons, no ongoing card — so a visible push
  # ships its title/body in the data map and the app posts the tray notification
  # itself (NotificationHelper), exactly like channel mail.
  def fcm_message(spec, token:)
    data = (spec["data"] || {}).transform_values(&:to_s)
    if spec["alert"]
      data["title"] = spec["alert"]["title"].to_s
      data["body"] = spec["alert"]["body"].to_s
    end
    message = { "token" => token, "data" => data, "android" => { "priority" => "HIGH" } }
    message["android"]["collapse_key"] = spec["collapse_id"] if spec["collapse_id"].present?
    { "message" => message }
  end
end
