require "mail"

# Mail that arrived at a bounce address (b+<token>@<bounce domain>). A delivery
# report settles the delivery it names; anything else sent there (an
# out-of-office, a reply) is dropped.
class Esp::BounceProcessor
  def initialize(payload)
    @rcpt = Array(payload.dig("envelope", "rcpt_to")).first
    @raw = Base64.decode64(payload["raw_message_b64"].to_s)
  end

  def process
    delivery = Esp::Delivery.for_bounce_address(@rcpt)
    return :unknown unless delivery

    report = Mail.new(@raw).all_parts.find { |p| p.mime_type == "message/delivery-status" }
    return :ignored unless report

    result = DsnBounceParser.new(report.body.decoded).parse
    # A success or delay report changes nothing; only a failure settles it.
    return :ignored unless result[:dsn_code].to_s.start_with?("4", "5")

    delivery.record_bounce!(hard: result[:bounce_type] == DsnBounceParser::BOUNCE_HARD,
      code: result[:dsn_code], diagnostic: result[:diagnostic])
    :bounce
  end
end
