require "rails_helper"

RSpec.describe Jev::Client do
  let(:client) { described_class.new(api_key: "tsk_test", model: "jev-1.13.0") }
  let(:questions) { { priority: { type: "score", instructions: "?", criteria: %w[a b] } } }

  def stub_response(code, body = "{}")
    res = instance_double(Net::HTTPResponse, code: code.to_s, body: body)
    captured = {}
    allow_any_instance_of(Net::HTTP).to receive(:request) do |http, req|
      captured[:http] = http
      captured[:req] = req
      res
    end
    captured
  end

  it "POSTs model/state/questions with the bearer key and returns the parsed answers" do
    captured = stub_response(200, { model: "jev-1.13.0", answers: { priority: { score: 1.0 } } }.to_json)

    result = client.ask(state: { owner: "a@b.c" }, questions: questions)

    expect(result["model"]).to eq("jev-1.13.0")
    expect(result.dig("answers", "priority", "score")).to eq(1.0)
    req = captured[:req]
    expect(req.path).to eq("/v1/systemone")
    expect(req["Authorization"]).to eq("Bearer tsk_test")
    expect(JSON.parse(req.body).keys).to eq(%w[model state questions])
    expect(JSON.parse(req.body)["model"]).to eq("jev-1.13.0")
    expect(captured[:http].open_timeout).to eq(5)
    expect(captured[:http].read_timeout).to eq(20)
  end

  it "raises AuthError on 401" do
    stub_response(401)
    expect { client.ask(state: {}, questions: questions) }.to raise_error(described_class::AuthError)
  end

  it "raises RequestError on 422 and logs the body" do
    stub_response(422, '{"detail":"questions.priority.criteria"}')
    expect(Rails.logger).to receive(:error).with(/questions\.priority\.criteria/)
    expect { client.ask(state: {}, questions: questions) }.to raise_error(described_class::RequestError)
  end

  [429, 500, 503, 529].each do |code|
    it "raises TransientError on #{code}" do
      stub_response(code)
      expect { client.ask(state: {}, questions: questions) }.to raise_error(described_class::TransientError)
    end
  end

  it "raises TransientError on a timeout" do
    allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(Net::ReadTimeout)
    expect { client.ask(state: {}, questions: questions) }.to raise_error(described_class::TransientError)
  end

  it "is configured only with a key and defaults to the pinned model" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TYPESAFE_API_KEY").and_return(nil)
    allow(ENV).to receive(:[]).with("TYPESAFE_MODEL").and_return(nil)
    default = described_class.default
    expect(default.configured?).to be(false)
    expect(default.model).to eq("jev-1.13.0")
  end
end

RSpec.describe JevTriage, ".verdict" do
  let(:labels) { TriageLabel::BUILTIN.map { |l| Struct.new(*l.keys, :enabled).new(*l.values, true) } }
  let(:spaces) { [Struct.new(:slug, :name, :description, :not_for).new("sales", "Sales", "quotes", nil)] }
  let(:questions) { described_class.questions(labels: labels, spaces: spaces) }

  def response(label: "needs_answer", space: "sales", probability: 0.8, score: 3.2)
    { "model" => "jev-1.13.0",
      "answers" => { "label" => { "choice" => label }, "priority" => { "score" => score },
                     "space" => { "choice" => space, "probabilities" => { space => probability } } } }
  end

  it "reads label, priority (float), space and provenance" do
    v = described_class.verdict(response, questions)
    expect(v.to_h).to eq(label: "needs_answer", priority: 3.2, space: "sales", source: "jev:jev-1.13.0")
  end

  it "maps an unknown label to fyi" do
    expect(described_class.verdict(response(label: "gone"), questions).label).to eq("fyi")
  end

  it "keeps a space at exactly 0.5 and drops it below or on no_match" do
    expect(described_class.verdict(response(probability: 0.5), questions).space).to eq("sales")
    expect(described_class.verdict(response(probability: 0.4999), questions).space).to be_nil
    expect(described_class.verdict(response(space: "no_match", probability: 0.9), questions).space).to be_nil
  end

  it "ignores answers to questions that weren't asked" do
    q = described_class.questions(labels: labels, spaces: [], ask_label: false)
    v = described_class.verdict(response, q)
    expect(v.label).to be_nil
    expect(v.space).to be_nil
  end
end
