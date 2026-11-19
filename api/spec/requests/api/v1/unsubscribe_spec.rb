require "rails_helper"

# spec 18.4.2 — List-Unsubscribe one-click handler (no auth required)
RSpec.describe "Api::V1::Unsubscribe", type: :request do
  describe "POST /api/v1/unsubscribe/:token" do
    context "positive" do
      it "unsubscribes for a valid token and merges the service result" do
        allow(ListUnsubscribeService).to receive(:process_unsubscribe)
          .with("valid-token").and_return({ list: "newsletter", email: "x@y.com" })

        post "/api/v1/unsubscribe/valid-token"
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["status"]).to eq("unsubscribed")
        expect(body["list"]).to eq("newsletter")
      end
    end

    context "negative" do
      it "returns 422 for an invalid or expired token" do
        allow(ListUnsubscribeService).to receive(:process_unsubscribe).and_return(nil)

        post "/api/v1/unsubscribe/bad-token"
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
