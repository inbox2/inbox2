require "rails_helper"

# Zero-knowledge cloud backup of channel credentials — see docs/E2EE.md.
RSpec.describe "Api::V1::StoredCredentials", type: :request do
  let(:user) { create(:user, username: "vaultuser") }
  let(:headers) { auth_headers(user) }

  def create_cred(u: user, provider: StoredCredential::PROVIDER_GMAIL,
    email: "me@gmail.com", blob: "Y2lwaGVydGV4dA==", nonce: "bm9uY2U=", version: 1)
    u.stored_credentials.create!(
      provider: provider, external_email: email, blob: blob, blob_nonce: nonce, blob_version: version
    )
  end

  describe "GET /api/v1/stored-credentials" do
    it "lists the user's credentials as metadata only (never the blob)" do
      cred = create_cred

      get "/api/v1/stored-credentials", headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["stored_credentials"]
      expect(rows.length).to eq(1)
      row = rows.first
      expect(row["id"]).to eq(cred.key)
      expect(row["id"]).to start_with("scr_")
      expect(row["provider"]).to eq("gmail")
      expect(row["external_email"]).to eq("me@gmail.com")
      # Zero-knowledge: the ciphertext must never appear in the list view.
      expect(row).not_to have_key("blob")
      expect(row).not_to have_key("blob_nonce")
      expect(row).not_to have_key("user_id")
    end

    it "does not list another user's credentials (tenant isolation)" do
      other = create(:user, username: "othervault")
      create_cred(u: other, email: "secret@gmail.com")

      get "/api/v1/stored-credentials", headers: headers

      expect(response.parsed_body["stored_credentials"]).to be_empty
    end

    it "requires authentication" do
      get "/api/v1/stored-credentials"
      expect(response).to have_http_status(:unauthorized)
    end

    it "authenticates with an ink_ API key bearer" do
      create_cred
      key = user.api_keys.create!(name: "device", scopes: ApiKey::SCOPES)

      get "/api/v1/stored-credentials", headers: { "Authorization" => "Bearer #{key.raw_token}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["stored_credentials"].length).to eq(1)
    end
  end

  describe "GET /api/v1/stored-credentials/:id" do
    it "returns the opaque ciphertext for restore" do
      cred = create_cred

      get "/api/v1/stored-credentials/#{cred.key}", headers: headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["stored_credential"]
      expect(row["blob"]).to eq("Y2lwaGVydGV4dA==")
      expect(row["blob_nonce"]).to eq("bm9uY2U=")
      expect(row["blob_version"]).to eq(1)
    end

    it "404s for another user's credential (tenant isolation)" do
      other = create(:user, username: "othervault")
      cred = create_cred(u: other)

      get "/api/v1/stored-credentials/#{cred.key}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PUT /api/v1/stored-credentials" do
    let(:params) do
      {
        provider: StoredCredential::PROVIDER_MICROSOFT,
        external_email: "work@outlook.com",
        blob: "Zmlyc3Q=",
        blob_nonce: "bm9uY2Ux",
        blob_version: 1
      }
    end

    it "creates a credential blob" do
      expect {
        put "/api/v1/stored-credentials", params: params, headers: headers
      }.to change(user.stored_credentials, :count).by(1)

      expect(response).to have_http_status(:created)
      cred = user.stored_credentials.last
      expect(cred.provider).to eq("microsoft")
      expect(cred.blob).to eq("Zmlyc3Q=")
    end

    it "is idempotent on (user, provider, email) — re-upload overwrites (last-writer-wins)" do
      put "/api/v1/stored-credentials", params: params, headers: headers
      expect {
        put "/api/v1/stored-credentials",
          params: params.merge(blob: "c2Vjb25k", blob_version: 2), headers: headers
      }.not_to change(user.stored_credentials, :count)

      expect(response).to have_http_status(:ok)
      cred = user.stored_credentials.last
      expect(cred.blob).to eq("c2Vjb25k")
      expect(cred.blob_version).to eq(2)
    end

    it "rejects an unknown provider" do
      put "/api/v1/stored-credentials", params: params.merge(provider: "bogus"), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.stored_credentials.count).to eq(0)
    end

    it "rejects a write from a read-only API key (scope enforcement)" do
      ro = user.api_keys.create!(name: "ro", scopes: [ApiKey::SCOPE_READ])

      put "/api/v1/stored-credentials", params: params,
        headers: { "Authorization" => "Bearer #{ro.raw_token}" }

      expect(response).to have_http_status(:forbidden)
      expect(user.stored_credentials.count).to eq(0)
    end
  end

  describe "DELETE /api/v1/stored-credentials/:id" do
    it "removes the credential so it isn't restored on a new device" do
      cred = create_cred
      delete "/api/v1/stored-credentials/#{cred.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(StoredCredential.exists?(cred.id)).to be(false)
    end

    it "404s for another user's credential" do
      other = create(:user, username: "othervault")
      cred = create_cred(u: other)
      delete "/api/v1/stored-credentials/#{cred.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "vault metadata" do
    let(:vault_params) do
      {
        device_wrapped_dek: "ZGV2aWNl",
        passphrase_wrapped_dek: "cGFzcw==",
        argon_salt: "c2FsdA==",
        argon_params: { mem_kib: 65536, iterations: 3, parallelism: 1 }
      }
    end

    it "upserts and fetches the wrapped DEK copies (opaque)" do
      put "/api/v1/stored-credentials/vault", params: vault_params, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      get "/api/v1/stored-credentials/vault", headers: headers
      expect(response).to have_http_status(:ok)
      v = response.parsed_body["vault"]
      expect(v["id"]).to start_with("vlt_")
      expect(v["device_wrapped_dek"]).to eq("ZGV2aWNl")
      expect(v["passphrase_wrapped_dek"]).to eq("cGFzcw==")
      expect(v["argon_params"]["iterations"]).to eq(3)
    end

    it "re-wraps on a second PUT without creating a duplicate vault (password rotation)" do
      put "/api/v1/stored-credentials/vault", params: vault_params, headers: headers, as: :json
      expect {
        put "/api/v1/stored-credentials/vault",
          params: vault_params.merge(passphrase_wrapped_dek: "bmV3"), headers: headers, as: :json
      }.not_to change(CredentialVault, :count)

      expect(user.credential_vault.reload.passphrase_wrapped_dek).to eq("bmV3")
    end

    it "404s when no vault exists yet" do
      get "/api/v1/stored-credentials/vault", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "destroy_vault disables backup — drops the vault and all stored credentials" do
      create_cred
      create_cred(provider: StoredCredential::PROVIDER_IMAP, email: "me@imap.test")
      put "/api/v1/stored-credentials/vault", params: vault_params, headers: headers, as: :json

      delete "/api/v1/stored-credentials/vault", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(user.stored_credentials.count).to eq(0)
      expect(user.reload.credential_vault).to be_nil
    end

    it "does not expose another user's vault (tenant isolation)" do
      other = create(:user, username: "othervault")
      other.create_credential_vault!(device_wrapped_dek: "x", passphrase_wrapped_dek: "y", argon_salt: "z")

      get "/api/v1/stored-credentials/vault", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
