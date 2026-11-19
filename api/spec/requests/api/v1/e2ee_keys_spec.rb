require "rails_helper"

# docs/E2EE.md Phase B — key provisioning. Blob-only: the server must never
# return a usable secret key, and sealed grants only ever go to their owner.
RSpec.describe "E2EE key provisioning", type: :request do
  let(:owner) { create(:user, username: "sealowner") }
  let(:org) do
    create(:organization, owner: owner, domain: "sealed-org.test").tap do |o|
      o.update!(plan: create(:plan, e2ee: true))
    end
  end
  let(:domain) { org.default_domain }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner") }
  let(:headers) { auth_headers(owner) }

  let(:member) { create(:user, username: "sealmember") }
  let!(:member_membership) { create(:membership, user: member, organization: org, role: "member") }
  let(:member_headers) { auth_headers(member) }

  def b64(n = 32) = Base64.strict_encode64(SecureRandom.bytes(n))

  describe "user identity key (/api/v1/user-key)" do
    it "404s before upload, then upserts and returns the wrapped blobs to self" do
      get "/api/v1/user-key", headers: headers
      expect(response).to have_http_status(:not_found)

      pub = b64
      put "/api/v1/user-key", headers: headers, params: {
        public_key: pub, encrypted_private_key: b64(72),
        recovery_encrypted_private_key: b64(72),
        kdf_params: { alg: "argon2id13", opslimit: 3 }
      }, as: :json
      expect(response).to have_http_status(:ok)

      get "/api/v1/user-key", headers: headers
      body = response.parsed_body["user_key"]
      expect(body["id"]).to start_with("ukey_")
      expect(body["public_key"]).to eq(pub)
      expect(body["encrypted_private_key"]).to be_present
      expect(body["kdf_params"]).to eq({ "alg" => "argon2id13", "opslimit" => 3 })
    end

    it "re-wraps (same public key) without a flag, but 409s on a silent identity swap" do
      pub = b64
      put "/api/v1/user-key", headers: headers, params: { public_key: pub, encrypted_private_key: b64(72) }
      expect(response).to have_http_status(:ok)

      # Password change: same identity, new wrapping.
      put "/api/v1/user-key", headers: headers, params: { public_key: pub, encrypted_private_key: b64(72) }
      expect(response).to have_http_status(:ok)

      # A different public key is a new identity — must be explicit.
      put "/api/v1/user-key", headers: headers, params: { public_key: b64, encrypted_private_key: b64(72) }
      expect(response).to have_http_status(:conflict)

      # …and explicit is not enough on its own: a stolen session must not be
      # able to swap the identity, so the account password is required too.
      put "/api/v1/user-key", headers: headers,
        params: { public_key: b64, encrypted_private_key: b64(72), replace_identity: true }
      expect(response).to have_http_status(:unauthorized)

      put "/api/v1/user-key", headers: headers,
        params: { public_key: b64, encrypted_private_key: b64(72), replace_identity: true, current_password: "password123" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "recovery re-wrap (current_password check)" do
    it "accepts the account password and refuses any other, leaving the key as it was" do
      pub = b64
      put "/api/v1/user-key", headers: headers, params: { public_key: pub, encrypted_private_key: b64(72) }
      before = owner.reload.user_key.encrypted_private_key

      put "/api/v1/user-key", headers: headers,
        params: { public_key: pub, encrypted_private_key: b64(72), current_password: "not-the-password" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(owner.reload.user_key.encrypted_private_key).to eq(before)

      put "/api/v1/user-key", headers: headers,
        params: { public_key: pub, encrypted_private_key: b64(72), current_password: "password123" }
      expect(response).to have_http_status(:ok)
      expect(owner.reload.user_key.encrypted_private_key).not_to eq(before)
    end
  end

  describe "GET e2ee/my-grants" do
    let(:other_domain) { create(:domain, organization: org, name: "elsewhere.test") }

    def grant(domain, version, membership, retired: false)
      key = DomainKey.create!(domain: domain, version: version, public_key: b64, retired_at: (Time.current if retired))
      DomainKeyGrant.create!(domain_key: key, membership: membership, sealed_secret_key: "sealed-#{version}-#{membership.id}")
    end

    it "returns the caller's grants on current keys, across their domains" do
      grant(domain, 1, member_membership, retired: true)
      current = grant(domain, 2, member_membership)
      grant(domain, 3, owner_membership, retired: true)
      assigned = grant(other_domain, 1, member_membership)

      get "/api/v1/orgs/#{org.key}/e2ee/my-grants", headers: member_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["grants"].map { |g| g["sealed_secret_key"] })
        .to contain_exactly(current.sealed_secret_key, assigned.sealed_secret_key)
    end

    it "does not hand out someone else's grant or another org's" do
      grant(domain, 1, owner_membership)
      get "/api/v1/orgs/#{org.key}/e2ee/my-grants", headers: member_headers
      expect(response.parsed_body["grants"]).to eq([])

      outsider = create(:user, username: "sealoutsider")
      get "/api/v1/orgs/#{org.key}/e2ee/my-grants", headers: auth_headers(outsider)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "domain e2ee provisioning" do
    def upload_identity(u_headers)
      put "/api/v1/user-key", headers: u_headers, params: { public_key: b64, encrypted_private_key: b64(72) }
    end

    def mint!(grants: nil, public_key: b64)
      grants ||= [
        { membership_id: owner_membership.key, sealed_secret_key: b64(80) },
        { membership_id: member_membership.key, sealed_secret_key: b64(80) }
      ]
      post "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee/keys",
        headers: headers, params: { public_key: public_key, grants: grants }, as: :json
    end

    it "shows the directory (public keys only) before any key exists" do
      upload_identity(member_headers)

      get "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee", headers: headers
      e2ee = response.parsed_body["e2ee"]
      expect(e2ee["enabled"]).to be(false)
      expect(e2ee["entitled"]).to be(true)
      expect(e2ee["current_key"]).to be_nil
      expect(e2ee["my_grant"]).to be_nil
      members = e2ee["members"]
      expect(members.map { |m| m["membership_id"] }).to include(owner_membership.key, member_membership.key)
      me = members.find { |m| m["membership_id"] == member_membership.key }
      expect(me["public_key"]).to eq(member.reload.user_key.public_key)
      # Directory exposes public identity material only.
      expect(me).not_to have_key("encrypted_private_key")
      expect(me).not_to have_key("sealed_secret_key")
    end

    it "mints v1 with grants and returns each member only their own grant" do
      mint!
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["domain_key"]["version"]).to eq(1)
      # No secret material in the mint response.
      expect(response.body).not_to include("sealed_secret_key")

      get "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee", headers: member_headers
      e2ee = response.parsed_body["e2ee"]
      expect(e2ee["my_grant"]["key_version"]).to eq(1)
      expect(e2ee["my_grant"]["sealed_secret_key"]).to be_present
      # The other member's sealed grant is nowhere in the payload.
      grants_in_body = response.body.scan(/sealed_secret_key/).length
      expect(grants_in_body).to eq(1)
    end

    it "rejects a mint that does not grant the minter (would brick the domain)" do
      mint!(grants: [{ membership_id: member_membership.key, sealed_secret_key: b64(80) }])
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a mint with a cross-tenant membership" do
      foreign = create(:membership)
      mint!(grants: [
        { membership_id: owner_membership.key, sealed_secret_key: b64(80) },
        { membership_id: foreign.key, sealed_secret_key: b64(80) }
      ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(DomainKey.count).to eq(0)
    end

    it "requires admin to mint" do
      post "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee/keys",
        headers: member_headers,
        params: { public_key: b64, grants: [{ membership_id: member_membership.key, sealed_secret_key: b64(80) }] },
        as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "minting v2 retires v1" do
      mint!
      mint!
      expect(response.parsed_body["domain_key"]["version"]).to eq(2)
      versions = domain.domain_keys.order(:version)
      expect(versions.first.retired_at).to be_present
      expect(versions.last.retired_at).to be_nil
      expect(domain.current_e2ee_key.version).to eq(2)
    end

    it "lets a grant-holder (non-admin) re-grant a member on the current key" do
      mint!
      post "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee/grants",
        headers: member_headers,
        params: { membership_id: owner_membership.key, sealed_secret_key: b64(80) }, as: :json
      expect(response).to have_http_status(:created)
    end

    it "refuses grants from a member without one (cannot know the secret)" do
      mint!(grants: [{ membership_id: owner_membership.key, sealed_secret_key: b64(80) }])
      post "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee/grants",
        headers: member_headers,
        params: { membership_id: member_membership.key, sealed_secret_key: b64(80) }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "enables the switch only after minting; disabling always allowed" do
      put "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee",
        headers: headers, params: { e2ee_enabled: true }
      expect(response).to have_http_status(:unprocessable_content)

      mint!
      put "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee",
        headers: headers, params: { e2ee_enabled: true }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["domain"]["e2ee_enabled"]).to be(true)

      put "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee",
        headers: headers, params: { e2ee_enabled: false }
      expect(response).to have_http_status(:ok)
      expect(domain.reload.e2ee_enabled).to be(false)
    end

    it "404s cross-tenant (E3)" do
      outsider = create(:user, username: "outsider")
      create(:organization, owner: outsider, domain: "other-org.test")
      get "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee", headers: auth_headers(outsider)
      expect(response).to have_http_status(:not_found)
    end

    it "never exposes a usable domain secret anywhere" do
      mint!
      get "/api/v1/orgs/#{org.key}/domains/#{domain.key}/e2ee", headers: headers
      # The only secret-adjacent field is the caller's own SEALED grant blob.
      json = response.parsed_body["e2ee"]
      expect(json["current_key"].keys).to match_array(%w[id version public_key retired_at created_at])
    end
  end
end
