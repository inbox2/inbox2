require "rails_helper"
require "ostruct"

# Cross-language parity: the Ruby half of the shared contract in
# fixtures/parity/fixtures.json. The Rust half lives in
# ui/desktop/core/src/parity_tests.rs and drives the SAME file. See
# fixtures/parity/README.md for the drift report.
#
# "agreed" cases assert the output both engines currently produce — locking
# behaviour that matches so it cannot silently drift. "divergences" cases assert
# the Ruby-specific output ("ruby" column); the Rust suite asserts its own
# ("rust") column. A change on either side breaks a test and forces the fixture
# (and the report) to be updated.
RSpec.describe "Cross-language parity (Ruby half)" do
  FIXTURES = JSON.parse(Rails.root.join("..", "fixtures", "parity", "fixtures.json").read).freeze

  # --- SnippetBuilder <-> threading::build_snippet ---------------------------
  describe "snippet" do
    FIXTURES["snippet"]["agreed"].each do |c|
      it "agreed: #{c['name']}" do
        expect(SnippetBuilder.build(c["body_plain"], c["body_html"])).to eq(c["expected"])
      end
    end

    FIXTURES["snippet"]["divergences"].each do |c|
      it "divergence: #{c['name']} (#{c['note']})" do
        expect(SnippetBuilder.build(c["body_plain"], c["body_html"])).to eq(c["ruby"])
      end
    end
  end

  # --- OtpDetector <-> otp::detect -------------------------------------------
  describe "otp" do
    FIXTURES["otp"]["agreed"].each do |c|
      it "agreed: #{c['name']}" do
        got = OtpDetector.detect(subject: c["subject"], body_plain: c["body_plain"], body_html: c["body_html"], snippet: c["snippet"])
        expect(got).to eq(c["expected"])
      end
    end
  end

  # --- NextActionExtractor <-> next_action::extract -------------------------
  describe "next_action" do
    FIXTURES["next_action"]["agreed"].each do |c|
      it "agreed: #{c['name']}" do
        got = NextActionExtractor.extract(label: c["label"], subject: c["subject"], text: c["text"],
                                          message_date: Date.iso8601(c["message_date"]))
        expect(got.to_h).to eq(c["expected"])
      end
    end
  end

  # --- SubjectNormalizer <-> threading::normalize_subject --------------------
  describe "subject" do
    FIXTURES["subject"]["agreed"].each do |c|
      it "agreed: #{c['name']}" do
        expect(SubjectNormalizer.normalize(c["input"])).to eq(c["expected"])
      end
    end

    FIXTURES["subject"]["divergences"].each do |c|
      it "divergence: #{c['name']} (#{c['note']})" do
        expect(SubjectNormalizer.normalize(c["input"])).to eq(c["ruby"])
      end
    end
  end

  # --- RuleExecutor#match_rule? <-> rules::conditions::conditions_match -------
  describe "conditions" do
    let(:msg_fixture) { FIXTURES["conditions"]["message"] }
    let(:conversation) { OpenStruct.new(subject: msg_fixture["subject"]) }
    let(:message) do
      OpenStruct.new(
        from_address: msg_fixture["from"],
        to_address: msg_fixture["to"],
        body_plain: msg_fixture["body"],
        # build_target_cache calls message.attachments.any?; the fixture's
        # has_attachment flag decides whether the collection is non-empty.
        attachments: msg_fixture["has_attachment"] ? [Object.new] : []
      )
    end

    # The fixture uses {field, op, value}; RuleExecutor expects "operator".
    def to_rule_conditions(conditions)
      conditions.map { |c| { "field" => c["field"], "operator" => c["op"], "value" => c["value"] } }
    end

    def matches?(conditions)
      RuleExecutor.new(nil).match_rule?(to_rule_conditions(conditions), conversation, message)
    end

    FIXTURES["conditions"]["agreed"].each do |c|
      it "agreed: #{c['name']}" do
        expect(matches?(c["conditions"])).to eq(c["expected"])
      end
    end

    FIXTURES["conditions"]["divergences"].each do |c|
      it "divergence: #{c['name']} (#{c['note']})" do
        expect(matches?(c["conditions"])).to eq(c["ruby"])
      end
    end
  end

  # --- JevTriage.questions/state <-> triage::jev_questions/jev_state ----------
  # Byte-identical JSON (key order included): the Jev request is the contract.
  describe "jev_triage" do
    let(:fixture) { FIXTURES["jev_triage"] }

    def labels_for(spec)
      rows = spec == "builtin" ? fixture["builtin_labels"].map { |l| l.merge("enabled" => true) } : spec
      rows.map { |l| OpenStruct.new(l) }
    end

    it "built-in labels match TriageLabel::BUILTIN" do
      expect(TriageLabel::BUILTIN.map { |l| l.transform_keys(&:to_s) }).to eq(fixture["builtin_labels"])
    end

    it "priority levels, model, holding pen and space threshold match" do
      expect(JevTriage::PRIORITY_LEVELS).to eq(fixture["priority_levels"])
      expect(Jev::Client::DEFAULT_MODEL).to eq(fixture["model"])
      expect(Space::HOLDING_PEN_SLUG).to eq(fixture["space_holding_pen"])
      expect(JevTriage::SPACE_MIN_PROBABILITY).to eq(fixture["space_min_probability"])
    end

    it "state: example" do
      ex = fixture["state_example"]
      built = JevTriage.state(
        owner: ex["owner"], subject: ex["subject"],
        messages: ex["messages"].map { |m| m.transform_keys(&:to_sym) }
      )
      expect(JSON.generate(built)).to eq(JSON.generate(ex["expected"]))
    end

    FIXTURES["jev_triage"]["agreed"].each do |c|
      it "agreed: #{c['name']}" do
        built = JevTriage.questions(
          labels: labels_for(c["labels"]),
          spaces: c["spaces"].map { |s| OpenStruct.new(s) },
          ask_label: c["ask_label"]
        )
        expect(JSON.generate(built)).to eq(JSON.generate(c["expected"]))
      end
    end
  end
end
