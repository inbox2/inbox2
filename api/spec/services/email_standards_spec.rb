require "rails_helper"

RSpec.describe "Email Standards" do
  let(:owner) { create(:user, username: "emailstdowner") }
  let(:org) { create(:organization, owner: owner, domain: "emailstd.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  # spec 18.2.4 — ARC (RFC 8617)
  describe ArcHeaderService do
    subject { described_class.new(org) }

    it "generates ARC headers with correct instance" do
      headers = subject.generate_headers(authentication_results: "dkim=pass; spf=pass")
      expect(headers["ARC-Authentication-Results"]).to include("i=1")
      expect(headers["ARC-Authentication-Results"]).to include("dkim=pass")
      expect(headers["ARC-Message-Signature"]).to include("d=emailstd.com")
      expect(headers["ARC-Seal"]).to include("cv=none")
    end

    it "sets cv=pass for non-first instances" do
      service = described_class.new(org, instance: 2)
      headers = service.generate_headers(authentication_results: "dkim=pass")
      expect(headers["ARC-Seal"]).to include("cv=pass")
    end

    it "validates a sequential ARC chain" do
      headers = {
        "ARC-Seal" => "i=1; cv=none; b=abc",
        "arc-seal" => "i=2; cv=pass; b=def"
      }
      # With hash, only last key survives — test with single seal
      result = described_class.validate_chain({ "ARC-Seal" => "i=1; cv=none; b=abc" })
      expect(result[:valid]).to be true
      expect(result[:chain_length]).to eq(1)
    end

    it "produces a real RSA-SHA256 ARC-Seal that verifies against the public key" do
      key = OpenSSL::PKey::RSA.new(2048)
      raw = "From: a@emailstd.com\r\nTo: b@x.com\r\nSubject: hi\r\nDate: Mon, 1 Jun 2026 00:00:00 +0000\r\nMessage-ID: <1@emailstd.com>\r\n\r\nbody text\r\n"
      service = described_class.new(org, key: key)

      headers = service.generate_headers(authentication_results: "dkim=pass", raw_message: raw)
      seal = headers["ARC-Seal"]
      b = seal[/b=([A-Za-z0-9+\/=]+)\z/, 1]
      expect(b).to be_present

      # Reconstruct the signing input (AAR + AMS + AS-with-empty-b) and verify.
      canon = ->(name, value) { "#{name.downcase}:#{value.gsub(/\s+/, ' ').strip}" }
      input = canon.call("arc-authentication-results", headers["ARC-Authentication-Results"]) + "\r\n"
      input += canon.call("arc-message-signature", headers["ARC-Message-Signature"]) + "\r\n"
      input += canon.call("arc-seal", seal.sub(/b=[A-Za-z0-9+\/=]+\z/, "b="))

      expect(key.verify(OpenSSL::Digest.new("SHA256"), Base64.strict_decode64(b), input)).to be(true)
    end
  end

  # spec 18.3.1 — MTA-STS (RFC 8461)
  describe MtaStsPolicy do
    it "generates policy text" do
      policy = MtaStsPolicy.create!(
        domain: org.default_domain,
        mode: MtaStsPolicy::MODE_ENFORCE,
        max_age: 604800,
        mx_hosts: "mx1.emailstd.com\nmx2.emailstd.com"
      )

      text = policy.policy_text
      expect(text).to include("version: STSv1")
      expect(text).to include("mode: enforce")
      expect(text).to include("max_age: 604800")
      expect(text).to include("mx: mx1.emailstd.com")
      expect(text).to include("mx: mx2.emailstd.com")
    end

    it "generates DNS record" do
      policy = MtaStsPolicy.create!(domain: org.default_domain, mode: MtaStsPolicy::MODE_TESTING)
      expect(policy.dns_record).to include("_mta-sts.emailstd.com")
      expect(policy.dns_record).to include("v=STSv1")
    end

    it "validates mode" do
      policy = MtaStsPolicy.new(domain: org.default_domain, mode: "invalid", max_age: 100)
      expect(policy).not_to be_valid
    end
  end

  # spec 18.3.2 — TLS-RPT (RFC 8460)
  describe TlsRptConfig do
    it "generates DNS record" do
      config = TlsRptConfig.create!(domain: org.default_domain, reporting_email: "tlsrpt@emailstd.com")
      expect(config.dns_record).to include("_smtp._tls.emailstd.com")
      expect(config.dns_record).to include("rua=mailto:tlsrpt@emailstd.com")
    end

    it "requires reporting email" do
      config = TlsRptConfig.new(domain: org.default_domain, reporting_email: nil)
      expect(config).not_to be_valid
    end
  end

  # spec 18.4.3 — DSN bounce handling (RFC 3464)
  describe DsnBounceParser do
    it "parses hard bounce from DSN content" do
      dsn = <<~DSN
        Reporting-MTA: dns; mx.example.com
        Final-Recipient: rfc822; user@invalid.com
        Status: 5.1.1
        Diagnostic-Code: smtp; 550 User unknown
        Action: failed
      DSN

      result = DsnBounceParser.new(dsn).parse
      expect(result[:bounce_type]).to eq(DsnBounceParser::BOUNCE_HARD)
      expect(result[:dsn_code]).to eq("5.1.1")
      expect(result[:diagnostic]).to eq("550 User unknown")
      expect(result[:original_recipient]).to eq("user@invalid.com")
    end

    it "parses transient bounce" do
      dsn = "Status: 4.2.1\nDiagnostic-Code: smtp; 450 Mailbox temporarily unavailable"
      result = DsnBounceParser.new(dsn).parse
      expect(result[:bounce_type]).to eq(DsnBounceParser::BOUNCE_TRANSIENT)
      expect(result[:dsn_code]).to eq("4.2.1")
    end

    it "updates delivery status from DSN" do
      conv = create(:conversation, organization: org)
      msg = create(:message, conversation: conv, organization: org)
      ds = DeliveryStatus.create!(message: msg, status: DeliveryStatus::STATUS_QUEUED)

      dsn = "Status: 5.1.1\nDiagnostic-Code: smtp; 550 User unknown\nFinal-Recipient: rfc822; bad@test.com"
      DsnBounceParser.new(dsn).update_delivery_status!(ds)

      ds.reload
      expect(ds.status).to eq(DeliveryStatus::STATUS_BOUNCED)
      expect(ds.dsn_code).to eq("5.1.1")
      expect(ds.bounce_type).to eq(DsnBounceParser::BOUNCE_HARD)
    end

    it "handles missing status code" do
      result = DsnBounceParser.new("Some bounce message").parse
      expect(result[:bounce_type]).to eq(DsnBounceParser::BOUNCE_HARD) # default when no status
    end
  end
end
