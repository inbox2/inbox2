class WidgetConfig < ApplicationRecord
  key_prefix "wgt"

  STATUSES = %w[active disabled].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_DISABLED = "disabled".freeze

  belongs_to :organization

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :widget_token, presence: true, uniqueness: true

  before_validation :generate_widget_token, on: :create

  def domain_allowed?(origin)
    return true if allowed_domains.blank?

    host = begin
      URI.parse(origin).host
    rescue URI::InvalidURIError
      nil
    end
    return false unless host

    allowed_domains.split("\n").map(&:strip).reject(&:blank?).any? do |domain|
      host == domain || host.end_with?(".#{domain}")
    end
  end

  private

  def generate_widget_token
    self.widget_token ||= "wt_#{SecureRandom.hex(24)}"
  end
end
