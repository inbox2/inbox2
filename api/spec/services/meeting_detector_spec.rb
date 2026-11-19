require "rails_helper"

RSpec.describe MeetingDetector do
  def llm(reply)
    Class.new do
      define_method(:configured?) { true }
      define_method(:complete) { |**| reply }
    end.new
  end

  it "reads a confirmed appointment" do
    m = described_class.detect(llm('{"title":"Viewing","start":"2026-10-07T16:30","end":"2026-10-07T17:30","location":"Rotterdam"}'),
                               subject: "Afspraak", text: "vrijdag 7 oktober 2026 om 16:30 uur", sent_at: Time.utc(2026, 10, 1))
    expect(m).to eq("title" => "Viewing", "start" => "2026-10-07T16:30:00", "end" => "2026-10-07T17:30:00", "location" => "Rotterdam")
  end

  it "drops a meeting dated before the mail was sent" do
    m = described_class.detect(llm('{"title":"Call","start":"2026-09-26T09:00"}'),
                               subject: "Re: review", text: "Can we talk at 9:00?", sent_at: Time.utc(2026, 9, 28))
    expect(m).to be_nil
  end

  it "doesn't call the model without a clock time in the text" do
    model = llm("x")
    expect(model).not_to receive(:complete)
    expect(described_class.detect(model, subject: "Invoice", text: "Pay before 7 October", sent_at: nil)).to be_nil
  end

  it "treats null, a date without a time and junk as no meeting" do
    expect(described_class.parse("null")).to be_nil
    expect(described_class.parse('{"start":"2026-10-07"}')).to be_nil
    expect(described_class.parse("{nope")).to be_nil
    expect(described_class.parse('{"start":"2026-10-0716:30","end":"2026-10-07THH:MM"}'))
      .to include("start" => "2026-10-07T16:30:00", "end" => nil)
  end
end
