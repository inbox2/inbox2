require "rails_helper"

# Cloud-synced per-channel open-tracking config (docs/Open-Tracking.md).
RSpec.describe "Api::V1::TrackingChannels", type: :request do
  let(:user) { create(:user) }
  let(:headers) { auth_headers(user) }

  it "requires authentication (the mx-or-api-token gate)" do
    get "/api/v1/tracking/channels"
    expect(response).to have_http_status(:unauthorized)
  end

  it "upserts and reads back a channel's tracking config, scoped to the user" do
    put "/api/v1/tracking/channels",
        params: { email: "Waseem@Tuli.com", open_tracking_enabled: true, track_domain: "track.tuli.com" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["channel"]).to include(
      "email_address" => "waseem@tuli.com", "open_tracking_enabled" => true, "track_domain" => "track.tuli.com"
    )

    get "/api/v1/tracking/channels", headers: headers
    expect(response.parsed_body["channels"].size).to eq(1)
    expect(response.parsed_body["channels"].first["email_address"]).to eq("waseem@tuli.com")
  end

  it "updates the same channel in place (idempotent on email)" do
    put "/api/v1/tracking/channels", params: { email: "a@b.co", open_tracking_enabled: true }, headers: headers
    put "/api/v1/tracking/channels", params: { email: "a@b.co", open_tracking_enabled: false }, headers: headers

    get "/api/v1/tracking/channels", headers: headers
    expect(response.parsed_body["channels"].size).to eq(1)
    expect(response.parsed_body["channels"].first["open_tracking_enabled"]).to be(false)
  end

  it "does not leak another user's channels (tenant isolation)" do
    other = create(:user)
    put "/api/v1/tracking/channels", params: { email: "x@y.co", open_tracking_enabled: true }, headers: auth_headers(other)

    get "/api/v1/tracking/channels", headers: headers
    expect(response.parsed_body["channels"]).to be_empty
  end
end
