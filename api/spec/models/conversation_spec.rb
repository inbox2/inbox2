require "rails_helper"

# Spec 3.1.2-3.1.5 — Conversation model
RSpec.describe Conversation, type: :model do
  describe "validations" do
    it { should validate_inclusion_of(:status).in_array(Conversation::STATUSES) }
  end

  describe "associations" do
    it { should belong_to(:organization) }
    it { should have_many(:messages).dependent(:destroy) }
    it { should have_many(:conversation_tags).dependent(:destroy) }
    it { should have_many(:tags).through(:conversation_tags) }
    it { should have_many(:conversation_assignees).dependent(:destroy) }
    it { should have_many(:assignees).through(:conversation_assignees) }
  end

  describe "public ID (E5)" do
    it "generates a public ID with conv_ prefix" do
      conversation = create(:conversation)
      expect(conversation.key).to start_with("conv_")
    end
  end

  describe "statuses (spec 6.1.1)" do
    it "supports Open, Pending, and Archived" do
      expect(Conversation::STATUSES).to eq(%w[open pending archived trash spam])
    end

    it "defaults to open" do
      conversation = create(:conversation)
      expect(conversation.status).to eq("open")
    end
  end

  describe "tagging (spec 6.2.2)" do
    it "supports multiple tags per conversation" do
      conv = create(:conversation)
      tag1 = create(:tag, organization: conv.organization, name: "billing")
      tag2 = create(:tag, organization: conv.organization, name: "urgent")
      conv.tags << tag1
      conv.tags << tag2
      expect(conv.tags.count).to eq(2)
    end
  end
end
