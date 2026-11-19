require "rails_helper"

RSpec.describe View, type: :model do
  describe "validations" do
    it { should validate_presence_of(:name) }
    it { should validate_inclusion_of(:kind).in_array(View::KINDS) }
  end

  describe "associations" do
    it { should belong_to(:organization) }
  end

  describe "public ID (E5)" do
    it "generates a key with view_ prefix" do
      user = create(:user, username: "viewmodeluser")
      org = create(:organization, owner: user, domain: "viewmodel.com")
      view = create(:view, organization: org, name: "Test View")
      expect(view.key).to start_with("view_")
    end
  end

  describe ".ensure_system_views" do
    it "creates all system views for an organization" do
      user = create(:user, username: "sysviewuser")
      org = create(:organization, owner: user, domain: "sysview.com")

      expect { View.ensure_system_views(org) }.to change(View, :count).by(6)
      expect(org.views.system_views.pluck(:name)).to include("Inbox", "All Mail", "Mentioned", "Unassigned", "Sent", "Drafts")
    end

    it "is idempotent" do
      user = create(:user, username: "idempotent")
      org = create(:organization, owner: user, domain: "idempotent.com")

      View.ensure_system_views(org)
      expect { View.ensure_system_views(org) }.not_to change(View, :count)
    end

    it "Inbox is the open pool, not assigned-to-me" do
      user = create(:user, username: "inboxpool")
      org = create(:organization, owner: user, domain: "inboxpool.com")

      View.ensure_system_views(org)
      inbox = org.views.system_views.find_by(name: "Inbox")
      expect(inbox.filters).to eq([{ "field" => "status", "operator" => "equals", "value" => Conversation::STATUS_OPEN }])
    end

    it "self-heals a stale system-view filter on existing orgs" do
      user = create(:user, username: "staleview")
      org = create(:organization, owner: user, domain: "staleview.com")

      # Simulate an org seeded before the Inbox filter was migrated.
      View.create!(organization: org, name: "Inbox", kind: View::KIND_SYSTEM,
                   filters: [{ "field" => "assignee", "operator" => "is_me" }], position: 0)

      View.ensure_system_views(org)
      inbox = org.views.system_views.find_by(name: "Inbox")
      expect(inbox.filters).to eq([{ "field" => "status", "operator" => "equals", "value" => Conversation::STATUS_OPEN }])
    end
  end
end
