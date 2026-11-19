require "rails_helper"

# docs/E2EE.md Phase G — notifications under sealing. The push spec transits
# solid_queue_jobs.arguments and the APNs/FCM wire, so for sealed mail it must
# be content-free (IDs only + sealed flag), while plaintext mail keeps its rich
# alert.
RSpec.describe MobilePushSender, "sealed mail (Phase G)" do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, username: "push_owner") }
  let(:org) { create(:organization, owner: owner, domain: "push-sealed.example") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:device) { create(:push_device, user: owner) }

  before do
    allow(MobilePushConfig).to receive(:configured?).and_return(true)
    allow(owner).to receive(:push_enabled?).and_return(true)
  end

  def sealed_message
    conv = create(:conversation, organization: org, subject: nil, from_address: nil, snippet: nil)
    create(:message, conversation: conv, organization: org,
      encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
      from_address: nil, subject: nil, body_plain: nil, body_html: nil,
      message_id_header: nil, msgid_hmac: "hmac-x", domain_key_version: 3,
      sealed_dek: "blob", body_ciphertext: "SECRET-CT", header_ciphertext: "SECRET-CT")
  end

  def plaintext_message
    conv = create(:conversation, organization: org, subject: "Q3 numbers", from_address: "alice@ext.example",
                                 snippet: "the numbers look bad")
    create(:message, conversation: conv, organization: org,
      from_address: "alice@ext.example", subject: "Q3 numbers", body_plain: "the numbers look bad")
  end

  it "builds a content-free spec for sealed mail (no sender/subject/snippet anywhere)" do
    message = sealed_message

    described_class.new_message(owner, organization: org, conversation: message.conversation, message: message)

    job = enqueued_jobs.find { |j| j["job_class"] == "MobilePushDeliveryJob" }
    expect(job).to be_present
    spec = job["arguments"][1]
    args_json = job["arguments"].to_json

    expect(spec["alert"]["title"]).to eq("New message")
    expect(spec["alert"]["body"]).to eq("")
    expect(spec["data"]["sealed"]).to eq("true")
    expect(spec["data"]["domain_key_version"]).to eq("3")
    expect(spec["data"]["conversation_id"]).to eq(message.conversation.key)
    expect(spec["data"]["message_id"]).to eq(message.key)
    expect(args_json).not_to include("SECRET")

    # The wire payloads built from this spec are content-free too.
    apns = MobilePushPayloadBuilder.apns_body(spec)
    fcm = MobilePushPayloadBuilder.fcm_message(spec, token: "tok")
    expect(apns.dig("aps", "alert", "title")).to eq("New message")
    expect(apns.to_json).not_to include("SECRET")
    expect(fcm.to_json).not_to include("SECRET")
  end

  it "uses the MX-shipped preview when the domain opted in (from + subject, nothing more)" do
    message = sealed_message

    described_class.new_message(owner, organization: org, conversation: message.conversation,
      message: message, sealed_preview: { "from" => "Alice <alice@ext.example>", "subject" => "Q3 SECRET-SUBJECT plans" })

    job = enqueued_jobs.find { |j| j["job_class"] == "MobilePushDeliveryJob" }
    spec = job["arguments"][1]
    expect(spec["alert"]["title"]).to eq("Alice <alice@ext.example>")
    expect(spec["alert"]["body"]).to eq("Q3 SECRET-SUBJECT plans")
    # Still flagged sealed for the client; ciphertext/body never rides along.
    expect(spec["data"]["sealed"]).to eq("true")
    expect(job["arguments"].to_json).not_to include("SECRET-CT")
  end

  it "keeps the rich alert for plaintext mail" do
    message = plaintext_message

    described_class.new_message(owner, organization: org, conversation: message.conversation, message: message)

    job = enqueued_jobs.find { |j| j["job_class"] == "MobilePushDeliveryJob" }
    spec = job["arguments"][1]
    expect(spec["alert"]["title"]).to eq("alice@ext.example")
    expect(spec["alert"]["body"]).to include("Q3 numbers")
  end

  it "keeps the desktop cable alert content-free for sealed mail" do
    message = sealed_message

    expect {
      described_class.new_message(owner, organization: org, conversation: message.conversation, message: message)
    }.to have_broadcasted_to("push_sync_#{owner.key}").with(hash_including(
      "type" => "new_message", "from_address" => "New message", "subject" => "", "snippet" => ""
    ))
  end
end
