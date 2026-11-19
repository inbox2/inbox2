require "rails_helper"

# spec 13.1.1 — public plan catalogue. E2EE is a paid entitlement surfaced as a
# plan feature (docs/E2EE.md), so the serializer must expose it for the pricing
# UI to advertise it on Startup + Serial Entrepreneur.
RSpec.describe "Api::V1::Plans", type: :request do
  it "exposes e2ee per tier so the pricing UI can list it (paid tiers on, free off)" do
    get "/api/v1/plans"
    expect(response).to have_http_status(:ok)

    by_tier = response.parsed_body["plans"].index_by { |p| p["tier"] }
    expect(by_tier.keys).to include("free", "paid", "max")

    # Startup (paid) + Serial Entrepreneur (max) include E2EE; Free does not.
    expect(by_tier["paid"]["e2ee"]).to be(true)
    expect(by_tier["max"]["e2ee"]).to be(true)
    expect(by_tier["free"]["e2ee"]).to be(false)

    # Still a public, no-auth endpoint.
    expect(by_tier["paid"]).to include("name", "price_cents", "spam_filter", "e2ee")
  end
end
