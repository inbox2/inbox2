require "rails_helper"

# Spec 2.1.1 — User model
RSpec.describe User, type: :model do
  describe "validations" do
    subject { build(:user) }

    it { should validate_presence_of(:username) }
    it { should validate_uniqueness_of(:username) }
    it { should validate_length_of(:username).is_at_least(3).is_at_most(50) }
    it { should have_secure_password }

    it "keeps billing_email unique per address, case-insensitively, and lower-cases it" do
      create(:user, billing_email: "Jo@Corp.com")
      dup = build(:user, billing_email: "jo@corp.com")
      expect(dup).not_to be_valid
      expect(User.find_by(billing_email: "JO@corp.com").billing_email).to eq("jo@corp.com")
    end
  end

  describe "reserved usernames" do
    it "refuses role addresses as a username, case-insensitively (they double as From addresses)" do
      expect(build(:user, username: "Info")).not_to be_valid
      expect(build(:user, username: "sales")).not_to be_valid
      expect(build(:user, username: "infoman")).to be_valid
    end
  end

  describe "associations" do
    it { should have_many(:sessions).dependent(:destroy) }
    it { should have_many(:memberships).dependent(:destroy) }
    it { should have_many(:organizations).through(:memberships) }
  end

  describe "public ID (E5)" do
    it "generates a public ID with usr_ prefix on create" do
      user = create(:user)
      expect(user.key).to start_with("usr_")
      expect(user.key.length).to be > 4
    end

    it "does not expose internal numeric ID" do
      user = create(:user)
      serialized = UserSerializer.new(user).to_h
      expect(serialized["id"]).to eq(user.key)
    end
  end

  describe "#accessible_organizations" do
    it "returns only organizations with active memberships" do
      user = create(:user)
      org1 = create(:organization, owner: user)
      org2 = create(:organization, owner: user)
      create(:membership, user: user, organization: org1, status: "active")
      create(:membership, user: user, organization: org2, status: "disabled")

      expect(user.accessible_organizations).to include(org1)
      expect(user.accessible_organizations).not_to include(org2)
    end
  end

  describe "TOTP" do
    let(:user) { create(:user) }
    let(:secret) { ROTP::Base32.random }

    it "stores the totp_secret encrypted at rest" do
      user.update!(totp_secret: secret)
      # The model attribute decrypts transparently...
      expect(user.reload.totp_secret).to eq(secret)
      # ...but the raw column value must be ciphertext, never the plaintext seed.
      raw = User.connection.select_value("SELECT totp_secret FROM users WHERE id = #{user.id}")
      expect(raw).not_to eq(secret)
      # Active Record Encryption stores a JSON envelope ({"p":<payload>,"h":{...}}).
      expect(JSON.parse(raw)).to include("p")
    end

    it "accepts a valid current code and rejects replay of the same code" do
      user.update!(totp_secret: secret, totp_enabled: true)
      code = ROTP::TOTP.new(secret).now

      expect(user.verify_totp(code)).to be(true)
      expect(user.verify_totp(code)).to be(false) # replay of an already-consumed step
    end

    it "rejects a code outside the tight drift window" do
      user.update!(totp_secret: secret, totp_enabled: true)
      old_code = ROTP::TOTP.new(secret).at(Time.current - 5.minutes)
      expect(user.verify_totp(old_code)).to be(false)
    end
  end

  describe "username validation" do
    it "rejects usernames with spaces" do
      user = build(:user, username: "has space")
      expect(user).not_to be_valid
    end

    it "allows underscores and hyphens" do
      user = build(:user, username: "test_user-1")
      expect(user).to be_valid
    end
  end
end
