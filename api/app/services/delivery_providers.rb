# Customer-owned ESP transports for outbound mail. When an org configures a
# custom deliverability provider (see DeliveryChannel / DeliverabilityController),
# OutboundMailPublisher hands the composed message to the matching adapter here
# instead of publishing to NATS for the inbox2 Go MTA.
#
# Each adapter speaks one provider's HTTP API (or raw SMTP for `smtp_relay`),
# consuming whichever representation that API wants from the Context: the fully
# composed RFC 5322 MIME (SES / Mailgun / SMTP) or the structured fields
# (SendGrid / Postmark / Messy). Adapters are stateless wrappers around the
# channel's `config` jsonb.
module DeliveryProviders
  # Outcome of one delivery attempt against a provider.
  #   accepted  — the ESP took the message for delivery (a provider message id is
  #               usually returned); we treat this as "delivered" since we have no
  #               webhook feedback loop yet.
  #   permanent — set on a rejection that retrying won't fix (bad credentials,
  #               unverified sender, malformed request) so the publisher fails
  #               fast instead of backing off five times.
  Result = Struct.new(:accepted, :provider_message_id, :error, :permanent, keyword_init: true) do
    def accepted?
      !!accepted
    end

    def permanent?
      !!permanent
    end

    def self.ok(provider_message_id = nil)
      new(accepted: true, provider_message_id: provider_message_id)
    end

    def self.transient(error)
      new(accepted: false, error: error, permanent: false)
    end

    def self.permanent_failure(error)
      new(accepted: false, error: error, permanent: true)
    end
  end

  # Everything an adapter might need to transmit one message. `to`/`cc`/`bcc` are arrays
  # of bare addr-specs; `raw_mime` is the publisher-composed RFC 5322 string.
  Context = Struct.new(
    :from, :to, :cc, :bcc, :subject, :text_body, :html_body, :raw_mime, :headers,
    keyword_init: true
  )

  # Single source of truth for the UI: the provider picker (label + icon) and the
  # credential form (field list). `icon` is a key the web app maps to a brand
  # mark; `secret` fields are write-only — redacted on read, only re-sent when the
  # user types a new value. Keep this in sync with the web EspIcon map.
  CATALOG = {
    DeliveryChannel::KIND_SES => {
      label: "Amazon SES",
      icon: "ses",
      blurb: "Send through your AWS account's Simple Email Service.",
      fields: [
        { key: "access_key_id", label: "Access key ID", type: "text", required: true },
        { key: "secret_access_key", label: "Secret access key", type: "password", secret: true, required: true },
        { key: "region", label: "Region", type: "select", required: true, default: "us-east-1",
          options: %w[us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-west-2 eu-central-1 eu-north-1 ap-south-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ca-central-1 sa-east-1] }
      ]
    },
    DeliveryChannel::KIND_SENDGRID => {
      label: "SendGrid",
      icon: "sendgrid",
      blurb: "Twilio SendGrid Web API v3.",
      fields: [
        { key: "api_key", label: "API key", type: "password", secret: true, required: true, placeholder: "SG.xxxxxxxx" }
      ]
    },
    DeliveryChannel::KIND_MAILGUN => {
      label: "Mailgun",
      icon: "mailgun",
      blurb: "Mailgun Messages API. Use the sending domain you verified in Mailgun.",
      fields: [
        { key: "api_key", label: "API key", type: "password", secret: true, required: true, placeholder: "key-xxxxxxxx" },
        { key: "domain", label: "Sending domain", type: "text", required: true, placeholder: "mg.example.com" },
        { key: "region", label: "Region", type: "select", required: true, default: "us", options: %w[us eu] }
      ]
    },
    DeliveryChannel::KIND_POSTMARK => {
      label: "Postmark",
      icon: "postmark",
      blurb: "Postmark transactional email API.",
      fields: [
        { key: "server_token", label: "Server token", type: "password", secret: true, required: true },
        { key: "message_stream", label: "Message stream", type: "text", required: false, default: "outbound", placeholder: "outbound" }
      ]
    },
    DeliveryChannel::KIND_MESSY => {
      label: "Messy",
      icon: "messy",
      blurb: "Send through your Messy account (api.messy.sh). The from-identity is set on the Messy side.",
      fields: [
        { key: "api_key", label: "API key", type: "password", secret: true, required: true },
        { key: "base_url", label: "API URL", type: "text", required: false, placeholder: "https://api.messy.sh" }
      ]
    },
    DeliveryChannel::KIND_SMTP_RELAY => {
      label: "Custom SMTP",
      icon: "smtp",
      blurb: "Any other provider — relay over plain SMTP with your own credentials.",
      fields: [
        { key: "host", label: "Host", type: "text", required: true, placeholder: "smtp.example.com" },
        { key: "port", label: "Port", type: "text", required: true, default: "587" },
        { key: "username", label: "Username", type: "text", required: false },
        { key: "password", label: "Password", type: "password", secret: true, required: false },
        { key: "security", label: "Security", type: "select", required: true, default: "starttls", options: %w[starttls tls none] }
      ]
    }
  }.freeze

  REGISTRY = {
    DeliveryChannel::KIND_SES => "DeliveryProviders::Ses",
    DeliveryChannel::KIND_SENDGRID => "DeliveryProviders::Sendgrid",
    DeliveryChannel::KIND_MAILGUN => "DeliveryProviders::Mailgun",
    DeliveryChannel::KIND_POSTMARK => "DeliveryProviders::Postmark",
    DeliveryChannel::KIND_MESSY => "DeliveryProviders::Messy",
    DeliveryChannel::KIND_SMTP_RELAY => "DeliveryProviders::Smtp"
  }.freeze

  # The fields the UI must never read back. Used by the serializer to redact and
  # by the controller to skip blank (untouched) secrets on update.
  def self.secret_fields(kind)
    (CATALOG.dig(kind, :fields) || []).select { |f| f[:secret] }.map { |f| f[:key] }
  end

  def self.field_keys(kind)
    (CATALOG.dig(kind, :fields) || []).map { |f| f[:key] }
  end

  def self.label_for(kind)
    return "Inbox2 Deliverability" if kind == DeliveryChannel::KIND_BUILTIN

    CATALOG.dig(kind, :label) || kind.to_s.titleize
  end

  def self.for(channel)
    class_name = REGISTRY.fetch(channel.kind) do
      raise ArgumentError, "no delivery provider for kind=#{channel.kind.inspect}"
    end
    class_name.constantize.new(channel)
  end
end
