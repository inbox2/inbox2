require "rails_helper"

# Calendar zones (docs/Calendar.md "Zones") — user-scoped soft focus blocks.
RSpec.describe "Api::V1::Zones", type: :request do
  let(:user) { create(:user, username: "zoneuser") }
  let(:headers) { auth_headers(user) }
  let(:other) { create(:user, username: "zoneother") }

  describe "GET /api/v1/account/zone-categories" do
    it "seeds the default categories on first list" do
      get "/api/v1/account/zone-categories", headers: headers
      expect(response).to have_http_status(:ok)
      cats = response.parsed_body["zone_categories"]
      expect(cats.map { |c| c["name"] }).to eq(["Deep work", "Prep", "Admin", "Personal"])
      expect(cats.first["id"]).to start_with("zcat_")
      expect(cats.first["color"]).to eq("blue")

      get "/api/v1/account/zone-categories", headers: headers
      expect(response.parsed_body["zone_categories"].length).to eq(4)
    end

    it "requires authentication" do
      get "/api/v1/account/zone-categories"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "zone categories CRUD" do
    it "creates, renames and deletes a category; its zones stay uncategorised" do
      post "/api/v1/account/zone-categories", params: { name: "Writing", color: "rose" }, headers: headers
      expect(response).to have_http_status(:created)
      key = response.parsed_body["zone_category"]["id"]

      patch "/api/v1/account/zone-categories/#{key}", params: { name: "Long-form" }, headers: headers
      expect(response.parsed_body["zone_category"]["name"]).to eq("Long-form")

      zone = user.zones.create!(name: "Essay", start_at: 1.hour.from_now, end_at: 2.hours.from_now,
        zone_category: user.zone_categories.find_by!(key: key))
      delete "/api/v1/account/zone-categories/#{key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(zone.reload.zone_category_id).to be_nil
    end

    it "rejects a colour outside the palette" do
      post "/api/v1/account/zone-categories", params: { name: "Neon", color: "#ff00ff" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s on another user's category" do
      theirs = other.zone_categories.create!(name: "Theirs", color: "teal")
      patch "/api/v1/account/zone-categories/#{theirs.key}", params: { name: "Mine" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "zones CRUD" do
    let(:category) { user.zone_categories.create!(name: "Deep work", color: "blue") }

    it "creates a zone with a category and lists it in range" do
      post "/api/v1/account/zones", headers: headers, params: {
        name: "Project Atlas", note: "Ship the onboarding draft", category_id: category.key,
        start_at: "2026-09-25T14:00:00Z", end_at: "2026-09-25T16:00:00Z"
      }
      expect(response).to have_http_status(:created)
      zone = response.parsed_body["zone"]
      expect(zone["id"]).to start_with("zon_")
      expect(zone["category_id"]).to eq(category.key)
      expect(zone["notify"]).to be(true)

      get "/api/v1/account/zones", params: { start: "2026-09-25T00:00:00Z", end: "2026-09-26T00:00:00Z" }, headers: headers
      expect(response.parsed_body["zones"].map { |z| z["name"] }).to eq(["Project Atlas"])

      get "/api/v1/account/zones", params: { start: "2026-09-26T00:00:00Z", end: "2026-09-27T00:00:00Z" }, headers: headers
      expect(response.parsed_body["zones"]).to be_empty
    end

    it "updates and deletes a zone" do
      zone = user.zones.create!(name: "Prep", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      patch "/api/v1/account/zones/#{zone.key}", params: { name: "Prep: board review", notify: false }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["zone"]).to include("name" => "Prep: board review", "notify" => false)

      delete "/api/v1/account/zones/#{zone.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Zone.exists?(zone.id)).to be(false)
    end

    it "rejects an end before the start" do
      post "/api/v1/account/zones", headers: headers,
        params: { name: "Backwards", start_at: "2026-09-25T16:00:00Z", end_at: "2026-09-25T14:00:00Z" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s on another user's category" do
      theirs = other.zone_categories.create!(name: "Theirs", color: "teal")
      post "/api/v1/account/zones", headers: headers,
        params: { name: "Sneaky", category_id: theirs.key, start_at: "2026-09-25T14:00:00Z", end_at: "2026-09-25T16:00:00Z" }
      expect(response).to have_http_status(:not_found)
    end

    it "never lists or touches another user's zones" do
      theirs = other.zones.create!(name: "Private", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      get "/api/v1/account/zones", headers: headers
      expect(response.parsed_body["zones"]).to be_empty
      delete "/api/v1/account/zones/#{theirs.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
  describe "repeating, overnight and anchored zones" do
    def list(from, to)
      get "/api/v1/account/zones", params: { start: from, end: to }, headers: headers
      response.parsed_body["zones"]
    end

    it "expands a weekday zone into occurrences in its own time zone, across DST" do
      post "/api/v1/account/zones", headers: headers, params: {
        name: "Focus", repeat: "weekdays", time_zone: "Europe/Amsterdam",
        start_at: "2026-10-22T14:00:00Z", end_at: "2026-10-22T16:00:00Z" # Thu 16:00 CEST
      }
      expect(response).to have_http_status(:created)
      series = response.parsed_body["zone"]["series_id"]

      zones = list("2026-10-22T00:00:00Z", "2026-10-28T00:00:00Z")
      # Thu, Fri, (weekend skipped), Mon, Tue — Monday is after the DST switch.
      expect(zones.map { |z| z["start_at"] }).to eq(%w[
        2026-10-22T14:00:00Z 2026-10-23T14:00:00Z 2026-10-26T15:00:00Z 2026-10-27T15:00:00Z
      ].map { |t| Time.iso8601(t).as_json })
      expect(zones.map { |z| z["series_id"] }.uniq).to eq([series])
      expect(zones.first["id"]).to eq("#{series}@20261022T140000Z")
    end

    it "stops at repeat_until and repeats weekly on the start's weekday" do
      post "/api/v1/account/zones", headers: headers, params: {
        name: "Planning", repeat: "weekly", repeat_until: "2026-10-12", time_zone: "UTC",
        start_at: "2026-09-28T09:00:00Z", end_at: "2026-09-28T10:00:00Z" # Mondays
      }
      starts = list("2026-09-01T00:00:00Z", "2026-12-01T00:00:00Z").map { |z| z["start_at"] }
      expect(starts).to eq(%w[2026-09-28T09:00:00Z 2026-10-05T09:00:00Z 2026-10-12T09:00:00Z].map { |t| Time.iso8601(t).as_json })
    end

    it "keeps each occurrence's wall-clock end when the series starts on a DST change day" do
      # 2027-03-28 Amsterdam springs forward at 02:00: 01:00–03:00 local is only one hour that day.
      zone = user.zones.create!(name: "Night", repeat: "daily", time_zone: "Europe/Amsterdam",
        start_at: Time.utc(2027, 3, 28, 0), end_at: Time.utc(2027, 3, 28, 1)) # 01:00–03:00 local
      tz = ActiveSupport::TimeZone["Europe/Amsterdam"]
      o = zone.occurrences(Time.utc(2027, 3, 29), Time.utc(2027, 3, 30)).first
      expect([o.start_at.in_time_zone(tz).strftime("%H:%M"), o.end_at.in_time_zone(tz).strftime("%H:%M")]).to eq(%w[01:00 03:00])
    end

    it "finds an occurrence lengthened by the spring change when the query starts inside it" do
      # Daily 23:30–03:00 Amsterdam from 2027-03-27 (3.5 h). The 2027-03-28 night jumps
      # an hour, but the 2027-03-28 23:30 occurrence (ending 03:00 on the 29th) is ordinary;
      # the one starting the 27th ends 03:00 CEST on the 28th = 2.5 h elapsed.
      zone = user.zones.create!(name: "Night", repeat: "daily", time_zone: "Europe/Amsterdam",
        start_at: Time.utc(2027, 3, 28, 22, 30) - 1.day, end_at: Time.utc(2027, 3, 28, 1))
      at = Time.utc(2027, 3, 29, 0, 30) # 02:30 CEST on the 29th, inside the 28th's occurrence
      expect(zone.occurrences(at, at + 1.minute).map { |o| o.start_at }).to eq([Time.utc(2027, 3, 28, 21, 30)])
    end

    it "keeps seconds on every occurrence, not just the first" do
      zone = user.zones.create!(name: "Odd", repeat: "daily", time_zone: "UTC",
        start_at: Time.utc(2026, 9, 25, 9, 0, 15), end_at: Time.utc(2026, 9, 25, 10, 0, 30))
      o = zone.occurrences(Time.utc(2026, 9, 26), Time.utc(2026, 9, 27)).first
      expect([o.start_at, o.end_at]).to eq([Time.utc(2026, 9, 26, 9, 0, 15), Time.utc(2026, 9, 26, 10, 0, 30)])
    end

    it "keeps the stored first occurrence across the ambiguous autumn hour" do
      # 2026-10-25 Amsterdam: 02:00–03:00 happens twice. First 02:30 (00:30Z) to second 02:45 (01:45Z) = 75 min.
      zone = user.zones.create!(name: "Late", repeat: "daily", time_zone: "Europe/Amsterdam",
        start_at: Time.utc(2026, 10, 25, 0, 30), end_at: Time.utc(2026, 10, 25, 1, 45))
      o = zone.occurrences(Time.utc(2026, 10, 24), Time.utc(2026, 10, 26)).first
      expect([o.start_at, o.end_at]).to eq([Time.utc(2026, 10, 25, 0, 30), Time.utc(2026, 10, 25, 1, 45)])
    end

    it "retimes the whole series when one occurrence is moved, and deletes it by occurrence id" do
      zone = user.zones.create!(name: "Daily", repeat: "daily", time_zone: "UTC",
        start_at: Time.utc(2026, 9, 25, 9), end_at: Time.utc(2026, 9, 25, 10))
      patch "/api/v1/account/zones/#{zone.key}@20260927T090000Z", headers: headers,
        params: { start_at: "2026-09-27T13:00:00Z", end_at: "2026-09-27T15:00:00Z" }
      expect(response).to have_http_status(:ok)
      zone.reload
      expect([zone.start_at, zone.end_at]).to eq([Time.utc(2026, 9, 25, 13), Time.utc(2026, 9, 25, 15)])

      delete "/api/v1/account/zones/#{zone.key}@20260928T130000Z", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Zone.exists?(zone.id)).to be(false)
    end

    it "deletes just one occurrence with scope=occurrence, keeping the series" do
      zone = user.zones.create!(name: "Daily", repeat: "daily", time_zone: "Europe/Amsterdam",
        start_at: Time.utc(2026, 9, 25, 22), end_at: Time.utc(2026, 9, 25, 23)) # 00:00 local, next day
      delete "/api/v1/account/zones/#{zone.key}@20260926T220000Z", headers: headers, params: { scope: "occurrence" }
      expect(response).to have_http_status(:no_content)
      expect(zone.reload.skip_dates).to eq([Date.new(2026, 9, 27)]) # the zone's local day, not UTC's
      starts = list("2026-09-25T00:00:00Z", "2026-09-28T00:00:00Z").map { |z| z["start_at"] }
      expect(starts).to eq(%w[2026-09-25T22:00:00Z 2026-09-27T22:00:00Z].map { |t| Time.iso8601(t).as_json })

      # A bare series key or a bad stamp is rejected, never read as "delete the series".
      delete "/api/v1/account/zones/#{zone.key}", headers: headers, params: { scope: "occurrence" }
      expect(response).to have_http_status(:unprocessable_content)
      delete "/api/v1/account/zones/#{zone.key}@garbage", headers: headers, params: { scope: "occurrence" }
      expect(response).to have_http_status(:unprocessable_content)
      # A stamp on a real day but not the series' start time, and a misspelt scope.
      delete "/api/v1/account/zones/#{zone.key}@20260928T090000Z", headers: headers, params: { scope: "occurrence" }
      expect(response).to have_http_status(:unprocessable_content)
      delete "/api/v1/account/zones/#{zone.key}@20260928T220000Z", headers: headers, params: { scope: "occurence" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(zone.reload.skip_dates).to eq([Date.new(2026, 9, 27)])
      expect(Zone.exists?(zone.id)).to be(true)
    end

    it "allows an overnight zone but not one longer than a day" do
      post "/api/v1/account/zones", headers: headers,
        params: { name: "Night shift", start_at: "2026-09-25T20:00:00Z", end_at: "2026-09-26T02:00:00Z" }
      expect(response).to have_http_status(:created)

      post "/api/v1/account/zones", headers: headers,
        params: { name: "Too long", start_at: "2026-09-25T20:00:00Z", end_at: "2026-09-27T02:00:00Z" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "keeps a prep zone's anchor and rejects an unknown repeat or time zone" do
      post "/api/v1/account/zones", headers: headers, params: {
        name: "Prep: board", anchor_event_id: "cev_abc", anchor_minutes: 60,
        start_at: "2026-09-25T13:00:00Z", end_at: "2026-09-25T14:00:00Z"
      }
      expect(response.parsed_body["zone"]).to include("anchor_event_id" => "cev_abc", "anchor_minutes" => 60, "repeat" => "none")

      post "/api/v1/account/zones", headers: headers,
        params: { name: "x", repeat: "hourly", start_at: "2026-09-25T13:00:00Z", end_at: "2026-09-25T14:00:00Z" }
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/account/zones", headers: headers,
        params: { name: "x", time_zone: "Mars/Olympus", start_at: "2026-09-25T13:00:00Z", end_at: "2026-09-25T14:00:00Z" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "keeps local time when an occurrence is moved across the DST change" do
      zone = user.zones.create!(name: "Focus", repeat: "daily", time_zone: "Europe/Amsterdam",
        start_at: Time.utc(2026, 10, 22, 14), end_at: Time.utc(2026, 10, 22, 16)) # 16:00 CEST
      # The Oct 26 occurrence (16:00 CET = 15:00Z) moved to Oct 24, still 16:00 local.
      patch "/api/v1/account/zones/#{zone.key}@20261026T150000Z", headers: headers,
        params: { start_at: "2026-10-24T14:00:00Z", end_at: "2026-10-24T16:00:00Z" }
      zone.reload
      expect(zone.start_at.in_time_zone("Europe/Amsterdam").strftime("%H:%M")).to eq("16:00")
      expect(zone.start_at.to_date).to eq(Date.new(2026, 10, 20))
    end

    it "keeps the edited occurrence when the repeat is turned off" do
      zone = user.zones.create!(name: "Daily", repeat: "daily", time_zone: "UTC",
        start_at: Time.utc(2026, 9, 25, 9), end_at: Time.utc(2026, 9, 25, 10))
      patch "/api/v1/account/zones/#{zone.key}@20260928T090000Z", headers: headers,
        params: { repeat: "none", start_at: "2026-09-28T09:00:00Z", end_at: "2026-09-28T10:00:00Z" }
      zone.reload
      expect([zone.repeat, zone.start_at]).to eq(["none", Time.utc(2026, 9, 28, 9)])
    end
  end

  describe "cross-device sync" do
    include ActiveSupport::Testing::TimeHelpers

    # The zones below are dated; dismissals are swept 7 days after a zone ends,
    # so pin the clock to the day they run.
    around { |ex| travel_to(Time.utc(2026, 9, 25, 12)) { ex.run } }

    let(:zone) { user.zones.create!(name: "Focus", start_at: Time.utc(2026, 9, 25, 14), end_at: Time.utc(2026, 9, 25, 16)) }

    it "records a dismissal once, flags it on the list, and tells the other devices" do
      expect {
        post "/api/v1/account/zone-dismissals", headers: headers, params: { occurrence_id: zone.key, end_at: zone.end_at.iso8601 }
      }.to have_broadcasted_to("zones_#{user.key}").with(type: "zones_changed", dismissed: zone.key)
      expect(response).to have_http_status(:created)

      # Idempotent: a second device clicking Done changes nothing and stays quiet.
      expect {
        post "/api/v1/account/zone-dismissals", headers: headers, params: { occurrence_id: zone.key, end_at: zone.end_at.iso8601 }
      }.not_to have_broadcasted_to("zones_#{user.key}")
      expect(response).to have_http_status(:ok)

      get "/api/v1/account/zones", params: { start: "2026-09-25T00:00:00Z", end: "2026-09-26T00:00:00Z" }, headers: headers
      expect(response.parsed_body["zones"].first["dismissed"]).to be(true)
      expect(ZoneDismissal.where(user: user).count).to eq(1)
    end

    it "dismisses one occurrence of a repeating zone, not the series" do
      daily = user.zones.create!(name: "Daily", repeat: "daily", time_zone: "UTC",
        start_at: Time.utc(2026, 9, 25, 9), end_at: Time.utc(2026, 9, 25, 10))
      post "/api/v1/account/zone-dismissals", headers: headers,
        params: { occurrence_id: "#{daily.key}@20260926T090000Z", end_at: "2026-09-26T10:00:00Z" }
      get "/api/v1/account/zones", params: { start: "2026-09-25T00:00:00Z", end: "2026-09-28T00:00:00Z" }, headers: headers
      expect(response.parsed_body["zones"].map { |z| z["dismissed"] }).to eq([false, true, false])
    end

    it "404s a dismissal for someone else's zone" do
      theirs = other.zones.create!(name: "Private", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      post "/api/v1/account/zone-dismissals", headers: headers, params: { occurrence_id: theirs.key, end_at: theirs.end_at.iso8601 }
      expect(response).to have_http_status(:not_found)
    end

    it "lists only live dismissals" do
      user.zone_dismissals.create!(occurrence_id: "zon_old", end_at: 3.days.ago)
      user.zone_dismissals.create!(occurrence_id: zone.key, end_at: 1.hour.from_now)
      get "/api/v1/account/zone-dismissals", headers: headers
      expect(response.parsed_body["zone_dismissals"].map { |d| d["occurrence_id"] }).to eq([zone.key])
    end

    it "tells the other devices when a zone or category changes" do
      expect {
        post "/api/v1/account/zones", headers: headers, params: { name: "New", start_at: "2026-09-25T14:00:00Z", end_at: "2026-09-25T15:00:00Z" }
      }.to have_broadcasted_to("zones_#{user.key}").with(type: "zones_changed")
      expect {
        post "/api/v1/account/zone-categories", headers: headers, params: { name: "Writing", color: "rose" }
      }.to have_broadcasted_to("zones_#{user.key}")
      expect {
        post "/api/v1/account/zones", headers: headers, params: { name: "", start_at: "2026-09-25T14:00:00Z", end_at: "2026-09-25T15:00:00Z" }
      }.not_to have_broadcasted_to("zones_#{user.key}")
    end

    it "clears a zone's dismissals when it's edited, so it alerts again" do
      post "/api/v1/account/zone-dismissals", headers: headers, params: { occurrence_id: zone.key, end_at: zone.end_at.iso8601 }
      patch "/api/v1/account/zones/#{zone.key}", headers: headers, params: { name: "Focus, round two" }
      expect(ZoneDismissal.where(user: user)).to be_empty
      get "/api/v1/account/zones", params: { start: "2026-09-25T00:00:00Z", end: "2026-09-26T00:00:00Z" }, headers: headers
      expect(response.parsed_body["zones"].first["dismissed"]).to be(false)
    end
  end
end
