require "rails_helper"

# spec 20.2.5 / TODO 46.8 — sender + assignees are notified when a delivery
# first lands on failed/bounced; upgrades between failure states stay silent.
RSpec.describe DeliveryFailureNotifier do
  let(:owner) { create(:user, username: "dfowner") }
  let(:org) { create(:organization, owner: owner, domain: "team.com") }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sender_mailbox) { Mailbox.create!(membership: owner_m, domain: org.default_domain, local_part: "support") }

  let(:assignee) { create(:user, username: "dfassignee") }
  let!(:assignee_m) { create(:membership, user: assignee, organization: org, role: "member", status: "active") }

  let(:conversation) { create(:conversation, organization: org, subject: "Order 42") }
  let(:message) do
    create(:message, conversation: conversation, organization: org,
           from_address: "support@team.com", to_address: "cust@external.com", is_inbound: false)
  end
  let!(:delivery_status) { create(:delivery_status, message: message) }

  before { conversation.conversation_assignees.create!(membership: assignee_m) }

  it "notifies the sending mailbox owner and the assignees once, on first failure" do
    expect {
      delivery_status.update!(status: DeliveryStatus::STATUS_FAILED, failed_at: Time.current)
    }.to change(Notification, :count).by(2)

    kinds = Notification.last(2).map(&:kind)
    expect(kinds).to all(eq(Notification::KIND_DELIVERY_FAILURE))
    expect(Notification.last(2).map(&:user)).to contain_exactly(owner, assignee)
    expect(Notification.last.title).to include("Order 42")
  end

  it "does not re-notify when failed upgrades to bounced" do
    delivery_status.update!(status: DeliveryStatus::STATUS_FAILED)
    expect {
      delivery_status.update!(status: DeliveryStatus::STATUS_BOUNCED, bounce_type: "hard")
    }.not_to change(Notification, :count)
  end

  it "stays silent on non-failure transitions" do
    expect {
      delivery_status.update!(status: DeliveryStatus::STATUS_SENDING)
      delivery_status.update!(status: DeliveryStatus::STATUS_DELIVERED)
    }.not_to change(Notification, :count)
  end

  it "dedupes when the sender is also an assignee" do
    conversation.conversation_assignees.create!(membership: owner_m)
    expect {
      delivery_status.update!(status: DeliveryStatus::STATUS_BOUNCED)
    }.to change(Notification, :count).by(2) # owner once + assignee once
  end
end
