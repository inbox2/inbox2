require "rails_helper"

RSpec.describe WebhookDeliveryJob, type: :job do
  let(:owner) { create(:user, username: "whkjobowner") }
  let(:org) { create(:organization, owner: owner, domain: "whkjob.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org, subject: "Hello there") }
  let(:message) { create(:message, conversation: conv, organization: org, from_address: "a@b.com", to_address: "khuram@whkjob.com", body_plain: "hi") }
  let(:rule) { create(:rule, organization: org, conditions: [{ "field" => "from", "operator" => "contains", "value" => "b.com" }], actions: [{ "type" => "webhook", "value" => "x" }]) }
  let(:webhook) { create(:webhook, organization: org, url: "https://example.com/hook", secret: "s3cr3t") }

  # Capture the outgoing request without hitting the network.
  def stub_http(code: "200")
    captured = {}
    response = instance_double(Net::HTTPResponse, code: code)
    allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, req|
      captured[:req] = req
      captured[:body] = req.body
      response
    end
    captured
  end

  it "POSTs a signed JSON body for a non-sealed message" do
    captured = stub_http
    described_class.perform_now(webhook.id, conv.id, message.id, rule.id)

    req = captured[:req]
    expect(req["Content-Type"]).to eq("application/json")
    expect(req["X-Inbox2-Event"]).to eq(Webhook::EVENT_RULE_MATCHED)
    expected_sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", "s3cr3t", captured[:body])
    expect(req["X-Inbox2-Signature"]).to eq(expected_sig)

    body = JSON.parse(captured[:body])
    expect(body["event"]).to eq("rule.matched")
    expect(body.dig("message", "from")).to eq("a@b.com")
    expect(body.dig("conversation", "subject")).to eq("Hello there")
  end

  it "sends a metadata-only body for a sealed message (no plaintext leaks)" do
    sealed = create(:message, conversation: conv, organization: org, from_address: nil,
                              subject: nil, body_plain: nil,
                              encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1)
    captured = stub_http
    described_class.perform_now(webhook.id, conv.id, sealed.id, rule.id)

    body = JSON.parse(captured[:body])
    expect(body.dig("message", "sealed")).to be(true)
    expect(body["message"]).not_to have_key("from")
    expect(body["message"]).not_to have_key("subject")
    expect(body.dig("conversation", "sealed")).to be(true)
    expect(body["conversation"]).not_to have_key("subject")
  end

  # Tested at the deliver level: retry_on would swallow the raise under perform_now
  # (re-enqueueing instead). The raise is what drives that retry.
  it "raises DeliveryError on a 5xx response (drives a retry)" do
    stub_http(code: "503")
    expect {
      described_class.new.send(:deliver, webhook, "{}")
    }.to raise_error(WebhookDeliveryJob::DeliveryError)
  end

  it "does nothing for a disabled webhook" do
    webhook.update!(enabled: false)
    expect_any_instance_of(Net::HTTP).not_to receive(:request)
    described_class.perform_now(webhook.id, conv.id, message.id, rule.id)
  end

  it "omits the signature header when the webhook has no secret" do
    webhook.update!(secret: nil)
    captured = stub_http
    described_class.perform_now(webhook.id, conv.id, message.id, rule.id)
    expect(captured[:req]["X-Inbox2-Signature"]).to be_nil
  end
end
