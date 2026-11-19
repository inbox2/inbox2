require "rails_helper"

# Spec F10 endpoints (build guide 7): sources, connect and callback, start,
# progress, resume, cancel, report. The source adapter is a stand-in here;
# each real adapter has its own spec against HTTP fixtures.
RSpec.describe "Disk imports", type: :request do
  include_context "disk import"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:other_h) { auth_headers(other_user) }

  let(:adapter_class) do
    Class.new(Disk::Importer) do
      def self.identify(connection, _tokens)
        connection.account_email = "me@source.test"
        connection.tenant = "source.test"
      end

      def spaces
        [Disk::Importer::Space.new(id: "shared:1", kind: Disk::Import::SPACE_SHARED, name: "Marketing Drive"),
         Disk::Importer::Space.new(id: "member:9", kind: Disk::Import::SPACE_MEMBER, name: "Mo", email: "mo@acme.test"),
         Disk::Importer::Space.new(id: "member:10", kind: Disk::Import::SPACE_MEMBER, name: "Gone", email: "gone@else.test")]
      end
    end
  end

  before do
    allow(Disk::ImportSource).to receive(:adapter).and_return(adapter_class)
    allow(Disk::ImportSource).to receive(:member_index).and_return("mo@acme.test" => member)
  end

  def imports_path(path = "") = disk_path("/imports#{path}")
  def foreign_path(path) = "/api/v1/orgs/#{outsider_org.key}/disk/imports#{path}"

  describe "GET /imports/sources" do
    it "lists the offered sources with this member's connection and the org's spaces for admins" do
      connection_for(owner, "google")
      connection_for(owner, "google", reach: Disk::ImportConnection::REACH_ORG, account_email: "admin@acme.test")
      get imports_path("/sources"), headers: owner_h
      expect(response).to have_http_status(:ok)
      google = response.parsed_body["sources"].find { |s| s["provider"] == "google" }
      expect(google).to include("label" => "Google", "folder_name" => "Google Drive", "connected" => true,
                                "org_available" => true, "org_connected" => true, "org_account" => "admin@acme.test")
      expect(google["spaces"].map { |s| [s["id"], s["member_id"]] })
        .to eq([["personal", nil], ["shared:1", nil], ["member:9", member.key], ["member:10", nil]])
      dropbox = response.parsed_body["sources"].find { |s| s["provider"] == "dropbox" }
      expect(dropbox).to include("connected" => false, "spaces" => nil)
    end

    it "hides a source that is not configured or not offered to this org (gate G7)" do
      ENV.delete("DISK_IMPORT_DROPBOX_CLIENT_SECRET")
      ENV["DISK_IMPORT_MICROSOFT_ORGS"] = "org_someone_else"
      get imports_path("/sources"), headers: member_h
      expect(response.parsed_body["sources"].map { |s| s["provider"] }).to eq(["google"])
      expect(response.parsed_body["sources"].first["org_available"]).to be(false)

      ENV["DISK_IMPORT_MICROSOFT_APPROVED"] = "true"
      get imports_path("/sources"), headers: member_h
      expect(response.parsed_body["sources"].map { |s| s["provider"] }).to eq(%w[google microsoft])
    end

    it "is 404 for another org" do
      get foreign_path("/sources"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /imports/:provider/connect" do
    it "answers a consent URL with the read-only scope and our callback" do
      post imports_path("/google/connect"), headers: member_h
      expect(response).to have_http_status(:ok)
      url = URI(response.parsed_body["authorize_url"])
      query = Rack::Utils.parse_query(url.query)
      expect(url.host).to eq("accounts.google.com")
      expect(query).to include("client_id" => "google-client", "access_type" => "offline", "prompt" => "consent",
                               "redirect_uri" => "http://www.example.com/api/v1/disk/imports/google/callback")
      expect(query["scope"]).to eq("https://www.googleapis.com/auth/drive.readonly email")
    end

    it "asks a Microsoft tenant admin for consent to the application permissions for the org reach" do
      post imports_path("/microsoft/connect"), params: { reach: "org" }, headers: owner_h
      url = URI(response.parsed_body["authorize_url"])
      expect(url.path).to eq("/organizations/v2.0/adminconsent")
      expect(Rack::Utils.parse_query(url.query)).to include("scope" => "https://graph.microsoft.com/.default")
    end

    it "asks Dropbox for offline access with no prompt parameter" do
      post imports_path("/dropbox/connect"), params: { reach: "org" }, headers: owner_h
      query = Rack::Utils.parse_query(URI(response.parsed_body["authorize_url"]).query)
      expect(query).to include("token_access_type" => "offline")
      expect(query).not_to have_key("prompt")
      expect(query["scope"]).to include("team_data.member", "files.content.read")
      expect(query["scope"]).not_to include("write")
    end

    it "refuses the org reach to a member, an unconfigured source, an unknown one and an unoffered one" do
      post imports_path("/google/connect"), params: { reach: "org" }, headers: member_h
      expect(response).to have_http_status(:forbidden)
      post imports_path("/box/connect"), headers: member_h
      expect(response).to have_http_status(:not_found)
      ENV.delete("DISK_IMPORT_DROPBOX_CLIENT_ID")
      post imports_path("/dropbox/connect"), headers: member_h
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["errors"].first["message"]).to include("DISK_IMPORT_DROPBOX_CLIENT_ID")
      ENV["DISK_IMPORT_GOOGLE_ORGS"] = ""
      post imports_path("/google/connect"), headers: member_h
      expect(response).to have_http_status(:forbidden)
    end

    it "is 404 for another org" do
      post foreign_path("/google/connect"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /disk/imports/:provider/callback" do
    def state_for(m, reach = "member", provider: "google")
      Api::V1::Disk::ImportsController.verifier.generate({ "m" => m.key, "o" => org.slug, "r" => reach, "p" => provider,
                                                           "n" => SecureRandom.hex(16) }, expires_in: 15.minutes)
    end

    it "stores the grant encrypted and returns to the import screen" do
      allow(OauthProvider).to receive(:exchange_code)
        .and_return("access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600)
      get "/api/v1/disk/imports/google/callback", params: { state: state_for(member), code: "c" }
      expect(response).to redirect_to(%r{/disk/import\?org=#{org.slug}&source=google&status=connected})
      conn = Disk::ImportConnection.find_by!(membership: member, provider: "google", reach: "member")
      expect(conn).to have_attributes(refresh_token: "rt", account_email: "me@source.test", tenant: "source.test")
      raw = Disk::ImportConnection.connection.select_value("SELECT refresh_token FROM disk_import_connections LIMIT 1")
      expect(raw).not_to eq("rt")
      expect(raw).to include("\"p\":") # Active Record encryption's envelope
      expect(OauthProvider).to have_received(:exchange_code)
        .with("google", "c", "http://www.example.com/api/v1/disk/imports/google/callback",
              scope: Disk::ImportSource.scope("google", "member"), client: hash_including(id: "google-client", secret: "google-secret",
                                                                                           token_url: "https://oauth2.googleapis.com/token"))
    end

    it "records a Microsoft tenant admin's consent" do
      get "/api/v1/disk/imports/microsoft/callback", params: { state: state_for(owner, "org", provider: "microsoft"),
                                                                   tenant: "tid-1", admin_consent: "True" }
      expect(response).to redirect_to(/status=connected/)
      expect(Disk::ImportConnection.find_by!(membership: owner, provider: "microsoft")).to have_attributes(reach: "org", tenant: "tid-1")
    end

    it "sends a forged or refused authorisation back with an error and stores nothing" do
      get "/api/v1/disk/imports/google/callback", params: { state: "forged", code: "c" }
      expect(response).to have_http_status(:redirect)
      get "/api/v1/disk/imports/google/callback", params: { state: state_for(member), error: "access_denied" }
      expect(response).to redirect_to(/status=error/)
      get "/api/v1/disk/imports/google/callback", params: { state: state_for(member, "org"), code: "c" }
      expect(response).to redirect_to(/status=error/)
      expect(Disk::ImportConnection.count).to eq(0)
    end
  end

  describe "callback state (review round two)" do
    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      allow(OauthProvider).to receive(:exchange_code)
        .and_return("access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600)
    end

    def connect_state(provider)
      post imports_path("/#{provider}/connect"), params: { reach: "member" }, headers: member_h, as: :json
      Rack::Utils.parse_query(URI(response.parsed_body["authorize_url"]).query)["state"]
    end

    it "names its provider: a Google state is refused on the Dropbox callback" do
      get "/api/v1/disk/imports/dropbox/callback", params: { state: connect_state("google"), code: "c" }
      expect(response.location).not_to include("connected") # an unverified state names no org: the web root
      expect(Disk::ImportConnection.count).to eq(0)
    end

    it "is good for one callback only" do
      state = connect_state("google")
      get "/api/v1/disk/imports/google/callback", params: { state: state, code: "c" }
      expect(response).to redirect_to(/status=connected/)
      Disk::ImportConnection.delete_all
      get "/api/v1/disk/imports/google/callback", params: { state: state, code: "c2" }
      expect(response).to have_http_status(:redirect)
      expect(response.location).not_to include("connected")
      expect(Disk::ImportConnection.count).to eq(0)
    end
  end

  describe "DELETE /imports/:provider/connection" do
    it "forgets the grant, and 404s when there is none" do
      connection_for(member, "google")
      delete imports_path("/google/connection"), headers: member_h
      expect(response).to have_http_status(:no_content)
      delete imports_path("/google/connection"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /imports" do
    it "starts a personal import into a folder named for the source on C:\\ and queues it" do
      connection_for(member, "google")
      expect do
        post imports_path, params: { provider: "google", spaces: ["personal"] }, headers: member_h, as: :json
      end.to have_enqueued_job(Disk::ImportJob)
      expect(response).to have_http_status(:created)
      body = response.parsed_body["imports"].first
      expect(body).to include("provider" => "google", "space_kind" => "personal", "state" => "queued")
      folder = Disk::Node.find_by!(key: body["target_id"])
      expect(folder).to have_attributes(name: "Google Drive", parent_id: c_root(member).id)
    end

    it "continues an earlier import of the same space in the same folder from its change token" do
      connection_for(member, "google")
      post imports_path, params: { provider: "google", spaces: ["personal"] }, headers: member_h, as: :json
      first = Disk::Import.last
      first.update!(state: "done", cursor: "token-7")
      post imports_path, params: { provider: "google", spaces: ["personal"] }, headers: member_h, as: :json
      second = Disk::Import.last
      expect(second).to have_attributes(target_node_id: first.target_node_id, cursor: "token-7")
    end

    it "makes a share per shared space and lands member spaces in that member's C:\\, listing unmatched people" do
      connection_for(owner, "google", reach: "org")
      post imports_path, params: { provider: "google", spaces: %w[shared:1 member:9 member:10] }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      shared, mine, gone = response.parsed_body["imports"]
      share = Disk::Share.find_by!(key: shared["share_id"])
      expect(share).to have_attributes(name: "Marketing Drive", openness: "assigned")
      expect(Disk::Node.find_by!(key: mine["target_id"]).custodian_membership_id).to eq(member.personal_membership_id)
      expect(mine["owner"]["id"]).to eq(member.key)
      expect(gone).to include("state" => "skipped", "error" => /gone@else.test/)
    end

    it "refuses a sealed target, a source not connected, and org spaces to a member" do
      connection_for(member, "google")
      sealed = make_folder(c_root(member), "Vault").tap { |n| n.update_columns(sealed: true, name: nil, metadata_ciphertext: "x") }
      post imports_path, params: { provider: "google", spaces: ["personal"], target_id: sealed.key }, headers: member_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to include("sealed")

      post imports_path, params: { provider: "dropbox", spaces: ["personal"] }, headers: member_h, as: :json
      expect(response.parsed_body["errors"].first["message"]).to include("Connect Dropbox first")

      post imports_path, params: { provider: "google", spaces: ["shared:1"] }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(Disk::Import.count).to eq(0)
    end

    it "is 404 for another org" do
      post foreign_path(""), params: { provider: "google", spaces: ["personal"] }, headers: member_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "progress, resume, cancel and the report" do
    let(:import) { personal_import(member, "google").tap { |i| i.update!(state: "paused", pause_reason: "quota", error: "Full") } }

    it "GET /imports lists my imports, every import for an admin, and 404s across orgs" do
      import
      get imports_path, headers: member_h
      expect(response.parsed_body["imports"].map { |i| i["id"] }).to eq([import.key])
      get imports_path, headers: other_h
      expect(response.parsed_body["imports"]).to eq([])
      get imports_path, headers: owner_h
      expect(response.parsed_body["imports"].size).to eq(1)
      get foreign_path(""), headers: member_h
      expect(response).to have_http_status(:not_found)
    end

    it "GET /imports/:id shows progress to its starter, not to another member, and 404s across orgs" do
      get imports_path("/#{import.key}"), headers: member_h
      expect(response.parsed_body["import"]).to include("state" => "paused", "pause_reason" => "quota", "resumable" => true)
      get imports_path("/#{import.key}"), headers: other_h
      expect(response).to have_http_status(:not_found)
      get foreign_path("/#{import.key}"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end

    it "POST /imports/:id/resume queues a paused import, refuses a running one, 404s across orgs" do
      expect { post imports_path("/#{import.key}/resume"), headers: member_h }.to have_enqueued_job(Disk::ImportJob).with(import.id)
      expect(import.reload).to have_attributes(state: "queued", pause_reason: nil, error: nil)
      import.update!(state: "running")
      post imports_path("/#{import.key}/resume"), headers: member_h
      expect(response).to have_http_status(:conflict)
      post foreign_path("/#{import.key}/resume"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end

    it "DELETE /imports/:id cancels, refuses a finished import, 404s across orgs" do
      delete imports_path("/#{import.key}"), headers: member_h
      expect(response.parsed_body["import"]["state"]).to eq("cancelled")
      import.update!(state: "done")
      delete imports_path("/#{import.key}"), headers: member_h
      expect(response).to have_http_status(:conflict)
      delete foreign_path("/#{import.key}"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end

    it "GET /imports/:id/report lists notable items and people, downloads, and 404s for others" do
      import.update!(report: { "unmatched_people" => { "guest@else.test" => 2 } })
      base = { organization_id: org.id, import: import, provider: "google", target_node_id: import.target_node_id }
      Disk::ImportItem.create!(base.merge(source_id: "1", name: "ok.txt", status: "done"))
      Disk::ImportItem.create!(base.merge(source_id: "2", name: "Notebook", status: "skipped", reason: "OneNote"))
      Disk::ImportItem.create!(base.merge(source_id: "3", name: "Sheet", status: "done",
                                          detail: { "converted" => true, "format" => "xlsx", "hash_verified" => false }))
      get imports_path("/#{import.key}/report?download=1"), headers: member_h
      expect(response.headers["Content-Disposition"]).to include("attachment", "import-report-#{import.key}.json")
      report = response.parsed_body["report"]
      expect(report["unmatched_people"]).to eq([{ "email" => "guest@else.test", "items" => 2 }])
      expect(report["entries"].map { |e| [e["name"], e["status"], e["converted"]] })
        .to eq([["Notebook", "skipped", false], ["Sheet", "done", true]])
      get imports_path("/#{import.key}/report"), headers: other_h
      expect(response).to have_http_status(:not_found)
      get foreign_path("/#{import.key}/report"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end
end
