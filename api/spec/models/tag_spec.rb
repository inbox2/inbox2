require "rails_helper"

# Spec 6.2.1 — Tag model
RSpec.describe Tag, type: :model do
  describe "validations" do
    subject { build(:tag) }

    it { should validate_presence_of(:name) }
    it { should validate_uniqueness_of(:name).scoped_to(:organization_id, :membership_id) }
    it { should validate_presence_of(:color) }
  end

  describe "associations" do
    it { should belong_to(:organization) }
  end

  describe "public ID (E5)" do
    it "generates a public ID with tag_ prefix" do
      tag = create(:tag)
      expect(tag.key).to start_with("tag_")
    end
  end
end
