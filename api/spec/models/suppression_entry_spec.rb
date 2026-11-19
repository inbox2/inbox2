require "rails_helper"

RSpec.describe SuppressionEntry do
  let(:org) { create(:organization) }

  describe "validations" do
    it "requires a valid reason" do
      entry = described_class.new(organization: org, address: "a@x.com", reason: "bogus")
      expect(entry).not_to be_valid
      expect(entry.errors[:reason]).to be_present
    end

    it "is unique per org + address (case-insensitive)" do
      described_class.record!(org, "Dead@X.com", reason: SuppressionEntry::REASON_HARD_BOUNCE)
      dup = described_class.new(organization: org, address: "dead@x.com", reason: SuppressionEntry::REASON_COMPLAINT)
      expect(dup).not_to be_valid
    end
  end

  describe ".suppressed?" do
    it "matches regardless of case/whitespace" do
      described_class.record!(org, "dead@x.com", reason: SuppressionEntry::REASON_HARD_BOUNCE)
      expect(described_class.suppressed?(org, "  DEAD@X.com ")).to be(true)
      expect(described_class.suppressed?(org, "alive@x.com")).to be(false)
    end

    it "is scoped to the organization" do
      other = create(:organization)
      described_class.record!(org, "dead@x.com", reason: SuppressionEntry::REASON_HARD_BOUNCE)
      expect(described_class.suppressed?(other, "dead@x.com")).to be(false)
    end
  end

  describe ".record!" do
    it "is idempotent and refreshes detail without downgrading the reason" do
      described_class.record!(org, "dead@x.com", reason: SuppressionEntry::REASON_HARD_BOUNCE, detail: "550")
      described_class.record!(org, "dead@x.com", reason: SuppressionEntry::REASON_PERMANENT_FAILURE, detail: "later")

      entry = described_class.find_by(organization: org, address: "dead@x.com")
      expect(described_class.where(organization: org).count).to eq(1)
      expect(entry.reason).to eq(SuppressionEntry::REASON_HARD_BOUNCE) # not downgraded
      expect(entry.detail).to eq("later")
    end
  end
end
