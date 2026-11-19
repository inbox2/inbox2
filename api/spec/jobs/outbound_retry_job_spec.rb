require "rails_helper"

RSpec.describe OutboundRetryJob do
  let(:owner) { create(:user, username: "retry_owner") }
  let(:org) { create(:organization, owner: owner, domain: "retry.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conversation) { create(:conversation, organization: org, subject: "Retry test") }
  let(:message) do
    create(:message,
      conversation: conversation,
      organization: org,
      from_address: "support@retry.com",
      to_address: "customer@example.com",
      is_inbound: false,
      is_draft: false
    )
  end
  let(:channel) { DeliveryChannel.ensure_builtin(org) }
  let(:delivery_status) do
    DeliveryStatus.create!(
      message: message,
      delivery_channel: channel,
      status: DeliveryStatus::STATUS_DEFERRED,
      attempt_count: 1
    )
  end

  describe "#perform" do
    it "does nothing if delivery status is not deferred" do
      delivery_status.update!(status: DeliveryStatus::STATUS_DELIVERED)
      expect_any_instance_of(OutboundMailPublisher).not_to receive(:publish)
      described_class.new.perform(delivery_status.id)
    end

    it "updates status to queued when retrying" do
      # We can't test the full NATS publish without a running NATS server,
      # but we can verify the status transition
      allow_any_instance_of(OutboundMailPublisher).to receive(:publish).and_return(delivery_status)

      described_class.new.perform(delivery_status.id)
      expect(delivery_status.reload.status).to eq(DeliveryStatus::STATUS_QUEUED)
    end

    it "republishes onto the existing delivery status (no duplicate)" do
      ds = delivery_status
      expect_any_instance_of(OutboundMailPublisher)
        .to receive(:publish).with(delivery_status: ds).and_return(ds)

      described_class.new.perform(ds.id)
    end
  end
end
