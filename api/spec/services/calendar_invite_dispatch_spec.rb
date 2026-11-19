require "rails_helper"

# Outbound invitations (docs/Calendar.md). Adding attendees to an event used to
# write calendar_attendees rows and tell nobody, while the compose UI already
# promised "An .ics calendar file is attached".
RSpec.describe CalendarInviteDispatch do
  let(:owner) { create(:user, username: "invowner", display_name: "Inv Owner") }
  let(:org) { create(:organization, owner: owner, domain: "inv.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let!(:mailbox) { Mailbox.create!(membership: membership, domain: org.default_domain, local_part: "owner") }
  let(:calendar) { org.calendars.create!(name: "Team", membership: membership) }

  let(:event) do
    calendar.calendar_events.create!(
      organization: org, title: "Roadmap review", location: "Room 2",
      start_at: Time.utc(2026, 3, 2, 10, 0), end_at: Time.utc(2026, 3, 2, 11, 0),
      timezone: "UTC", organizer_email: "owner@inv.com", created_by_membership: membership
    )
  end

  def add_attendee(email, **attrs)
    event.attendees.create!({ email: email }.merge(attrs))
  end

  describe "#deliver" do
    it "queues one outbound message carrying a METHOD:REQUEST part" do
      add_attendee("guest@example.com")

      expect { described_class.deliver(event.reload, membership) }
        .to have_enqueued_job(OutboundDeliveryJob)

      message = org.messages.order(:id).last
      expect(message.to_address).to eq("guest@example.com")
      expect(message.is_inbound).to be(false)
      expect(message.calendar_reply).to include("METHOD:REQUEST")
      expect(message.calendar_reply).to include("UID:#{event.ical_uid}")
      expect(message.calendar_reply).to include("ATTENDEE")
      expect(message.subject).to start_with("Invitation: Roadmap review")
    end

    it "refuses to send an invitation From an address the member cannot send as" do
      add_attendee("guest@example.com")
      event.update!(organizer_email: "ceo@inv.com")

      expect { described_class.deliver(event.reload, membership) }
        .to raise_error(CalendarInviteDispatch::SenderNotAllowed)
      expect(org.messages.count).to eq(0)
    end

    it "never mails the organizer their own invitation" do
      add_attendee("owner@inv.com", is_organizer: true)
      add_attendee("guest@example.com")

      described_class.deliver(event.reload, membership)

      expect(org.messages.order(:id).last.to_address).to eq("guest@example.com")
    end

    it "sends nothing when the event has no attendees" do
      expect { described_class.deliver(event.reload, membership) }.not_to change { org.messages.count }
    end

    it "sends nothing when the organizer has no address to send from" do
      add_attendee("guest@example.com")
      mailbox.destroy!
      event.update!(organizer_email: nil)

      expect(described_class.deliver(event.reload, membership)).to be_nil
      expect(org.messages.count).to eq(0)
    end

    it "threads a later notice onto the original invitation's conversation" do
      add_attendee("guest@example.com")
      described_class.deliver(event.reload, membership)
      first_conversation = org.messages.order(:id).last.conversation

      described_class.deliver(event.reload, membership, action: described_class::ACTION_CANCEL)

      expect(org.messages.order(:id).last.conversation).to eq(first_conversation)
      expect(org.conversations.count).to eq(1)
    end

    it "marks a cancellation as METHOD:CANCEL with STATUS:CANCELLED" do
      add_attendee("guest@example.com")

      described_class.deliver(event.reload, membership, action: described_class::ACTION_CANCEL)

      message = org.messages.order(:id).last
      expect(message.calendar_reply).to include("METHOD:CANCEL")
      expect(message.calendar_reply).to include("STATUS:CANCELLED")
      expect(message.subject).to start_with("Cancelled: Roadmap review")
    end
  end

  describe "the generated ICS" do
    it "carries the recurrence rule for a repeating event" do
      event.update!(recurrence_rule: "FREQ=WEEKLY;BYDAY=MO")
      add_attendee("guest@example.com")

      ics = IcsRequest.build(event.reload, organizer_email: "owner@inv.com")
      expect(ics).to include("RRULE:FREQ=WEEKLY;BYDAY=MO")
    end

    it "uses a DATE value for an all-day event" do
      event.update!(all_day: true)
      ics = IcsRequest.build(event.reload, organizer_email: "owner@inv.com")

      expect(ics).to include("DTSTART;VALUE=DATE:20260302")
    end

    it "names the instance it replaces when the event is a series exception" do
      event.update!(original_start_at: Time.utc(2026, 3, 2, 9, 0))
      ics = IcsRequest.build(event.reload, organizer_email: "owner@inv.com")

      expect(ics).to include("RECURRENCE-ID:20260302T090000Z")
    end

    it "folds a line longer than the RFC 5545 limit" do
      event.update!(title: "x" * 200)
      ics = IcsRequest.build(event.reload, organizer_email: "owner@inv.com")

      expect(ics.split("\r\n").map(&:bytesize).max).to be <= 76
      # Continuation lines begin with a single space and rejoin to the original.
      expect(ics.gsub("\r\n ", "")).to include("SUMMARY:#{'x' * 200}")
    end

    it "round-trips through IcsParser" do
      add_attendee("guest@example.com", name: "A Guest")
      ics = IcsRequest.build(event.reload, organizer_email: "owner@inv.com")

      parsed = IcsParser.new(ics).parse.first
      expect(parsed[:method]).to eq("REQUEST")
      expect(parsed[:uid]).to eq(event.ical_uid)
      expect(parsed[:summary]).to eq("Roadmap review")
      expect(parsed[:location]).to eq("Room 2")
      expect(parsed[:attendees].map { |a| a[:email] }).to include("guest@example.com")
    end
  end
end
