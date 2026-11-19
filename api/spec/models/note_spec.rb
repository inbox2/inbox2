require "rails_helper"

# Spec 9.1.1 — Note model
RSpec.describe Note, type: :model do
  describe "validations" do
    it { should validate_presence_of(:body) }
  end

  describe "associations" do
    it { should belong_to(:conversation) }
    it { should belong_to(:organization) }
    it { should belong_to(:membership) }
  end

  describe "public ID (E5)" do
    it "generates a public ID with note_ prefix" do
      user = create(:user, username: "noteuser")
      org = create(:organization, owner: user, domain: "notemodel.com")
      membership = create(:membership, user: user, organization: org, role: "owner", status: "active")
      conv = create(:conversation, organization: org)
      note = create(:note, conversation: conv, organization: org, membership: membership)
      expect(note.key).to start_with("note_")
    end
  end
end
