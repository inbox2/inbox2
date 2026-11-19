# A member's Google/Microsoft OAuth grant for generating meeting links at
# accept time (docs/Calendar.md). Deliberately narrow scopes — this can create
# Meet spaces / Teams meetings and nothing else — and read only when a meeting
# request is accepted.
class ConferencingConnection < ApplicationRecord
  key_prefix "cfc"

  # Standalone-meeting scopes: Meet REST API spaces.create, Graph onlineMeetings.
  # Neither touches mail or calendars.
  # The email/User.Read halves exist only so the Settings card can show which
  # account is connected.
  SCOPES = {
    OauthProvider::GOOGLE => "https://www.googleapis.com/auth/meetings.space.created email",
    OauthProvider::MICROSOFT => "OnlineMeetings.ReadWrite User.Read offline_access"
  }.freeze

  belongs_to :membership

  encrypts :refresh_token

  validates :provider, inclusion: { in: OauthProvider::PROVIDERS }, uniqueness: { scope: :membership_id }
  validates :refresh_token, presence: true

  def scopes = SCOPES.fetch(provider)
end
