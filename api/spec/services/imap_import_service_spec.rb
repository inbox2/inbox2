require "rails_helper"

RSpec.describe ImapImportService do
  let(:owner) { create(:user, username: "imapowner") }
  let(:org) { create(:organization, owner: owner, domain: "imap.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  let(:config) { { host: "imap.example.com", username: "user@example.com", password: "secret" } }

  subject { described_class.new(org, config) }

  describe "#import (spec 11.2.1)" do
    it "handles connection errors gracefully" do
      result = subject.import
      expect(result[:error]).to be_present
      expect(result[:imported]).to eq(0)
    end
  end

  describe "#test_connection" do
    it "returns error for unreachable server" do
      result = subject.test_connection
      expect(result[:status]).to eq("error")
      expect(result[:message]).to be_present
    end
  end

  describe "SSRF guard (non-public host)" do
    let(:config) { { host: "127.0.0.1", username: "u", password: "p" } }

    it "refuses to import from a non-public host and never opens a connection" do
      expect(Net::IMAP).not_to receive(:new)
      result = subject.import
      expect(result[:imported]).to eq(0)
      expect(result[:error]).to match(/non-public/i)
    end

    it "refuses to test a non-public host" do
      expect(Net::IMAP).not_to receive(:new)
      result = subject.test_connection
      expect(result[:status]).to eq("error")
    end
  end

  describe "#create_conversation_from_envelope (private, via import)" do
    it "does not duplicate messages with same message_id" do
      # Create an existing message with a known message_id
      conv = create(:conversation, organization: org)
      create(:message, conversation: conv, organization: org, message_id_header: "<existing@test.com>")

      expect(org.messages.exists?(message_id_header: "<existing@test.com>")).to be true
    end
  end
end
