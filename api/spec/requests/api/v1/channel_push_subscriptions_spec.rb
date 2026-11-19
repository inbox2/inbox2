require "rails_helper"

# Cloud push for local channels (Gmail/Office365) — see docs/Cloud-Push.md
RSpec.describe "Api::V1::ChannelPushSubscriptions", type: :request do
  let(:user) { create(:user, username: "pushuser") }
  let(:headers) { auth_headers(user) }
  # Push is a paid feature (TODO 45.6) — give the user a paid org.
  let(:org) { create(:organization, owner: user, domain: "pushteam.com") }
  let!(:membership) { create(:membership, user: user, organization: org, role: "owner", status: "active") }
  let!(:subscription) { create(:subscription, organization: org, plan: Plan.paid) }

  describe "GET /api/v1/channel-push-subscriptions" do
    it "returns the user's active subscription and push_enabled flag" do
      sub = create(:channel_push_subscription, user: user, external_email: "me@gmail.com")

      get "/api/v1/channel-push-subscriptions", params: { email: "me@gmail.com" }, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["push_enabled"]).to be(true)
      expect(body["subscriptions"].length).to eq(1)
      returned = body["subscriptions"].first
      expect(returned["id"]).to eq(sub.key)
      expect(returned["id"]).to start_with("cpsub_")
      # E4: secrets are never exposed
      expect(returned).not_to have_key("client_state")
      expect(returned).not_to have_key("provider_subscription_id")
      expect(returned).not_to have_key("user_id")
    end

    it "omits expired-lease subscriptions" do
      create(:channel_push_subscription, user: user, external_email: "stale@gmail.com",
        lease_expires_at: 1.day.ago)

      get "/api/v1/channel-push-subscriptions", params: { email: "stale@gmail.com" }, headers: headers

      expect(response.parsed_body["subscriptions"]).to be_empty
    end

    it "omits subscriptions whose provider-side expiry has lapsed (so the client re-registers)" do
      # Lease still valid (30d) but the Graph/watch subscription expired — the client
      # must see "no active sub" and register a fresh one, not trust the stale lease.
      create(:channel_push_subscription, user: user, external_email: "lapsed@gmail.com",
        lease_expires_at: 20.days.from_now, expires_at: 1.hour.ago)

      get "/api/v1/channel-push-subscriptions", params: { email: "lapsed@gmail.com" }, headers: headers

      expect(response.parsed_body["subscriptions"]).to be_empty
    end

    it "does not return another user's subscriptions (tenant isolation)" do
      other = create(:user, username: "otherpush")
      create(:channel_push_subscription, user: other, external_email: "secret@gmail.com")

      get "/api/v1/channel-push-subscriptions", params: { email: "secret@gmail.com" }, headers: headers

      expect(response.parsed_body["subscriptions"]).to be_empty
    end

    it "requires authentication" do
      get "/api/v1/channel-push-subscriptions"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/channel-push-subscriptions" do
    let(:params) do
      {
        provider: ChannelPushSubscription::PROVIDER_MICROSOFT,
        external_email: "work@outlook.com",
        provider_subscription_id: "graph-sub-1",
        client_state: "secret-state",
        expires_at: 3.days.from_now.iso8601
      }
    end

    it "registers a subscription and stamps the lease" do
      expect {
        post "/api/v1/channel-push-subscriptions", params: params, headers: headers
      }.to change(user.channel_push_subscriptions, :count).by(1)

      expect(response).to have_http_status(:created)
      sub = user.channel_push_subscriptions.last
      expect(sub.provider).to eq(ChannelPushSubscription::PROVIDER_MICROSOFT)
      expect(sub.client_state).to eq("secret-state")
      expect(sub.lease_expires_at).to be_within(1.minute).of(ChannelPushSubscription::LEASE_DURATION.from_now)
    end

    it "is idempotent on (user, provider, email) — re-registering updates, not duplicates" do
      post "/api/v1/channel-push-subscriptions", params: params, headers: headers
      expect {
        post "/api/v1/channel-push-subscriptions",
          params: params.merge(provider_subscription_id: "graph-sub-2"), headers: headers
      }.not_to change(user.channel_push_subscriptions, :count)

      expect(user.channel_push_subscriptions.last.provider_subscription_id).to eq("graph-sub-2")
    end

    it "is forbidden when push is not enabled (gating)" do
      allow_any_instance_of(User).to receive(:push_enabled?).and_return(false)

      post "/api/v1/channel-push-subscriptions", params: params, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(user.channel_push_subscriptions.count).to eq(0)
    end

    it "is forbidden for a user whose orgs are all on the free plan (TODO 45.6)" do
      subscription.update!(plan: Plan.free)

      post "/api/v1/channel-push-subscriptions", params: params, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(user.channel_push_subscriptions.count).to eq(0)
    end
  end

  describe "PATCH /api/v1/channel-push-subscriptions/:id" do
    it "renews the provider expiry and the lease" do
      sub = create(:channel_push_subscription, user: user, lease_expires_at: 2.days.from_now)

      patch "/api/v1/channel-push-subscriptions/#{sub.key}",
        params: { expires_at: 5.days.from_now.iso8601, provider_subscription_id: "renewed" },
        headers: headers

      expect(response).to have_http_status(:ok)
      sub.reload
      expect(sub.provider_subscription_id).to eq("renewed")
      expect(sub.lease_expires_at).to be_within(1.minute).of(ChannelPushSubscription::LEASE_DURATION.from_now)
    end

    it "404s for another user's subscription" do
      other_sub = create(:channel_push_subscription)
      patch "/api/v1/channel-push-subscriptions/#{other_sub.key}", params: {}, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/channel-push-subscriptions/:id" do
    it "removes the subscription" do
      sub = create(:channel_push_subscription, user: user)
      delete "/api/v1/channel-push-subscriptions/#{sub.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(ChannelPushSubscription.exists?(sub.id)).to be(false)
    end
  end

  describe "GET /api/v1/channel-push-subscriptions/config" do
    it "returns push config for the engine" do
      allow(PushConfig).to receive(:webhook_base_url).and_return("https://host.tailnet.ts.net")
      allow(PushConfig).to receive(:gmail_topic).and_return("projects/inbox2/topics/gmail-push")

      get "/api/v1/channel-push-subscriptions/config", headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["push_enabled"]).to be(true)
      expect(body["gmail_topic"]).to eq("projects/inbox2/topics/gmail-push")
      expect(body["microsoft_notification_url"]).to eq("https://host.tailnet.ts.net/api/v1/push/microsoft")
    end
  end
end
