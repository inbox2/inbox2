require "rails_helper"

# docs/E2EE.md Phase A — the single sealing resolver. Three independent gates:
# plan entitlement × per-domain switch × the INBOX2_E2EE_FORCE_OFF kill switch.
RSpec.describe E2ee do
  def stub_force_off(value)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("INBOX2_E2EE_FORCE_OFF", anything).and_return(value)
  end

  describe ".force_off? / .available?" do
    it "defaults to forced off outside production (dev/test never seal accidentally)" do
      expect(E2ee.force_off?).to be(true)
      expect(E2ee.available?).to be(false)
    end

    it "honours an explicit INBOX2_E2EE_FORCE_OFF=false" do
      stub_force_off("false")
      expect(E2ee.available?).to be(true)
    end
  end

  describe ".effective?" do
    let(:org) { create(:organization, domain: "sealed.test") }
    let(:domain) { org.default_domain }

    # entitled × enabled × force_off truth table: sealing requires exactly
    # (entitled && enabled && !force_off).
    [
      # entitled, enabled, force_off => effective
      [true,  true,  false, true],
      [true,  true,  true,  false],
      [true,  false, false, false],
      [false, true,  false, false],
      [false, false, false, false],
      [true,  false, true,  false],
      [false, true,  true,  false],
      [false, false, true,  false]
    ].each do |entitled, enabled, force_off, expected|
      it "entitled=#{entitled} enabled=#{enabled} force_off=#{force_off} → #{expected}" do
        stub_force_off(force_off ? "true" : "false")
        org.update!(plan: create(:plan, e2ee: entitled))
        # update_column bypasses the entitlement guard — deliberately, to model a
        # domain enabled under a paid plan whose org later downgraded.
        domain.update_column(:e2ee_enabled, enabled)

        expect(E2ee.effective?(domain.reload)).to be(expected)
      end
    end

    it "is false for nil" do
      stub_force_off("false")
      expect(E2ee.effective?(nil)).to be(false)
    end
  end

  describe ".threading_hmac_key" do
    it "reads INBOX2_THREADING_HMAC_KEY" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("INBOX2_THREADING_HMAC_KEY").and_return("secret")
      expect(E2ee.threading_hmac_key).to eq("secret")
    end
  end
end
