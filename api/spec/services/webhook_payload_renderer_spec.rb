require "rails_helper"

RSpec.describe WebhookPayloadRenderer do
  let(:owner) { create(:user, username: "wprowner") }
  let(:org) { create(:organization, owner: owner, domain: "wpr.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org, subject: "Test Subject", from_address: "sender@example.com") }
  let(:message) { create(:message, conversation: conv, organization: org, from_address: "sender@example.com", to_address: "team@wpr.com", subject: "Re: Test Subject") }

  describe "#render" do
    context "with no payload_template" do
      let(:webhook) { create(:webhook, organization: org, payload_template: {}) }

      it "returns default payload (spec 7.4.6)" do
        renderer = described_class.new(webhook, conv, message: message, event: Webhook::EVENT_MESSAGE_CREATED)
        result = renderer.render

        expect(result["event"]).to eq(Webhook::EVENT_MESSAGE_CREATED)
        expect(result["conversation"]["id"]).to eq(conv.key)
        expect(result["conversation"]["subject"]).to eq("Test Subject")
        expect(result["message"]["id"]).to eq(message.key)
      end

      it "omits message when nil" do
        renderer = described_class.new(webhook, conv, event: Webhook::EVENT_CONVERSATION_UPDATED)
        result = renderer.render

        expect(result["event"]).to eq(Webhook::EVENT_CONVERSATION_UPDATED)
        expect(result).not_to have_key("message")
      end
    end

    context "with custom payload_template (spec 7.4.7)" do
      let(:webhook) do
        create(:webhook, organization: org, payload_template: {
          "text" => "New email: {{conversation.subject}} from {{message.from_address}}",
          "conv_id" => "{{conversation.id}}",
          "org" => "{{organization.domain}}"
        })
      end

      it "interpolates template placeholders" do
        renderer = described_class.new(webhook, conv, message: message, event: Webhook::EVENT_MESSAGE_CREATED)
        result = renderer.render

        expect(result["text"]).to eq("New email: Test Subject from sender@example.com")
        expect(result["conv_id"]).to eq(conv.key)
        expect(result["org"]).to eq("wpr.com")
      end
    end

    context "with nested template structure" do
      let(:webhook) do
        create(:webhook, organization: org, payload_template: {
          "blocks" => [
            { "type" => "section", "text" => "Subject: {{conversation.subject}}" }
          ]
        })
      end

      it "renders nested arrays and hashes" do
        renderer = described_class.new(webhook, conv, message: message)
        result = renderer.render

        expect(result["blocks"].first["text"]).to eq("Subject: Test Subject")
        expect(result["blocks"].first["type"]).to eq("section")
      end
    end

    context "with unknown placeholders" do
      let(:webhook) do
        create(:webhook, organization: org, payload_template: {
          "value" => "{{unknown.path}}"
        })
      end

      it "replaces unknown placeholders with empty string" do
        renderer = described_class.new(webhook, conv)
        result = renderer.render

        expect(result["value"]).to eq("")
      end
    end
  end
end
