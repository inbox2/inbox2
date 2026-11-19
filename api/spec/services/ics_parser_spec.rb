require "rails_helper"

RSpec.describe IcsParser do
  def ics(body)
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n#{body}\r\nEND:VCALENDAR\r\n"
  end

  it "parses a basic timed VEVENT" do
    events = described_class.new(ics(<<~EV.strip)).parse
      BEGIN:VEVENT
      UID:abc-123@test
      SUMMARY:Team Sync
      DESCRIPTION:Weekly catch-up
      LOCATION:Room 4
      DTSTART:20260601T090000Z
      DTEND:20260601T100000Z
      SEQUENCE:2
      END:VEVENT
    EV

    expect(events.length).to eq(1)
    e = events.first
    expect(e[:uid]).to eq("abc-123@test")
    expect(e[:summary]).to eq("Team Sync")
    expect(e[:description]).to eq("Weekly catch-up")
    expect(e[:location]).to eq("Room 4")
    expect(e[:dtstart].utc.strftime("%Y-%m-%dT%H:%M:%S")).to eq("2026-06-01T09:00:00")
    expect(e[:dtend].utc.strftime("%H:%M")).to eq("10:00")
    expect(e[:all_day]).to be false
    expect(e[:sequence]).to eq(2)
    expect(e[:timezone]).to eq("UTC")
  end

  it "treats VALUE=DATE as an all-day event" do
    events = described_class.new(ics(<<~EV.strip)).parse
      BEGIN:VEVENT
      UID:allday@test
      SUMMARY:Holiday
      DTSTART;VALUE=DATE:20260704
      DTEND;VALUE=DATE:20260705
      END:VEVENT
    EV

    e = events.first
    expect(e[:all_day]).to be true
    expect(e[:dtstart].strftime("%Y-%m-%d")).to eq("2026-07-04")
  end

  it "honours TZID-qualified start times" do
    events = described_class.new(ics(<<~EV.strip)).parse
      BEGIN:VEVENT
      UID:tz@test
      SUMMARY:Local
      DTSTART;TZID=America/New_York:20260601T090000
      DTEND;TZID=America/New_York:20260601T100000
      END:VEVENT
    EV

    e = events.first
    expect(e[:timezone]).to eq("America/New_York")
    # 09:00 in New York (EDT, -4) == 13:00 UTC
    expect(e[:dtstart].utc.strftime("%H:%M")).to eq("13:00")
  end

  it "extracts organizer name and email" do
    events = described_class.new(ics(<<~EV.strip)).parse
      BEGIN:VEVENT
      UID:org@test
      SUMMARY:With organizer
      DTSTART:20260601T090000Z
      DTEND:20260601T100000Z
      ORGANIZER;CN="Jane Doe":mailto:jane@example.com
      END:VEVENT
    EV

    e = events.first
    expect(e[:organizer_email]).to eq("jane@example.com")
    expect(e[:organizer_name]).to eq("Jane Doe")
  end

  it "unfolds continuation lines and unescapes text" do
    raw = ics("BEGIN:VEVENT\r\nUID:fold@test\r\nSUMMARY:A very long title that has\r\n  been folded\r\nDESCRIPTION:line one\\nline two\\; and a comma\\, too\r\nDTSTART:20260601T090000Z\r\nDTEND:20260601T100000Z\r\nEND:VEVENT")
    e = described_class.new(raw).parse.first
    expect(e[:summary]).to eq("A very long title that has been folded")
    expect(e[:description]).to eq("line one\nline two; and a comma, too")
  end

  it "derives end from DURATION when DTEND is absent" do
    events = described_class.new(ics(<<~EV.strip)).parse
      BEGIN:VEVENT
      UID:dur@test
      SUMMARY:Durational
      DTSTART:20260601T090000Z
      DURATION:PT1H30M
      END:VEVENT
    EV

    e = events.first
    expect((e[:dtend] - e[:dtstart])).to eq(90 * 60)
  end

  it "parses multiple events" do
    events = described_class.new(ics(<<~EV.strip)).parse
      BEGIN:VEVENT
      UID:1@test
      SUMMARY:First
      DTSTART:20260601T090000Z
      DTEND:20260601T100000Z
      END:VEVENT
      BEGIN:VEVENT
      UID:2@test
      SUMMARY:Second
      DTSTART:20260602T090000Z
      DTEND:20260602T100000Z
      END:VEVENT
    EV

    expect(events.map { |e| e[:uid] }).to eq(["1@test", "2@test"])
  end

  it "returns an empty array for a valid calendar with no events" do
    expect(described_class.new(ics("")).parse).to eq([])
  end

  it "raises ParseError for non-iCalendar content" do
    expect { described_class.new("just some text").parse }.to raise_error(IcsParser::ParseError)
  end

  it "raises ParseError for an unparseable date" do
    expect {
      described_class.new(ics(<<~EV.strip)).parse
        BEGIN:VEVENT
        UID:bad@test
        DTSTART:not-a-date
        END:VEVENT
      EV
    }.to raise_error(IcsParser::ParseError)
  end
end
