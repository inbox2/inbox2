require "rails_helper"

RSpec.describe "Api::V1::Saml", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:owner) { create(:user, username: "samlowner") }
  let(:org) { create(:organization, owner: owner, domain: "saml.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  let(:saml_params) do
    {
      idp_entity_id: "https://idp.example.com/saml",
      idp_sso_url: "https://idp.example.com/sso",
      idp_certificate: "MIICVjCCAb+gAwIBAgIBADANBgkqhkiG9w0BAQ0FADB...",
      enabled: true
    }
  end

  describe "PUT /api/v1/orgs/:org_id/saml (spec 2.1.7, A1.11)" do
    it "creates SAML configuration" do
      put "/api/v1/orgs/#{org.key}/saml", params: saml_params, headers: headers
      expect(response).to have_http_status(:created)
      config = response.parsed_body["saml_config"]
      expect(config["id"]).to start_with("saml_")
      expect(config["idp_entity_id"]).to eq("https://idp.example.com/saml")
      expect(config["enabled"]).to be true
      # Should not expose certificate in response
      expect(config).not_to have_key("idp_certificate")
    end

    it "updates existing SAML configuration" do
      SamlConfig.create!(organization: org, **saml_params)

      put "/api/v1/orgs/#{org.key}/saml",
          params: { idp_entity_id: "https://new-idp.example.com" },
          headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["saml_config"]["idp_entity_id"]).to eq("https://new-idp.example.com")
    end

    it "forbids regular members" do
      member = create(:user, username: "samlmember")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

      put "/api/v1/orgs/#{org.key}/saml", params: saml_params, headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/orgs/:org_id/saml" do
    it "returns nil when not configured" do
      get "/api/v1/orgs/#{org.key}/saml", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["saml_config"]).to be_nil
    end

    it "returns config when configured" do
      SamlConfig.create!(organization: org, **saml_params)

      get "/api/v1/orgs/#{org.key}/saml", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["saml_config"]["enabled"]).to be true
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/saml" do
    it "removes SAML configuration" do
      SamlConfig.create!(organization: org, **saml_params)

      expect {
        delete "/api/v1/orgs/#{org.key}/saml", headers: headers
      }.to change(SamlConfig, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET /api/v1/orgs/:org_id/saml/initiate" do
    it "returns redirect URL when SAML is configured" do
      SamlConfig.create!(organization: org, **saml_params)

      get "/api/v1/orgs/#{org.key}/saml/initiate"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["redirect_url"]).to include("idp.example.com")
    end

    it "returns 404 when SAML not configured" do
      get "/api/v1/orgs/#{org.key}/saml/initiate"
      expect(response).to have_http_status(:not_found)
    end

    it "accepts the org slug (what the login page asks for)" do
      SamlConfig.create!(organization: org, **saml_params)
      get "/api/v1/orgs/#{org.slug}/saml/initiate"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["redirect_url"]).to include("idp.example.com")
    end
  end

  describe "POST /api/v1/orgs/:org_id/saml/consume" do
    before { org.create_saml_config!(saml_params) }

    def stub_response(valid:, assertion_id:, nameid: "alice@saml.com")
      resp = instance_double(OneLogin::RubySaml::Response, is_valid?: valid, nameid: nameid, assertion_id: assertion_id, errors: ["bad"])
      allow(OneLogin::RubySaml::Response).to receive(:new).and_return(resp)
    end

    def consume(nameid:, assertion_id: "_a#{SecureRandom.hex(4)}", relay: nil, **opts)
      stub_response(valid: true, assertion_id: assertion_id, nameid: nameid)
      post "/api/v1/orgs/#{org.key}/saml/consume",
           params: { SAMLResponse: "x", RelayState: relay }.compact, **{ as: :json }.merge(opts)
    end

    it "provisions a first-seen NameID as a new active member and mints a session" do
      expect { consume(nameid: "newcomer@saml.com") }.to change(User, :count).by(1).and change(SamlIdentity, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["token"]).to be_present
      user = User.find_by(billing_email: "newcomer@saml.com")
      expect(response.parsed_body["user"]["id"]).to eq(user.key)
      expect(org.memberships.active.find_by(user: user).role).to eq(Membership::ROLE_MEMBER)
      expect(org.saml_identities.find_by(name_id: "newcomer@saml.com").user).to eq(user)
    end

    it "never resolves a NameID by username local-part (the old admin→owner escalation)" do
      # The org owner's username is "samlowner"; an IdP the admin controls asserts
      # samlowner@anything. That must not become the owner's session.
      consume(nameid: "samlowner@attacker.example")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]["id"]).not_to eq(owner.key)
      expect(response.parsed_body["user"]["username"]).not_to eq("samlowner")
      expect(Session.find_by_token(response.parsed_body["token"]).user).not_to eq(owner)
    end

    it "logs a linked identity's user in and stamps last_login_at" do
      member = create(:user, username: "linked1")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      identity = org.saml_identities.create!(user: member, name_id: "idp-opaque-123")

      expect { consume(nameid: "idp-opaque-123") }.not_to change(User, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]["id"]).to eq(member.key)
      expect(identity.reload.last_login_at).to be_present
    end

    it "refuses a linked identity whose membership was disabled" do
      member = create(:user, username: "gone1")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_DISABLED)
      org.saml_identities.create!(user: member, name_id: "gone@saml.com")

      consume(nameid: "gone@saml.com")
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses to provision when the NameID is an existing member's address (they must link first)" do
      member = create(:user, username: "alice1", billing_email: "alice@saml.com")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

      expect { consume(nameid: "alice@saml.com") }.not_to change(User, :count)
      expect(response).to have_http_status(:conflict)
      expect(org.saml_identities.where(name_id: "alice@saml.com")).not_to exist
    end

    it "refuses to provision when the NameID is an existing member's org mailbox" do
      member = create(:user, username: "bob1")
      m = create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      Mailbox.create!(membership: m, domain: org.default_domain, local_part: "bob")

      consume(nameid: "Bob@saml.com")
      expect(response).to have_http_status(:conflict)
    end

    it "rejects a replayed assertion id" do
      consume(nameid: "x@saml.com", assertion_id: "_assert_dup")
      expect(response).to have_http_status(:ok)

      consume(nameid: "x@saml.com", assertion_id: "_assert_dup")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an invalid assertion" do
      stub_response(valid: false, assertion_id: "_assert_2")
      post "/api/v1/orgs/#{org.key}/saml/consume", params: { SAMLResponse: "x" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an assertion with no NameID" do
      consume(nameid: "")
      expect(response).to have_http_status(:unprocessable_content)
    end

    context "linking (RelayState from POST /saml/link)" do
      def relay_from_link(user_headers)
        post "/api/v1/orgs/#{org.key}/saml/link", headers: user_headers
        expect(response).to have_http_status(:ok)
        Rack::Utils.parse_query(URI(response.parsed_body["redirect_url"]).query)["RelayState"]
      end

      it "binds the asserted NameID to the signed-in member and logs them in" do
        relay = relay_from_link(headers)

        expect { consume(nameid: "owner@idp.example", relay: relay) }.not_to change(User, :count)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["user"]["id"]).to eq(owner.key)
        expect(org.saml_identities.find_by(name_id: "owner@idp.example").user).to eq(owner)

        get "/api/v1/orgs/#{org.key}/saml/identity", headers: headers
        expect(response.parsed_body["saml_identity"]["name_id"]).to eq("owner@idp.example")

        delete "/api/v1/orgs/#{org.key}/saml/identity", headers: headers
        expect(response).to have_http_status(:no_content)
        expect(org.saml_identities.where(user: owner)).not_to exist
      end

      it "refuses to steal an identity already linked to someone else" do
        other = create(:user, username: "other1")
        create(:membership, user: other, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
        org.saml_identities.create!(user: other, name_id: "shared@idp.example")

        consume(nameid: "shared@idp.example", relay: relay_from_link(headers))
        expect(response).to have_http_status(:conflict)
        expect(org.saml_identities.find_by(name_id: "shared@idp.example").user).to eq(other)
      end

      it "ignores a RelayState minted for another org" do
        other_org = create(:organization, owner: owner, domain: "other-saml.com")
        create(:membership, user: owner, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
        other_org.create_saml_config!(saml_params)
        post "/api/v1/orgs/#{other_org.key}/saml/link", headers: headers
        foreign_relay = Rack::Utils.parse_query(URI(response.parsed_body["redirect_url"]).query)["RelayState"]

        consume(nameid: "stranger@idp.example", relay: foreign_relay)
        # No link honoured → ordinary first-seen provisioning, not a binding to the owner.
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["user"]["id"]).not_to eq(owner.key)
        expect(org.saml_identities.find_by(name_id: "stranger@idp.example").user).not_to eq(owner)
      end

      it "forbids linking for a non-member" do
        outsider = create(:user, username: "outsider1")
        post "/api/v1/orgs/#{org.key}/saml/link", headers: auth_headers(outsider)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "browser flow (the IdP's form POST)" do
      # The test env's null cache store never remembers a claim; single-use
      # needs a real store.
      before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

      it "redirects to the web app with a one-time ticket that /auth/saml/exchange turns into a session" do
        stub_response(valid: true, assertion_id: "_browser_1", nameid: "browser@saml.com")
        post "/api/v1/orgs/#{org.key}/saml/consume", params: { SAMLResponse: "x" }
        expect(response).to have_http_status(:found)
        location = URI(response.headers["Location"])
        expect(location.path).to eq("/sso/saml/callback")
        ticket = Rack::Utils.parse_query(location.query)["ticket"]
        expect(ticket).to be_present

        post "/api/v1/auth/saml/exchange", params: { ticket: ticket }, as: :json
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["token"]).to be_present
        expect(response.parsed_body["user"]["id"]).to eq(User.find_by(billing_email: "browser@saml.com").key)

        # Single use.
        post "/api/v1/auth/saml/exchange", params: { ticket: ticket }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects a forged or expired ticket" do
        post "/api/v1/auth/saml/exchange", params: { ticket: "garbage" }, as: :json
        expect(response).to have_http_status(:unauthorized)

        stale = Api::V1::SamlController.verifier.generate({ "user_id" => owner.id, "nonce" => "n" }, purpose: :saml_login, expires_in: 1.second)
        travel 5.seconds do
          post "/api/v1/auth/saml/exchange", params: { ticket: stale }, as: :json
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end
end
