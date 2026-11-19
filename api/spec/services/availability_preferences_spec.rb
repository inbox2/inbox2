require "rails_helper"

# Per-person working hours and out-of-office, as the scheduler sees them
# (docs/Calendar.md). Both live on the user's profile alongside default_timezone.
RSpec.describe "Availability preferences" do
  let(:owner) { create(:user, username: "prefowner", default_timezone: "UTC") }
  let(:org) { create(:organization, owner: owner, domain: "pref.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:domain) { org.domains.first }
  let!(:owner_mailbox) { Mailbox.create!(membership: membership, domain: domain, local_part: "prefowner") }

  let(:colleague) { create(:user, username: "prefmate", display_name: "Pref Mate", default_timezone: "UTC") }
  let!(:colleague_membership) { create(:membership, user: colleague, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
  let!(:colleague_mailbox) { Mailbox.create!(membership: colleague_membership, domain: domain, local_part: "prefmate") }

  let(:monday) { Time.utc(2026, 3, 2) }

  def run(from: monday, to: monday + 1.day, duration: 60)
    Availability.new(
      organization: org, membership: membership, emails: [colleague_mailbox.email_address],
      range_start: from, range_end: to, duration_minutes: duration
    ).call
  end

  describe "working hours" do
    it "falls back to the default when never set" do
      row = run[:attendees].first
      expect(row[:working_hours][:start_minute]).to eq(User::DEFAULT_WORKING_HOURS["start_minute"])
      expect(row[:working_hours][:days]).to eq([1, 2, 3, 4, 5])
    end

    it "uses the person's own hours when they have set them" do
      colleague.update!(working_hours: { "start_minute" => 11 * 60, "end_minute" => 15 * 60, "days" => [1, 2] })

      row = run[:attendees].first
      expect(row[:working_hours][:start_minute]).to eq(660)
      expect(row[:working_hours][:end_minute]).to eq(900)
    end

    it "ranks a slot outside their hours below one inside them" do
      colleague.update!(working_hours: { "start_minute" => 14 * 60, "end_minute" => 17 * 60, "days" => [1, 2, 3, 4, 5] })

      best = run[:suggestions].first
      expect(best[:outside_working_hours]).to be_empty
      expect(best[:start].utc.hour).to be >= 14
    end

    it "supports half-hour boundaries" do
      colleague.update!(working_hours: { "start_minute" => (9 * 60) + 30, "end_minute" => 17 * 60, "days" => [1] })

      best = run(duration: 30)[:suggestions].first
      expect(best[:outside_working_hours]).to be_empty
      expect(best[:start].utc.strftime("%H:%M")).to eq("09:30")
    end

    it "treats a day they do not work as outside hours" do
      colleague.update!(working_hours: { "start_minute" => 9 * 60, "end_minute" => 17 * 60, "days" => [3] })

      # Monday is not a working day for them, so every Monday slot is flagged.
      expect(run[:suggestions].map { |s| s[:outside_working_hours] }.flatten.uniq)
        .to eq([colleague_mailbox.email_address])
    end

    it "rejects an impossible working day (negative)" do
      colleague.working_hours = { "start_minute" => 1000, "end_minute" => 200 }
      expect(colleague).not_to be_valid
      expect(colleague.errors[:working_hours].join).to include("after start")
    end

    it "rejects a weekday outside 0-6 (negative)" do
      colleague.working_hours = { "days" => [1, 9] }
      expect(colleague).not_to be_valid
    end
  end

  describe "out of office" do
    before do
      colleague.update!(out_of_office_start: monday + 8.hours, out_of_office_end: monday + 18.hours,
                        out_of_office_message: "On holiday")
    end

    it "reports the period on the attendee row with its message" do
      row = run[:attendees].first
      expect(row[:out_of_office][:start]).to eq(monday + 8.hours)
      expect(row[:out_of_office][:message]).to eq("On holiday")
    end

    it "blocks the period as busy so no slot is suggested inside it" do
      slots = run[:suggestions]
      expect(slots.none? { |s| s[:start] < monday + 18.hours && s[:end] > monday + 8.hours }).to be(true)
    end

    it "flags the busy block as out-of-office rather than a mystery meeting" do
      block = run[:attendees].first[:busy].find { |b| b[:out_of_office] }
      expect(block).to be_present
      expect(block[:start]).to eq(monday + 8.hours)
    end

    it "clips the period to the queried window" do
      colleague.update!(out_of_office_start: monday - 5.days, out_of_office_end: monday + 5.days)

      row = run[:attendees].first
      expect(row[:out_of_office][:start]).to eq(monday)
      expect(row[:out_of_office][:end]).to eq(monday + 1.day)
    end

    it "reports nothing when the period does not overlap the window" do
      colleague.update!(out_of_office_start: monday + 30.days, out_of_office_end: monday + 31.days)
      expect(run[:attendees].first[:out_of_office]).to be_nil
    end

    it "merges with a real booking rather than double-counting the hour" do
      org.calendars.create!(name: "P", membership: colleague_membership)
        .calendar_events.create!(organization: org, title: "Booked",
                                 start_at: monday + 9.hours, end_at: monday + 10.hours,
                                 organizer_email: colleague_mailbox.email_address,
                                 created_by_membership: colleague_membership)

      busy = run[:attendees].first[:busy]
      expect(busy.size).to eq(1)
      expect(busy.first[:start]).to eq(monday + 8.hours)
      expect(busy.first[:end]).to eq(monday + 18.hours)
    end
  end

  describe "User#out_of_office?" do
    it "is true inside the period and false outside it" do
      colleague.update!(out_of_office_start: monday, out_of_office_end: monday + 1.day)

      expect(colleague.out_of_office?(monday + 3.hours)).to be(true)
      expect(colleague.out_of_office?(monday - 1.hour)).to be(false)
      expect(colleague.out_of_office?(monday + 2.days)).to be(false)
    end

    it "is false when no period is set" do
      expect(colleague.out_of_office?).to be(false)
    end
  end
end
