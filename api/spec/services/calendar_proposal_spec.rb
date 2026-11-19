require "rails_helper"

# Counter-proposals (docs/Calendar.md). `propose-time` used to write the
# suggestion onto the attendee row and stop — nothing mailed the organizer,
# nothing surfaced it, no endpoint could act on it.
RSpec.describe CalendarProposal do
  let(:owner) { create(:user, username: "propowner", display_name: "Prop Owner") }
  let(:org) { create(:organization, owner: owner, domain: "prop.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let!(:mailbox) { Mailbox.create!(membership: membership, domain: org.default_domain, local_part: "owner") }
  let(:calendar) { org.calendars.create!(name: "Team", membership: membership) }

  let(:event) do
    calendar.calendar_events.create!(
      organization: org, title: "Roadmap review",
      start_at: Time.utc(2026, 3, 2, 10), end_at: Time.utc(2026, 3, 2, 11),
      timezone: "UTC", organizer_email: "owner@prop.com", created_by_membership: membership
    )
  end
  let!(:attendee) do
    event.attendees.create!(email: "guest@example.com", name: "A Guest",
                            proposed_start: Time.utc(2026, 3, 3, 14),
                            proposed_end: Time.utc(2026, 3, 3, 15))
  end

  describe ".notify" do
    it "mails the organizer a METHOD:COUNTER carrying the proposed time" do
      expect { described_class.notify(event.reload, attendee, membership) }
        .to change { org.messages.count }.by(1)

      message = org.messages.order(:id).last
      expect(message.to_address).to eq("owner@prop.com")
      expect(message.from_address).to eq("guest@example.com")
      expect(message.calendar_reply).to include("METHOD:COUNTER")
      # The COUNTER must carry the PROPOSED time, not the event's current one.
      expect(message.calendar_reply).to include("DTSTART:20260303T140000Z")
      expect(message.calendar_reply).to include("UID:#{event.ical_uid}")
    end

    it "says nothing when the proposer is the organizer" do
      attendee.update!(email: "owner@prop.com")
      expect { described_class.notify(event.reload, attendee, membership) }
        .not_to change { org.messages.count }
    end

    it "says nothing when there is no proposal" do
      attendee.update!(proposed_start: nil, proposed_end: nil)
      expect { described_class.notify(event.reload, attendee, membership) }
        .not_to change { org.messages.count }
    end
  end

  describe ".accept!" do
    it "moves the event onto the proposed time and bumps SEQUENCE" do
      described_class.accept!(event.reload, attendee, membership)

      expect(event.reload.start_at).to eq(Time.utc(2026, 3, 3, 14))
      expect(event.end_at).to eq(Time.utc(2026, 3, 3, 15))
      expect(event.sequence).to eq(1)
    end

    it "clears the proposal and marks the proposer as accepted" do
      described_class.accept!(event.reload, attendee, membership)

      expect(attendee.reload.proposed_start).to be_nil
      expect(attendee.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
    end

    it "re-invites everyone at the new time" do
      expect { described_class.accept!(event.reload, attendee, membership) }
        .to change { org.messages.count }.by(1)

      expect(org.messages.order(:id).last.calendar_reply).to include("METHOD:REQUEST")
    end

    it "clears other attendees' now-stale proposals" do
      other = event.attendees.create!(email: "second@example.com",
                                      proposed_start: Time.utc(2026, 3, 4, 9))

      described_class.accept!(event.reload, attendee, membership)
      expect(other.reload.proposed_start).to be_nil
    end

    it "returns nil when there is no proposal to accept" do
      attendee.update!(proposed_start: nil)
      expect(described_class.accept!(event.reload, attendee, membership)).to be_nil
    end

    it "defaults a proposal with no end time to the event's own duration" do
      attendee.update!(proposed_end: nil)
      described_class.accept!(event.reload, attendee, membership)

      expect(event.reload.end_at - event.start_at).to eq(1.hour)
    end
  end

  describe ".decline!" do
    it "mails a DECLINECOUNTER and clears the proposal" do
      expect { described_class.decline!(event.reload, attendee, membership) }
        .to change { org.messages.count }.by(1)

      expect(org.messages.order(:id).last.calendar_reply).to include("METHOD:DECLINECOUNTER")
      expect(attendee.reload.proposed_start).to be_nil
      # The meeting itself does not move.
      expect(event.reload.start_at).to eq(Time.utc(2026, 3, 2, 10))
    end
  end

  describe ".apply_counter (inbound)" do
    let(:conversation) { org.conversations.create!(subject: "Re: Roadmap", status: Conversation::STATUS_OPEN) }
    let(:message) do
      conversation.messages.create!(organization: org, from_address: "guest@example.com",
                                    to_address: "owner@prop.com", subject: "Counter",
                                    is_inbound: true, is_draft: false)
    end

    def counter_ics(uid: nil, email: "guest@example.com")
      <<~ICS
        BEGIN:VCALENDAR
        METHOD:COUNTER
        BEGIN:VEVENT
        UID:#{uid || event.ical_uid}
        ATTENDEE;PARTSTAT=TENTATIVE:mailto:#{email}
        DTSTART:20260305T130000Z
        DTEND:20260305T140000Z
        END:VEVENT
        END:VCALENDAR
      ICS
    end

    it "records an external attendee's counter-proposal" do
      event # force creation
      described_class.apply_counter(org, message, IcsParser.new(counter_ics).parse.first)

      expect(attendee.reload.proposed_start).to eq(Time.utc(2026, 3, 5, 13))
      expect(attendee.proposed_end).to eq(Time.utc(2026, 3, 5, 14))
      expect(attendee.response_status).to eq(CalendarAttendee::RESPONSE_TENTATIVE)
    end

    it "ignores a counter from someone who was never invited (negative)" do
      event
      described_class.apply_counter(org, message, IcsParser.new(counter_ics(email: "stranger@x.com")).parse.first)

      expect(event.attendees.reload.map(&:email)).to eq(["guest@example.com"])
      expect(attendee.reload.proposed_start).to eq(Time.utc(2026, 3, 3, 14))
    end

    it "ignores a counter for an unknown event (negative)" do
      event
      expect(described_class.apply_counter(org, message, IcsParser.new(counter_ics(uid: "nope@x.com")).parse.first))
        .to be_nil
    end
  end
end
