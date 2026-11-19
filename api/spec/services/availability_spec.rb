require "rails_helper"

# The scheduling assistant's data source (docs/Calendar.md).
RSpec.describe Availability do
  let(:owner) { create(:user, username: "avowner", display_name: "Av Owner", default_timezone: "UTC") }
  let(:org) { create(:organization, owner: owner, domain: "av.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:domain) { org.domains.first }
  let!(:owner_mailbox) { Mailbox.create!(membership: membership, domain: domain, local_part: "avowner") }

  let(:colleague) { create(:user, username: "avmate", display_name: "Av Mate", default_timezone: "Europe/Amsterdam") }
  let!(:colleague_membership) { create(:membership, user: colleague, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
  let!(:colleague_mailbox) { Mailbox.create!(membership: colleague_membership, domain: domain, local_part: "avmate") }

  # Their own private calendar — the case that used to read as "free all week".
  let(:colleague_calendar) { org.calendars.create!(name: "Private", membership: colleague_membership) }

  # Monday 2 March 2026.
  let(:monday) { Time.utc(2026, 3, 2) }

  def book(cal, from, to, **attrs)
    cal.calendar_events.create!({
      organization: org, title: "Booked", start_at: from, end_at: to,
      created_by_membership: colleague_membership, organizer_email: colleague_mailbox.email_address
    }.merge(attrs))
  end

  def run(emails: [colleague_mailbox.email_address], from: monday, to: monday + 1.day, duration: 60)
    described_class.new(
      organization: org, membership: membership, emails: emails,
      range_start: from, range_end: to, duration_minutes: duration
    ).call
  end

  describe "attendee rows" do
    it "identifies a colleague with their name, timezone and working day" do
      row = run[:attendees].first

      expect(row[:email]).to eq("avmate@av.com")
      expect(row[:name]).to eq("Av Mate")
      expect(row[:internal]).to be(true)
      expect(row[:availability_known]).to be(true)
      expect(row[:timezone]).to eq("Europe/Amsterdam")
      expect(row[:working_hours][:start_minute]).to eq(User::DEFAULT_WORKING_HOURS["start_minute"])
    end

    it "marks an outside guest as unknown rather than free" do
      row = run(emails: ["outsider@example.com"])[:attendees].first

      expect(row[:internal]).to be(false)
      expect(row[:availability_known]).to be(false)
      expect(row[:working_hours]).to be_nil
      expect(row[:busy]).to eq([])
    end

    it "reports busy time from a colleague's private calendar" do
      book(colleague_calendar, monday + 10.hours, monday + 11.hours)

      busy = run[:attendees].first[:busy]
      expect(busy.size).to eq(1)
      expect(busy.first[:start]).to eq(monday + 10.hours)
    end

    it "does not reveal the title of an event the caller cannot open" do
      book(colleague_calendar, monday + 10.hours, monday + 11.hours, title: "Secret 1:1")

      expect(run[:attendees].first[:busy].first).not_to have_key(:title)
    end

    it "does include the title when the caller can already open the event" do
      shared = org.calendars.create!(name: "Shared", membership: nil)
      book(shared, monday + 10.hours, monday + 11.hours, title: "All-hands")

      expect(run[:attendees].first[:busy].first[:title]).to eq("All-hands")
    end

    it "expands a recurring booking into a busy block per occurrence" do
      book(colleague_calendar, monday + 9.hours, monday + 9.hours + 30.minutes,
           recurrence_rule: "FREQ=DAILY", timezone: "UTC")

      result = run(from: monday, to: monday + 5.days)
      expect(result[:attendees].first[:busy].size).to eq(5)
    end
  end

  describe "suggestions" do
    it "proposes slots inside the working day and skips booked time" do
      # 09:00–12:00 UTC booked; Amsterdam is UTC+1 in March (pre-DST).
      book(colleague_calendar, monday + 9.hours, monday + 12.hours)

      slots = run[:suggestions]
      expect(slots).not_to be_empty
      expect(slots.none? { |s| s[:start] < monday + 12.hours && s[:end] > monday + 9.hours }).to be(true)
    end

    it "ranks slots that suit everyone's working day first" do
      slots = run(from: monday, to: monday + 1.day)[:suggestions]

      expect(slots.first[:outside_working_hours]).to be_empty
      # 03:00 is technically free but must not outrank a mid-morning slot.
      expect(slots.first[:start].in_time_zone("Europe/Amsterdam").hour).to be >= User::DEFAULT_WORKING_HOURS["start_minute"] / 60
    end

    it "honours the requested duration" do
      slot = run(duration: 90)[:suggestions].first
      expect(slot[:end] - slot[:start]).to eq(90.minutes)
    end

    it "returns nothing when the whole window is booked solid" do
      book(colleague_calendar, monday, monday + 1.day)

      expect(run[:suggestions]).to be_empty
    end

    it "does not treat an outside guest's unknown calendar as a conflict" do
      slots = run(emails: ["outsider@example.com"])[:suggestions]
      expect(slots).not_to be_empty
    end

    it "skips the weekend when ranking" do
      saturday = Time.utc(2026, 3, 7)
      slots = described_class.new(
        organization: org, membership: membership, emails: [colleague_mailbox.email_address],
        range_start: saturday, range_end: saturday + 1.day, duration_minutes: 60
      ).call[:suggestions]

      # Everything on a Saturday is outside the working week, so every slot is
      # flagged rather than silently offered as normal.
      expect(slots.map { |s| s[:outside_working_hours] }.flatten.uniq).to eq(["avmate@av.com"])
    end

    it "does not let a declined invitation block a slot" do
      event = book(colleague_calendar, monday + 9.hours, monday + 12.hours)
      event.attendees.create!(email: colleague_mailbox.email_address,
                              response_status: CalendarAttendee::RESPONSE_DECLINED)
      # Organizer still counts as busy, so use an event they merely declined.
      event.update!(organizer_email: "someone-else@av.com")

      slots = run[:suggestions]
      expect(slots.any? { |s| s[:start] == monday + 9.hours }).to be(true)
    end
  end
end
