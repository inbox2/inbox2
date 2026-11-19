require "rails_helper"

RSpec.describe DeliveryRetryService do
  let(:owner) { create(:user, username: "retryowner") }
  let(:org) { create(:organization, owner: owner, domain: "retry.com") }
  let(:conv) { create(:conversation, organization: org) }
  let(:msg) { create(:message, conversation: conv, organization: org, is_inbound: false) }
  let(:channel) { DeliveryChannel.ensure_builtin(org) }
  let(:delivery) { create(:delivery_status, message: msg, delivery_channel: channel, status: "deferred", attempt_count: 0) }

  subject { described_class.new(delivery) }

  describe "#should_retry?" do
    it "returns true for deferred with low attempt count" do
      expect(subject.should_retry?).to eq(true)
    end

    it "returns false when max retries exceeded" do
      delivery.update!(attempt_count: 5)
      expect(subject.should_retry?).to eq(false)
    end
  end

  describe "#next_retry_delay" do
    it "uses exponential backoff" do
      expect(subject.next_retry_delay).to eq(60) # 60 * 2^0
      delivery.update!(attempt_count: 2)
      expect(subject.next_retry_delay).to eq(240) # 60 * 2^2
    end
  end

  describe "#record_attempt" do
    it "records success and marks delivered" do
      subject.record_attempt(result: "success", smtp_code: "250", message: "OK")
      expect(delivery.reload.status).to eq("delivered")
      expect(delivery.delivered_at).to be_present
      expect(delivery.delivery_attempts.count).to eq(1)
    end

    it "records permanent failure and marks failed" do
      subject.record_attempt(result: "permanent_failure", smtp_code: "550", message: "User unknown")
      expect(delivery.reload.status).to eq("failed")
      expect(delivery.failed_at).to be_present
    end

    it "records transient failure and marks deferred for retry" do
      subject.record_attempt(result: "transient_failure", smtp_code: "421", message: "Try again later")
      expect(delivery.reload.status).to eq("deferred")
    end

    it "marks failed after max retries on transient failure" do
      delivery.update!(attempt_count: 4)
      subject.record_attempt(result: "transient_failure", smtp_code: "421", message: "Still failing")
      expect(delivery.reload.status).to eq("failed")
    end
  end
end
