require "rails_helper"

# Spec 3.1.3 — Message model (RFC 5322 threading)
RSpec.describe Message, type: :model do
  describe "validations" do
    it { should validate_presence_of(:from_address) }
  end

  describe "associations" do
    it { should belong_to(:conversation) }
    it { should belong_to(:organization) }
  end

  describe "public ID (E5)" do
    it "generates a public ID with msg_ prefix" do
      message = create(:message)
      expect(message.key).to start_with("msg_")
    end
  end

  describe "encryption scheme (docs/E2EE.md Phase A)" do
    it "defaults to plaintext" do
      message = create(:message)
      expect(message.encryption_scheme).to eq(Message::ENCRYPTION_SCHEME_NONE)
      expect(message.sealed?).to be(false)
    end

    it "rejects unknown schemes" do
      message = build(:message, encryption_scheme: "rot13")
      expect(message).not_to be_valid
      expect(message.errors[:encryption_scheme]).to be_present
    end

    it "allows a sealed row without a plaintext sender (it lives in the header ciphertext)" do
      message = build(:message,
        encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
        from_address: nil, subject: nil, body_plain: nil)
      expect(message).to be_valid
      expect(message.sealed?).to be(true)
    end

    it "still requires from_address on plaintext rows" do
      expect(build(:message, from_address: nil)).not_to be_valid
    end
  end

  describe "RFC 5322 threading (spec 3.1.3)" do
    it "stores Message-ID, In-Reply-To, and References headers" do
      message = create(:message,
        message_id_header: "<abc123@example.com>",
        in_reply_to: "<parent@example.com>",
        references_header: "<parent@example.com> <grandparent@example.com>"
      )
      expect(message.message_id_header).to eq("<abc123@example.com>")
      expect(message.in_reply_to).to eq("<parent@example.com>")
      expect(message.references_header).to include("<parent@example.com>")
    end

    # A blank Message-ID must store as NULL, not "", or the second header-less mail
    # per org collides on the partial unique index and orphans its conversation.
    it "normalizes a blank Message-ID to nil so header-less mail doesn't collide" do
      org = create(:organization)
      m1 = create(:message, organization: org, message_id_header: "")
      m2 = create(:message, organization: org, message_id_header: "")
      expect(m1.message_id_header).to be_nil
      expect(m2.message_id_header).to be_nil
    end
  end
end
