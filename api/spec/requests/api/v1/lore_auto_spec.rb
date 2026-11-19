require "rails_helper"

# Lore "Handled for you" auto mode (docs/Triage.md "Auto mode").
RSpec.describe "Api::V1::LoreAuto", type: :request do
  let(:user) { create(:user) }
  let(:json) { JSON.parse(response.body) }

  it "is all off for a person who never set it" do
    get "/api/v1/account/lore-auto", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(json).to eq("lore_auto" => { "fyi" => false, "receipt" => false, "notification" => false })
  end

  it "saves the three buckets and drops unknown keys" do
    put "/api/v1/account/lore-auto", params: { lore_auto: { fyi: true, notification: true, needs_answer: true } },
                                     headers: auth_headers(user), as: :json

    expect(response).to have_http_status(:ok)
    expect(json["lore_auto"]).to eq("fyi" => true, "receipt" => false, "notification" => true)
    expect(user.reload.lore_auto).not_to have_key("needs_answer")

    put "/api/v1/account/lore-auto", params: { lore_auto: { fyi: false } }, headers: auth_headers(user), as: :json
    expect(JSON.parse(response.body)["lore_auto"]).to eq("fyi" => false, "receipt" => false, "notification" => true)
  end

  it "rejects a value that is not a boolean" do
    put "/api/v1/account/lore-auto", params: { lore_auto: { fyi: "yes" } }, headers: auth_headers(user), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.lore_auto).to eq({})
  end

  it "rejects a missing body" do
    put "/api/v1/account/lore-auto", params: {}, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:bad_request)
  end

  it "requires a session" do
    get "/api/v1/account/lore-auto"
    expect(response).to have_http_status(:unauthorized)
  end
end
