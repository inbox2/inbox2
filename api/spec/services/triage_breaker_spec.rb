require "rails_helper"

RSpec.describe TriageBreaker do
  let(:owner) { create(:user, username: "breakerowner") }
  let(:org) { create(:organization, owner: owner, domain: "breaker.com") }
  let(:domain) { org.default_domain }
  let(:membership) { org.memberships.find_by(user: owner) || create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  # Paid tier → caps { org: 30_000, domain: 20_000, user: 12_000 }.
  before { org.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE) }

  def usage(scope_type, scope_id, n)
    AiTriageUsage.create!(organization: org, scope_type:, scope_id:, period: AiTriageUsage.period_for, triaged_count: n)
  end

  describe "#allow?" do
    it "allows when every scope is under its cap" do
      breaker = described_class.new(org, domain: domain, membership: membership)
      expect(breaker.allow?).to be(true)
    end

    it "blocks once the org cap is reached" do
      usage(AiTriageUsage::SCOPE_ORG, org.id, 30_000)
      expect(described_class.new(org).allow?).to be(false)
    end

    it "blocks once the per-domain cap is reached (org still under)" do
      usage(AiTriageUsage::SCOPE_DOMAIN, domain.id, 20_000)
      expect(described_class.new(org, domain: domain).allow?).to be(false)
    end

    it "blocks once the per-user cap is reached (org + domain still under)" do
      usage(AiTriageUsage::SCOPE_USER, membership.id, 12_000)
      breaker = described_class.new(org, domain: domain, membership: membership)
      expect(breaker.allow?).to be(false)
    end

    it "isolates a maxed-out user — a different user on the same org still triages" do
      other = create(:user, username: "breakerother")
      other_m = create(:membership, user: other, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      usage(AiTriageUsage::SCOPE_USER, membership.id, 12_000) # owner maxed

      expect(described_class.new(org, domain: domain, membership: membership).allow?).to be(false)
      expect(described_class.new(org, domain: domain, membership: other_m).allow?).to be(true)
    end

    it "never allows a free-plan org (caps are 0)" do
      org.subscription.destroy! # back to Free
      expect(described_class.new(org.reload).allow?).to be(false)
    end
  end

  describe "counter recording" do
    it "bumps triaged_count on every applicable scope" do
      described_class.new(org, domain: domain, membership: membership).record_triaged!
      p = AiTriageUsage.period_for
      expect(AiTriageUsage.count_for(org.id, AiTriageUsage::SCOPE_ORG, org.id, p)).to eq(1)
      expect(AiTriageUsage.count_for(org.id, AiTriageUsage::SCOPE_DOMAIN, domain.id, p)).to eq(1)
      expect(AiTriageUsage.count_for(org.id, AiTriageUsage::SCOPE_USER, membership.id, p)).to eq(1)
    end

    it "bumps throttled_count without touching triaged_count" do
      described_class.new(org, domain: domain).record_throttled!
      row = AiTriageUsage.find_by(organization: org, scope_type: AiTriageUsage::SCOPE_ORG, scope_id: org.id)
      expect([row.throttled_count, row.triaged_count]).to eq([1, 0])
    end
  end
end
