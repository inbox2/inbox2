require "rails_helper"

# CRUD + rsvp/propose-time/free-busy for calendar events
# E1 mapping: Calendar module — events, RSVP, free/busy (no dedicated A-number in the reference table)
RSpec.describe "Api::V1::CalendarEvents", type: :request do
  let(:owner) { create(:user, username: "evowner") }
  let(:org) { create(:organization, owner: owner, domain: "ev.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }
  let(:calendar) { org.calendars.create!(name: "Team", membership: membership) }

  def create_event(cal = calendar, **attrs)
    cal.calendar_events.create!({
      organization: org,
      title: "Standup",
      start_at: 1.hour.from_now,
      end_at: 2.hours.from_now,
      created_by_membership: membership
    }.merge(attrs))
  end

  describe "GET /api/v1/orgs/:org_id/events" do
    context "positive" do
      it "lists non-cancelled events ordered by start, with pagination meta" do
        create_event(title: "Later", start_at: 3.hours.from_now, end_at: 4.hours.from_now)
        create_event(title: "Sooner", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
        create_event(title: "Gone", status: CalendarEvent::STATUS_CANCELLED)

        get "/api/v1/orgs/#{org.key}/events", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["events"].map { |e| e["title"] }).to eq(%w[Sooner Later])
        expect(body["meta"]["total"]).to eq(2)
      end

      it "filters by date range" do
        create_event(title: "InWindow", start_at: 2.days.from_now + 1.hour, end_at: 2.days.from_now + 2.hours)
        create_event(title: "OutOfWindow", start_at: 10.days.from_now, end_at: 10.days.from_now + 1.hour)

        get "/api/v1/orgs/#{org.key}/events",
            params: { start: 2.days.from_now.iso8601, end: 3.days.from_now.iso8601 }, headers: headers
        titles = response.parsed_body["events"].map { |e| e["title"] }
        expect(titles).to eq(%w[InWindow])
      end
    end

    context "negative" do
      it "requires authentication" do
        get "/api/v1/orgs/#{org.key}/events"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/events/:id" do
    context "positive" do
      it "returns an event with its attendees" do
        event = create_event
        event.attendees.create!(email: "a@x.com", response_status: CalendarAttendee::RESPONSE_ACCEPTED)

        get "/api/v1/orgs/#{org.key}/events/#{event.key}", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body["event"]
        expect(body["title"]).to eq("Standup")
        expect(body["attendees"].first["email"]).to eq("a@x.com")
      end
    end

    context "negative" do
      it "returns 404 for an unknown event key" do
        get "/api/v1/orgs/#{org.key}/events/cev_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for an event in another organization (E3)" do
        event = create_event
        other = create(:user, username: "evother")
        other_org = create(:organization, owner: other, domain: "evother.com")
        create(:membership, user: other, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)

        get "/api/v1/orgs/#{other_org.key}/events/#{event.key}", headers: auth_headers(other)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/events" do
    let(:valid_params) do
      {
        calendar_id: calendar.key,
        title: "Planning",
        start_at: 1.hour.from_now.iso8601,
        end_at: 2.hours.from_now.iso8601,
        attendees: [{ email: "guest@x.com", name: "Guest" }],
        reminders: [{ method: "popup", minutes_before: 10 }]
      }
    end

    context "positive" do
      it "creates an event with attendees and reminders" do
        expect {
          post "/api/v1/orgs/#{org.key}/events", params: valid_params, headers: headers
        }.to change(org.calendar_events, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body["event"]
        expect(body["id"]).to start_with("cev_")
        expect(body["title"]).to eq("Planning")
        expect(body["calendar_id"]).to eq(calendar.key)
        expect(body["attendees"].first["email"]).to eq("guest@x.com")
        expect(body["reminders"].first["minutes_before"]).to eq(10)
      end

      it "creates a repeating event that expands in its own zone and stops at COUNT" do
        # Mon 26 Oct and Wed 28 Oct 2026, 14:00 Amsterdam, and no third time.
        post "/api/v1/orgs/#{org.key}/events",
             params: valid_params.except(:attendees).merge(
               start_at: "2026-10-26T13:00:00Z", end_at: "2026-10-26T13:30:00Z",
               timezone: "Europe/Amsterdam", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2"
             ),
             headers: headers
        expect(response).to have_http_status(:created)

        get "/api/v1/orgs/#{org.key}/events",
            params: { start: "2026-10-25T00:00:00Z", end: "2026-11-15T00:00:00Z" }, headers: headers
        starts = response.parsed_body["events"].select { |e| e["title"] == "Planning" }.map { |e| e["start_at"] }
        expect(starts.map { |s| Time.zone.parse(s).utc.iso8601 }).to eq(%w[2026-10-26T13:00:00Z 2026-10-28T13:00:00Z])
      end

      it "keeps an all-day event on the date it was given" do
        post "/api/v1/orgs/#{org.key}/events",
             params: valid_params.merge(all_day: true, start_at: "2026-09-18", end_at: "2026-09-19"),
             headers: headers

        expect(response).to have_http_status(:created)
        event = org.calendar_events.order(:created_at).last
        # The clients send a bare date for an all-day event precisely so it
        # can't drift: IcsRequest writes VALUE=DATE off the UTC clock, so a
        # start of 22:30Z would mail the day before.
        expect(event.start_at.utc.to_date.iso8601).to eq("2026-09-18")
      end

      it "attaches a generated Meet link when the member has a conferencing connection" do
        ConferencingConnection.create!(
          membership: membership, provider: OauthProvider::GOOGLE, refresh_token: "rt", account_email: "me@x.com"
        )
        allow(ConferenceLink).to receive(:generate).and_return("https://meet.google.com/abc-defg-hij")

        post "/api/v1/orgs/#{org.key}/events",
             params: valid_params.merge(conference: MeetLink::CONFERENCE_MEET), headers: headers

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["event"]["location"]).to eq("https://meet.google.com/abc-defg-hij")
      end
    end

    context "negative" do
      it "refuses a video call it cannot create, without saving the event" do
        # Nothing is written yet when the link is generated, so failing here
        # leaves nothing to duplicate when the user retries.
        expect(ConferenceLink).not_to receive(:generate)
        expect {
          post "/api/v1/orgs/#{org.key}/events",
               params: valid_params.merge(conference: MeetLink::CONFERENCE_TEAMS), headers: headers
        }.not_to change(org.calendar_events, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].first["message"]).to include("Settings")
      end

      it "still reports success when the event saved but the invitation could not be mailed" do
        # The event exists; raising here would report a created event as a
        # failed request and the retry would make a second one.
        allow(CalendarInviteDispatch).to receive(:deliver).and_raise(StandardError, "smtp down")
        expect {
          post "/api/v1/orgs/#{org.key}/events", params: valid_params, headers: headers
        }.to change(org.calendar_events, :count).by(1)
        expect(response).to have_http_status(:created)
      end

      it "returns 422 when end is not after start" do
        post "/api/v1/orgs/#{org.key}/events",
             params: valid_params.merge(start_at: 2.hours.from_now.iso8601, end_at: 1.hour.from_now.iso8601),
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 404 when the calendar key is unknown" do
        post "/api/v1/orgs/#{org.key}/events",
             params: valid_params.merge(calendar_id: "cal_missing"), headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/events/:id" do
    context "positive" do
      it "updates an event" do
        event = create_event
        patch "/api/v1/orgs/#{org.key}/events/#{event.key}", params: { title: "Renamed" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["event"]["title"]).to eq("Renamed")
      end
    end

    context "negative" do
      it "returns 422 when the update would make end precede start" do
        event = create_event
        patch "/api/v1/orgs/#{org.key}/events/#{event.key}",
              params: { end_at: event.start_at - 1.hour }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 404 for an unknown event" do
        patch "/api/v1/orgs/#{org.key}/events/cev_missing", params: { title: "X" }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/events/:id" do
    context "positive" do
      it "deletes a single event" do
        event = create_event
        expect {
          delete "/api/v1/orgs/#{org.key}/events/#{event.key}", headers: headers
        }.to change(org.calendar_events, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end

    context "negative" do
      it "returns 404 for an unknown event" do
        delete "/api/v1/orgs/#{org.key}/events/cev_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/events/:id/rsvp" do
    context "positive" do
      it "records the current user's RSVP" do
        event = create_event
        post "/api/v1/orgs/#{org.key}/events/#{event.key}/rsvp",
             params: { status: CalendarAttendee::RESPONSE_ACCEPTED }, headers: headers
        expect(response).to have_http_status(:ok)
        attendee = response.parsed_body["event"]["attendees"].first
        expect(attendee["response_status"]).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
      end
    end

    context "negative" do
      it "returns 422 for an invalid RSVP status" do
        event = create_event
        post "/api/v1/orgs/#{org.key}/events/#{event.key}/rsvp",
             params: { status: "maybe" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 400 when status is missing" do
        event = create_event
        post "/api/v1/orgs/#{org.key}/events/#{event.key}/rsvp", headers: headers
        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/events/:id/propose-time" do
    it "records a tentative response with proposed times" do
      event = create_event
      post "/api/v1/orgs/#{org.key}/events/#{event.key}/propose-time",
           params: { proposed_start: 5.hours.from_now.iso8601, proposed_end: 6.hours.from_now.iso8601 },
           headers: headers
      expect(response).to have_http_status(:ok)
      attendee = response.parsed_body["event"]["attendees"].first
      expect(attendee["response_status"]).to eq(CalendarAttendee::RESPONSE_TENTATIVE)
    end
  end

  describe "GET /api/v1/orgs/:org_id/events/free-busy" do
    it "returns busy periods grouped by attendee email" do
      event = create_event(start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      event.attendees.create!(email: "busy@x.com", response_status: CalendarAttendee::RESPONSE_ACCEPTED)

      get "/api/v1/orgs/#{org.key}/events/free-busy",
          params: { emails: ["busy@x.com"], start: Time.current.iso8601, end: 1.day.from_now.iso8601 },
          headers: headers
      expect(response).to have_http_status(:ok)
      fb = response.parsed_body["free_busy"]
      expect(fb["busy@x.com"].length).to eq(1)
    end

    it "returns an empty group for emails with no events" do
      get "/api/v1/orgs/#{org.key}/events/free-busy",
          params: { emails: ["nobody@x.com"], start: Time.current.iso8601, end: 1.day.from_now.iso8601 },
          headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["free_busy"]).to eq({})
    end

    context "calendar visibility" do
      let(:other) { create(:user, username: "evfbmember") }
      let!(:other_membership) { create(:membership, user: other, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
      let(:fb_params) { { emails: ["busy@x.com"], start: Time.current.iso8601, end: 1.day.from_now.iso8601 } }

      # Deliberate change of policy (docs/Calendar.md): free/busy is org-wide.
      # Scheduling against a colleague is the entire point, and it is safe
      # because a block is a start and an end — the negative assertion below is
      # that no DETAIL crosses the private-calendar line, not that the time is
      # hidden. Previously a teammate with a private calendar read as free all
      # week, which made the scheduling assistant actively misleading.
      it "includes busy times from another member's private calendar" do
        event = create_event # on owner's private calendar
        event.attendees.create!(email: "busy@x.com", response_status: CalendarAttendee::RESPONSE_ACCEPTED)

        get "/api/v1/orgs/#{org.key}/events/free-busy", params: fb_params, headers: auth_headers(other)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["free_busy"]["busy@x.com"].size).to eq(1)
      end

      it "leaks no detail about a private-calendar event (negative)" do
        event = create_event(calendar, title: "Secret 1:1", location: "Room 9", description: "sensitive")
        event.attendees.create!(email: "busy@x.com", response_status: CalendarAttendee::RESPONSE_ACCEPTED)

        get "/api/v1/orgs/#{org.key}/events/free-busy", params: fb_params, headers: auth_headers(other)

        block = response.parsed_body["free_busy"]["busy@x.com"].first
        expect(block.keys).to contain_exactly("start", "end")
        expect(response.body).not_to include("Secret 1:1")
        expect(response.body).not_to include("Room 9")
      end

      it "includes busy blocks from an org-shared calendar (positive)" do
        shared_cal = org.calendars.create!(name: "Shared", membership: nil)
        event = create_event(shared_cal)
        event.attendees.create!(email: "busy@x.com", response_status: CalendarAttendee::RESPONSE_ACCEPTED)

        get "/api/v1/orgs/#{org.key}/events/free-busy", params: fb_params, headers: auth_headers(other)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["free_busy"]["busy@x.com"].length).to eq(1)
      end
    end

    context "negative — malformed range" do
      it "returns 422 for unparseable start/end" do
        get "/api/v1/orgs/#{org.key}/events/free-busy",
            params: { emails: ["busy@x.com"], start: "not-a-time", end: 1.day.from_now.iso8601 },
            headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 422 when start/end are missing" do
        get "/api/v1/orgs/#{org.key}/events/free-busy", params: { emails: ["busy@x.com"] }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/events/from-ics" do
    def ics(uid: "import-1@test", summary: "Imported")
      <<~ICS
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        BEGIN:VEVENT
        UID:#{uid}
        SUMMARY:#{summary}
        DTSTART:20260601T090000Z
        DTEND:20260601T100000Z
        END:VEVENT
        END:VCALENDAR
      ICS
    end

    context "positive" do
      it "creates events from an ICS payload" do
        expect {
          post "/api/v1/orgs/#{org.key}/events/from-ics",
               params: { calendar_id: calendar.key, ics_content: ics(summary: "Conference") }, headers: headers
        }.to change(org.calendar_events, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body["events"]
        expect(body.first["title"]).to eq("Conference")
        expect(body.first["calendar_id"]).to eq(calendar.key)
      end

      it "is idempotent on repeated import of the same UID" do
        2.times do
          post "/api/v1/orgs/#{org.key}/events/from-ics",
               params: { calendar_id: calendar.key, ics_content: ics(uid: "same@test") }, headers: headers
        end
        expect(org.calendar_events.where(ical_uid: "same@test").count).to eq(1)
      end
    end

    context "negative" do
      it "returns 400 when ics_content is missing" do
        post "/api/v1/orgs/#{org.key}/events/from-ics",
             params: { calendar_id: calendar.key }, headers: headers
        expect(response).to have_http_status(:bad_request)
      end

      it "returns 422 for non-iCalendar content" do
        post "/api/v1/orgs/#{org.key}/events/from-ics",
             params: { calendar_id: calendar.key, ics_content: "this is not an ics file" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 404 for an unknown calendar" do
        post "/api/v1/orgs/#{org.key}/events/from-ics",
             params: { calendar_id: "cal_missing", ics_content: ics }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # A member must not reach events on another member's PRIVATE calendar. Events
  # are scoped through the same for_member calendar set as CalendarsController.
  describe "cross-member private-calendar isolation" do
    let(:other) { create(:user, username: "evother") }
    let!(:other_membership) { create(:membership, user: other, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
    let(:other_headers) { auth_headers(other) }
    let!(:private_event) { create_event(title: "Owner-only") } # on owner's private calendar

    it "omits another member's private-calendar events from index" do
      get "/api/v1/orgs/#{org.key}/events", headers: other_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["events"]).to be_empty
    end

    it "404s on show for another member's private-calendar event" do
      get "/api/v1/orgs/#{org.key}/events/#{private_event.key}", headers: other_headers
      expect(response).to have_http_status(:not_found)
    end

    it "404s on update for another member's private-calendar event" do
      patch "/api/v1/orgs/#{org.key}/events/#{private_event.key}", params: { title: "Hijack" }, headers: other_headers
      expect(response).to have_http_status(:not_found)
      expect(private_event.reload.title).to eq("Owner-only")
    end

    it "404s on destroy for another member's private-calendar event" do
      delete "/api/v1/orgs/#{org.key}/events/#{private_event.key}", headers: other_headers
      expect(response).to have_http_status(:not_found)
      expect(CalendarEvent.exists?(private_event.id)).to be(true)
    end

    it "still surfaces events on an org-shared calendar to other members" do
      shared_cal = org.calendars.create!(name: "Shared", membership: nil)
      shared_event = create_event(shared_cal, title: "All-hands")
      get "/api/v1/orgs/#{org.key}/events", headers: other_headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to include(shared_event.key)
    end
  end

  # ── Recurrence, invitations and occurrence semantics (docs/Calendar.md) ──

  describe "recurring series" do
    let(:series_start) { Time.utc(2026, 1, 5, 9, 0) } # a Monday

    def create_series(**attrs)
      create_event(calendar, title: "Standup", start_at: series_start, end_at: series_start + 30.minutes,
                             timezone: "UTC", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO", **attrs)
    end

    it "expands a series into one event per occurrence inside the window" do
      create_series

      get "/api/v1/orgs/#{org.key}/events",
          params: { start: "2026-02-01T00:00:00Z", end: "2026-03-01T00:00:00Z" }, headers: headers

      expect(response).to have_http_status(:ok)
      events = response.parsed_body["events"]
      expect(events.size).to eq(4)
      expect(events.map { |e| e["is_recurring"] }.uniq).to eq([true])
      expect(events.first["id"]).to include("@")
      expect(events.first["series_id"]).to eq(CalendarEvent.last.key)
    end

    it "deletes a single occurrence without touching the rest of the series" do
      series = create_series
      occurrence_id = "#{series.key}@20260209T090000Z"

      delete "/api/v1/orgs/#{org.key}/events/#{CGI.escape(occurrence_id)}",
             params: { scope: "this" }, headers: headers
      expect(response).to have_http_status(:no_content)

      get "/api/v1/orgs/#{org.key}/events",
          params: { start: "2026-02-01T00:00:00Z", end: "2026-03-01T00:00:00Z" }, headers: headers
      starts = response.parsed_body["events"].map { |e| e["start_at"] }
      expect(starts.size).to eq(3)
      expect(starts.none? { |s| s.to_s.start_with?("2026-02-09") }).to be(true)
      expect(CalendarEvent.exists?(series.id)).to be(true)
    end

    it "edits a single occurrence by splitting it into an exception" do
      series = create_series
      occurrence_id = "#{series.key}@20260209T090000Z"

      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape(occurrence_id)}",
            params: { title: "Standup (special)" }, headers: headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/orgs/#{org.key}/events",
          params: { start: "2026-02-01T00:00:00Z", end: "2026-03-01T00:00:00Z" }, headers: headers
      titles = response.parsed_body["events"].map { |e| e["title"] }
      expect(titles.count("Standup (special)")).to eq(1)
      expect(titles.count("Standup")).to eq(3)
      expect(series.reload.title).to eq("Standup")
    end

    def series_window
      get "/api/v1/orgs/#{org.key}/events",
          params: { start: "2026-01-01T00:00:00Z", end: "2026-03-01T00:00:00Z" }, headers: headers
      response.parsed_body["events"]
    end

    it "splits the series for scope=following: the old one stops, the rest takes the edits" do
      series = create_series
      series.reminders.create!(method: "popup", minutes_before: 10)
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}",
            params: { scope: "following", title: "Standup v2", start_at: "2026-02-09T09:00:00Z",
                      end_at: "2026-02-09T09:30:00Z", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE" },
            headers: headers
      expect(response).to have_http_status(:ok)
      tail = response.parsed_body["event"]
      expect(tail["reminders"].map { |r| r["minutes_before"] }).to eq([10])
      expect(tail["series_id"]).not_to eq(series.key)
      expect(tail["ical_uid"]).not_to eq(series.reload.ical_uid)

      events = series_window
      before = events.select { |e| e["title"] == "Standup" }.map { |e| e["start_at"][0, 10] }
      after = events.select { |e| e["title"] == "Standup v2" }.map { |e| e["start_at"][0, 10] }
      expect(before).to eq(%w[2026-01-05 2026-01-12 2026-01-19 2026-01-26 2026-02-02])
      expect(after.first(3)).to eq(%w[2026-02-09 2026-02-11 2026-02-16])
    end

    it "carries only the remaining COUNT over to the split-off series" do
      series = create_series(recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=4")
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260119T090000Z")}",
            params: { scope: "following", title: "Later" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(series.reload.recurrence_rule).not_to include("COUNT")
      expect(series_window.map { |e| [e["title"], e["start_at"][0, 10]] }).to eq([
        %w[Standup 2026-01-05], %w[Standup 2026-01-12], %w[Later 2026-01-19], %w[Later 2026-01-26]
      ])
    end

    it "re-rules the whole series for scope=all and drops exceptions of the old rule" do
      series = create_series
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260112T090000Z")}",
            params: { title: "Moved one" }, headers: headers
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260119T090000Z")}",
            params: { scope: "all", recurrence_rule: "FREQ=WEEKLY;BYDAY=TU" }, headers: headers
      expect(response).to have_http_status(:ok)
      events = series_window
      expect(events.map { |e| e["title"] }.uniq).to eq(%w[Standup])
      expect(events.map { |e| Time.zone.parse(e["start_at"]).wday }.uniq).to eq([2])
    end

    it "keeps an exception whose slot the new rule still has" do
      series = create_series
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260112T090000Z")}",
            params: { title: "Kept edit" }, headers: headers
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260119T090000Z")}",
            params: { scope: "all", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE" }, headers: headers
      expect(response).to have_http_status(:ok)
      kept = series_window.find { |e| e["title"] == "Kept edit" }
      expect(kept && kept["start_at"][0, 10]).to eq("2026-01-12")
    end

    it "turns the series into a one-off at the chosen instance for scope=all + no repeat" do
      series = create_series
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}",
            params: { scope: "all", recurrence_rule: nil, start_at: "2026-02-09T10:00:00Z", end_at: "2026-02-09T10:30:00Z" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(series_window.map { |e| Time.zone.parse(e["start_at"]).utc.iso8601 }).to eq(%w[2026-02-09T10:00:00Z])
    end

    it "ignores a rule sent with a single-instance edit, and shows the series rule on the exception" do
      series = create_series
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}",
            params: { title: "Just this", recurrence_rule: "FREQ=DAILY" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["event"]["recurrence_rule"]).to be_nil
      expect(response.parsed_body["event"]["series_rule"]).to eq("FREQ=WEEKLY;BYDAY=MO")
      expect(series.reload.recurrence_rule).to eq("FREQ=WEEKLY;BYDAY=MO")
    end

    it "moves the whole series for scope=all, by the instance's shift" do
      series = create_series

      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}",
            params: { scope: "all", start_at: "2026-02-09T10:00:00Z", end_at: "2026-02-09T11:00:00Z" },
            headers: headers
      expect(response).to have_http_status(:ok)

      series.reload
      expect(series.start_at).to eq(Time.utc(2026, 1, 5, 10, 0))
      expect(series.end_at).to eq(Time.utc(2026, 1, 5, 11, 0))
      expect(CalendarEvent.where(recurring_event_key: series.key)).to be_empty
    end

    it "moves exceptions along with the series" do
      series = create_series
      patch "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}",
            params: { title: "Special" }, headers: headers
      exception = CalendarEvent.find_by!(recurring_event_key: series.key)

      patch "/api/v1/orgs/#{org.key}/events/#{exception.key}",
            params: { scope: "all", start_at: "2026-02-09T09:30:00Z", end_at: "2026-02-09T10:00:00Z" },
            headers: headers
      expect(response).to have_http_status(:ok)

      exception.reload
      expect(series.reload.start_at).to eq(Time.utc(2026, 1, 5, 9, 30))
      expect(exception.original_start_at).to eq(Time.utc(2026, 2, 9, 9, 30))
      expect(exception.start_at).to eq(Time.utc(2026, 2, 9, 9, 30))
    end

    it "moves one instance when scope=all is sent for a one-off event" do
      event = create_event(start_at: Time.utc(2026, 2, 9, 9), end_at: Time.utc(2026, 2, 9, 10))

      patch "/api/v1/orgs/#{org.key}/events/#{event.key}",
            params: { scope: "all", start_at: "2026-02-09T11:00:00Z", end_at: "2026-02-09T12:00:00Z" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(event.reload.start_at).to eq(Time.utc(2026, 2, 9, 11))
    end

    it "ends the series at the cutoff for scope=following" do
      series = create_series

      delete "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}",
             params: { scope: "following" }, headers: headers

      get "/api/v1/orgs/#{org.key}/events",
          params: { start: "2026-01-01T00:00:00Z", end: "2026-04-01T00:00:00Z" }, headers: headers
      starts = response.parsed_body["events"].map { |e| e["start_at"] }
      expect(starts.size).to eq(5) # 5, 12, 19, 26 Jan + 2 Feb
      expect(starts.none? { |s| s.to_s >= "2026-02-09" }).to be(true)
    end

    it "removes the whole series for scope=all" do
      series = create_series

      delete "/api/v1/orgs/#{org.key}/events/#{series.key}", params: { scope: "all" }, headers: headers

      expect(CalendarEvent.exists?(series.id)).to be(false)
    end

    it "RSVPs to one occurrence without answering the series" do
      series = create_series

      post "/api/v1/orgs/#{org.key}/events/#{CGI.escape("#{series.key}@20260209T090000Z")}/rsvp",
           params: { status: CalendarAttendee::RESPONSE_ACCEPTED }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(series.reload.attendees).to be_empty
      exception = org.calendar_events.find_by(recurring_event_key: series.key)
      expect(exception.attendees.first.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
    end
  end

  describe "invitations" do
    it "does not mail guests about a move with notify=false" do
      event = create_event(organizer_email: "evowner@ev.com")
      event.attendees.create!(email: "guest@x.com")
      allow(CalendarInviteDispatch).to receive(:deliver)

      patch "/api/v1/orgs/#{org.key}/events/#{event.key}",
            params: { start_at: 3.hours.from_now.iso8601, end_at: 4.hours.from_now.iso8601, notify: "false" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(CalendarInviteDispatch).not_to have_received(:deliver)
    end

    it "mails an invitation when an event is created with attendees" do
      expect {
        post "/api/v1/orgs/#{org.key}/events",
             params: { calendar_id: calendar.key, title: "Kickoff",
                       start_at: 1.day.from_now.iso8601, end_at: (1.day.from_now + 1.hour).iso8601,
                       attendees: [{ email: "guest@example.com" }] },
             headers: headers
      }.to change { org.messages.count }.by(1)

      expect(response).to have_http_status(:created)
      message = org.messages.order(:id).last
      expect(message.to_address).to eq("guest@example.com")
      expect(message.calendar_reply).to include("METHOD:REQUEST")
    end

    it "ignores a client-supplied organizer_email: the creator is the organizer (and the From)" do
      post "/api/v1/orgs/#{org.key}/events",
           params: { calendar_id: calendar.key, title: "Spoof attempt",
                     start_at: 1.day.from_now.iso8601, end_at: (1.day.from_now + 1.hour).iso8601,
                     organizer_email: "ceo@ev.com", attendees: [{ email: "guest@example.com" }] },
           headers: headers

      expect(response).to have_http_status(:created)
      event = org.calendar_events.find_by!(title: "Spoof attempt")
      expect(event.organizer_email).to eq("evowner@ev.com")
      expect(org.messages.order(:id).last.from_address).to eq("evowner@ev.com")

      patch "/api/v1/orgs/#{org.key}/events/#{event.key}", params: { organizer_email: "ceo@ev.com" }, headers: headers
      expect(event.reload.organizer_email).to eq("evowner@ev.com")
    end

    it "does not mail anything for an event with no attendees" do
      expect {
        post "/api/v1/orgs/#{org.key}/events",
             params: { calendar_id: calendar.key, title: "Solo focus time",
                       start_at: 1.day.from_now.iso8601, end_at: (1.day.from_now + 1.hour).iso8601 },
             headers: headers
      }.not_to change { org.messages.count }
    end

    it "re-sends with a bumped SEQUENCE when the time moves" do
      event = create_event
      event.attendees.create!(email: "guest@example.com")

      patch "/api/v1/orgs/#{org.key}/events/#{event.key}",
            params: { start_at: 5.days.from_now.iso8601, end_at: (5.days.from_now + 1.hour).iso8601 },
            headers: headers

      expect(event.reload.sequence).to eq(1)
      expect(org.messages.order(:id).last.calendar_reply).to include("SEQUENCE:1")
    end

    it "does not re-send when only the description changes" do
      event = create_event
      event.attendees.create!(email: "guest@example.com")

      expect {
        patch "/api/v1/orgs/#{org.key}/events/#{event.key}", params: { description: "notes" }, headers: headers
      }.not_to change { org.messages.count }
      expect(event.reload.sequence).to eq(0)
    end

    it "mails a cancellation when an event with attendees is deleted" do
      event = create_event
      event.attendees.create!(email: "guest@example.com")

      delete "/api/v1/orgs/#{org.key}/events/#{event.key}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(org.messages.order(:id).last.calendar_reply).to include("METHOD:CANCEL")
    end

    it "does not mail a cancellation when deleting an invite someone else organized" do
      event = create_event(organizer_email: "boss@elsewhere.com")
      event.attendees.create!(email: "boss@elsewhere.com", is_organizer: true)
      event.attendees.create!(email: "guest@example.com")

      expect {
        delete "/api/v1/orgs/#{org.key}/events/#{event.key}", headers: headers
      }.not_to change { org.messages.count }
      expect(response).to have_http_status(:no_content)
    end

    it "does not re-invite when moving an invite someone else organized" do
      event = create_event(organizer_email: "boss@elsewhere.com")
      event.attendees.create!(email: "guest@example.com")

      expect {
        patch "/api/v1/orgs/#{org.key}/events/#{event.key}",
              params: { start_at: 5.days.from_now.iso8601, end_at: (5.days.from_now + 1.hour).iso8601 },
              headers: headers
      }.not_to change { org.messages.count }
    end

    it "tells the client whether the member organized the event" do
      mine = create_event(title: "Mine")
      invite = create_event(title: "Invite", organizer_email: "boss@elsewhere.com")

      get "/api/v1/orgs/#{org.key}/events/#{mine.key}", headers: headers
      expect(response.parsed_body["event"]["organized_by_me"]).to be(true)
      get "/api/v1/orgs/#{org.key}/events/#{invite.key}", headers: headers
      expect(response.parsed_body["event"]["organized_by_me"]).to be(false)
    end

    it "assigns an iCalendar UID so inbound replies can be correlated" do
      post "/api/v1/orgs/#{org.key}/events",
           params: { calendar_id: calendar.key, title: "Kickoff",
                     start_at: 1.day.from_now.iso8601, end_at: (1.day.from_now + 1.hour).iso8601 },
           headers: headers

      expect(response.parsed_body["event"]["ical_uid"]).to be_present
    end

    it "falls back to the member's primary calendar when no calendar_id is given" do
      post "/api/v1/orgs/#{org.key}/events",
           params: { title: "No calendar named",
                     start_at: 1.day.from_now.iso8601, end_at: (1.day.from_now + 1.hour).iso8601 },
           headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["event"]["calendar_id"]).to eq(Calendar.primary_for(org, membership).key)
    end
  end

  # ── Internal invitations: one canonical event, seen by every guest ──
  # (docs/Calendar.md). No row is copied onto the guest's calendar, so the
  # organizer sees responses live and updates cannot drift between copies.
  describe "inviting a colleague" do
    let(:mate) { create(:user, username: "evmate", display_name: "Ev Mate") }
    let!(:mate_membership) { create(:membership, user: mate, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
    let(:domain) { org.domains.first }
    let!(:mate_mailbox) { Mailbox.create!(membership: mate_membership, domain: domain, local_part: "evmate") }
    let(:mate_headers) { auth_headers(mate) }

    it "shows the meeting on the invited colleague's calendar without copying it" do
      event = create_event(calendar, title: "Roadmap")
      event.attendees.create!(email: mate_mailbox.email_address)

      get "/api/v1/orgs/#{org.key}/events", headers: mate_headers

      ids = response.parsed_body["events"].map { |e| e["id"] }
      expect(ids).to include(event.key)
      expect(org.calendar_events.count).to eq(1)
    end

    it "matches the invitation address case-insensitively" do
      event = create_event(calendar, title: "Roadmap")
      event.attendees.create!(email: mate_mailbox.email_address.upcase)

      get "/api/v1/orgs/#{org.key}/events", headers: mate_headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to include(event.key)
    end

    it "lets the invited colleague RSVP on the organizer's event" do
      event = create_event(calendar, title: "Roadmap")
      event.attendees.create!(email: mate_mailbox.email_address)

      post "/api/v1/orgs/#{org.key}/events/#{event.key}/rsvp",
           params: { status: CalendarAttendee::RESPONSE_ACCEPTED }, headers: mate_headers

      expect(response).to have_http_status(:ok)
      expect(event.attendees.reload.first.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)
      expect(org.calendar_events.count).to eq(1)
    end

    it "does not let an invited colleague edit the event (negative)" do
      event = create_event(calendar, title: "Roadmap")
      event.attendees.create!(email: mate_mailbox.email_address)

      patch "/api/v1/orgs/#{org.key}/events/#{event.key}", params: { title: "Hijacked" }, headers: mate_headers

      expect(response).to have_http_status(:not_found)
      expect(event.reload.title).to eq("Roadmap")
    end

    it "does not let an invited colleague delete the event (negative)" do
      event = create_event(calendar, title: "Roadmap")
      event.attendees.create!(email: mate_mailbox.email_address)

      delete "/api/v1/orgs/#{org.key}/events/#{event.key}", headers: mate_headers

      expect(response).to have_http_status(:not_found)
      expect(CalendarEvent.exists?(event.id)).to be(true)
    end

    it "still hides an event they were never invited to (negative)" do
      other_event = create_event(calendar, title: "Not for you")

      get "/api/v1/orgs/#{org.key}/events", headers: mate_headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).not_to include(other_event.key)
    end
  end

  # Counter-proposals (docs/Calendar.md): propose → organizer accepts or declines.
  describe "counter-proposals" do
    let(:mate) { create(:user, username: "evprop", display_name: "Ev Prop") }
    let!(:mate_membership) { create(:membership, user: mate, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
    let!(:mate_mailbox) { Mailbox.create!(membership: mate_membership, domain: org.domains.first, local_part: "evprop") }
    let(:mate_headers) { auth_headers(mate) }

    let(:event) do
      create_event(calendar, title: "Roadmap",
                             start_at: Time.utc(2026, 3, 2, 10), end_at: Time.utc(2026, 3, 2, 11),
                             organizer_email: "evowner@ev.com")
    end
    let!(:invited) { event.attendees.create!(email: mate_mailbox.email_address) }

    it "records a proposal and mails the organizer a COUNTER" do
      expect {
        post "/api/v1/orgs/#{org.key}/events/#{event.key}/propose-time",
             params: { proposed_start: "2026-03-03T14:00:00Z", proposed_end: "2026-03-03T15:00:00Z",
                       comment: "Tuesday suits better" },
             headers: mate_headers
      }.to change { org.messages.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(invited.reload.proposed_start).to eq(Time.utc(2026, 3, 3, 14))
      expect(org.messages.order(:id).last.calendar_reply).to include("METHOD:COUNTER")
    end

    it "422s without a proposed start (negative)" do
      post "/api/v1/orgs/#{org.key}/events/#{event.key}/propose-time", params: {}, headers: mate_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "surfaces the proposal on the event so the organizer can see it" do
      invited.update!(proposed_start: Time.utc(2026, 3, 3, 14), proposed_end: Time.utc(2026, 3, 3, 15))

      get "/api/v1/orgs/#{org.key}/events/#{event.key}", headers: headers

      attendee = response.parsed_body["event"]["attendees"].first
      expect(attendee["proposed_start"]).to be_present
    end

    it "moves the event when the organizer accepts" do
      invited.update!(proposed_start: Time.utc(2026, 3, 3, 14), proposed_end: Time.utc(2026, 3, 3, 15))

      post "/api/v1/orgs/#{org.key}/events/#{event.key}/accept-proposal",
           params: { attendee_email: mate_mailbox.email_address }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(event.reload.start_at).to eq(Time.utc(2026, 3, 3, 14))
      expect(event.sequence).to eq(1)
      expect(invited.reload.proposed_start).to be_nil
    end

    it "leaves the event alone when the organizer declines" do
      invited.update!(proposed_start: Time.utc(2026, 3, 3, 14))

      post "/api/v1/orgs/#{org.key}/events/#{event.key}/decline-proposal",
           params: { attendee_email: mate_mailbox.email_address }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(event.reload.start_at).to eq(Time.utc(2026, 3, 2, 10))
      expect(invited.reload.proposed_start).to be_nil
    end

    it "does not let an invited guest accept their own proposal (negative)" do
      invited.update!(proposed_start: Time.utc(2026, 3, 3, 14))

      post "/api/v1/orgs/#{org.key}/events/#{event.key}/accept-proposal",
           params: { attendee_email: mate_mailbox.email_address }, headers: mate_headers

      expect(response).to have_http_status(:not_found)
      expect(event.reload.start_at).to eq(Time.utc(2026, 3, 2, 10))
    end

    it "404s when there is no pending proposal (negative)" do
      post "/api/v1/orgs/#{org.key}/events/#{event.key}/accept-proposal",
           params: { attendee_email: mate_mailbox.email_address }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET availability" do
    let(:mate) { create(:user, username: "evsched", display_name: "Ev Sched", default_timezone: "UTC") }
    let!(:mate_membership) { create(:membership, user: mate, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
    let(:domain) { org.domains.first }
    let!(:mate_mailbox) { Mailbox.create!(membership: mate_membership, domain: domain, local_part: "evsched") }
    let(:monday) { Time.utc(2026, 3, 2) }

    it "returns attendee rows plus ranked suggestions" do
      get "/api/v1/orgs/#{org.key}/events/availability",
          params: { emails: [mate_mailbox.email_address], start: monday.iso8601,
                    end: (monday + 1.day).iso8601, duration_minutes: 60 },
          headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      row = body["attendees"].find { |a| a["email"] == mate_mailbox.email_address }
      expect(row["name"]).to eq("Ev Sched")
      expect(row["internal"]).to be(true)
      expect(body["suggestions"]).not_to be_empty
    end

    it "puts the requesting member on the grid without being invited" do
      get "/api/v1/orgs/#{org.key}/events/availability",
          params: { emails: [mate_mailbox.email_address], start: monday.iso8601, end: (monday + 1.day).iso8601 },
          headers: headers

      expect(response.parsed_body["attendees"].size).to eq(2)
    end

    it "422s without a usable window (negative)" do
      get "/api/v1/orgs/#{org.key}/events/availability",
          params: { emails: [mate_mailbox.email_address] }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires authentication (negative)" do
      get "/api/v1/orgs/#{org.key}/events/availability",
          params: { start: monday.iso8601, end: (monday + 1.day).iso8601 }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET directory" do
    let(:mate) { create(:user, username: "evdir", display_name: "Ev Dir") }
    let!(:mate_membership) { create(:membership, user: mate, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
    let!(:mate_mailbox) { Mailbox.create!(membership: mate_membership, domain: org.domains.first, local_part: "evdir") }

    it "lists the org's own addresses for the colleague picker" do
      get "/api/v1/orgs/#{org.key}/events/directory", headers: headers

      expect(response).to have_http_status(:ok)
      emails = response.parsed_body["people"].map { |p| p["email"] }
      expect(emails).to include("evdir@ev.com")
    end

    it "requires authentication (negative)" do
      get "/api/v1/orgs/#{org.key}/events/directory"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET free-busy with recurrence" do
    it "reports a busy block for every occurrence of a series" do
      series_start = Time.utc(2026, 1, 5, 9, 0)
      event = create_event(calendar, title: "Standup", start_at: series_start, end_at: series_start + 30.minutes,
                                     timezone: "UTC", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO")
      event.attendees.create!(email: "guest@example.com")

      get "/api/v1/orgs/#{org.key}/events/free-busy",
          params: { emails: ["guest@example.com"], start: "2026-02-01T00:00:00Z", end: "2026-03-01T00:00:00Z" },
          headers: headers

      expect(response.parsed_body["free_busy"]["guest@example.com"].size).to eq(4)
    end

    it "counts the organizer as busy even with no attendee row of their own" do
      create_event(calendar, title: "Solo", organizer_email: "owner@ev.com",
                             start_at: Time.utc(2026, 2, 2, 9), end_at: Time.utc(2026, 2, 2, 10))

      get "/api/v1/orgs/#{org.key}/events/free-busy",
          params: { emails: ["owner@ev.com"], start: "2026-02-01T00:00:00Z", end: "2026-03-01T00:00:00Z" },
          headers: headers

      expect(response.parsed_body["free_busy"]["owner@ev.com"].size).to eq(1)
    end

    it "does not count a declined invitation as busy" do
      event = create_event(calendar, start_at: Time.utc(2026, 2, 2, 9), end_at: Time.utc(2026, 2, 2, 10))
      event.attendees.create!(email: "guest@example.com", response_status: CalendarAttendee::RESPONSE_DECLINED)

      get "/api/v1/orgs/#{org.key}/events/free-busy",
          params: { emails: ["guest@example.com"], start: "2026-02-01T00:00:00Z", end: "2026-03-01T00:00:00Z" },
          headers: headers

      expect(response.parsed_body["free_busy"]).to eq({})
    end
  end
end
