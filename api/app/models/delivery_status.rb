class DeliveryStatus < ApplicationRecord
  key_prefix "ds"

  STATUSES = %w[queued sending delivered failed bounced deferred].freeze
  STATUS_QUEUED = "queued".freeze
  STATUS_DELIVERED = "delivered".freeze
  STATUS_FAILED = "failed".freeze
  STATUS_BOUNCED = "bounced".freeze
  STATUS_SENDING = "sending".freeze
  STATUS_DEFERRED = "deferred".freeze

  # A row is ONE destination of the message: a recipient domain for the builtin
  # MTA (one MX lookup, one connection, one envelope) or the ESP itself for a
  # BYO-ESP channel, which fans out to every domain on its own. See the
  # AddDestinationsToDeliveryStatuses migration for why the split exists.
  DESTINATION_ESP_PREFIX = "esp:".freeze

  belongs_to :message
  belongs_to :delivery_channel, optional: true
  has_many :delivery_attempts, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  # Every failed/bounced transition routes through here (retry exhaustion, DSN
  # bounce, all-recipients-suppressed…), so the notification hook lives on the
  # model instead of each call site. Only fires on FIRST entry into a terminal
  # failure state — a later failed→bounced upgrade (a DSN arriving after retries
  # ran out) doesn't re-notify.
  FAILURE_STATUSES = [STATUS_FAILED, STATUS_BOUNCED].freeze
  after_update :notify_failure, if: -> {
    saved_change_to_status? &&
      FAILURE_STATUSES.include?(status) &&
      !FAILURE_STATUSES.include?(saved_change_to_status.first)
  }

  # The envelope this row owns — bare addr-specs.
  def recipient_list
    recipients.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def recipient_list=(addrs)
    self.recipients = Array(addrs).join(", ")
  end

  # True once the job actually reached NATS (or the ESP). A row that exists but
  # was never published is a FAILED publish, not a send in flight — the delivery
  # job re-publishes those instead of treating the row's presence as "done".
  def published?
    published_at.present?
  end

  def covers?(address)
    addr = address.to_s.downcase.strip
    return false if addr.blank?

    recipient_list.any? { |a| a.downcase == addr }
  end

  private

  def notify_failure
    DeliveryFailureNotifier.call(self)
  end
end
