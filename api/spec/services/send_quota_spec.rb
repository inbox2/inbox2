require "rails_helper"

# Reputation-based outbound throttle (docs/Mail-Deliverability.md).
RSpec.describe SendQuota do
  let(:owner) { create(:user, username: "quotaowner") }
  let(:org) { create(:organization, owner: owner, domain: "quota.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:conversation) { create(:conversation, organization: org) }

  def outbound!(created_at: Time.current, to: "a@example.com", cc: nil, delivered: false)
    msg = create(:message, organization: org, conversation: conversation,
      is_inbound: false, is_draft: false, to_address: to, cc_address: cc, created_at: created_at)
    DeliveryStatus.create!(message: msg, status: DeliveryStatus::STATUS_DELIVERED, delivered_at: Time.current) if delivered
    msg
  end

  describe ".count_recipients" do
    it "counts across to and cc, ignoring blanks, minimum 1" do
      expect(described_class.count_recipients("a@x.com, b@x.com", "c@x.com")).to eq(3)
      expect(described_class.count_recipients("a@x.com,, ", nil)).to eq(1)
      expect(described_class.count_recipients(nil, nil)).to eq(1) # sealed/unknown still costs one
    end
  end

  it "counts Bcc recipients of earlier sends, so hidden recipients use the quota too" do
    conversation = create(:conversation, organization: org)
    create(:message, conversation: conversation, organization: org, is_inbound: false, is_draft: false,
      to_address: "a@x.com", bcc_address: "b@x.com, c@x.com")
    expect(described_class.new(org).send(:recent_sends).sum { |_, *a| described_class.count_recipients(*a) }).to eq(3)
  end

  describe "#tier" do
    it "starts every new org on the tightest tier" do
      q = described_class.new(org)
      expect(q.tier.hourly).to eq(15)
      expect(q.tier.daily).to eq(125)
      expect(q.unlimited?).to be(false)
    end

    it "does not advance on age alone — delivery history is required" do
      org.update!(created_at: 2.weeks.ago)
      expect(described_class.new(org).tier.hourly).to eq(15)
    end

    it "advances when age AND delivered history are both met" do
      org.update!(created_at: 2.weeks.ago)
      25.times { outbound!(created_at: 10.days.ago, delivered: true) }
      expect(described_class.new(org).tier.hourly).to eq(50)
    end

    it "goes unlimited at 6 months regardless of history" do
      org.update!(created_at: 7.months.ago)
      q = described_class.new(org)
      expect(q.unlimited?).to be(true)
      expect(q.deny_reason(recipients: 5_000)).to be_nil
    end
  end

  describe "#deny_reason" do
    it "allows sends under the caps" do
      14.times { outbound!(created_at: 30.minutes.ago) }
      expect(described_class.new(org).deny_reason(recipients: 1)).to be_nil
    end

    it "denies when the hourly cap is reached" do
      15.times { outbound!(created_at: 30.minutes.ago) }
      expect(described_class.new(org).deny_reason(recipients: 1)).to include("Hourly sending limit")
    end

    it "frees hourly headroom once sends age out of the window" do
      15.times { outbound!(created_at: 2.hours.ago) }
      expect(described_class.new(org).deny_reason(recipients: 1)).to be_nil
    end

    it "denies when the daily cap is reached even with hourly headroom" do
      125.times { outbound!(created_at: 5.hours.ago) }
      expect(described_class.new(org).deny_reason(recipients: 1)).to include("Daily sending limit")
    end

    it "counts every recipient of a message against the caps" do
      7.times { outbound!(created_at: 10.minutes.ago, to: "a@x.com, b@x.com") } # 14 recipients
      q = described_class.new(org)
      expect(q.deny_reason(recipients: 1)).to be_nil
      expect(q.deny_reason(recipients: 2)).to include("Hourly sending limit")
    end

    it "caps recipients per message for young senders" do
      expect(described_class.new(org).deny_reason(recipients: 11)).to include("at most 10 recipients")
    end
  end
end
