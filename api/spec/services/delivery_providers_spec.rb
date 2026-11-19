require "rails_helper"

# Adapter mapping tests — HTTP/SMTP is stubbed at the adapter's own transport
# helpers so we exercise the response→Result logic without real network calls.
RSpec.describe DeliveryProviders do
  # Minimal stand-in for a Net::HTTPResponse (supports #code, #body, #[]).
  def fake_response(code:, body: "", headers: {})
    instance_double(Net::HTTPResponse).tap do |r|
      allow(r).to receive(:code).and_return(code.to_s)
      allow(r).to receive(:body).and_return(body)
      allow(r).to receive(:[]) { |k| headers[k] }
    end
  end

  let(:context) do
    DeliveryProviders::Context.new(
      from: "support@acme.com",
      to: ["customer@example.com"],
      cc: [],
      subject: "Hello",
      text_body: "Hi there",
      html_body: "<p>Hi there</p>",
      raw_mime: "From: support@acme.com\r\nTo: customer@example.com\r\n\r\nHi",
      headers: {}
    )
  end

  describe ".for" do
    it "maps each custom kind to its adapter" do
      {
        "ses" => DeliveryProviders::Ses,
        "sendgrid" => DeliveryProviders::Sendgrid,
        "mailgun" => DeliveryProviders::Mailgun,
        "postmark" => DeliveryProviders::Postmark,
        "messy" => DeliveryProviders::Messy,
        "smtp_relay" => DeliveryProviders::Smtp
      }.each do |kind, klass|
        expect(DeliveryProviders.for(DeliveryChannel.new(kind: kind))).to be_a(klass)
      end
    end

    it "raises for an unmapped kind" do
      expect { DeliveryProviders.for(DeliveryChannel.new(kind: "builtin")) }.to raise_error(ArgumentError)
    end
  end

  describe ".secret_fields / .field_keys / .label_for" do
    it "identifies secret fields for redaction" do
      expect(DeliveryProviders.secret_fields("sendgrid")).to eq(["api_key"])
      expect(DeliveryProviders.secret_fields("smtp_relay")).to eq(["password"])
    end

    it "labels builtin and providers" do
      expect(DeliveryProviders.label_for("builtin")).to eq("Inbox2 Deliverability")
      expect(DeliveryProviders.label_for("ses")).to eq("Amazon SES")
    end
  end

  describe DeliveryProviders::Sendgrid do
    subject(:adapter) { described_class.new(DeliveryChannel.new(kind: "sendgrid", config: { "api_key" => "SG.x" })) }

    it "accepts on 202" do
      allow(adapter).to receive(:post_json).and_return(fake_response(code: 202, headers: { "X-Message-Id" => "msg_1" }))
      result = adapter.deliver(context)
      expect(result).to be_accepted
      expect(result.provider_message_id).to eq("msg_1")
    end

    it "marks a 401 permanent" do
      allow(adapter).to receive(:post_json).and_return(fake_response(code: 401, body: '{"errors":[{"message":"bad key"}]}'))
      result = adapter.deliver(context)
      expect(result).not_to be_accepted
      expect(result).to be_permanent
      expect(result.error).to include("bad key")
    end

    it "marks a 503 transient" do
      allow(adapter).to receive(:post_json).and_return(fake_response(code: 503))
      expect(adapter.deliver(context)).not_to be_permanent
    end
  end

  describe DeliveryProviders::Postmark do
    subject(:adapter) { described_class.new(DeliveryChannel.new(kind: "postmark", config: { "server_token" => "tok" })) }

    it "accepts on ErrorCode 0" do
      allow(adapter).to receive(:post_json).and_return(fake_response(code: 200, body: '{"ErrorCode":0,"MessageID":"pm_1"}'))
      result = adapter.deliver(context)
      expect(result).to be_accepted
      expect(result.provider_message_id).to eq("pm_1")
    end

    it "fails (permanent) on a non-zero ErrorCode" do
      allow(adapter).to receive(:post_json).and_return(fake_response(code: 422, body: '{"ErrorCode":406,"Message":"Inactive recipient"}'))
      result = adapter.deliver(context)
      expect(result).not_to be_accepted
      expect(result).to be_permanent
    end
  end

  describe DeliveryProviders::Mailgun do
    subject(:adapter) { described_class.new(DeliveryChannel.new(kind: "mailgun", config: { "api_key" => "key", "domain" => "mg.acme.com", "region" => "eu" })) }

    it "accepts on 200 and targets the EU base" do
      expect(adapter).to receive(:post_form).with(a_string_starting_with("https://api.eu.mailgun.net"), anything).and_return(fake_response(code: 200, body: '{"id":"<mg_1>"}'))
      result = adapter.deliver(context)
      expect(result).to be_accepted
      expect(result.provider_message_id).to eq("<mg_1>")
    end
  end

  describe DeliveryProviders::Messy do
    subject(:adapter) { described_class.new(DeliveryChannel.new(kind: "messy", config: { "api_key" => "mk" })) }

    it "accepts on 2xx" do
      allow(adapter).to receive(:post_json).and_return(fake_response(code: 201, body: '{"id":"msy_1"}'))
      expect(adapter.deliver(context)).to be_accepted
    end
  end

  describe DeliveryProviders::Smtp do
    subject(:adapter) { described_class.new(DeliveryChannel.new(kind: "smtp_relay", config: { "host" => "smtp.acme.com", "port" => "587", "username" => "u", "password" => "p" })) }

    it "relays via Net::SMTP and accepts" do
      smtp = instance_double(Net::SMTP)
      allow(Net::SMTP).to receive(:new).and_return(smtp)
      allow(smtp).to receive(:open_timeout=)
      allow(smtp).to receive(:read_timeout=)
      allow(smtp).to receive(:enable_starttls_auto)
      allow(smtp).to receive(:start).and_yield(smtp)
      expect(smtp).to receive(:send_message).with(context.raw_mime, "support@acme.com", "customer@example.com")

      expect(adapter.deliver(context)).to be_accepted
    end

    it "marks an auth error permanent" do
      smtp = instance_double(Net::SMTP)
      allow(Net::SMTP).to receive(:new).and_return(smtp)
      allow(smtp).to receive(:open_timeout=)
      allow(smtp).to receive(:read_timeout=)
      allow(smtp).to receive(:enable_starttls_auto)
      allow(smtp).to receive(:start).and_raise(Net::SMTPAuthenticationError.new("535 bad auth"))

      result = adapter.deliver(context)
      expect(result).not_to be_accepted
      expect(result).to be_permanent
    end
  end
end
