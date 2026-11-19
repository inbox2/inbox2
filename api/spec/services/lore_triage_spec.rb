require "rails_helper"

# Lore on MX (docs/Triage.md "Next-action fields", "Auto mode", "Upgrade re-triage").
RSpec.describe "Lore triage" do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner, domain: "solo.test") }
  let(:domain) { org.domains.first }
  let!(:owner_membership) { create(:membership, organization: org, user: owner, role: Membership::ROLE_OWNER) }

  before { Space.ensure_default_spaces(org) }

  def thread(label: nil, source: "jev:jev-1.13.0", status: Conversation::STATUS_OPEN, body: "Hello", updated_at: Time.current)
    conv = create(:conversation, organization: org, domain: domain, subject: "Factuur", status: status,
                                 triage_label: label, triage_source: source)
    create(:message, organization: org, conversation: conv, is_inbound: true, body_plain: body)
    conv.update_columns(updated_at: updated_at)
    conv
  end

  def jev(label)
    client = Class.new do
      define_method(:configured?) { true }
      define_method(:model) { "jev-1.13.0" }
      define_method(:ask) do |**|
        { "model" => "jev-1.13.0",
          "answers" => { "label" => { "type" => "choice", "choice" => label },
                         "priority" => { "type" => "score", "score" => 2.0 } } }
      end
    end.new
    llm = Class.new { def configured? = false }.new
    SpaceClassifier.new(org, provider: ClassificationProviders::Typesafe.new(client: client), llm: llm)
  end

  describe "next-action fields" do
    it "stores the due date and amount when the label lands" do
      conv = thread(body: "Te betalen: € 386,00 uiterlijk 24 oktober 2099.")
      jev(TriageLabel::PAYMENT_DUE).classify(conv, conv.messages.first)

      conv.reload
      expect(conv.next_action_amount_cents).to eq(38_600)
      expect(conv.next_action_currency).to eq("EUR")
      expect(conv.next_action_due_on).to eq(Date.new(2099, 10, 24))
      row = ConversationSerializer.new(conv).to_h
      expect(row).to include("next_action_due_on" => "2099-10-24", "next_action_amount_cents" => 38_600,
                             "next_action_currency" => "EUR")
    end

    it "clears them when the label leaves the next-action set" do
      conv = thread(body: "Total €10 due 2099-01-01")
      conv.update_columns(next_action_amount_cents: 1000, next_action_currency: "EUR")
      jev(TriageLabel::READ_LATER).classify(conv, conv.messages.first)

      expect(conv.reload.next_action_amount_cents).to be_nil
    end
  end

  describe "auto mode" do
    it "archives fyi for the domain's only member when they opted in, marking +auto" do
      owner.update!(lore_auto: { "fyi" => true })
      conv = thread
      jev(TriageLabel::FYI).classify(conv, conv.messages.first)

      conv.reload
      expect(conv.status).to eq(Conversation::STATUS_ARCHIVED)
      expect(conv.triage_source).to eq("jev:jev-1.13.0+auto")
    end

    it "trashes a notification" do
      owner.update!(lore_auto: { "notification" => true })
      conv = thread
      jev(TriageLabel::NOTIFICATION).classify(conv, conv.messages.first)
      expect(conv.reload.status).to eq(Conversation::STATUS_TRASH)
    end

    it "leaves the thread alone when the setting is off" do
      conv = thread
      jev(TriageLabel::FYI).classify(conv, conv.messages.first)
      expect(conv.reload.status).to eq(Conversation::STATUS_OPEN)
    end

    it "never acts on a shared domain inbox" do
      owner.update!(lore_auto: { "fyi" => true })
      create(:membership, organization: org, all_domains: true)
      conv = thread
      jev(TriageLabel::FYI).classify(conv, conv.messages.first)
      expect(conv.reload.status).to eq(Conversation::STATUS_OPEN)
    end

    it "never acts on a thread the person replied in" do
      owner.update!(lore_auto: { "fyi" => true })
      conv = thread
      create(:message, organization: org, conversation: conv, is_inbound: false)
      jev(TriageLabel::FYI).classify(conv, conv.messages.where(is_inbound: true).first)
      expect(conv.reload.status).to eq(Conversation::STATUS_OPEN)
    end

    it "never acts on a manual label" do
      owner.update!(lore_auto: { "fyi" => true })
      conv = thread(label: TriageLabel::FYI, source: TriageLabel::SOURCE_MANUAL)
      expect(LoreAuto.apply(conv)).to be_nil
    end

    it "is skipped on a re-triage" do
      owner.update!(lore_auto: { "fyi" => true })
      conv = thread
      jev(TriageLabel::FYI).classify(conv, conv.messages.first, new_thread: false, retriage: true)
      expect(conv.reload).to have_attributes(status: Conversation::STATUS_OPEN, triage_label: TriageLabel::FYI)
    end
  end

  describe LoreRetriageJob do
    before do
      org.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE)
      allow(SpaceClassifier).to receive(:enabled?).and_return(true)
    end

    it "scopes to open, recent, machine-labelled threads with an overlapping label, newest first" do
      older = thread(label: TriageLabel::FYI, updated_at: 2.days.ago)
      newer = thread(label: TriageLabel::ACTION_REQUIRED, source: "rule:action")
      thread(label: TriageLabel::FYI, source: TriageLabel::SOURCE_MANUAL)
      thread(label: TriageLabel::FYI, status: Conversation::STATUS_ARCHIVED)
      thread(label: TriageLabel::FYI, updated_at: 100.days.ago)
      thread(label: TriageLabel::NEEDS_ANSWER)
      thread(label: nil, source: nil)
      sealed = thread(label: TriageLabel::FYI)
      sealed.messages.update_all(encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1)

      expect(described_class.scope(org).to_a).to eq([newer, older])
    end

    it "caps the batch" do
      stub_const("LoreRetriageJob::CAP", 2)
      3.times { thread(label: TriageLabel::FYI) }
      expect(described_class.scope(org).count).to eq(2)
    end

    it "queues the threads once, in retriage mode, and marks the org" do
      conv = thread(label: TriageLabel::FYI)

      expect { described_class.perform_now(org.id) }
        .to have_enqueued_job(ClassifySpaceJob).with(conv.id, false, true)
      expect(org.reload.lore_retriaged_at).to be_present

      expect { described_class.perform_now(org.id) }.not_to have_enqueued_job(ClassifySpaceJob)
    end

    it "skips an org without AI triage and leaves it unmarked" do
      org.subscription.update!(plan: Plan.free)
      thread(label: TriageLabel::FYI)
      expect { described_class.perform_now(org.id) }.not_to have_enqueued_job(ClassifySpaceJob)
      expect(org.reload.lore_retriaged_at).to be_nil
    end

    it "sweeps only orgs not yet done" do
      org.update_columns(lore_retriaged_at: 1.day.ago)
      other = create(:organization)
      other.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE)

      expect { described_class.perform_now }.to have_enqueued_job(described_class).with(other.id).exactly(:once)
    end

    it "re-triage runs the classify path without push" do
      conv = thread(label: TriageLabel::FYI)
      classifier = instance_double(SpaceClassifier)
      allow(SpaceClassifier).to receive(:new).and_return(classifier)
      expect(classifier).to receive(:classify).with(conv, conv.messages.first, new_thread: false, retriage: true)
      expect(MobilePushSender).not_to receive(:notify_new_message)

      ClassifySpaceJob.perform_now(conv.id, false, true)
    end
  end
end
