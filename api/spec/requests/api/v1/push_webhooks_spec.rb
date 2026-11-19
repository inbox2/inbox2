require "rails_helper"

# Provider webhook receivers for cloud push — see docs/Cloud-Push.md
RSpec.describe "Api::V1::PushWebhooks", type: :request do
  let(:user) { create(:user, username: "webhookuser") }

  def gmail_payload(email:, history_id: 12345)
    data = Base64.encode64({ emailAddress: email, historyId: history_id }.to_json)
    { message: { data: data, messageId: "m1" }, subscription: "projects/x/subscriptions/y" }
  end

  describe "POST /api/v1/push/gmail" do
    # Hermetic against ambient env: dotenv loads .env in the test group, which may
    # set GMAIL_PUBSUB_VERIFICATION_TOKEN. Default to "unset" (accept) here; the
    # verification-token cases stub their own value.
    before { allow(PushConfig).to receive(:gmail_verification_token).and_return(nil) }

    it "broadcasts a content-free sync signal to the matching user's stream" do
      sub = create(:channel_push_subscription, user: user,
        provider: ChannelPushSubscription::PROVIDER_GMAIL, external_email: "me@gmail.com")

      expect(ChannelPushBroadcaster).to receive(:call).with(
        having_attributes(id: sub.id), history_id: 12345
      )

      post "/api/v1/push/gmail", params: gmail_payload(email: "me@gmail.com"), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "does not broadcast for an unknown mailbox" do
      expect(ChannelPushBroadcaster).not_to receive(:call)
      post "/api/v1/push/gmail", params: gmail_payload(email: "nobody@gmail.com"), as: :json
      expect(response).to have_http_status(:ok)
    end

    it "rejects when the verification token is configured and missing" do
      allow(PushConfig).to receive(:gmail_verification_token).and_return("expected-token")
      expect(ChannelPushBroadcaster).not_to receive(:call)

      post "/api/v1/push/gmail", params: gmail_payload(email: "me@gmail.com"), as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "accepts when the verification token matches" do
      allow(PushConfig).to receive(:gmail_verification_token).and_return("expected-token")
      create(:channel_push_subscription, user: user,
        provider: ChannelPushSubscription::PROVIDER_GMAIL, external_email: "me@gmail.com")

      post "/api/v1/push/gmail?token=expected-token",
        params: gmail_payload(email: "me@gmail.com"), as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/push/microsoft" do
    it "echoes the validationToken on subscription creation" do
      post "/api/v1/push/microsoft", params: { validationToken: "abc-123" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("abc-123")
      expect(response.media_type).to eq("text/plain")
    end

    it "broadcasts when clientState matches" do
      sub = create(:channel_push_subscription, user: user,
        provider: ChannelPushSubscription::PROVIDER_MICROSOFT,
        provider_subscription_id: "graph-1", client_state: "good-state")

      expect(ChannelPushBroadcaster).to receive(:call).with(having_attributes(id: sub.id))

      post "/api/v1/push/microsoft",
        params: { value: [{ subscriptionId: "graph-1", clientState: "good-state" }] }, as: :json

      expect(response).to have_http_status(:ok)
    end

    it "ignores notifications with a mismatched clientState" do
      create(:channel_push_subscription, user: user,
        provider: ChannelPushSubscription::PROVIDER_MICROSOFT,
        provider_subscription_id: "graph-1", client_state: "good-state")

      expect(ChannelPushBroadcaster).not_to receive(:call)

      post "/api/v1/push/microsoft",
        params: { value: [{ subscriptionId: "graph-1", clientState: "WRONG" }] }, as: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
