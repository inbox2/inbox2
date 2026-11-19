require "rails_helper"

RSpec.describe "Api::V1::Accounts", type: :request do
  let(:user) { create(:user, billing_email: "owner@external.com") }
  let(:headers) { auth_headers(user) }

  # Spec 2.2.2, A2.1 — Read account
  describe "GET /api/v1/account" do
    context "positive" do
      it "returns the current user's account" do
        get "/api/v1/account", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["account"]["username"]).to eq(user.username)
        expect(body["account"]["id"]).to start_with("usr_")
        # E4: no internal data exposed
        expect(body["account"]).not_to have_key("password_digest")
      end

      it "lists the user's orgs with their primary mailbox address + role" do
        org = create(:organization, owner: user, domain: "acct.test")
        m = create(:membership, user: user, organization: org, role: "owner", status: "active")
        create(:mailbox, membership: m, domain: org.default_domain, local_part: "me")

        get "/api/v1/account", headers: headers
        expect(response).to have_http_status(:ok)
        org_row = response.parsed_body["organizations"].find { |o| o["id"] == org.key }
        expect(org_row["mailbox"]).to eq("me@acct.test")
        expect(org_row["role"]).to eq("owner")
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        get "/api/v1/account"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # Spec 2.2.2, A2.2 — Update account
  describe "PATCH /api/v1/account" do
    context "positive" do
      it "updates account settings" do
        patch "/api/v1/account", params: { display_name: "New Name", default_timezone: "US/Eastern" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["account"]["display_name"]).to eq("New Name")
        expect(response.parsed_body["account"]["default_timezone"]).to eq("US/Eastern")
      end
    end

    context "negative — a language the clients don't offer" do
      it "refuses it and keeps the current one" do
        patch "/api/v1/account", params: { default_language: "xx" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.default_language).to eq("en")
      end
    end

    context "negative — does not allow username change" do
      it "ignores unpermitted params" do
        patch "/api/v1/account", params: { username: "hackerusername" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(user.reload.username).not_to eq("hackerusername")
      end
    end

    # Scheduling preferences (docs/Calendar.md) — the working day the scheduling
    # assistant ranks against, and an out-of-office period that makes someone
    # busy without them blocking their own calendar.
    context "scheduling preferences" do
      it "returns the resolved working day even when never set" do
        get "/api/v1/account", headers: headers
        hours = response.parsed_body["account"]["working_hours"]
        expect(hours["start_minute"]).to eq(User::DEFAULT_WORKING_HOURS["start_minute"])
        expect(hours["days"]).to eq([1, 2, 3, 4, 5])
      end

      it "saves working hours" do
        patch "/api/v1/account",
              params: { working_hours: { start_minute: 480, end_minute: 960, days: [1, 2, 3] } },
              headers: headers

        expect(response).to have_http_status(:ok)
        expect(user.reload.working_hours["start_minute"]).to eq(480)
        expect(response.parsed_body["account"]["working_hours"]["days"]).to eq([1, 2, 3])
      end

      it "saves an out-of-office period" do
        patch "/api/v1/account",
              params: { out_of_office_start: "2026-03-02T00:00:00Z",
                        out_of_office_end: "2026-03-09T00:00:00Z",
                        out_of_office_message: "On holiday" },
              headers: headers

        expect(response).to have_http_status(:ok)
        expect(user.reload.out_of_office_start).to eq(Time.utc(2026, 3, 2))
        expect(response.parsed_body["account"]["out_of_office_message"]).to eq("On holiday")
      end

      it "clears the period when the dates are blanked" do
        user.update!(out_of_office_start: Time.utc(2026, 3, 2), out_of_office_end: Time.utc(2026, 3, 9))

        patch "/api/v1/account", params: { out_of_office_start: "", out_of_office_end: "" }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(user.reload.out_of_office_start).to be_nil
        expect(response.parsed_body["account"]["out_of_office"]).to be(false)
      end

      it "422s on a working day that ends before it starts (negative)" do
        patch "/api/v1/account",
              params: { working_hours: { start_minute: 1000, end_minute: 200 } }, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.working_hours).to be_nil
      end
    end
  end

  # A2 — Profile picture upload
  describe "POST /api/v1/account/avatar" do
    # Full 8-byte PNG signature — uploads are validated by magic bytes, not the
    # client-supplied Content-Type.
    let(:image) { Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\n"), "image/png", original_filename: "me.png") }

    context "positive" do
      it "stores the avatar and returns a public stream URL" do
        storage = instance_double(S3StorageService, upload: "users/#{user.key}/2026/06/20/abc/me.png")
        allow(S3StorageService).to receive(:new).and_return(storage)

        post "/api/v1/account/avatar", params: { file: image }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(user.reload.avatar_url).to eq("users/#{user.key}/2026/06/20/abc/me.png")
        # The URL carries a signed token, not the raw user key (non-enumerable).
        url = response.parsed_body["account"]["avatar_url"]
        expect(url).to include("/api/v1/account/avatar/")
        expect(url).not_to include(user.key)
        token = url.split("/api/v1/account/avatar/").last
        expect(AvatarToken.user_key(token)).to eq(user.key)
      end
    end

    context "negative — no file" do
      it "returns 422" do
        post "/api/v1/account/avatar", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "negative — non-image file" do
      it "returns 422" do
        bad = Rack::Test::UploadedFile.new(StringIO.new("nope"), "text/plain", original_filename: "x.txt")
        post "/api/v1/account/avatar", params: { file: bad }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "security — SVG disguised as an image (stored XSS)" do
      it "rejects an SVG even when the client claims image/svg+xml" do
        svg = Rack::Test::UploadedFile.new(
          StringIO.new(%(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>)),
          "image/svg+xml", original_filename: "x.svg"
        )
        post "/api/v1/account/avatar", params: { file: svg }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects a script payload mislabeled as image/png" do
        fake = Rack::Test::UploadedFile.new(StringIO.new("<script>alert(1)</script>"), "image/png", original_filename: "x.png")
        post "/api/v1/account/avatar", params: { file: fake }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        post "/api/v1/account/avatar", params: { file: image }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # A2 — Avatar stream (gated by a signed capability token, not the raw key)
  describe "GET /api/v1/account/avatar/:token" do
    let(:token) { AvatarToken.generate(user) }

    context "positive — valid signed token" do
      it "streams the stored avatar" do
        user.update!(avatar_url: "users/#{user.key}/img.png")
        storage = instance_double(S3StorageService, download_with_type: ["\x89PNG".b, "image/png"])
        allow(S3StorageService).to receive(:new).and_return(storage)

        get "/api/v1/account/avatar/#{token}"

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to start_with("image/png")
        expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      end

      it "never serves a stored SVG inline (defence in depth for legacy objects)" do
        user.update!(avatar_url: "users/#{user.key}/legacy.svg")
        storage = instance_double(S3StorageService, download_with_type: ["<svg/>".b, "image/svg+xml"])
        allow(S3StorageService).to receive(:new).and_return(storage)

        get "/api/v1/account/avatar/#{token}"

        expect(response.content_type).to start_with("application/octet-stream")
        expect(response.headers["Content-Disposition"]).to include("attachment")
        expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      end
    end

    context "negative — no avatar set" do
      it "returns 404" do
        get "/api/v1/account/avatar/#{token}"
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — not enumerable by raw user key" do
      it "returns 404 when given a raw usr_ key instead of a token" do
        user.update!(avatar_url: "users/#{user.key}/img.png")
        get "/api/v1/account/avatar/#{user.key}"
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — forged / tampered token" do
      it "returns 404 for an unsigned value" do
        get "/api/v1/account/avatar/not-a-real-token"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for an expired token" do
        user.update!(avatar_url: "users/#{user.key}/img.png")
        expired = AvatarToken.verifier.generate({ "u" => user.key }, expires_in: -1.minute)
        get "/api/v1/account/avatar/#{expired}"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Spec 2.1.8, A2.3 — Billing email
  describe "PUT /api/v1/account/billing-email" do
    context "positive" do
      it "keeps the confirmed address and mails a link to the new one" do
        expect do
          put "/api/v1/account/billing-email", params: { billing_email: "New@External.com" }, headers: headers
        end.to have_enqueued_job(MessyTriggerJob).with("send_message", hash_including(to: "new@external.com"))
        expect(response).to have_http_status(:ok)
        expect(user.reload).to have_attributes(billing_email: "owner@external.com", pending_billing_email: "new@external.com")
        expect(response.parsed_body["account"]).to include("billing_email" => "owner@external.com", "pending_billing_email" => "new@external.com")
      end

      it "takes the new address when its link is used, once" do
        raw = user.begin_billing_email_change!("new@external.com")
        post "/api/v1/auth/confirm-email", params: { token: raw }
        expect(response).to have_http_status(:ok)
        expect(user.reload).to have_attributes(billing_email: "new@external.com", pending_billing_email: nil, billing_email_token_digest: nil)
        post "/api/v1/auth/confirm-email", params: { token: raw }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "drops a waiting change when the confirmed address is entered again" do
        user.begin_billing_email_change!("new@external.com")
        put "/api/v1/account/billing-email", params: { billing_email: "owner@external.com" }, headers: headers
        expect(user.reload).to have_attributes(billing_email: "owner@external.com", pending_billing_email: nil)
      end
    end

    context "negative" do
      it "refuses something that is not an address" do
        put "/api/v1/account/billing-email", params: { billing_email: "nope" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "refuses a wrong token, an expired link and an address another account confirmed first" do
        post "/api/v1/auth/confirm-email", params: { token: "wrong" }
        expect(response).to have_http_status(:unprocessable_content)

        raw = user.begin_billing_email_change!("new@external.com")
        user.update_columns(billing_email_token_sent_at: 25.hours.ago)
        post "/api/v1/auth/confirm-email", params: { token: raw }
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.billing_email).to eq("owner@external.com")

        raw = user.begin_billing_email_change!("taken@external.com")
        create(:user, billing_email: "taken@external.com")
        post "/api/v1/auth/confirm-email", params: { token: raw }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].first["message"]).to eq("Another account uses this address.")
        expect(user.reload.billing_email).to eq("owner@external.com")
      end
    end

    context "warns if Inbox2-hosted domain" do
      it "returns a warning" do
        org = create(:organization, owner: user, domain: "mycompany.com")
        create(:membership, user: user, organization: org, status: "active")

        put "/api/v1/account/billing-email", params: { billing_email: "billing@mycompany.com" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["warnings"]).to be_present
      end
    end
  end

  # PUT /api/v1/account/password — change own password (re-auth required)
  describe "PUT /api/v1/account/password" do
    context "positive" do
      it "changes the password when the current password is correct" do
        put "/api/v1/account/password",
            params: { current_password: "password123", password: "newpassword456" }, headers: headers
        expect(response).to have_http_status(:no_content)
        expect(user.reload.authenticate("newpassword456")).to be_truthy
      end
    end

    context "negative" do
      it "rejects a wrong current password" do
        put "/api/v1/account/password",
            params: { current_password: "wrong", password: "newpassword456" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.authenticate("password123")).to be_truthy
      end

      it "rejects a new password below the minimum length" do
        put "/api/v1/account/password",
            params: { current_password: "password123", password: "short" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.authenticate("password123")).to be_truthy
      end

      it "requires authentication" do
        put "/api/v1/account/password", params: { current_password: "password123", password: "newpassword456" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
