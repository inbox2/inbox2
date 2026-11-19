require "rails_helper"

RSpec.describe SpaceClassifier do
  let(:owner) { create(:user, username: "classifyowner") }
  let(:org) { create(:organization, owner: owner, domain: "classify.com") }

  before { Space.ensure_default_spaces(org) }

  let(:conversation) do
    create(:conversation, organization: org, subject: "Refund for order 1234", from_address: "buyer@x.com",
                          to_address: "Support <support@classify.com>")
  end
  let!(:message) { create(:message, organization: org, conversation: conversation, body_plain: "I want my money back",
                                   to_address: "Support <support@classify.com>") }

  # A stand-in Jev: answers with a canned response and records what it was asked.
  class FakeJevClient
    attr_reader :calls

    def initialize(response, configured: true)
      @response = response
      @configured = configured
      @calls = []
    end

    def configured? = @configured
    def model = "jev-1.13.0"

    def ask(state:, questions:)
      @calls << { state: state, questions: questions }
      raise @response if @response.is_a?(Exception)

      @response
    end
  end

  def jev_response(label: "needs_answer", score: 2.5, space: "sales", probability: 0.9)
    {
      "model" => "jev-1.13.0",
      "answers" => {
        "label" => { "type" => "choice", "choice" => label },
        "priority" => { "type" => "score", "score" => score },
        "space" => { "type" => "choice", "choice" => space, "probabilities" => { space => probability } }
      }
    }
  end

  def fake_llm(reply: nil, configured: true)
    Class.new do
      define_method(:configured?) { configured }
      define_method(:complete) { |**| reply }
    end.new
  end

  def classifier(jev, llm: fake_llm, breaker: TriageBreaker::Null.new)
    described_class.new(org, provider: ClassificationProviders::Typesafe.new(client: jev), llm: llm, breaker: breaker)
  end

  describe "#classify" do
    it "writes label, priority, source and the space Jev picked" do
      classifier(FakeJevClient.new(jev_response)).classify(conversation, message)

      conversation.reload
      expect(conversation.triage_label).to eq("needs_answer")
      expect(conversation.triage_priority).to eq(2.5)
      expect(conversation.triage_source).to eq("jev:jev-1.13.0")
      expect(conversation.space.slug).to eq("sales")
    end

    # Manual triage (docs/Triage.md): a hand-picked label is re-judged by the next
    # Jev run, a hand-placed Space is not (Space is only asked while space_id is nil).
    it "overwrites a manual label but keeps a manually placed Space" do
      support = org.spaces.find_by!(slug: "support")
      conversation.update!(triage_label: "fyi", triage_source: TriageLabel::SOURCE_MANUAL, space: support)
      jev = FakeJevClient.new(jev_response(space: "sales"))

      classifier(jev).classify(conversation, message, new_thread: false)

      conversation.reload
      expect(conversation.triage_label).to eq("needs_answer")
      expect(conversation.triage_source).to eq("jev:jev-1.13.0")
      expect(conversation.space).to eq(support)
      expect(jev.calls.first[:questions]).not_to have_key("space")
    end

    it "sends the owner, the sender and the message text as the one-message state" do
      jev = FakeJevClient.new(jev_response)
      classifier(jev).classify(conversation, message)

      state = jev.calls.first[:state]
      expect(state[:owner]).to eq("support@classify.com")
      expect(state[:thread][:subject]).to eq("Refund for order 1234")
      expect(state[:thread][:messages]).to eq([{ direction: "received", from: message.from_address, text: "I want my money back" }])
    end

    it "strips quoted history from the message text" do
      message.update!(body_plain: "Yes please, go ahead.\n\nOn Mon, 1 Sep 2026 at 10:00, Ops <ops@x.com> wrote:\n> old stuff")
      jev = FakeJevClient.new(jev_response)
      classifier(jev).classify(conversation, message)
      expect(jev.calls.first[:state][:thread][:messages].first[:text]).to eq("Yes please, go ahead.")
    end

    it "asks the enabled labels in position order and the classifiable spaces (never the holding pen)" do
      TriageLabel.ensure_defaults(org)
      org.triage_labels.find_by!(slug: "resolved").update!(enabled: false)
      jev = FakeJevClient.new(jev_response)
      classifier(jev).classify(conversation, message)

      q = jev.calls.first[:questions]
      expect(q[:label][:criteria].keys).to eq(TriageLabel::BUILTIN_SLUGS - ["resolved"])
      expect(q[:space][:criteria].keys).to eq(%w[support sales marketing finance operations no_match])
    end

    it "falls back to the holding pen on no_match" do
      classifier(FakeJevClient.new(jev_response(space: "no_match"))).classify(conversation, message)
      expect(conversation.reload.space.slug).to eq("triage")
    end

    it "falls back to the holding pen when the space probability is below 0.5" do
      classifier(FakeJevClient.new(jev_response(probability: 0.49))).classify(conversation, message)
      expect(conversation.reload.space.slug).to eq("triage")
    end

    it "maps an unknown label to fyi" do
      classifier(FakeJevClient.new(jev_response(label: "deleted_mid_flight"))).classify(conversation, message)
      expect(conversation.reload.triage_label).to eq("fyi")
    end

    it "keeps the thread's space and skips the space question once it has one" do
      support = org.spaces.find_by!(slug: "support")
      conversation.update!(space: support)
      jev = FakeJevClient.new(jev_response(label: "resolved", space: "sales"))

      classifier(jev).classify(conversation, message, new_thread: false)

      expect(jev.calls.first[:questions]).not_to have_key(:space)
      expect(conversation.reload.space).to eq(support)
      expect(conversation.triage_label).to eq("resolved")
    end

    it "leaves the thread unlabelled in the holding pen when no provider is configured" do
      jev = FakeJevClient.new(jev_response, configured: false)
      classifier(jev).classify(conversation, message)

      expect(jev.calls).to be_empty
      expect(conversation.reload.space.slug).to eq("triage")
      expect(conversation.triage_label).to be_nil
    end

    it "treats a rejected key as unlabelled + holding pen (no retry)" do
      classifier(FakeJevClient.new(Jev::Client::AuthError.new("401"))).classify(conversation, message)
      expect(conversation.reload.space.slug).to eq("triage")
      expect(conversation.triage_label).to be_nil
    end

    it "raises a transient failure so the job can retry" do
      expect {
        classifier(FakeJevClient.new(Jev::Client::TransientError.new("529"))).classify(conversation, message)
      }.to raise_error(Jev::Client::TransientError)
      expect(conversation.reload.space_id).to be_nil
    end

    it "still labels when there are no classifiable spaces, without routing" do
      org.spaces.classifiable.destroy_all
      jev = FakeJevClient.new(jev_response)
      classifier(jev).classify(conversation, message)

      expect(jev.calls.first[:questions]).not_to have_key(:space)
      expect(conversation.reload.space_id).to be_nil
      expect(conversation.triage_label).to eq("needs_answer")
    end

    it "labels a sign-in code mail notification by rule, asking Jev only priority + space" do
      conversation.update!(subject: "Your sign-in code")
      message.update!(body_plain: "Your verification code is 482910. It expires in 10 minutes.")
      jev = FakeJevClient.new(jev_response(label: "needs_answer"))
      classifier(jev).classify(conversation, message)

      expect(jev.calls.first[:questions]).not_to have_key(:label)
      conversation.reload
      expect(conversation.triage_label).to eq(TriageLabel::NOTIFICATION)
      expect(conversation.triage_source).to eq("#{TriageLabel::SOURCE_RULE_OTP}+jev:jev-1.13.0")
      expect(conversation.triage_priority).to eq(2.5)
    end

    it "still applies the sign-in rule when no provider is configured" do
      message.update!(body_plain: "Use this one-time passcode to log in: 5521")
      classifier(FakeJevClient.new(jev_response, configured: false)).classify(conversation, message)
      expect(conversation.reload).to have_attributes(triage_label: TriageLabel::NOTIFICATION,
                                                     triage_source: TriageLabel::SOURCE_RULE_OTP)
    end

    it "never files spam itself" do
      message.update!(spam_score: 12.0)
      classifier(FakeJevClient.new(jev_response)).classify(conversation, message)
      expect(conversation.reload.status).not_to eq(Conversation::STATUS_SPAM)
    end

    describe "detected meetings (docs/Meeting-Invites.md)" do
      let(:reply) { '{"title":"Viewing","start":"2026-10-07T16:30","end":null,"location":"Prins Alexanderlaan 151, Rotterdam"}' }

      # Sent before the meeting it books: MeetingDetector drops a meeting dated before the mail.
      before { message.update!(body_plain: "Hierbij bevestig ik onze afspraak voor 7 oktober 2026 om 16:30 uur.", created_at: Time.zone.parse("2026-10-01")) }

      it "stores the meeting read out of a body with no ICS, on re-triage too" do
        classifier(FakeJevClient.new(jev_response), llm: fake_llm(reply: reply)).classify(conversation, message, new_thread: false)
        expect(message.reload.detected_meeting).to eq(
          "title" => "Viewing", "start" => "2026-10-07T16:30:00", "end" => nil,
          "location" => "Prins Alexanderlaan 151, Rotterdam"
        )
      end

      it "skips a message that already carries an ICS" do
        message.update!(calendar_invite: { "method" => "REQUEST", "uid" => "x" })
        classifier(FakeJevClient.new(jev_response), llm: fake_llm(reply: reply)).classify(conversation, message, new_thread: false)
        expect(message.reload.detected_meeting).to be_nil
      end
    end

    describe "summary (new threads only)" do
      it "stores the one-line OpenAI summary for a new thread" do
        classifier(FakeJevClient.new(jev_response), llm: fake_llm(reply: "Wants a refund on order 1234\nAlso shipping"))
          .classify(conversation, message)
        expect(conversation.reload.ai_summary_short).to eq("Wants a refund on order 1234")
      end

      it "sends the summary-only prompt" do
        llm = fake_llm(reply: "x")
        expect(llm).to receive(:complete).with(hash_including(system: described_class::SUMMARY_PROMPT)).and_return("x")
        classifier(FakeJevClient.new(jev_response), llm: llm).classify(conversation, message)
      end

      it "does not summarize a re-triaged thread" do
        llm = fake_llm(reply: "x")
        expect(llm).not_to receive(:complete)
        classifier(FakeJevClient.new(jev_response), llm: llm).classify(conversation, message, new_thread: false)
      end

      it "stores the summary and the Lore to-do title from one JSON reply" do
        llm = fake_llm
        reply = '{"summary":"Wants a refund on order 1234","title":"Refund order 1234 to the buyer."}'
        expect(llm).to receive(:complete).once
          .with(hash_including(response_format: described_class::SUMMARY_FORMAT)).and_return(reply)
        classifier(FakeJevClient.new(jev_response), llm: llm).classify(conversation, message)
        expect(conversation.reload).to have_attributes(ai_summary_short: "Wants a refund on order 1234",
                                                       next_action_title: "Refund order 1234 to the buyer")
      end

      it "leaves the title null when the reply has none" do
        classifier(FakeJevClient.new(jev_response), llm: fake_llm(reply: '{"summary":"Wants a refund"}'))
          .classify(conversation, message)
        expect(conversation.reload).to have_attributes(ai_summary_short: "Wants a refund", next_action_title: nil)
      end

      it "does not re-summarize when the title-only backfill finds a summary" do
        conversation.update!(ai_summary_short: "Kept")
        classifier(FakeJevClient.new(jev_response), llm: fake_llm(reply: '{"summary":"New","title":"Refund the buyer"}'))
          .summarize(conversation, message, title_only: true)
        expect(conversation.reload).to have_attributes(ai_summary_short: "Kept", next_action_title: "Refund the buyer")
      end

      it "parses the reply defensively" do
        expect(described_class.parse_summary('{"summary":"a\nb","title":"' + ("x" * 120) + '"}'))
          .to eq(["a", "x" * Conversation::NEXT_ACTION_TITLE_MAX])
        expect(described_class.parse_summary('{"summary":"a","title":"  "}')).to eq(["a", nil])
        expect(described_class.parse_summary('{"summary":"a","title":7}')).to eq(["a", nil])
        expect(described_class.parse_summary("[1]")).to eq(["[1]", nil])
        expect(described_class.parse_summary(nil)).to eq([nil, nil])
      end

      it "leaves the summary null when OpenAI isn't configured" do
        classifier(FakeJevClient.new(jev_response), llm: fake_llm(reply: "x", configured: false)).classify(conversation, message)
        expect(conversation.reload.ai_summary_short).to be_nil
      end
    end

    context "with a circuit breaker" do
      it "counts one triaged per Jev call" do
        breaker = instance_double(TriageBreaker, allow?: true)
        expect(breaker).to receive(:record_triaged!).once
        expect(breaker).not_to receive(:record_throttled!)
        classifier(FakeJevClient.new(jev_response), breaker: breaker).classify(conversation, message)
      end

      it "skips Jev and the summary, dropping to the holding pen, when throttled" do
        breaker = instance_double(TriageBreaker, allow?: false)
        expect(breaker).to receive(:record_throttled!)
        expect(breaker).not_to receive(:record_triaged!)
        jev = FakeJevClient.new(jev_response)
        llm = fake_llm(reply: "x")
        expect(llm).not_to receive(:complete)

        classifier(jev, llm: llm, breaker: breaker).classify(conversation, message)
        expect(jev.calls).to be_empty
        expect(conversation.reload.space.slug).to eq("triage")
      end
    end
  end

  describe "#classify_excerpt (sealed lane)" do
    it "triages from the excerpt and never writes a summary" do
      llm = fake_llm(reply: "x")
      expect(llm).not_to receive(:complete)
      jev = FakeJevClient.new(jev_response)

      classifier(jev, llm: llm).classify_excerpt(conversation, subject: "Buy", from: "b@corp.example",
                                                             to: "team@classify.com", excerpt: "50 licenses please")
      expect(jev.calls.first[:state][:thread][:messages].first[:text]).to eq("50 licenses please")
      expect(conversation.reload.triage_label).to eq("needs_answer")
      expect(conversation.ai_summary_short).to be_nil
    end
  end

  describe "#file_in_holding_pen" do
    it "parks an unrouted thread and leaves a routed one alone" do
      described_class.new(org).file_in_holding_pen(conversation)
      expect(conversation.reload.space.slug).to eq("triage")

      sales = org.spaces.find_by!(slug: "sales")
      conversation.update!(space: sales)
      described_class.new(org).file_in_holding_pen(conversation)
      expect(conversation.reload.space).to eq(sales)
    end
  end
end
