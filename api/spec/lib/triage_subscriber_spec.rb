require "rails_helper"
require Rails.root.join("lib/triage_subscriber")

# docs/E2EE.md Phase E — the sealed-mail triage worker. Excerpts arrive from
# the transient memory stream; only low-information metadata (space, label,
# priority) is ever written back.
RSpec.describe TriageSubscriber, "#handle_excerpt" do
  let(:subscriber) { TriageSubscriber.allocate } # skip initialize (no NATS)
  let(:owner) { create(:user, username: "triage_owner") }
  let(:org) do
    create(:organization, owner: owner, domain: "triaged.example").tap do |o|
      o.update!(plan: create(:plan, e2ee: true, ai_triage: true, tier: Plan::TIER_PAID))
    end
  end
  let!(:sales) { create(:space, organization: org, name: "Sales", slug: "sales") }
  let!(:pen) { create(:space, organization: org, name: "Triage", slug: "triage", classify: false) }

  def sealed_message(msgid_hmac: "hmac-#{SecureRandom.hex(4)}")
    conv = create(:conversation, organization: org, subject: nil, from_address: nil, snippet: nil)
    create(:message, conversation: conv, organization: org,
      encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
      from_address: nil, subject: nil, body_plain: nil, body_html: nil,
      message_id_header: nil, msgid_hmac: msgid_hmac,
      sealed_dek: "blob", body_ciphertext: "ct", header_ciphertext: "ct")
  end

  def excerpt_for(message, body: "I'd like to buy 50 licenses")
    {
      "org_id" => org.id, "domain_id" => org.default_domain.id,
      "msgid_hmac" => message.msgid_hmac,
      "subject" => "Purchase inquiry", "from" => "buyer@corp.example",
      "to" => "team@triaged.example", "excerpt" => body
    }
  end

  def with_stub_provider(slug, label: nil)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("INBOX2_CLASSIFICATION_PROVIDER", anything).and_return("stub")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INBOX2_CLASSIFICATION_STUB_SLUG").and_return(slug)
    allow(ENV).to receive(:[]).with("INBOX2_CLASSIFICATION_STUB_LABEL").and_return(label)
  end

  it "labels the sealed conversation and writes nothing else" do
    with_stub_provider("sales")
    message = sealed_message
    before_attrs = message.reload.attributes

    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:ack)

    expect(message.conversation.reload.space_id).to eq(sales.id)
    expect(message.conversation.triage_label).to eq("fyi")
    expect(message.conversation.triage_source).to eq("stub")
    # The excerpt body must not have landed anywhere on the row.
    expect(message.reload.attributes).to eq(before_attrs)
    expect(message.conversation.snippet).to be_nil
    expect(message.conversation.subject).to be_nil
    expect(message.conversation.ai_summary_short).to be_nil
  end

  it "naks while the sealed row hasn't been written yet (consumer race)" do
    with_stub_provider("sales")
    result = subscriber.handle_excerpt(
      "org_id" => org.id, "msgid_hmac" => "not-yet-written", "subject" => "x", "excerpt" => "y"
    )
    expect(result).to eq(:nak)
  end

  it "re-runs the label on a routed thread but keeps its space (reply inherits)" do
    with_stub_provider("sales", label: "needs_answer")
    message = sealed_message
    message.conversation.update!(space_id: pen.id)

    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:ack)
    conv = message.conversation.reload
    expect(conv.space_id).to eq(pen.id)
    expect(conv.triage_label).to eq("needs_answer")
    expect(conv.ai_summary_short).to be_nil # never a plaintext summary of sealed mail
  end

  it "naks a transient Jev failure (redeliver within the TTL window)" do
    with_stub_provider("sales")
    allow_any_instance_of(ClassificationProviders::Stub).to receive(:triage).and_raise(Jev::Client::TransientError, "529")
    message = sealed_message

    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:nak)
  end

  it "acks without labeling when Rspamd marked the thread spam at ingest" do
    with_stub_provider("sales")
    message = sealed_message
    message.conversation.update!(status: Conversation::STATUS_SPAM)

    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:ack)
    expect(message.conversation.reload.space_id).to be_nil
  end

  it "acks without labeling when the org has no ai_triage entitlement" do
    with_stub_provider("sales")
    org.update!(plan: create(:plan, e2ee: true, ai_triage: false))
    message = sealed_message

    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:ack)
    expect(message.conversation.reload.space_id).to be_nil
  end

  it "acks (seal stands, unlabeled) when no provider is configured" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("INBOX2_CLASSIFICATION_PROVIDER", anything).and_return("stub")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INBOX2_CLASSIFICATION_STUB_SLUG").and_return(nil)

    message = sealed_message
    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:ack)
    expect(message.conversation.reload.space_id).to be_nil
  end

  it "naks on a provider exception (redeliver within the TTL window)" do
    with_stub_provider("sales")
    allow_any_instance_of(SpaceClassifier).to receive(:classify_excerpt).and_raise("provider exploded")
    message = sealed_message

    expect(subscriber.handle_excerpt(excerpt_for(message))).to eq(:nak)
  end

  it "acks an uncorrelatable excerpt (no msgid_hmac)" do
    expect(subscriber.handle_excerpt("org_id" => org.id, "msgid_hmac" => "")).to eq(:ack)
  end

  it "swapping providers changes nothing but the adapter (stub vs typesafe)" do
    # Same excerpt, provider selected purely by env — the vendor-independence
    # guarantee of the ClassificationProviders framework.
    with_stub_provider("sales")
    expect(ClassificationProviders.default).to be_a(ClassificationProviders::Stub)

    allow(ENV).to receive(:fetch).with("INBOX2_CLASSIFICATION_PROVIDER", anything).and_return("typesafe")
    expect(ClassificationProviders.default).to be_a(ClassificationProviders::Typesafe)
  end
end
