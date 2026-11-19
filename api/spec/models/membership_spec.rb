require "rails_helper"

# Spec 5.1 — Membership model
RSpec.describe Membership, type: :model do
  describe "validations" do
    subject { build(:membership) }

    it { should validate_inclusion_of(:role).in_array(Membership::ROLES) }
    it { should validate_inclusion_of(:status).in_array(Membership::STATUSES) }
    it { should validate_uniqueness_of(:user_id).scoped_to(:organization_id) }
  end

  describe "associations" do
    it { should belong_to(:user) }
    it { should belong_to(:organization) }
  end

  describe "public ID (E5)" do
    it "generates a public ID with mbr_ prefix" do
      membership = create(:membership)
      expect(membership.key).to start_with("mbr_")
    end
  end

  describe "role predicates" do
    it "owner? is true only for owner" do
      expect(build(:membership, role: "owner")).to be_owner
      expect(build(:membership, role: "admin")).not_to be_owner
    end

    it "admin? is true for owner and admin" do
      expect(build(:membership, role: "owner")).to be_admin
      expect(build(:membership, role: "admin")).to be_admin
      expect(build(:membership, role: "member")).not_to be_admin
    end

    it "member? is true only for member" do
      expect(build(:membership, role: "member")).to be_member
      expect(build(:membership, role: "admin")).not_to be_member
    end

    it "rank orders owner > admin > member" do
      expect(build(:membership, role: "owner").rank).to be > build(:membership, role: "admin").rank
      expect(build(:membership, role: "admin").rank).to be > build(:membership, role: "member").rank
    end
  end

  describe "#can_grant_role? — admins grant member only; owners grant any" do
    let(:owner)  { build(:membership, role: "owner") }
    let(:admin)  { build(:membership, role: "admin") }
    let(:member) { build(:membership, role: "member") }

    it "lets an owner grant any role" do
      expect(owner.can_grant_role?("owner")).to be(true)
      expect(owner.can_grant_role?("admin")).to be(true)
      expect(owner.can_grant_role?("member")).to be(true)
    end

    it "lets an admin grant only member" do
      expect(admin.can_grant_role?("member")).to be(true)
      expect(admin.can_grant_role?("admin")).to be(false)
      expect(admin.can_grant_role?("owner")).to be(false)
    end

    it "lets a member grant nothing" do
      expect(member.can_grant_role?("member")).to be(false)
    end
  end
end
