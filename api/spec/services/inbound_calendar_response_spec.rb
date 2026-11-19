require "rails_helper"

# Inbound REPLY / CANCEL (docs/Calendar.md). Without this, invitations we send
# are write-only: attendees answer, their client mails a valid REPLY, and the
# organizer's guest list sits on "needs_action" forever.
RSpec.describe InboundCalendarResponse do
  let(:owner) { create(:user, username: "rspowner") }
  let(:org) { create(:organization, owner: owner, domain: "rsp.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:calendar) { org.calendars.create!(name: "Team", membership: membership) }

  let!(:event) do
    calendar.calendar_events.create!(
      organization: org, title: "Roadmap review",
      start_at: Time.utc(2026, 3, 2, 10), end_at: Time.utc(2026, 3, 2, 11),
      ical_uid: "uid-roadmap@inv.com", organizer_email: "owner@rsp.com",
      created_by_membership: membership
    )
  end
  let!(:attendee) { event.attendees.create!(email: "guest@example.com") }

  let(:conversation) { org.conversations.create!(subject: "Re: Roadmap", status: Conversation::STATUS_OPEN) }
  let(:message) do
    conversation.messages.create!(
      organization: org, from_address: "guest@example.com", to_address: "owner@rsp.com",
      subject: "Accepted", is_inbound: true, is_draft: false
    )
  end

  def reply_ics(partstat, email: "guest@example.com", uid: "uid-roadmap@inv.com")
    <<~ICS
      BEGIN:VCALENDAR
      METHOD:REPLY
      BEGIN:VEVENT
      UID:#{uid}
      ATTENDEE;PARTSTAT=#{partstat}:mailto:#{email}
      DTSTART:20260302T100000Z
      END:VEVENT
      END:VCALENDAR
    ICS
  end

  def parse(ics)
    IcsParser.new(ics).parse.first
  end

  describe ".apply_reply" do
    it "records an acceptance against the matching attendee" do
      described_class.apply_reply(org, message, parse(reply_ics("ACCEPTED")))

      expect(attendee.reload.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
      expect(attendee.responded_at).to be_present
    end

    it "records a decline" do
      described_class.apply_reply(org, message, parse(reply_ics("DECLINED")))
      expect(attendee.reload.response_status).to eq(CalendarAttendee::RESPONSE_DECLINED)
    end

    it "records a tentative answer" do
      described_class.apply_reply(org, message, parse(reply_ics("TENTATIVE")))
      expect(attendee.reload.response_status).to eq(CalendarAttendee::RESPONSE_TENTATIVE)
    end

    it "matches the attendee case-insensitively instead of duplicating the row" do
      described_class.apply_reply(org, message, parse(reply_ics("ACCEPTED", email: "GUEST@Example.COM")))

      expect(event.attendees.count).to eq(1)
      expect(attendee.reload.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
    end

    it "ignores a reply for an unknown event" do
      expect { described_class.apply_reply(org, message, parse(reply_ics("ACCEPTED", uid: "nope@x.com"))) }
        .not_to change { attendee.reload.response_status }
    end

    it "ignores a reply carrying no usable PARTSTAT" do
      ics = reply_ics("ACCEPTED").sub("ATTENDEE;PARTSTAT=ACCEPTED:mailto:guest@example.com", "ATTENDEE:mailto:guest@example.com")
      described_class.apply_reply(org, message, parse(ics))

      expect(attendee.reload.response_status).to eq(CalendarAttendee::RESPONSE_NEEDS_ACTION)
    end

    it "does not reach across organizations" do
      other_org = create(:organization, owner: create(:user, username: "otherowner"), domain: "other.com")

      described_class.apply_reply(other_org, message, parse(reply_ics("ACCEPTED")))

      expect(attendee.reload.response_status).to eq(CalendarAttendee::RESPONSE_NEEDS_ACTION)
    end
  end

  describe ".apply_cancel" do
    let(:cancel_ics) do
      <<~ICS
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:uid-roadmap@inv.com
        STATUS:CANCELLED
        DTSTART:20260302T100000Z
        END:VEVENT
        END:VCALENDAR
      ICS
    end

    it "cancels the matching event" do
      described_class.apply_cancel(org, message, parse(cancel_ics))
      expect(event.reload.status).to eq(CalendarEvent::STATUS_CANCELLED)
    end

    it "flags the original invitation message so the reading pane can say so" do
      invite = conversation.messages.create!(
        organization: org, from_address: "owner@rsp.com", to_address: "guest@example.com",
        subject: "Roadmap", is_inbound: true, is_draft: false,
        calendar_invite: { "uid" => "uid-roadmap@inv.com", "summary" => "Roadmap review" },
        rsvp_status: CalendarAttendee::RESPONSE_NEEDS_ACTION
      )

      described_class.apply_cancel(org, message, parse(cancel_ics))

      expect(invite.reload.calendar_invite["cancelled"]).to be(true)
    end

    it "is a no-op for an unknown UID" do
      ics = cancel_ics.sub("uid-roadmap@inv.com", "unknown@x.com")
      expect { described_class.apply_cancel(org, message, parse(ics)) }
        .not_to change { event.reload.status }
    end
  end
end
