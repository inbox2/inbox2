require "net/http"

# Creates a standalone video-meeting URL at accept time (docs/Calendar.md):
# Google Meet via the Meet REST API (spaces.create — no shadow event on the
# member's Google calendar, which the Calendar-API conferenceData route would
# force), Teams via Graph onlineMeetings. Returns the join URL or nil; callers
# must treat nil as "retry later", never as a reason to fail the booking.
class ConferenceLink
  # Which provider mints the link for a given conference mode.
  PROVIDER_FOR_MODE = {
    MeetLink::CONFERENCE_MEET => OauthProvider::GOOGLE,
    MeetLink::CONFERENCE_TEAMS => OauthProvider::MICROSOFT
  }.freeze

  MEET_SPACES_URL = "https://meet.googleapis.com/v2/spaces".freeze
  GRAPH_MEETINGS_URL = "https://graph.microsoft.com/v1.0/me/onlineMeetings".freeze

  def self.generate(connection, subject:, start_at:, end_at:)
    access_token = fresh_access_token(connection)
    return nil if access_token.blank?

    case connection.provider
    when OauthProvider::GOOGLE
      create_meet_space(access_token)
    when OauthProvider::MICROSOFT
      create_teams_meeting(access_token, subject: subject, start_at: start_at, end_at: end_at)
    end
  rescue StandardError => e
    Rails.logger.warn("[ConferenceLink] #{connection.provider} generation failed: #{e.class}: #{e.message}")
    nil
  end

  def self.fresh_access_token(connection)
    tokens = OauthProvider.refresh_tokens(connection.provider, connection.refresh_token, scope: connection.scopes)
    # Microsoft rotates refresh tokens; keep the newest or the next refresh dies.
    if tokens["refresh_token"].present? && tokens["refresh_token"] != connection.refresh_token
      connection.update!(refresh_token: tokens["refresh_token"])
    end
    tokens["access_token"]
  rescue OauthProvider::Error => e
    Rails.logger.warn("[ConferenceLink] token refresh failed: #{e.message}")
    nil
  end
  private_class_method :fresh_access_token

  def self.create_meet_space(access_token)
    response = post_json(MEET_SPACES_URL, access_token, {})
    response&.dig("meetingUri")
  end
  private_class_method :create_meet_space

  def self.create_teams_meeting(access_token, subject:, start_at:, end_at:)
    response = post_json(GRAPH_MEETINGS_URL, access_token, {
      subject: subject,
      startDateTime: start_at.utc.iso8601,
      endDateTime: end_at.utc.iso8601
    })
    response&.dig("joinWebUrl")
  end
  private_class_method :create_teams_meeting

  def self.post_json(url, access_token, payload)
    uri = URI(url)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    request["Content-Type"] = "application/json"
    request.body = payload.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("[ConferenceLink] #{url} → HTTP #{response.code} #{response.body&.first(300)}")
      return nil
    end
    JSON.parse(response.body)
  end
  private_class_method :post_json
end
