require "rails_helper"

RSpec.describe "Api::V1::Auth", type: :request do
  # Spec 2.1.1, A1.1 — Signup
  describe "POST /api/v1/auth/signup" do
    let(:valid_params) { { username: "testuser", password: "password123", password_confirmation: "password123", billing_email: "test@external.com" } }

    context "positive" do
      it "creates an account and returns a session token" do
        post "/api/v1/auth/signup", params: valid_params
        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["user"]["username"]).to eq("testuser")
        expect(body["user"]["id"]).to start_with("usr_")
        expect(body["token"]).to be_present
        # E5: no internal numeric ID exposed
        expect(body["user"]).not_to have_key("internal_id")
      end
    end

    context "negative" do
      it "refuses a contact address that is not an address, and makes no account" do
        expect do
          post "/api/v1/auth/signup", params: valid_params.merge(billing_email: "nope")
        end.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects duplicate username" do
        create(:user, username: "testuser")
        post "/api/v1/auth/signup", params: valid_params
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"]).to be_present
      end

      it "rejects short username" do
        post "/api/v1/auth/signup", params: valid_params.merge(username: "ab")
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects invalid username characters" do
        post "/api/v1/auth/signup", params: valid_params.merge(username: "test user!")
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects mismatched passwords" do
        post "/api/v1/auth/signup", params: valid_params.merge(password_confirmation: "wrong")
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "when INVITE_ENABLED (invite-only)" do
      around do |ex|
        orig = ENV["INVITE_ENABLED"]
        ENV["INVITE_ENABLED"] = "true"
        ex.run
        ENV["INVITE_ENABLED"] = orig
      end

      it "rejects signup without a valid invite token" do
        expect {
          post "/api/v1/auth/signup", params: valid_params
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].to_s).to match(/invite-only/i)
      end

      it "creates the account from a redeemable invite and marks the waitlist registered" do
        signup = create(:waitlist_signup, :invited, email: "invited@example.com")

        post "/api/v1/auth/signup", params: valid_params.merge(invite_token: signup.invite_token)

        expect(response).to have_http_status(:created)
        user = User.find_by(username: "testuser")
        # billing_email is taken from the waitlist row, not the request
        expect(user.billing_email).to eq("invited@example.com")
        # …and so is the name they gave on the waitlist
        expect(user.display_name).to eq(signup.name)
        expect(response.parsed_body["user"]["display_name"]).to eq(signup.name)
        expect(signup.reload.status).to eq(WaitlistSignup::STATUS_REGISTERED)
        expect(signup.user).to eq(user)
      end
    end
  end

  # Spec 2.1.3, A1.2 — Login
  describe "POST /api/v1/auth/login" do
    let!(:user) { create(:user, username: "loginuser", password: "secret123") }

    context "positive" do
      it "returns a session token on valid credentials" do
        post "/api/v1/auth/login", params: { username: "loginuser", password: "secret123" }
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["token"]).to be_present
        expect(body["user"]["id"]).to start_with("usr_")
      end

      it "also sets the HttpOnly session cookie (web SPA auth)" do
        post "/api/v1/auth/login", params: { username: "loginuser", password: "secret123" }
        set_cookie = response.headers["Set-Cookie"]
        expect(set_cookie).to include("inbox2_session=")
        expect(set_cookie).to match(/httponly/i)
        expect(set_cookie).to match(/samesite=lax/i)
      end

      it "authenticates a subsequent request via the cookie alone (no Authorization header)" do
        post "/api/v1/auth/login", params: { username: "loginuser", password: "secret123" }
        # Browser carries the cookie back; rack-test threads response cookies into
        # the next request's jar automatically.
        get "/api/v1/account"
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["account"]["username"]).to eq("loginuser")
      end
    end

    context "negative" do
      it "rejects wrong password" do
        post "/api/v1/auth/login", params: { username: "loginuser", password: "wrong" }
        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects nonexistent user" do
        post "/api/v1/auth/login", params: { username: "noone", password: "secret123" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # Spec 2.1.3, A1.3 — Logout
  describe "POST /api/v1/auth/logout" do
    let(:user) { create(:user) }

    it "destroys the session" do
      headers = auth_headers(user)
      expect { post "/api/v1/auth/logout", headers: headers }.to change(Session, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  # Spec 2.1.3, A1.4 — Password reset request
  describe "POST /api/v1/auth/password/reset-request" do
    it "always returns accepted (prevents enumeration)" do
      post "/api/v1/auth/password/reset-request", params: { email: "nonexistent@example.com" }
      expect(response).to have_http_status(:accepted)
    end

    it "generates a reset token for valid billing email" do
      user = create(:user, billing_email: "owner@external.com")
      post "/api/v1/auth/password/reset-request", params: { email: "owner@external.com" }
      expect(response).to have_http_status(:accepted)
      expect(user.reload.reset_token).to be_present
    end
  end

  # Spec 2.1.3, A1.5 — Password reset
  describe "POST /api/v1/auth/password/reset" do
    let(:user) { create(:user, billing_email: "owner@external.com") }

    context "positive" do
      it "resets password with valid token" do
        token = user.generate_reset_token!
        post "/api/v1/auth/password/reset", params: { token: token, password: "newpassword123" }
        expect(response).to have_http_status(:ok)
        expect(user.reload.authenticate("newpassword123")).to be_truthy
        expect(user.reset_token).to be_nil
      end

      it "destroys all sessions on reset" do
        create(:session, user: user)
        create(:session, user: user)
        token = user.generate_reset_token!
        expect { post "/api/v1/auth/password/reset", params: { token: token, password: "newpassword123" } }
          .to change { user.sessions.count }.to(0)
      end
    end

    context "negative" do
      it "rejects invalid token" do
        post "/api/v1/auth/password/reset", params: { token: "bogus", password: "newpassword123" }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects expired token" do
        user.update!(reset_token: SecureRandom.hex(32), reset_token_expires_at: 1.hour.ago)
        post "/api/v1/auth/password/reset", params: { token: user.reset_token, password: "newpassword123" }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # Spec 2.1.4, A1.6 — List sessions
  describe "GET /api/v1/auth/sessions" do
    let(:user) { create(:user) }

    context "positive" do
      it "lists active sessions" do
        headers = auth_headers(user)
        get "/api/v1/auth/sessions", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["sessions"]).to be_an(Array)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        get "/api/v1/auth/sessions"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # Spec 2.1.4, A1.7 — Sign out all sessions
  describe "DELETE /api/v1/auth/sessions" do
    let(:user) { create(:user) }

    it "destroys all other sessions" do
      # Create extra sessions
      create(:session, user: user)
      create(:session, user: user)
      headers = auth_headers(user)

      expect { delete "/api/v1/auth/sessions", headers: headers }.to change(Session, :count).by(-2)
      expect(response).to have_http_status(:no_content)
    end
  end
end
