require "rails_helper"

RSpec.describe EmailNotifier do
  let(:owner) { create(:user, username: "notifowner") }
  let(:org) { create(:organization, owner: owner, domain: "notifier.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:conv) { create(:conversation, organization: org) }

  describe ".notify" do
    it "creates a notification for assignment event" do
      expect {
        EmailNotifier.notify(user: owner, event: "assignment", conversation: conv, actor: membership)
      }.to change(Notification, :count).by(1)

      notification = Notification.last
      expect(notification.kind).to eq("assignment")
      expect(notification.user).to eq(owner)
      expect(notification.conversation).to eq(conv)
    end

    it "creates a notification for mention event" do
      notification = EmailNotifier.notify(user: owner, event: "mention", conversation: conv, actor: membership)
      expect(notification.title).to include("mentioned you")
    end

    it "ignores unknown events" do
      result = EmailNotifier.notify(user: owner, event: "unknown", conversation: conv)
      expect(result).to be_nil
    end
  end
end
