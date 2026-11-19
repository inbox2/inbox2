# Parses DSN (Delivery Status Notification) bounce messages per RFC 3464 (spec 18.4.3)
# Extracts bounce type, status code, and diagnostic from DSN reports.
class DsnBounceParser
  BOUNCE_TYPES = %w[hard soft transient].freeze
  BOUNCE_HARD = "hard".freeze
  BOUNCE_SOFT = "soft".freeze
  BOUNCE_TRANSIENT = "transient".freeze

  # DSN status code classes
  PERMANENT_FAILURE = "5".freeze
  TRANSIENT_FAILURE = "4".freeze
  SUCCESS = "2".freeze

  def initialize(dsn_content)
    @content = dsn_content.to_s
  end

  def parse
    status_code = extract_status_code
    diagnostic = extract_diagnostic
    original_recipient = extract_original_recipient
    reporting_mta = extract_field("Reporting-MTA")

    {
      bounce_type: classify_bounce(status_code),
      dsn_code: status_code,
      diagnostic: diagnostic,
      original_recipient: original_recipient,
      reporting_mta: reporting_mta
    }
  end

  def update_delivery_status!(delivery_status)
    result = parse
    delivery_status.update!(
      status: result[:bounce_type] == BOUNCE_HARD ? DeliveryStatus::STATUS_BOUNCED : DeliveryStatus::STATUS_FAILED,
      dsn_code: result[:dsn_code],
      dsn_diagnostic: result[:diagnostic],
      bounce_type: result[:bounce_type]
    )
    result
  end

  private

  def extract_status_code
    @content.match(/Status:\s*(\d\.\d\.\d)/i)&.captures&.first || extract_smtp_code
  end

  def extract_smtp_code
    match = @content.match(/(\d{3})\s/)
    return nil unless match

    code = match[1]
    "#{code[0]}.#{code[1]}.#{code[2]}"
  end

  def extract_diagnostic
    @content.match(/Diagnostic-Code:\s*smtp;\s*(.+)/i)&.captures&.first&.strip ||
      @content.match(/Action:\s*(\w+)/i)&.captures&.first
  end

  def extract_original_recipient
    @content.match(/Original-Recipient:\s*rfc822;\s*(.+)/i)&.captures&.first&.strip ||
      @content.match(/Final-Recipient:\s*rfc822;\s*(.+)/i)&.captures&.first&.strip
  end

  def extract_field(field_name)
    @content.match(/#{field_name}:\s*dns;\s*(.+)/i)&.captures&.first&.strip
  end

  def classify_bounce(status_code)
    return BOUNCE_HARD unless status_code

    case status_code[0]
    when PERMANENT_FAILURE then BOUNCE_HARD
    when TRANSIENT_FAILURE then BOUNCE_TRANSIENT
    else BOUNCE_SOFT
    end
  end
end
