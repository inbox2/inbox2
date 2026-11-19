require "rails_helper"

# Meta channels — device-reported asset→user routing. See docs/Cloud-Push.md (Meta).
RSpec.describe "Api::V1::MetaChannelSubscriptions", type: :request do
  let(:user) { create(:user, username: "metauser") }
  # Push is a paid feature (TODO 45.6) — give the user a paid org.
  let(:paid_org) { create(:organization, owner: user, domain: "metateam.com") }
  let!(:paid_membership) { create(:membership, user: user, organization: paid_org, role: "owner", status: "active") }
  let!(:paid_subscription) { create(:subscription, organization: paid_org, plan: Plan.paid) }
  let(:headers) { auth_headers(user) }

  describe "POST /api/v1/meta-channel-subscriptions" do
    let(:params) do
      { channel: "messenger", asset_type: "page", asset_id: "PAGE123" }
    end

    it "registers an asset→user routing row (E1 positive)" do
      post "/api/v1/meta-channel-subscriptions", params: params, headers: headers

      expect(response).to have_http_status(:created)
      sub = MetaChannelSubscription.last
      expect(sub.user).to eq(user)
      expect(sub.asset_type).to eq("page")
      expect(sub.asset_id).to eq("PAGE123")
      expect(sub.live?).to be(true)

      returned = response.parsed_body["subscription"]
      expect(returned["id"]).to start_with("mcs_")
      # E4: no secret fields (none exist on this record) and no user_id leak.
      expect(returned).not_to have_key("user_id")
    end

    it "is idempotent on (user, asset_type, asset_id) and bumps the lease" do
      create(:meta_channel_subscription, user: user, asset_type: "page", asset_id: "PAGE123",
        lease_expires_at: 1.hour.from_now)

      expect {
        post "/api/v1/meta-channel-subscriptions", params: params, headers: headers
      }.not_to change(MetaChannelSubscription, :count)

      expect(response).to have_http_status(:created)
      expect(MetaChannelSubscription.last.lease_expires_at).to be > 29.days.from_now
    end

    it "requires authentication (E1 negative)" do
      post "/api/v1/meta-channel-subscriptions", params: params
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/meta-channel-subscriptions" do
    it "lists the user's active rows and excludes other tenants (E3)" do
      mine = create(:meta_channel_subscription, user: user, asset_type: "page", asset_id: "MINE")
      other = create(:user, username: "other")
      create(:meta_channel_subscription, user: other, asset_type: "page", asset_id: "THEIRS")

      get "/api/v1/meta-channel-subscriptions", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["subscriptions"].map { |s| s["asset_id"] }
      expect(ids).to contain_exactly("MINE")
      expect(response.parsed_body["subscriptions"].first["id"]).to eq(mine.key)
    end
  end

  describe "GET /api/v1/meta-channel-subscriptions/config" do
    it "returns the verify token + push gating for client webhook auto-config" do
      allow(MetaConfig).to receive(:verify_token).and_return("vtok-123")
      get "/api/v1/meta-channel-subscriptions/config", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["verify_token"]).to eq("vtok-123")
      expect(response.parsed_body["push_enabled"]).to be(true)
    end

    it "requires authentication" do
      get "/api/v1/meta-channel-subscriptions/config"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/v1/meta-channel-subscriptions/:id" do
    it "tears down the row" do
      sub = create(:meta_channel_subscription, user: user)
      delete "/api/v1/meta-channel-subscriptions/#{sub.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(MetaChannelSubscription.exists?(sub.id)).to be(false)
    end

    it "cannot delete another user's row (E3 → 404)" do
      other = create(:user, username: "other2")
      sub = create(:meta_channel_subscription, user: other)
      delete "/api/v1/meta-channel-subscriptions/#{sub.key}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(MetaChannelSubscription.exists?(sub.id)).to be(true)
    end
  end
end
