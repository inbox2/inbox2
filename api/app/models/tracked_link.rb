# One rewritten link in a tracked outbound message (docs/Open-Tracking.md). The
# <a href> was replaced with GET /l/<token>, which records a LinkClick then 302s
# to `url`. Grouped to its message by message_tracking_token (shared with the
# open-tracking pixel token). One row per unique URL per message.
class TrackedLink < ApplicationRecord
  key_prefix "tl"

  belongs_to :organization, optional: true
  # Clicks correlated by the capability token (the redirect endpoint holds only it).
  has_many :clicks, -> { order(clicked_at: :asc) }, class_name: "LinkClick",
    primary_key: :token, foreign_key: :token, dependent: :destroy, inverse_of: false

  validates :token, :message_tracking_token, :url, presence: true

  # Stable token for a (message, url) pair so re-composing/retrying a send — or the
  # same URL appearing twice — reuses one row (clicks aggregate per unique link).
  def self.for(message_tracking_token:, url:, organization_id: nil)
    find_or_create_by!(message_tracking_token: message_tracking_token, url: url) do |link|
      link.token = Tracking.token
      link.organization_id = organization_id
    end
  end
end
