# Mobile-push runtime config (APNs token auth + FCM HTTP v1), env-driven like
# PushConfig. Each platform is independently optional: with neither configured
# every send path no-ops, so the feature is dormant until the secrets land.
# See docs/Cloud-Push.md "Mobile push".
module MobilePushConfig
  module_function

  APNS_DEFAULT_TOPIC = "com.inbox2.ios".freeze

  # The APNs Auth Key (.p8 PEM). Env vars can't hold newlines comfortably, so
  # the value may be \n-escaped; unescape on read.
  def apns_key_p8
    ENV["APNS_KEY_P8"].presence&.gsub('\n', "\n")
  end

  def apns_key_id
    ENV["APNS_KEY_ID"].presence
  end

  # Optional sandbox-specific key: portal keys can be restricted to a single
  # APNs environment, so a production-only key needs a sandbox sibling for
  # dev builds. Falls back to the main key — a single sandbox+production key
  # needs only APNS_KEY_P8/APNS_KEY_ID.
  def apns_sandbox_key_p8
    ENV["APNS_SANDBOX_KEY_P8"].presence&.gsub('\n', "\n") || apns_key_p8
  end

  def apns_sandbox_key_id
    ENV["APNS_SANDBOX_KEY_ID"].presence || apns_key_id
  end

  def apns_team_id
    ENV["APNS_TEAM_ID"].presence
  end

  # The app bundle id the alert/background pushes target.
  def apns_topic
    ENV["APNS_TOPIC"].presence || APNS_DEFAULT_TOPIC
  end

  # Service-account JSON for FCM v1 sends (the whole file, as one env value).
  def fcm_service_account_json
    ENV["FCM_SERVICE_ACCOUNT_JSON"].presence
  end

  def fcm_project_id
    ENV["FCM_PROJECT_ID"].presence || fcm_project_id_from_json
  end

  def apns_configured?
    apns_key_p8.present? && apns_key_id.present? && apns_team_id.present?
  end

  def fcm_configured?
    fcm_service_account_json.present? && fcm_project_id.present?
  end

  def configured?
    apns_configured? || fcm_configured?
  end

  def fcm_project_id_from_json
    json = fcm_service_account_json
    return nil unless json
    JSON.parse(json)["project_id"].presence
  rescue JSON::ParserError
    nil
  end
end
