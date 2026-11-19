require "rails_helper"

# Recurrence expansion (docs/Calendar.md). Before this existed a weekly series
# rendered exactly once — on the day it started — because only the master row
# is stored.
RSpec.describe CalendarOccurrences do
  let(:owner) { create(:user, username: "occowner") }
  let(:org) { create(:organization, owner: owner, domain: "occ.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:calendar) { org.calendars.create!(name: "Team", membership: membership) }

  # A fixed anchor keeps DST assertions meaningful rather than relative to today.
  let(:series_start) { Time.utc(2026, 1, 5, 9, 0) } # a Monday

  def build_series(rule: "FREQ=WEEKLY;BYDAY=MO", **attrs)
    calendar.calendar_events.create!({
      organization: org,
      title: "Standup",
      start_at: series_start,
      end_at: series_start + 30.minutes,
      timezone: "UTC",
      recurrence_rule: rule,
      created_by_membership: membership
    }.merge(attrs))
  end

  # Deliberately unfiltered: cancelled override rows are the tombstones that
  # suppress deleted occurrences, so the expander must be able to see them.
  def expand(from, to)
    described_class.for_range(org.calendar_events, from, to)
  end

  describe "expansion" do
    it "emits one occurrence per week across a window the master never touches" do
      build_series

      results = expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1))

      expect(results.size).to eq(4)
      expect(results.map { |e| e.start_at.utc.strftime("%Y-%m-%d %H:%M") })
        .to eq(["2026-02-02 09:00", "2026-02-09 09:00", "2026-02-16 09:00", "2026-02-23 09:00"])
      expect(results.map(&:title).uniq).to eq(["Standup"])
    end

    it "preserves each occurrence's duration" do
      build_series
      occurrence = expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)).first

      expect(occurrence.end_at - occurrence.start_at).to eq(30.minutes)
    end

    it "addresses each occurrence with a series-qualified id" do
      series = build_series
      occurrence = expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)).first

      expect(occurrence.occurrence_id).to eq("#{series.key}@20260202T090000Z")
      expect(CalendarEvent.parse_occurrence_id(occurrence.occurrence_id))
        .to eq([series.key, Time.find_zone("UTC").parse("2026-02-02T09:00:00Z")])
    end

    it "holds a local time steady across a DST transition" do
      # Europe/Amsterdam moves to summer time on 2026-03-29; a 09:00 standup
      # must stay 09:00 local, which means its UTC offset changes.
      build_series(timezone: "Europe/Amsterdam",
                   start_at: Time.find_zone("Europe/Amsterdam").parse("2026-03-23 09:00"),
                   end_at: Time.find_zone("Europe/Amsterdam").parse("2026-03-23 09:30"))

      results = expand(Time.utc(2026, 3, 20), Time.utc(2026, 4, 10))
      local = results.map { |e| e.start_at.in_time_zone("Europe/Amsterdam").strftime("%Y-%m-%d %H:%M") }

      expect(local).to eq(["2026-03-23 09:00", "2026-03-30 09:00", "2026-04-06 09:00"])
    end

    it "stops at an RRULE UNTIL" do
      build_series(rule: "FREQ=WEEKLY;BYDAY=MO;UNTIL=20260126T090000Z")

      expect(expand(Time.utc(2026, 1, 1), Time.utc(2026, 3, 1)).size).to eq(4)
    end

    it "honours an RRULE COUNT" do
      build_series(rule: "FREQ=DAILY;COUNT=3")

      expect(expand(Time.utc(2026, 1, 1), Time.utc(2026, 3, 1)).size).to eq(3)
    end

    it "includes an occurrence that starts before the window but overlaps into it" do
      build_series(rule: "FREQ=WEEKLY;BYDAY=MO",
                   start_at: series_start, end_at: series_start + 3.hours)

      # Window opens at 10:00, an hour into the 09:00–12:00 occurrence.
      results = expand(Time.utc(2026, 1, 5, 10, 0), Time.utc(2026, 1, 5, 11, 0))
      expect(results.size).to eq(1)
    end

    it "leaves a non-recurring event alone" do
      calendar.calendar_events.create!(
        organization: org, title: "One-off",
        start_at: Time.utc(2026, 2, 3, 9), end_at: Time.utc(2026, 2, 3, 10),
        created_by_membership: membership
      )

      expect(expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)).map(&:title)).to eq(["One-off"])
    end

    it "survives an RRULE it cannot parse without blanking the calendar" do
      build_series(rule: "FREQ=NONSENSE;;;")

      # The master still overlaps its own first occurrence, so that renders.
      expect { expand(series_start - 1.hour, series_start + 1.hour) }.not_to raise_error
    end
  end

  describe "occurrence overrides" do
    it "replaces a generated instance with its moved exception" do
      series = build_series
      moved_from = Time.utc(2026, 2, 9, 9, 0)
      calendar.calendar_events.create!(
        organization: org, title: "Standup (moved)",
        start_at: moved_from + 2.hours, end_at: moved_from + 2.hours + 30.minutes,
        recurring_event_key: series.key, original_start_at: moved_from,
        created_by_membership: membership
      )

      results = expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1))
      starts = results.map { |e| e.start_at.utc.strftime("%Y-%m-%d %H:%M") }

      expect(results.size).to eq(4)
      expect(starts).to include("2026-02-09 11:00")
      expect(starts).not_to include("2026-02-09 09:00")
    end

    it "suppresses an occurrence cancelled by a tombstone exception" do
      series = build_series
      skipped = Time.utc(2026, 2, 9, 9, 0)
      calendar.calendar_events.create!(
        organization: org, title: "Standup",
        start_at: skipped, end_at: skipped + 30.minutes,
        recurring_event_key: series.key, original_start_at: skipped,
        status: CalendarEvent::STATUS_CANCELLED,
        created_by_membership: membership
      )

      results = expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1))

      expect(results.size).to eq(3)
      expect(results.map { |e| e.start_at.utc.day }).not_to include(9)
    end

    it "still suppresses the generated instance when the exception moved out of the window" do
      series = build_series
      moved_from = Time.utc(2026, 2, 9, 9, 0)
      calendar.calendar_events.create!(
        organization: org, title: "Standup (next month)",
        start_at: Time.utc(2026, 5, 9, 9), end_at: Time.utc(2026, 5, 9, 10),
        recurring_event_key: series.key, original_start_at: moved_from,
        created_by_membership: membership
      )

      results = expand(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1))

      expect(results.size).to eq(3)
      expect(results.map { |e| e.start_at.utc.day }).not_to include(9)
    end
  end
end
