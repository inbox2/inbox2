require "rails_helper"

# docs/Open-Tracking.md, TODO 48.20: the token in a mail no longer reads its opens.
RSpec.describe "Api::V1::Tracking", type: :request do
  def open_for(token, org: nil)
    MessageOpen.create!(token: token, opened_at: Time.current, ip: "203.0.113.9", organization_id: org&.id)
  end

  it "derives the token as the Rust core does" do
    expect(Tracking.token_for("abc-secret-for-the-vector")).to eq("RxoDeNON5B-uEL6OqeMInQdE")
  end

  it "reads opens with the secret, keyed by token" do
    token = Tracking.token_for("s3cret")
    open_for(token)
    post "/api/v1/tracking/opens", params: { secrets: ["s3cret"] }
    expect(response.parsed_body["opens"].keys).to eq([token])
  end

  it "refuses to read a hashed token by the token itself" do
    token = Tracking.token_for("s3cret")
    open_for(token)
    post "/api/v1/tracking/opens", params: { tokens: [token] }
    expect(response.parsed_body["opens"]).to eq({})
  end

  it "still serves a local-channel token from before secrets, but never an inbox2-hosted message's" do
    legacy = "a" * 22
    hosted = "b" * 22
    open_for(legacy)
    open_for(hosted, org: create(:organization))
    post "/api/v1/tracking/opens", params: { tokens: [legacy, hosted] }
    expect(response.parsed_body["opens"].keys).to eq([legacy])
  end

  it "needs a signed-in account to register or verify a custom host" do
    post "/api/v1/tracking/register", params: { host: "track.example.com" }
    expect(response).to have_http_status(:unauthorized)
    post "/api/v1/tracking/verify-host", params: { host: "track.example.com" }
    expect(response).to have_http_status(:unauthorized)
  end
end
