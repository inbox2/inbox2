require "rails_helper"

# Meet links: public scheduler page API, link management, blocked time,
# accept/decline (docs/Calendar.md).
# E1 mapping: Calendar module — meet links / meeting requests.
RSpec.describe "Meet scheduling", type: :request do
  let(:owner) { create(:user, username: "meetowner", display_name: "Waseem") }
  let(:org) { create(:organization, owner: owner, domain: "meet.test") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let!(:mailbox) { create(:mailbox, membership: membership, domain: org.domains.first, local_part: "waseem") }
  let(:headers) { auth_headers(owner) }

  let(:colleague_user) { create(:user, username: "meetana", display_name: "Ana") }
  let!(:colleague) { create(:membership, user: colleague_user, organization: org, status: Membership::STATUS_ACTIVE) }
  let!(:colleague_mailbox) { create(:mailbox, membership: colleague, domain: org.domains.first, local_part: "ana") }

  let!(:link) { org.meet_links.create!(membership: membership, label: "Default") }

  # Next Tuesday 10:00 UTC — inside default working hours (Mon–Fri 09:00–17:00,
  # UTC default timezone) and past the default 4h notice.
  let(:slot_start) { Date.current.next_occurring(:tuesday).in_time_zone("UTC").change(hour: 10) }

  def calendar
    Calendar.primary_for(org, membership)
  end

  # ── Public endpoints ───────────────────────────────────────────────────────

  describe "GET /api/v1/meet/:token" do
    it "returns the public payload and counts the visit" do
      expect {
        get "/api/v1/meet/#{link.token}"
      }.to change { link.reload.visits_count }.by(1)

      expect(response).to have_http_status(:ok)
      meet = response.parsed_body["meet"]
      expect(meet["label"]).to eq("Default")
      expect(meet["duration_minutes"]).to eq(30)
      expect(meet["invitee"]["name"]).to eq("Waseem")
      expect(meet["working_hours"]["start_minute"]).to eq(540)
      expect(meet["timezone"]).to eq("UTC")
    end

    it "404s an unknown token" do
      get "/api/v1/meet/nope"
      expect(response).to have_http_status(:not_found)
    end

    it "404s a revoked link with the same generic error" do
      link.revoke!
      get "/api/v1/meet/#{link.token}"
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["errors"].first["message"]).to eq("This link is not available")
    end

    it "404s when the invitee is no longer an active member" do
      membership.update!(status: Membership::STATUS_DISABLED)
      get "/api/v1/meet/#{link.token}"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "does not count a link-preview fetch as a visit" do
    expect { get "/api/v1/meet/#{link.token}", params: { preview: 1 } }.not_to change { link.reload.visits_count }
    expect(response).to have_http_status(:ok)
  end

  it "falls back to the username when the invitee has no display name" do
    owner.update!(display_name: nil)
    get "/api/v1/meet/#{link.token}"
    expect(response.parsed_body["meet"]["invitee"]["name"]).to eq("meetowner")
  end

  describe "GET /api/v1/meet/:token/availability" do
    it "merges events, blocked time and OOO into bare busy periods" do
      calendar.calendar_events.create!(
        organization: org, title: "Secret meeting", created_by_membership: membership,
        organizer_email: mailbox.email_address,
        start_at: slot_start, end_at: slot_start + 1.hour
      )
      org.blocked_times.create!(membership: membership, start_at: slot_start + 2.hours, end_at: slot_start + 3.hours)

      get "/api/v1/meet/#{link.token}/availability",
        params: { start: (slot_start - 4.hours).iso8601, end: (slot_start + 8.hours).iso8601 }

      expect(response).to have_http_status(:ok)
      busy = response.parsed_body["busy"]
      expect(busy.size).to eq(2)
      # Bare periods only — never a title, never an attendee.
      expect(busy.first.keys).to match_array(%w[start end])
      expect(response.body).not_to include("Secret meeting")
    end

    it "only reveals busy time inside working hours" do
      # 08:00–10:00 straddles the 09:00 start; 18:00–19:00 is after hours.
      org.blocked_times.create!(membership: membership, start_at: slot_start - 2.hours, end_at: slot_start)
      org.blocked_times.create!(membership: membership, start_at: slot_start.change(hour: 18), end_at: slot_start.change(hour: 19))

      get "/api/v1/meet/#{link.token}/availability",
        params: { start: slot_start.beginning_of_day.iso8601, end: slot_start.end_of_day.iso8601 }

      busy = response.parsed_body["busy"]
      expect(busy).to eq([{ "start" => slot_start.change(hour: 9).iso8601, "end" => slot_start.iso8601 }])
    end

    it "starts a working day inside the spring-forward gap at the gap's end, and handles 24:00" do
      # Europe/Amsterdam skips 02:00–03:00 on 2027-03-28 (a Sunday); 02:30 doesn't exist.
      owner.update!(default_timezone: "Europe/Amsterdam",
        working_hours: { "start_minute" => 150, "end_minute" => 24 * 60, "days" => [0] })
      day = Time.utc(2027, 3, 28)
      avail = MeetAvailability.new(link, day, day + 1.day)
      busy = [{ start: Time.utc(2027, 3, 28, 1), end: Time.utc(2027, 3, 28, 2) }] # 03:00–04:00 CEST
      # Booking accepts 03:00 local, so the page must still show 03:00–04:00 as busy.
      expect(avail.send(:within_working_windows, busy)).to eq(busy)
    end

    it "uses the real transition for a half-hour gap (Lord Howe)" do
      # 2026-10-04 Lord Howe jumps 02:00 → 02:30; a 02:15 start begins at 02:30.
      owner.update!(default_timezone: "Australia/Lord_Howe",
        working_hours: { "start_minute" => 135, "end_minute" => 12 * 60, "days" => [0] })
      tz = ActiveSupport::TimeZone["Australia/Lord_Howe"]
      day = tz.local(2026, 10, 4)
      busy = [{ start: tz.local(2026, 10, 4, 2, 30), end: tz.local(2026, 10, 4, 3, 30) }]
      expect(MeetAvailability.new(link, day, day + 1.day).send(:within_working_windows, busy)).to eq(busy)
    end

    it "counts a blocking zone as busy and ignores a soft one" do
      owner.zones.create!(name: "Deep work", start_at: slot_start, end_at: slot_start + 1.hour, blocks: true)
      owner.zones.create!(name: "Admin", start_at: slot_start + 2.hours, end_at: slot_start + 3.hours)

      get "/api/v1/meet/#{link.token}/availability",
        params: { start: slot_start.beginning_of_day.iso8601, end: slot_start.end_of_day.iso8601 }

      expect(response.parsed_body["busy"]).to eq([{ "start" => slot_start.iso8601, "end" => (slot_start + 1.hour).iso8601 }])
      expect(response.body).not_to include("Deep work")
    end

    it "rejects a range wider than the scan ceiling" do
      get "/api/v1/meet/#{link.token}/availability",
        params: { start: Time.current.iso8601, end: 60.days.from_now.iso8601 }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/meet/:token/requests" do
    let(:params) do
      { name: "Sarah Chen", email: "sarah@acme.com", note: "API intro",
        start_at: slot_start.iso8601, timezone: "America/New_York" }
    end

    it "creates the request plus the invitee's inbox message with the banner payload" do
      expect {
        post "/api/v1/meet/#{link.token}/requests", params: params
      }.to change(MeetingRequest, :count).by(1).and change(Message, :count).by(1)

      expect(response).to have_http_status(:created)
      request_row = MeetingRequest.last
      expect(request_row.status).to eq(MeetingRequest::STATUS_PENDING)
      expect(request_row.end_at).to eq(slot_start + 30.minutes)
      expect(link.reload.requests_count).to eq(1)

      message = request_row.message
      expect(message.is_inbound).to be(true)
      expect(message.to_address).to eq(mailbox.email_address)
      expect(message.meeting_request["name"]).to eq("Sarah Chen")
      expect(message.meeting_request["status"]).to eq("pending")
      expect(message.meeting_request["visitor_timezone"]).to eq("America/New_York")
      expect(message.meeting_request["invitee_email"]).to eq(mailbox.email_address)
      expect(message.conversation.domain).to eq(org.domains.first)
      expect(message.conversation.snippet).to be_present
    end

    it "rejects a slot that is already busy" do
      org.blocked_times.create!(membership: membership, start_at: slot_start, end_at: slot_start + 30.minutes)
      post "/api/v1/meet/#{link.token}/requests", params: params
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("no longer available")
    end

    it "rejects a slot outside working hours" do
      post "/api/v1/meet/#{link.token}/requests", params: params.merge(start_at: slot_start.change(hour: 22).iso8601)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a misaligned start time" do
      post "/api/v1/meet/#{link.token}/requests", params: params.merge(start_at: (slot_start + 7.minutes).iso8601)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an invalid email without creating anything" do
      expect {
        post "/api/v1/meet/#{link.token}/requests", params: params.merge(email: "nope")
      }.not_to change(MeetingRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s a revoked link" do
      link.revoke!
      post "/api/v1/meet/#{link.token}/requests", params: params
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Link management ────────────────────────────────────────────────────────

  describe "meet-links CRUD" do
    it "lists my links and links booking me separately" do
      colleague_link = org.meet_links.create!(membership: colleague, invitee_membership: membership, label: "Books Waseem")

      get "/api/v1/orgs/#{org.key}/meet-links", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["meet_links"].map { |l| l["label"] }).to eq(["Default"])
      expect(body["booking_you"].map { |l| l["label"] }).to eq(["Books Waseem"])
      expect(body["booking_you"].first["id"]).to eq(colleague_link.key)
    end

    it "creates a link booking a colleague" do
      post "/api/v1/orgs/#{org.key}/meet-links", headers: headers,
        params: { label: "Intro with Ana", duration_minutes: 60, invitee_membership_id: colleague.key }

      expect(response).to have_http_status(:created)
      created = response.parsed_body["meet_link"]
      expect(created["invitee"]["name"]).to eq("Ana")
      expect(created["invitee"]["self"]).to be(false)
      expect(created["token"]).to be_present
    end

    it "defaults the invitee to the creator" do
      post "/api/v1/orgs/#{org.key}/meet-links", headers: headers, params: { label: "Mine" }
      expect(response.parsed_body["meet_link"]["invitee"]["self"]).to be(true)
    end

    it "rejects a Meet conference mode when the invitee has no Google connection" do
      post "/api/v1/orgs/#{org.key}/meet-links", headers: headers, params: { label: "Video", conference_mode: "meet" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Google")
    end

    it "accepts a Meet conference mode when the invitee's Google connection exists" do
      ConferencingConnection.create!(membership: membership, provider: "google", refresh_token: "rt")
      post "/api/v1/orgs/#{org.key}/meet-links", headers: headers, params: { label: "Video", conference_mode: "meet" }
      expect(response).to have_http_status(:created)
    end

    it "rejects a duration off the fixed menu" do
      post "/api/v1/orgs/#{org.key}/meet-links", headers: headers, params: { label: "Odd", duration_minutes: 17 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lets the invitee revoke a link that books them" do
      colleague_link = org.meet_links.create!(membership: colleague, invitee_membership: membership, label: "Books Waseem")
      delete "/api/v1/orgs/#{org.key}/meet-links/#{colleague_link.key}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(colleague_link.reload.active?).to be(false)
    end

    it "404s another org's link (E3)" do
      outsider = create(:user, username: "meetoutsider")
      other_org = create(:organization, owner: outsider, domain: "othermeet.test")
      other_membership = create(:membership, user: outsider, organization: other_org, status: Membership::STATUS_ACTIVE)
      foreign = other_org.meet_links.create!(membership: other_membership, label: "Foreign")

      delete "/api/v1/orgs/#{org.key}/meet-links/#{foreign.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Blocked time ───────────────────────────────────────────────────────────

  describe "blocked-times" do
    it "creates, lists in range, and deletes own blocks" do
      post "/api/v1/orgs/#{org.key}/blocked-times", headers: headers,
        params: { start_at: slot_start.iso8601, end_at: (slot_start + 1.hour).iso8601 }
      expect(response).to have_http_status(:created)
      key = response.parsed_body["blocked_time"]["id"]

      get "/api/v1/orgs/#{org.key}/blocked-times", headers: headers,
        params: { start: (slot_start - 1.day).iso8601, end: (slot_start + 1.day).iso8601 }
      expect(response.parsed_body["blocked_times"].map { |b| b["id"] }).to include(key)

      delete "/api/v1/orgs/#{org.key}/blocked-times/#{key}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "rejects an inverted range" do
      post "/api/v1/orgs/#{org.key}/blocked-times", headers: headers,
        params: { start_at: slot_start.iso8601, end_at: (slot_start - 1.hour).iso8601 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another member's block" do
      block = org.blocked_times.create!(membership: colleague, start_at: slot_start, end_at: slot_start + 1.hour)
      delete "/api/v1/orgs/#{org.key}/blocked-times/#{block.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "shows up as busy in org free-busy" do
      org.blocked_times.create!(membership: membership, start_at: slot_start, end_at: slot_start + 1.hour)
      get "/api/v1/orgs/#{org.key}/events/free-busy", headers: headers,
        params: { emails: [mailbox.email_address], start: (slot_start - 1.hour).iso8601, end: (slot_start + 2.hours).iso8601 }
      periods = response.parsed_body["free_busy"][mailbox.email_address]
      expect(periods.size).to eq(1)
      expect(Time.iso8601(periods.first["start"])).to eq(slot_start)
    end
  end

  # ── Conferencing connections ───────────────────────────────────────────────

  describe "conferencing" do
    it "lists connections without ever exposing the token" do
      ConferencingConnection.create!(membership: membership, provider: "google", refresh_token: "secret-rt", account_email: "w@g.com")
      get "/api/v1/orgs/#{org.key}/conferencing", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body["connections"]
      expect(body.first["provider"]).to eq("google")
      expect(body.first["account_email"]).to eq("w@g.com")
      expect(response.body).not_to include("secret-rt")
    end

    it "connect returns the provider consent URL with the narrow conferencing scope" do
      allow(OauthProvider).to receive(:web_client_id).and_return("test-client")
      post "/api/v1/orgs/#{org.key}/conferencing/google/connect", headers: headers
      expect(response).to have_http_status(:ok)
      url = response.parsed_body["authorize_url"]
      expect(url).to include("meetings.space.created")
      expect(url).not_to include("gmail.modify")
      # E5: the readable signed state carries the membership KEY, never the row id.
      state = Rack::Utils.parse_query(URI(url).query)["state"]
      expect(Api::V1::ConferencingController.verifier.verified(state)["m"]).to eq(membership.key)
    end

    it "connect rejects an unknown provider" do
      post "/api/v1/orgs/#{org.key}/conferencing/zoom/connect", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "callback stores the connection and bounces to Settings › Scheduling" do
      allow(OauthProvider).to receive(:exchange_code).and_return({ "access_token" => "at", "refresh_token" => "rt" })
      allow(OauthProvider).to receive(:fetch_email).and_return("w@gmail.com")
      state = Api::V1::ConferencingController.verifier.generate({ "m" => membership.key, "o" => org.slug, "n" => SecureRandom.hex(4) }, expires_in: 5.minutes)

      get "/api/v1/conferencing/google/callback", params: { state: state, code: "abc" }
      expect(response).to have_http_status(:redirect)
      expect(response.headers["Location"]).to include("/#{org.slug}/settings?section=scheduling&conferencing=connected")
      connection = ConferencingConnection.find_by(membership: membership, provider: "google")
      expect(connection.refresh_token).to eq("rt")
      expect(connection.account_email).to eq("w@gmail.com")
    end

    it "callback with a forged state redirects home without touching anything" do
      expect {
        get "/api/v1/conferencing/google/callback", params: { state: "forged", code: "abc" }
      }.not_to change(ConferencingConnection, :count)
      expect(response).to have_http_status(:redirect)
    end

    it "callback with a provider error redirects with the error status" do
      state = Api::V1::ConferencingController.verifier.generate({ "m" => membership.key, "o" => org.slug, "n" => SecureRandom.hex(4) }, expires_in: 5.minutes)
      get "/api/v1/conferencing/google/callback", params: { state: state, error: "access_denied" }
      expect(response.headers["Location"]).to include("conferencing=error")
    end

    it "destroy removes the connection" do
      ConferencingConnection.create!(membership: membership, provider: "google", refresh_token: "rt")
      delete "/api/v1/orgs/#{org.key}/conferencing/google", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(ConferencingConnection.where(membership: membership)).to be_empty
    end
  end

  # ── Accept / decline ───────────────────────────────────────────────────────

  describe "meeting-requests decisions" do
    let!(:request_row) do
      post "/api/v1/meet/#{link.token}/requests", params: {
        name: "Sarah Chen", email: "sarah@acme.com", note: "API intro",
        start_at: slot_start.iso8601, timezone: "America/New_York"
      }
      MeetingRequest.last
    end

    it "accept creates the event with the invitee as organizer and mails a real invite" do
      expect {
        post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept", headers: headers
      }.to change(CalendarEvent, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["request"]["status"]).to eq("accepted")
      expect(body["conflict"]).to be(false)

      event = CalendarEvent.last
      expect(event.organizer_email).to eq(mailbox.email_address)
      expect(event.attendees.map(&:email)).to eq(["sarah@acme.com"])
      expect(event.attendees.first.response_status).to eq(CalendarAttendee::RESPONSE_ACCEPTED)

      # The outbound METHOD:REQUEST invite rode CalendarInviteDispatch.
      invite_mail = Message.where(is_inbound: false).last
      expect(invite_mail.to_address).to eq("sarah@acme.com")
      expect(invite_mail.calendar_reply).to include("METHOD:REQUEST")

      # The banner collapses: the message payload carries the new status.
      expect(request_row.reload.message.meeting_request["status"]).to eq("accepted")
    end

    it "accept reports (but does not enforce) a conflict" do
      org.blocked_times.create!(membership: membership, start_at: slot_start, end_at: slot_start + 30.minutes)
      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conflict"]).to be(true)
      expect(request_row.reload.status).to eq("accepted")
    end

    it "decline records the reason and does not touch the calendar" do
      expect {
        post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/decline", headers: headers,
          params: { reason: "Traveling that week" }
      }.not_to change(CalendarEvent, :count)

      expect(response).to have_http_status(:ok)
      expect(request_row.reload.status).to eq("declined")
      expect(request_row.decline_reason).to eq("Traveling that week")
      expect(request_row.message.meeting_request["status"]).to eq("declined")
    end

    it "403s a member who is not the invitee" do
      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept",
        headers: auth_headers(colleague_user)
      expect(response).to have_http_status(:forbidden)
      expect(request_row.reload.status).to eq("pending")
    end

    it "422s an already-answered request" do
      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/decline", headers: headers
      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "expires a pending request whose start has passed instead of deciding it" do
      request_row.update!(start_at: 2.hours.ago, end_at: 90.minutes.ago)
      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("expired")
      expect(request_row.reload.status).to eq(MeetingRequest::STATUS_EXPIRED)
      expect(request_row.message.meeting_request["status"]).to eq("expired")
    end

    it "does not report a conflict for a free slot inside the min-notice window" do
      # Freeze the request to start 1h from now — inside the 4h notice, but the
      # calendar is free: accepting late is the invitee's call, not a conflict.
      soon = 1.hour.from_now.change(min: 0)
      request_row.update!(start_at: soon, end_at: soon + 30.minutes)

      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conflict"]).to be(false)
    end

    it "survives deleting the conversation, the event, and the booked member (FK hygiene)" do
      post "/api/v1/orgs/#{org.key}/meeting-requests/#{request_row.key}/accept", headers: headers
      request_row.reload

      expect { request_row.message.conversation.destroy! }.not_to raise_error
      expect(request_row.reload.message).to be_nil

      expect { request_row.calendar_event.destroy! }.not_to raise_error
      expect(request_row.reload.calendar_event).to be_nil

      booked = org.meet_links.create!(membership: membership, invitee_membership: colleague, label: "Books Ana")
      expect { colleague.destroy! }.not_to raise_error
      expect(MeetLink.exists?(booked.id)).to be(false)
    end

    it "404s a request from another org (E3)" do
      outsider = create(:user, username: "meetoutsider2")
      other_org = create(:organization, owner: outsider, domain: "othermeet2.test")
      create(:membership, user: outsider, organization: other_org, status: Membership::STATUS_ACTIVE)

      post "/api/v1/orgs/#{other_org.key}/meeting-requests/#{request_row.key}/accept",
        headers: auth_headers(outsider)
      expect(response).to have_http_status(:not_found)
    end
  end
end
