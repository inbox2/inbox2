require "mail"
require "rails_helper"

RSpec.describe OutboundMailPublisher do
  let(:owner) { create(:user, username: "outbound_owner") }
  let(:org) { create(:organization, owner: owner, domain: "acme.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conversation) { create(:conversation, organization: org, subject: "Test outbound", from_address: "support@acme.com") }
  let(:message) do
    create(:message,
      conversation: conversation,
      organization: org,
      from_address: "support@acme.com",
      to_address: "customer@example.com",
      subject: "Re: Test outbound",
      body_plain: "Hello, this is a reply.",
      body_html: "<p>Hello, this is a reply.</p>",
      is_inbound: false,
      is_draft: false
    )
  end

  describe "#build_payload" do
    it "keeps the Reply-To of a message submitted by a mail client" do
      message.update!(raw_headers: "From: support@acme.com\r\nReply-To: Billing <billing@acme.com>\r\nSubject: x\r\n")
      payload = described_class.new(message).send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))
      expect(Base64.strict_decode64(payload[:rfc5322_b64])).to include("Reply-To: Billing <billing@acme.com>")
    end

    it "composes a valid RFC 5322 message" do
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      expect(payload[:version]).to eq(1)
      expect(payload[:message_key]).to eq(message.key)
      expect(payload[:envelope][:mail_from]).to eq("support@acme.com")
      expect(payload[:envelope][:rcpt_to]).to include("customer@example.com")

      # Decode the RFC 5322 message
      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      expect(rfc5322).to include("From: support@acme.com")
      expect(rfc5322).to include("To: customer@example.com")
      expect(rfc5322).to include("Subject: Re: Test outbound")
      expect(rfc5322).to include("MIME-Version: 1.0")
    end

    it "creates multipart message when HTML body present" do
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      expect(rfc5322).to include("multipart/alternative")
      expect(rfc5322).to include("text/plain")
      expect(rfc5322).to include("text/html")
      expect(rfc5322).to include("Hello, this is a reply.")
      expect(rfc5322).to include("<p>Hello, this is a reply.</p>")
    end

    it "sends a signature's data: image as a cid: part of multipart/related" do
      png = Base64.strict_encode64("\x89PNG fake")
      message.update!(body_html: %(<p>Hi</p><div data-signature="sig_x"><img src="data:image/png;base64,#{png}"></div>))
      rfc5322 = described_class.new(message).compose_mime
      parsed = Mail.new(rfc5322)
      expect(parsed.mime_type).to eq("multipart/related")
      image = parsed.parts.find { |p| p.mime_type == "image/png" }
      expect(image.decoded.b).to eq("\x89PNG fake".b)
      html = parsed.html_part.decoded
      expect(html).to include("cid:#{image.content_id[1..-2]}")
      expect(html).not_to include("data:image")
    end

    it "builds the HTML alternative from the plain body when no HTML body was composed" do
      # Mobile composers post body_plain only — the mail still ships both parts.
      message.update!(body_html: nil)
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      expect(rfc5322).to include("multipart/alternative")
      expect(rfc5322).to include("Content-Type: text/plain")
      expect(rfc5322).to include("Content-Type: text/html")
      expect(rfc5322).to include("Hello, this is a reply.")
    end

    it "keeps a plain singlepart when there is no body at all" do
      message.update!(body_html: nil, body_plain: nil)
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      expect(rfc5322).to include("Content-Type: text/plain")
      expect(rfc5322).not_to include("multipart")
    end

    it "includes CC recipients in envelope" do
      message.update!(cc_address: "cc1@example.com, cc2@example.com")
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      expect(payload[:envelope][:rcpt_to]).to include("customer@example.com")
      expect(payload[:envelope][:rcpt_to]).to include("cc1@example.com")
      expect(payload[:envelope][:rcpt_to]).to include("cc2@example.com")
    end

    it "puts BCC recipients in the envelope but never in the headers" do
      message.update!(bcc_address: "blind1@example.com, blind2@example.com")
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      expect(payload[:envelope][:rcpt_to]).to include("blind1@example.com", "blind2@example.com")
      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      expect(rfc5322).not_to include("blind1@example.com")
      expect(rfc5322.downcase).not_to include("bcc:")
    end

    it "RFC 2047-encodes non-ASCII headers and keeps the envelope bare" do
      message.update!(
        to_address: 'Ahmet Akca <a@x.nl>, "Ömer Eryigit" <o@x.nl>',
        subject: "Rendez-vous café"
      )
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      headers = rfc5322.split("\r\n\r\n").first
      expect(headers.ascii_only?).to be(true), "headers must be ASCII-only: #{headers}"
      expect(rfc5322).to include("To: Ahmet Akca <a@x.nl>, =?UTF-8?B?w5ZtZXIgRXJ5aWdpdA==?= <o@x.nl>")
      expect(rfc5322).to include("Subject: =?UTF-8?B?UmVuZGV6LXZvdXMgY2Fmw6k=?=")
      # SMTP envelope wants bare addr-specs, not display-name mailboxes.
      expect(payload[:envelope][:rcpt_to]).to contain_exactly("a@x.nl", "o@x.nl")
      expect(payload[:envelope][:mail_from]).to eq("support@acme.com")
    end

    it "produces a fully 7-bit-clean wire message within SMTP line limits" do
      message.update!(
        subject: "Rendez-vous café",
        body_plain: "café\net thé",
        body_html: "<p>#{'café et thé ' * 300}</p>" # one giant line, as the editor emits
      )
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      rfc5322 = Base64.strict_decode64(payload[:rfc5322_b64])
      expect(rfc5322.ascii_only?).to be(true), "entire message must be 7-bit clean"
      expect(rfc5322).to include("Content-Transfer-Encoding: quoted-printable")
      rfc5322.split("\r\n").each do |line|
        expect(line.length).to be <= 998, "line exceeds SMTP limit: #{line[0, 80]}..."
      end
    end

    it "splits display-name mailboxes out of the envelope recipient list" do
      message.update!(to_address: "Customer Name <customer@example.com>")
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      expect(payload[:envelope][:rcpt_to]).to eq(["customer@example.com"])
    end

    it "includes DKIM config from organization" do
      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      expect(payload[:dkim][:domain]).to eq("acme.com")
      expect(payload[:dkim][:selector]).to eq("inbox2")
    end

    it "carries the central DKIM private key when configured" do
      pem = OpenSSL::PKey::RSA.new(2048).to_pem
      allow(DkimKey).to receive(:private_key_pem).and_return(pem)

      publisher = described_class.new(message)
      payload = publisher.send(:build_payload, DeliveryStatus.new(key: "ds_test"), DeliveryChannel.new(kind: "builtin", id: 1))

      expect(payload[:dkim][:private_key_pem]).to eq(pem)
    end
  end

  # A REAL JetStream object with only our two calls stubbed, so
  # `verify_partial_doubles` refuses any method the gem doesn't actually have.
  # The prod outage of 2026-09-09 was a call to `find_stream_by_subject` (the
  # real name is `find_stream_name_by_subject`) and the old loose `double(...)`
  # answered the typo happily — green tests, zero mail delivered. An
  # instance_double can't stand in here: the gem `extend`s its Manager module
  # per instance inside `initialize`, so the class itself defines none of the
  # stream methods.
  def verified_jetstream
    js = NATS::JetStream.new(Object.new)
    allow(js).to receive(:find_stream_name_by_subject).and_return("MAIL_OUTBOUND")
    allow(js).to receive(:publish).and_return(true)
    js
  end

  def fake_nats
    double(jetstream: verified_jetstream)
  end

  describe "#publish — destinations" do
    it "queues one job and one delivery status per recipient domain" do
      message.update!(to_address: "a@one.com, b@one.com", cc_address: "c@two.com")
      publisher = described_class.new(message)
      js = verified_jetstream
      allow(publisher).to receive(:connect_nats).and_return(double(jetstream: js))

      statuses = publisher.publish
      expect(statuses.map(&:destination)).to contain_exactly("one.com", "two.com")
      expect(statuses.find { |d| d.destination == "one.com" }.recipient_list).to contain_exactly("a@one.com", "b@one.com")
      expect(statuses.find { |d| d.destination == "two.com" }.recipient_list).to contain_exactly("c@two.com")
      expect(statuses).to all(be_published)

      # Each envelope carries only its own domain's recipients — the Go sender
      # does ONE MX lookup, so a foreign address would be RCPT'd to the wrong MX
      # and take the whole envelope down with it.
      expect(js).to have_received(:publish).with("mail.outbound.one.com", anything)
      expect(js).to have_received(:publish).with("mail.outbound.two.com", anything)
    end

    it "leaves a row unpublished when the publish itself fails, so the retry re-sends it" do
      publisher = described_class.new(message)
      allow(publisher).to receive(:connect_nats).and_raise(NoMethodError, "boom")

      expect { publisher.publish }.to raise_error(NoMethodError)
      expect(message.delivery_statuses.sole).not_to be_published
    end
  end

  describe "#publish — suppression" do
    it "does not queue to NATS when every recipient is suppressed" do
      SuppressionEntry.record!(org, "customer@example.com", reason: SuppressionEntry::REASON_HARD_BOUNCE)

      publisher = described_class.new(message)
      expect(publisher).not_to receive(:connect_nats)

      status = publisher.publish.sole
      expect(status.status).to eq(DeliveryStatus::STATUS_FAILED)
      expect(status.dsn_diagnostic).to include("suppressed")
    end

    it "reuses an existing delivery status on retry instead of creating a new one" do
      existing = create(:delivery_status, message: message, status: "queued")
      publisher = described_class.new(message)
      allow(publisher).to receive(:connect_nats).and_return(fake_nats)

      expect { publisher.publish(delivery_status: existing) }.not_to change(DeliveryStatus, :count)
      expect(existing.reload).to be_published
    end

    it "re-publishes only the destination being retried, never the other recipients" do
      message.update!(to_address: "a@one.com", cc_address: "b@two.com")
      publisher = described_class.new(message)
      js = verified_jetstream
      allow(publisher).to receive(:connect_nats).and_return(double(jetstream: js))

      one = publisher.publish.find { |d| d.destination == "one.com" }
      expect(js).to have_received(:publish).with("mail.outbound.one.com", anything)
      expect(js).to have_received(:publish).with("mail.outbound.two.com", anything)

      publisher.publish(delivery_status: one)
      # The retry queued one.com a second time and two.com exactly once — a
      # recipient who already got the mail must never be re-sent.
      expect(js).to have_received(:publish).with("mail.outbound.one.com", anything).twice
      expect(js).to have_received(:publish).with("mail.outbound.two.com", anything).once
    end
  end

  describe "#publish — custom ESP routing" do
    before do
      DeliveryChannel.ensure_builtin(org).update!(is_default: false)
    end

    let!(:custom) { org.delivery_channels.create!(name: "SendGrid", kind: "sendgrid", status: "active", is_default: true, config: { "api_key" => "SG.x" }) }

    it "delivers via the provider adapter, never NATS, and marks delivered" do
      adapter = instance_double(DeliveryProviders::Sendgrid)
      allow(DeliveryProviders).to receive(:for).with(custom).and_return(adapter)
      allow(adapter).to receive(:deliver).and_return(DeliveryProviders::Result.ok("msg_1"))

      publisher = described_class.new(message)
      expect(publisher).not_to receive(:connect_nats)

      status = publisher.publish.sole
      expect(status.status).to eq(DeliveryStatus::STATUS_DELIVERED)
      expect(status.destination).to eq("esp:sendgrid")
      expect(status.delivery_channel).to eq(custom)
      expect(status.delivery_attempts.last.result).to eq("success")
    end

    it "defers and schedules a retry on a transient provider failure" do
      adapter = instance_double(DeliveryProviders::Sendgrid)
      allow(DeliveryProviders).to receive(:for).and_return(adapter)
      allow(adapter).to receive(:deliver).and_return(DeliveryProviders::Result.transient("503 busy"))

      publisher = described_class.new(message)
      expect(OutboundRetryJob).to receive(:set).with(hash_including(:wait)).and_return(double(perform_later: true))

      status = publisher.publish.sole
      expect(status.reload.status).to eq(DeliveryStatus::STATUS_DEFERRED)
    end

    it "fails fast (no retry) on a permanent provider failure" do
      adapter = instance_double(DeliveryProviders::Sendgrid)
      allow(DeliveryProviders).to receive(:for).and_return(adapter)
      allow(adapter).to receive(:deliver).and_return(DeliveryProviders::Result.permanent_failure("401 bad key"))

      publisher = described_class.new(message)
      expect(OutboundRetryJob).not_to receive(:set)

      status = publisher.publish.sole
      expect(status.reload.status).to eq(DeliveryStatus::STATUS_FAILED)
    end
  end

  describe "#extract_domain" do
    it "extracts domain from email address" do
      publisher = described_class.new(message)
      expect(publisher.send(:extract_domain, "user@example.com")).to eq("example.com")
    end

    it "returns 'unknown' for blank address" do
      publisher = described_class.new(message)
      expect(publisher.send(:extract_domain, nil)).to eq("unknown")
      expect(publisher.send(:extract_domain, "")).to eq("unknown")
    end
  end
end
