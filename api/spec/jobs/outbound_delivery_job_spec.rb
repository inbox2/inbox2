require "rails_helper"

RSpec.describe OutboundDeliveryJob do
  let(:owner) { create(:user, username: "deliver_owner") }
  let(:org) { create(:organization, owner: owner, domain: "deliver.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conversation) { create(:conversation, organization: org, subject: "Deliver test") }
  let(:message) do
    create(:message,
      conversation: conversation,
      organization: org,
      from_address: "support@deliver.com",
      to_address: "customer@example.com",
      is_inbound: false,
      is_draft: false
    )
  end

  describe "#perform" do
    it "publishes the message via OutboundMailPublisher" do
      # NATS isn't available in the test env, so stub the publish itself.
      expect_any_instance_of(OutboundMailPublisher).to receive(:publish)
      described_class.new.perform(message.id)
    end

    it "does nothing if the message no longer exists" do
      expect_any_instance_of(OutboundMailPublisher).not_to receive(:publish)
      described_class.new.perform(-1)
    end

    it "does not publish a draft" do
      message.update!(is_draft: true)
      expect_any_instance_of(OutboundMailPublisher).not_to receive(:publish)
      described_class.new.perform(message.id)
    end

    it "does not publish an inbound message" do
      message.update!(is_inbound: true)
      expect_any_instance_of(OutboundMailPublisher).not_to receive(:publish)
      described_class.new.perform(message.id)
    end

    it "is idempotent — skips when every destination was already published" do
      DeliveryStatus.create!(
        message: message,
        delivery_channel: DeliveryChannel.ensure_builtin(org),
        status: DeliveryStatus::STATUS_QUEUED,
        published_at: Time.current
      )
      expect_any_instance_of(OutboundMailPublisher).not_to receive(:publish)
      described_class.new.perform(message.id)
    end

    it "re-publishes when the row exists but never reached the queue" do
      # The failed-publish shape: the row is written before the publish is
      # attempted, so presence alone must not read as "already sent" — that is
      # what silently swallowed every prod send on 2026-09-09.
      DeliveryStatus.create!(
        message: message,
        delivery_channel: DeliveryChannel.ensure_builtin(org),
        status: DeliveryStatus::STATUS_QUEUED,
        published_at: nil
      )
      expect_any_instance_of(OutboundMailPublisher).to receive(:publish)
      described_class.new.perform(message.id)
    end
  end
end
