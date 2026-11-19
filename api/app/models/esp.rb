# The ESP: mail an application sends through the API (docs/ESP.md). Models live
# under Esp:: and map to the esp_* tables. Nothing here touches conversations.
module Esp
  def self.table_name_prefix = "esp_"

  # Envelope sender domain. Every delivery goes out from b+<token>@ this
  # domain, so a bounce comes back to our MX and names its delivery.
  BOUNCE_DOMAIN = ENV.fetch("ESP_BOUNCE_DOMAIN", "bounces.#{DnsRecordsSerializer::MAIL_DOMAIN}").downcase.freeze
  BOUNCE_LOCAL_PREFIX = "b+".freeze

  MAX_RECIPIENTS = 50
  MAX_MESSAGE_BYTES = 10 * 1024 * 1024
  # The stored message is dropped after this long; the log row stays.
  BODY_RETENTION = 30.days

  def self.bounce_address?(address)
    address.to_s.downcase.end_with?("@#{BOUNCE_DOMAIN}")
  end

  # A send the API refuses, with the HTTP status to answer with.
  class Refused < StandardError
    attr_reader :status

    def initialize(message, status: 422)
      super(message)
      @status = status
    end
  end
end
