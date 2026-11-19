require "rails_helper"

RSpec.describe ListUnsubscribeService do
  let(:owner) { create(:user, username: "unsubreowner") }
  let(:org) { create(:organization, owner: owner, domain: "unsub.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org) }
  let(:message) { create(:message, conversation: conv, organization: org, to_address: "recipient@example.com") }

  subject { described_class.new(org, message) }

  describe "#headers (spec 18.4.2)" do
    it "generates List-Unsubscribe header with URL and mailto" do
      headers = subject.headers

      expect(headers["List-Unsubscribe"]).to include("unsubscribe")
      expect(headers["List-Unsubscribe"]).to include("mailto:unsubscribe@unsub.com")
    end

    it "generates List-Unsubscribe-Post header for one-click" do
      headers = subject.headers

      expect(headers["List-Unsubscribe-Post"]).to eq("List-Unsubscribe=One-Click")
    end
  end

  describe ".process_unsubscribe" do
    it "adds sender to blocklist from valid token" do
      headers = subject.headers
      # Extract token from the URL
      token = headers["List-Unsubscribe"].match(%r{unsubscribe/([^>]+)>})[1]

      expect {
        result = described_class.process_unsubscribe(token)
        expect(result[:unsubscribed]).to eq("recipient@example.com")
        expect(result[:organization]).to eq("unsub.com")
      }.to change(MailFilter, :count).by(1)
    end

    it "returns nil for invalid token" do
      expect(described_class.process_unsubscribe("invalid_token")).to be_nil
    end

    it "returns nil for expired token with bad org" do
      token = Base64.urlsafe_encode64({ org_id: 999999, from_address: "test@test.com" }.to_json)
      expect(described_class.process_unsubscribe(token)).to be_nil
    end
  end

  # A person's own mail must not be marked as list mail: receivers treat the
  # header as a bulk signal (Gmail spam placement, silent auto-responders).
  it "is not added to an ordinary outbound message" do
    conversation = create(:conversation)
    message = create(:message, conversation: conversation, is_inbound: false, from_address: "a@org.test", to_address: "b@example.com")
    expect(OutboundMailPublisher.new(message).compose_mime).not_to match(/^List-Unsubscribe/i)
  end
end
