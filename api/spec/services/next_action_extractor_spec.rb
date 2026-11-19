require "rails_helper"

# The shared contract is the `next_action` parity fixture
# (cross_language_parity_spec.rb); these pin the edges.
RSpec.describe NextActionExtractor do
  let(:day) { Date.new(2026, 10, 20) }

  def run(text, label: TriageLabel::PAYMENT_DUE, subject: "x") = described_class.extract(label:, subject:, text:, message_date: day).to_h

  it "reads EU and US number formats" do
    expect(run("Total € 1.234,56")["amount_cents"]).to eq(123_456)
    expect(run("Total $1,234.56")["amount_cents"]).to eq(123_456)
    expect(run("Total €1.234")["amount_cents"]).to eq(123_400)
    expect(run("Bedrag € 2.400,-")["amount_cents"]).to eq(240_000)
  end

  it "takes a cued amount over a larger uncued one" do
    expect(run("Credit limit €5000. Amount due: €120.00")).to include("amount_cents" => 12_000, "currency" => "EUR")
  end

  it "reads Dutch dates and relative days" do
    expect(run("Graag betalen vóór 3 november 2026")["due_on"]).to eq("2026-11-03")
    expect(run("binnen 7 dagen")["due_on"]).to eq("2026-10-27")
  end

  it "returns nothing without a message date or for other labels" do
    expect(described_class.extract(label: "payment_due", subject: "x", text: "Total €5", message_date: nil).to_h.values).to all(be_nil)
    expect(run("Total €5", label: TriageLabel::FYI).values).to all(be_nil)
  end
end
