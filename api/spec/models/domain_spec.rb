require "rails_helper"

RSpec.describe Domain, type: :model do
  it "has a valid factory" do
    expect(build(:domain)).to be_valid
  end

  it "enforces case-insensitive name uniqueness" do
    create(:domain, name: "acme.test")
    dup = build(:domain, name: "ACME.test")
    expect(dup).not_to be_valid
  end

  it "lets an org own many equal domains (no primary/secondary distinction)" do
    org = create(:organization, with_default_domain: false)
    create(:domain, organization: org, name: "first.test")
    second = build(:domain, organization: org, name: "second.test")
    expect(second).to be_valid
  end

  it "derives the org's default domain as the oldest" do
    org = create(:organization, with_default_domain: false)
    first = create(:domain, organization: org, name: "old.test")
    create(:domain, organization: org, name: "new.test")
    expect(org.reload.default_domain).to eq(first)
  end

  describe "#record_dns_check!" do
    it "verifies when MX is correct" do
      d = create(:domain, status: Domain::STATUS_PENDING_DNS)
      d.record_dns_check!(mx_ok: true, checks: { mx: true })
      expect(d.status).to eq(Domain::STATUS_VERIFIED)
      expect(d.dns_checks).to eq({ "mx" => true })
    end

    it "falls back to pending when MX is missing" do
      d = create(:domain, status: Domain::STATUS_VERIFIED)
      d.record_dns_check!(mx_ok: false, checks: { mx: false })
      expect(d.status).to eq(Domain::STATUS_PENDING_DNS)
    end

    it "never clobbers receiving_mail" do
      d = create(:domain, status: Domain::STATUS_RECEIVING_MAIL)
      d.record_dns_check!(mx_ok: false, checks: { mx: false })
      expect(d.status).to eq(Domain::STATUS_RECEIVING_MAIL)
    end
  end

  it "#accepting_mail? only for verified/receiving" do
    expect(build(:domain, status: "verified")).to be_accepting_mail
    expect(build(:domain, status: "receiving_mail")).to be_accepting_mail
    expect(build(:domain, status: "pending_dns")).not_to be_accepting_mail
  end

  describe "billing lock" do
    it "#locked? reflects locked_at and blocks accepting_mail" do
      d = build(:domain, status: "verified", locked_at: Time.current)
      expect(d).to be_locked
      expect(d).not_to be_accepting_mail
    end

    it "an unlocked verified domain accepts mail" do
      expect(build(:domain, status: "verified", locked_at: nil)).to be_accepting_mail
    end
  end

  describe "E2EE (docs/E2EE.md Phase A)" do
    let(:org) { create(:organization) }
    let(:domain) { org.default_domain }

    describe "entitlement guard" do
      it "rejects enabling e2ee without the plan entitlement (paywall, no half-enable)" do
        org.update!(plan: create(:plan, e2ee: false))
        domain.e2ee_enabled = true
        expect(domain).not_to be_valid
        expect(domain.errors[:e2ee_enabled]).to be_present
      end

      it "allows enabling e2ee on an entitled plan with a provisioned key" do
        org.update!(plan: create(:plan, e2ee: true))
        create(:domain_key, domain: domain)
        expect(domain.update(e2ee_enabled: true)).to be(true)
      end

      it "rejects enabling e2ee before a key is provisioned (never half-enable)" do
        org.update!(plan: create(:plan, e2ee: true))
        domain.e2ee_enabled = true
        expect(domain).not_to be_valid
        expect(domain.errors[:e2ee_enabled].join).to include("key")
      end

      it "does not break unrelated saves on an already-enabled domain after a downgrade" do
        org.update!(plan: create(:plan, e2ee: true))
        create(:domain_key, domain: domain)
        domain.update!(e2ee_enabled: true)
        org.update!(plan: create(:plan, e2ee: false))
        expect(domain.reload.update(status: Domain::STATUS_RECEIVING_MAIL)).to be(true)
      end
    end

    describe "#current_e2ee_key" do
      it "is nil before key provisioning" do
        expect(domain.current_e2ee_key).to be_nil
      end

      it "returns the highest non-retired version" do
        create(:domain_key, domain: domain, version: 1, retired_at: Time.current)
        v2 = create(:domain_key, domain: domain, version: 2)
        create(:domain_key, domain: domain, version: 3, retired_at: Time.current)
        expect(domain.current_e2ee_key).to eq(v2)
      end
    end
  end
end
