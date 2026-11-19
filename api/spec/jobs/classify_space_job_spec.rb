require "rails_helper"

RSpec.describe ClassifySpaceJob, type: :job do
  let(:owner) { create(:user, username: "jobowner") }
  let(:org) { create(:organization, owner: owner, domain: "jobclassify.com") }

  # AI triage is paid-only — give the org a plan with ai_triage on.
  before do
    Space.ensure_default_spaces(org)
    org.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE)
  end

  let(:conversation) { create(:conversation, organization: org, status: Conversation::STATUS_OPEN) }
  let!(:msg) { create(:message, organization: org, conversation: conversation, is_inbound: true) }

  def stub_classifier
    instance_double(SpaceClassifier).tap { |c| allow(SpaceClassifier).to receive(:new).and_return(c) }
  end

  it "triages a new thread with a breaker, then sends the deferred push" do
    classifier = instance_double(SpaceClassifier)
    expect(SpaceClassifier).to receive(:new).with(org, breaker: instance_of(TriageBreaker)).and_return(classifier)
    expect(classifier).to receive(:classify).with(conversation, msg, new_thread: true, retriage: false)
    expect(MobilePushSender).to receive(:notify_new_message).with(org, conversation, msg)

    described_class.perform_now(conversation.id)
  end

  it "re-triages a routed thread without pushing (the processor pushed inline)" do
    conversation.update!(space: org.spaces.find_by!(slug: "sales"))
    classifier = stub_classifier
    expect(classifier).to receive(:classify).with(conversation, msg, new_thread: false, retriage: false)
    expect(MobilePushSender).not_to receive(:notify_new_message)

    described_class.perform_now(conversation.id, false)
  end

  it "skips triage for a free-plan org (no Jev calls without a paid plan)" do
    free_org = create(:organization, owner: create(:user, username: "freejobowner"), domain: "freejob.com")
    conv = create(:conversation, organization: free_org)
    create(:message, organization: free_org, conversation: conv, is_inbound: true)

    expect(SpaceClassifier).not_to receive(:new)
    described_class.perform_now(conv.id, false)
  end

  it "skips a thread that is spam, trashed or archived" do
    conversation.update!(status: Conversation::STATUS_ARCHIVED)
    expect(SpaceClassifier).not_to receive(:new)
    expect(MobilePushSender).not_to receive(:notify_new_message)
    described_class.perform_now(conversation.id)
  end

  it "no-ops for a missing conversation" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "does not push a thread the user trashed before the job ran" do
    conversation.update!(status: Conversation::STATUS_TRASH)
    expect(MobilePushSender).not_to receive(:notify_new_message)
    described_class.perform_now(conversation.id)
  end

  describe "Jev outage" do
    include ActiveJob::TestHelper

    it "retries a transient failure" do
      allow(stub_classifier).to receive(:classify).and_raise(Jev::Client::TransientError, "529")
      expect(MobilePushSender).not_to receive(:notify_new_message)

      expect { described_class.perform_now(conversation.id) }.to have_enqueued_job(described_class)
    end

    it "gives up after the last attempt: holding pen + the push still goes out" do
      classifier = stub_classifier
      allow(classifier).to receive(:classify).and_raise(Jev::Client::TransientError, "529")
      expect(classifier).to receive(:file_in_holding_pen).with(conversation)
      expect(MobilePushSender).to receive(:notify_new_message).with(org, conversation, msg)

      perform_enqueued_jobs { described_class.perform_later(conversation.id) }
    end
  end
end
