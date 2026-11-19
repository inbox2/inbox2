require "rails_helper"

# Accepting an emailed invitation puts it on the member's calendar
# (docs/Calendar.md). Previously MX stored the invite on the message, emailed a
# REPLY, and the meeting never appeared in anybody's week.
RSpec.describe CalendarInviteImport do
  let(:owner) { create(:user, username: "impowner") }
  let(:org) { create(:organization, owner: owner, domain: "imp.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let!(:domain) { org.domains.first || create(:domain, organization: org, name: "imp.com") }
  let!(:mailbox) { Mailbox.create!(membership: membership, domain: domain, local_part: "impowner") }

  let(:invite) do
    {
      "uid" => "uid-1@ext.com",
      "summary" => "Design sync",
      "description" => "Bring mocks",
      "location" => "Room 1",
      "start" => "2026-03-02T10:00:00Z",
      "end" => "2026-03-02T11:00:00Z",
      "all_day" => false,
      "organizer_email" => "organizer@ext.com",
      "organizer_name" => "Ext Organizer",
      "attendees" => [{ "email" => "organizer@ext.com" }, { "email" => mailbox.email_address }],
      "sequence" => 0
    }
  end

  def apply(response, payload = invite)
    described_class.apply(org, membership, payload, response)
  end

  it "creates the event on the member's primary calendar" do
    event = apply(CalendarAttendee::RESPONSE_ACCEPTED)

    expect(event).to be_present
    expect(event.calendar).to eq(Calendar.primary_for(org, membership))
    expect(event.title).to eq("Design sync")
    expect(event.location).to eq("Room 1")
    expect(event.start_at).to eq(Time.utc(2026, 3, 2, 10))
    expect(event.status).to eq(CalendarEvent::STATUS_CONFIRMED)
  end

  it "provisions the primary calendar when the member has none" do
    expect { apply(CalendarAttendee::RESPONSE_ACCEPTED) }.to change { org.calendars.count }.from(0).to(1)
  end

  it "mirrors the answer onto the member's own attendee row" do
    event = apply(CalendarAttendee::RESPONSE_ACCEPTED)

    mine = event.attendees.find { |a| a.email.casecmp?(mailbox.email_address) }
    expect(mine.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
    expect(event.attendees.find { |a| a.email == "organizer@ext.com" }.is_organizer).to be(true)
  end

  it "marks a tentative answer as a tentative event" do
    expect(apply(CalendarAttendee::RESPONSE_TENTATIVE).status).to eq(CalendarEvent::STATUS_TENTATIVE)
  end

  it "is idempotent on UID — a re-sent invitation updates in place" do
    apply(CalendarAttendee::RESPONSE_ACCEPTED)
    updated = apply(CalendarAttendee::RESPONSE_ACCEPTED, invite.merge("summary" => "Design sync (moved)", "sequence" => 1))

    expect(org.calendar_events.count).to eq(1)
    expect(updated.title).to eq("Design sync (moved)")
    expect(updated.sequence).to eq(1)
  end

  it "removes the copy when the member declines" do
    apply(CalendarAttendee::RESPONSE_ACCEPTED)

    expect { apply(CalendarAttendee::RESPONSE_DECLINED) }.to change { org.calendar_events.count }.from(1).to(0)
  end

  it "carries the recurrence rule so a repeating invite lands as a series" do
    event = apply(CalendarAttendee::RESPONSE_ACCEPTED, invite.merge("rrule" => "FREQ=WEEKLY;BYDAY=MO"))

    expect(event.recurrence_rule).to eq("FREQ=WEEKLY;BYDAY=MO")
    expect(event.recurring_master?).to be(true)
  end

  it "defaults a missing end time to an hour rather than dropping the invite" do
    event = apply(CalendarAttendee::RESPONSE_ACCEPTED, invite.except("end"))

    expect(event.end_at).to eq(Time.utc(2026, 3, 2, 11))
  end

  it "ignores an invite with no UID or no start" do
    expect(apply(CalendarAttendee::RESPONSE_ACCEPTED, invite.except("uid"))).to be_nil
    expect(apply(CalendarAttendee::RESPONSE_ACCEPTED, invite.except("start"))).to be_nil
    expect(org.calendar_events.count).to eq(0)
  end
end
