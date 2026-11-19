# spec 20.2.3 — Automatic retry with exponential backoff
class DeliveryRetryService
  MAX_RETRIES = 5
  BASE_DELAY = 60 # seconds

  def initialize(delivery_status)
    @delivery_status = delivery_status
  end

  def should_retry?
    @delivery_status.status == DeliveryStatus::STATUS_DEFERRED && @delivery_status.attempt_count < MAX_RETRIES
  end

  def next_retry_delay
    # Exponential backoff: 1min, 2min, 4min, 8min, 16min
    BASE_DELAY * (2 ** @delivery_status.attempt_count)
  end

  def record_attempt(result:, smtp_code: nil, enhanced_code: nil, message: nil)
    @delivery_status.increment!(:attempt_count)

    attempt = @delivery_status.delivery_attempts.create!(
      delivery_channel: @delivery_status.delivery_channel,
      attempt_number: @delivery_status.attempt_count,
      result: result,
      smtp_response_code: smtp_code,
      enhanced_status_code: enhanced_code,
      response_message: message
    )

    case result
    when "success"
      @delivery_status.update!(status: DeliveryStatus::STATUS_DELIVERED, delivered_at: Time.current)
    when "permanent_failure"
      @delivery_status.update!(status: DeliveryStatus::STATUS_FAILED, failed_at: Time.current)
      # Only suppress when the 5xx is about the *address* (5.1.x / 550-553),
      # not a content/policy rejection that's specific to this one message.
      if self.class.bad_address?(smtp_code, enhanced_code)
        suppress_recipients!(SuppressionEntry::REASON_PERMANENT_FAILURE, message)
      end
    when "transient_failure"
      if should_retry?
        # The actual retry is scheduled by the caller (the NATS delivery-status
        # consumer) with next_retry_delay, so a single place owns the timer.
        @delivery_status.update!(status: DeliveryStatus::STATUS_DEFERRED)
      else
        @delivery_status.update!(status: DeliveryStatus::STATUS_FAILED, failed_at: Time.current)
      end
    end

    attempt
  end

  # True when the failure codes point at a dead/unknown mailbox rather than a
  # message-specific rejection. Enhanced status 5.1.x is "Addressing Status";
  # bare SMTP 550/551/553 are the classic "no such user" replies.
  def self.bad_address?(smtp_code, enhanced_code)
    return true if enhanced_code.to_s.start_with?("5.1.")

    %w[550 551 553].include?(smtp_code.to_s)
  end

  private

  # A 5xx (or retry-exhausted) recipient is dead for the foreseeable future;
  # record it so future sends skip it instead of re-bouncing (see SuppressionEntry).
  def suppress_recipients!(reason, detail)
    message = @delivery_status.message
    organization = message&.organization
    return unless organization

    MailHeaderEncoding.bare_addresses(message.to_address).each do |addr|
      SuppressionEntry.record!(organization, addr, reason: reason, source: "smtp", detail: detail)
    end
  rescue => e
    Rails.logger.warn("[DeliveryRetryService] suppression record failed: #{e.message}")
  end
end
