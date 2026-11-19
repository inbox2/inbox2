require "rails_helper"

RSpec.describe AiTriageUsage, type: :model do
  let(:owner) { create(:user, username: "usageowner") }
  let(:org) { create(:organization, owner: owner, domain: "usage.com") }
  let(:period) { described_class.period_for }

  describe ".count_for" do
    it "returns 0 when no row exists yet" do
      expect(described_class.count_for(org.id, described_class::SCOPE_ORG, org.id, period)).to eq(0)
    end
  end

  describe ".increment!" do
    it "creates the row on first use and increments on subsequent calls" do
      3.times { described_class.increment!(org.id, described_class::SCOPE_ORG, org.id, period, :triaged) }
      expect(described_class.count_for(org.id, described_class::SCOPE_ORG, org.id, period)).to eq(3)
      expect(described_class.where(organization: org).count).to eq(1)
    end

    it "keeps triaged and throttled counters independent" do
      described_class.increment!(org.id, described_class::SCOPE_ORG, org.id, period, :triaged)
      described_class.increment!(org.id, described_class::SCOPE_ORG, org.id, period, :throttled)
      row = described_class.find_by(organization: org, scope_type: described_class::SCOPE_ORG, scope_id: org.id, period:)
      expect([row.triaged_count, row.throttled_count]).to eq([1, 1])
    end

    it "separates counters by period (monthly reset)" do
      described_class.increment!(org.id, described_class::SCOPE_ORG, org.id, "2026-05", :triaged)
      described_class.increment!(org.id, described_class::SCOPE_ORG, org.id, "2026-06", :triaged)
      expect(described_class.count_for(org.id, described_class::SCOPE_ORG, org.id, "2026-05")).to eq(1)
      expect(described_class.count_for(org.id, described_class::SCOPE_ORG, org.id, "2026-06")).to eq(1)
    end
  end
end
