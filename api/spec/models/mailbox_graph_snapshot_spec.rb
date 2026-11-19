require "rails_helper"

RSpec.describe MailboxGraphSnapshot, type: :model do
  describe "associations" do
    it { should belong_to(:organization) }
  end

  describe "validations" do
    it { should validate_presence_of(:computed_at) }
    it { should validate_presence_of(:source_version) }
  end

  describe "public ID generation" do
    it "generates a key with mgs_ prefix on create" do
      org = create(:organization)
      snapshot = create(:mailbox_graph_snapshot, organization: org)
      expect(snapshot.key).to start_with("mgs_")
      expect(snapshot.key.length).to be > 4
    end
  end
end
