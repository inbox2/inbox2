require "rails_helper"

RSpec.describe WaitlistSignup, type: :model do
  it "normalizes email to stripped lowercase" do
    s = create(:waitlist_signup, email: "  Foo@Example.COM ")
    expect(s.email).to eq("foo@example.com")
  end

  it "enforces case-insensitive email uniqueness" do
    create(:waitlist_signup, email: "dup@example.com")
    dup = build(:waitlist_signup, email: "DUP@example.com")
    expect(dup).not_to be_valid
    expect(dup.errors[:email]).to be_present
  end

  it "requires name and a well-formed email" do
    expect(build(:waitlist_signup, name: "")).not_to be_valid
    expect(build(:waitlist_signup, email: "not-an-email")).not_to be_valid
  end

  it "defaults to pending status" do
    expect(create(:waitlist_signup).status).to eq(WaitlistSignup::STATUS_PENDING)
  end

  describe "#generate_invite_token!" do
    it "mints a token and moves to invited" do
      s = create(:waitlist_signup)
      token = s.generate_invite_token!(invited_by: "adm_x")
      expect(token).to be_present
      expect(s.reload.status).to eq(WaitlistSignup::STATUS_INVITED)
      expect(s.invited_at).to be_present
      expect(s.invited_by).to eq("adm_x")
    end
  end

  describe ".find_redeemable_by_token" do
    it "finds only invited entries by their token" do
      s = create(:waitlist_signup, :invited)
      expect(described_class.find_redeemable_by_token(s.invite_token)).to eq(s)
      expect(described_class.find_redeemable_by_token("nope")).to be_nil
      expect(described_class.find_redeemable_by_token(nil)).to be_nil
    end
  end

  describe "#mark_registered!" do
    it "links the user, flips to registered, clears the token" do
      s = create(:waitlist_signup, :invited)
      user = create(:user)
      s.mark_registered!(user)
      expect(s.reload.status).to eq(WaitlistSignup::STATUS_REGISTERED)
      expect(s.user).to eq(user)
      expect(s.registered_at).to be_present
      expect(s.invite_token).to be_nil
    end
  end

  describe ".invite_only?" do
    it "reflects the INVITE_ENABLED env var" do
      orig = ENV["INVITE_ENABLED"]
      ENV["INVITE_ENABLED"] = "true"
      expect(described_class.invite_only?).to be(true)
      ENV["INVITE_ENABLED"] = "false"
      expect(described_class.invite_only?).to be(false)
    ensure
      ENV["INVITE_ENABLED"] = orig
    end
  end
end
