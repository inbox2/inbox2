# One recipient of an API send: its own envelope, its own status, its own
# bounce address. One recipient per SMTP job keeps a retry from mailing
# someone twice.
class Esp::Delivery < ApplicationRecord
  key_prefix "ed"

  STATUS_QUEUED = "queued".freeze
  # A job has taken it for one attempt; the mail queue has it or is about to.
  STATUS_SENDING = "sending".freeze
  STATUS_DELIVERED = "delivered".freeze
  STATUS_DEFERRED = "deferred".freeze
  STATUS_BOUNCED = "bounced".freeze
  STATUS_FAILED = "failed".freeze
  STATUS_COMPLAINED = "complained".freeze
  STATUSES = [STATUS_QUEUED, STATUS_SENDING, STATUS_DELIVERED, STATUS_DEFERRED, STATUS_BOUNCED, STATUS_FAILED, STATUS_COMPLAINED].freeze

  belongs_to :organization
  belongs_to :message, class_name: "Esp::Message", foreign_key: :esp_message_id, inverse_of: :deliveries
  has_many :events, class_name: "Esp::Event", foreign_key: :esp_delivery_id, inverse_of: :delivery, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  before_validation(on: :create) { self.bounce_token ||= SecureRandom.hex(12) }

  # The envelope sender: a bounce to it finds this row (Esp::BounceProcessor).
  def bounce_address
    "#{Esp::BOUNCE_LOCAL_PREFIX}#{bounce_token}@#{Esp::BOUNCE_DOMAIN}"
  end

  def self.for_bounce_address(address)
    local = address.to_s.downcase.split("@").first.to_s
    return nil unless local.start_with?(Esp::BOUNCE_LOCAL_PREFIX)

    find_by(bounce_token: local.delete_prefix(Esp::BOUNCE_LOCAL_PREFIX))
  end

  # Deliveries that are waiting to go out and are on nobody's hands.
  scope :unclaimed, -> { where(status: [STATUS_QUEUED, STATUS_DEFERRED], published_at: nil) }

  # Takes the delivery for one attempt. Only one caller wins, so two jobs for
  # the same delivery (a replayed request, the sweeper) cannot both send it.
  def claim!
    self.class.unclaimed.where(id: id).update_all(status: STATUS_SENDING, updated_at: Time.current) == 1 && reload
  end

  # Gives a claimed delivery back when the publish failed.
  def release!
    self.class.where(id: id, status: STATUS_SENDING, published_at: nil).update_all(status: STATUS_QUEUED, updated_at: Time.current)
  end

  # Claimed, but the job died before the mail queue had it. Safe to take again.
  scope :abandoned, ->(before) { where(status: STATUS_SENDING, published_at: nil, updated_at: ...before) }
  # Published, and no verdict ever came back.
  scope :unanswered, ->(before) { where(status: STATUS_SENDING, published_at: ...before) }

  # The mail queue keeps a job for 72 hours. Past that no verdict can come.
  def expire!
    with_lock do
      settle!(STATUS_FAILED, response: "no result from the mail queue", failed_at: Time.current) if status == STATUS_SENDING
    end
  end

  # The key the Go sender echoes back: the delivery plus which attempt it is.
  def attempt_key = "#{key}:#{attempt_count + 1}"

  # The Go sender's verdict on one attempt (a DeliveryResult from NATS).
  # Returns the retry delay in seconds when the attempt should be repeated.
  # A verdict counts once, and only for the attempt now in flight: a repeated
  # or late one (NATS redelivers) is dropped, so it cannot count an attempt
  # twice, start an extra send, or overwrite a settled delivery.
  def record_result!(attempt:, result:, smtp_code: nil, enhanced_code: nil, response: nil, mx_host: nil)
    with_lock do
      return nil unless status == STATUS_SENDING && attempt.to_i == attempt_count + 1

      apply_result(result, smtp_code, enhanced_code, response, mx_host)
    end
  end

  # A bounce report that arrived later, at the bounce address.
  def record_bounce!(hard:, code:, diagnostic:)
    return if [STATUS_BOUNCED, STATUS_COMPLAINED].include?(status)

    settle!(hard ? STATUS_BOUNCED : STATUS_FAILED, smtp_code: code, response: diagnostic, failed_at: Time.current)
    suppress!(SuppressionEntry::REASON_HARD_BOUNCE, "dsn", diagnostic) if hard
  end

  def record_complaint!(detail)
    return if status == STATUS_COMPLAINED

    settle!(STATUS_COMPLAINED, response: detail)
    suppress!(SuppressionEntry::REASON_COMPLAINT, "arf", detail)
  end

  def refuse_suppressed!
    settle!(STATUS_FAILED, response: "suppressed: this address bounced or complained before", failed_at: Time.current)
  end

  private

  def apply_result(result, smtp_code, enhanced_code, response, mx_host)
    increment!(:attempt_count)
    attrs = { smtp_code: smtp_code.presence, response: response, mx_host: mx_host.presence || self.mx_host }

    case result
    when "success"
      settle!(STATUS_DELIVERED, attrs.merge(delivered_at: Time.current))
    when "permanent_failure"
      settle!(STATUS_BOUNCED, attrs.merge(failed_at: Time.current))
      suppress!(SuppressionEntry::REASON_PERMANENT_FAILURE, "smtp", response) if DeliveryRetryService.bad_address?(smtp_code, enhanced_code)
    else
      if attempt_count < DeliveryRetryService::MAX_RETRIES
        # Back on nobody's hands until the retry job claims it.
        settle!(STATUS_DEFERRED, attrs.merge(published_at: nil))
        return DeliveryRetryService::BASE_DELAY * (2**attempt_count)
      end
      settle!(STATUS_FAILED, attrs.merge(failed_at: Time.current))
    end
    nil
  end

  def settle!(new_status, attrs = {})
    update!(attrs.merge(status: new_status))
    events.create!(organization: organization, message: message, kind: new_status,
      detail: { smtp_code: smtp_code, response: response, mx_host: mx_host, attempt: attempt_count }.compact)
  end

  def suppress!(reason, source, detail)
    SuppressionEntry.record!(organization, recipient, reason: reason, source: source, detail: detail)
  end
end
