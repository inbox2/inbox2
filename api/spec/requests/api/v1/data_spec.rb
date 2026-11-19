require "rails_helper"

# spec 11.2.1/A15.4 (IMAP import), 11.3.3/A15.6 (export), 11.3.5/A15.7 (GDPR)
RSpec.describe "Api::V1::Data", type: :request do
  let(:owner) { create(:user, username: "dataowner") }
  let(:org) { create(:organization, owner: owner, domain: "data.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  let(:member) { create(:user, username: "datamember") }
  let!(:member_membership) { create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }
  let(:member_headers) { auth_headers(member) }

  describe "POST /api/v1/orgs/:org_id/export" do
    include ActiveJob::TestHelper

    context "positive" do
      it "queues an export and returns it with 202 (admin)" do
        expect {
          post "/api/v1/orgs/#{org.key}/export", headers: headers
        }.to have_enqueued_job(DataExportJob)
        expect(response).to have_http_status(:accepted)
        body = response.parsed_body["data_export"]
        expect(body["id"]).to start_with("dex_")
        expect(body["status"]).to eq(DataExport::STATUS_QUEUED)
        expect(DataExport.find_by!(key: body["id"]).requested_by).to eq(membership)
      end

      it "returns the export already in flight instead of queueing a second" do
        running = org.data_exports.create!(status: DataExport::STATUS_RUNNING)

        expect {
          post "/api/v1/orgs/#{org.key}/export", headers: headers
        }.not_to have_enqueued_job(DataExportJob)
        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body.dig("data_export", "id")).to eq(running.key)
        expect(org.data_exports.count).to eq(1)
      end

      it "starts a fresh export when the one in flight has stalled" do
        stuck = org.data_exports.create!(status: DataExport::STATUS_RUNNING)
        stuck.update_columns(updated_at: 7.hours.ago)

        post "/api/v1/orgs/#{org.key}/export", headers: headers
        expect(response.parsed_body.dig("data_export", "id")).not_to eq(stuck.key)
        expect(stuck.reload.status).to eq(DataExport::STATUS_FAILED)
      end
    end

    context "negative" do
      it "forbids regular members" do
        post "/api/v1/orgs/#{org.key}/export", headers: member_headers
        expect(response).to have_http_status(:forbidden)
        expect(org.data_exports.count).to eq(0)
      end

      it "requires authentication" do
        post "/api/v1/orgs/#{org.key}/export"
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 404 for another organisation" do
        other = create(:organization)
        post "/api/v1/orgs/#{other.key}/export", headers: headers
        expect(response).to have_http_status(:not_found)
        expect(other.data_exports.count).to eq(0)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/exports" do
    context "positive" do
      it "lists the org's exports, latest first" do
        older = org.data_exports.create!(status: DataExport::STATUS_FAILED, error: "boom", created_at: 2.days.ago)
        newer = org.data_exports.create!(status: DataExport::STATUS_READY, byte_size: 42, expires_at: 7.days.from_now)
        create(:organization).data_exports.create!

        get "/api/v1/orgs/#{org.key}/exports", headers: headers
        expect(response).to have_http_status(:ok)
        rows = response.parsed_body["data_exports"]
        expect(rows.map { |r| r["id"] }).to eq([newer.key, older.key])
        expect(rows.first).to include("status" => "ready", "byte_size" => 42)
        expect(rows.first).not_to have_key("storage_key")
      end
    end

    context "negative" do
      it "forbids regular members" do
        get "/api/v1/orgs/#{org.key}/exports", headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/exports/:id/download" do
    let(:storage) { instance_double(S3StorageService) }

    before { allow(S3StorageService).to receive(:new).and_return(storage) }

    context "positive" do
      it "streams the zip when ready" do
        export = org.data_exports.create!(status: DataExport::STATUS_READY, storage_key: "k/x.zip", byte_size: 10,
                                          expires_at: 7.days.from_now)
        allow(storage).to receive(:stream).with("k/x.zip").and_yield("PK\x03\x04").and_yield("rest!!")

        get "/api/v1/orgs/#{org.key}/exports/#{export.key}/download", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/zip")
        expect(response.headers["Content-Disposition"]).to include("attachment", ".zip")
        expect(response.body).to eq("PK\x03\x04rest!!")
      end
    end

    context "negative" do
      it "returns 409 while the export is still being built" do
        export = org.data_exports.create!(status: DataExport::STATUS_RUNNING)
        get "/api/v1/orgs/#{org.key}/exports/#{export.key}/download", headers: headers
        expect(response).to have_http_status(:conflict)
      end

      it "returns 410 once expired, even before the sweep runs" do
        export = org.data_exports.create!(status: DataExport::STATUS_READY, storage_key: "k/x.zip", expires_at: 1.minute.ago)
        get "/api/v1/orgs/#{org.key}/exports/#{export.key}/download", headers: headers
        expect(response).to have_http_status(:gone)

        export.update!(status: DataExport::STATUS_EXPIRED, storage_key: nil)
        get "/api/v1/orgs/#{org.key}/exports/#{export.key}/download", headers: headers
        expect(response).to have_http_status(:gone)
      end

      it "forbids regular members" do
        export = org.data_exports.create!(status: DataExport::STATUS_READY, storage_key: "k/x.zip", expires_at: 7.days.from_now)
        get "/api/v1/orgs/#{org.key}/exports/#{export.key}/download", headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end

      it "returns 404 for another organisation's export" do
        other = create(:organization)
        export = other.data_exports.create!(status: DataExport::STATUS_READY, storage_key: "k/x.zip", expires_at: 7.days.from_now)
        get "/api/v1/orgs/#{org.key}/exports/#{export.key}/download", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/gdpr/contact-request (export)" do
    context "positive" do
      it "returns the data footprint for a contact email (admin)" do
        conv = create(:conversation, organization: org, from_address: "subject@x.com")
        create(:message, conversation: conv, organization: org, from_address: "subject@x.com")

        post "/api/v1/orgs/#{org.key}/gdpr/contact-request",
             params: { email: "subject@x.com" }, headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["email"]).to eq("subject@x.com")
        expect(body["status"]).to eq("export_ready")
        expect(body["messages_count"]).to eq(1)
      end
    end

    context "negative" do
      it "returns 422 when email is missing" do
        post "/api/v1/orgs/#{org.key}/gdpr/contact-request", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "forbids regular members" do
        post "/api/v1/orgs/#{org.key}/gdpr/contact-request",
             params: { email: "subject@x.com" }, headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/gdpr/contact-request (delete)" do
    context "positive" do
      it "redacts personal data for the contact (admin)" do
        conv = create(:conversation, organization: org, from_address: "erase@x.com")
        msg = create(:message, conversation: conv, organization: org, from_address: "erase@x.com", body_plain: "secret")

        delete "/api/v1/orgs/#{org.key}/gdpr/contact-request",
               params: { email: "erase@x.com" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("deleted")

        msg.reload
        expect(msg.from_address).to eq("[redacted]")
        expect(msg.body_plain).to eq("[content deleted per GDPR request]")
      end
    end

    context "negative" do
      it "returns 422 when email is missing" do
        delete "/api/v1/orgs/#{org.key}/gdpr/contact-request", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "forbids regular members" do
        delete "/api/v1/orgs/#{org.key}/gdpr/contact-request",
               params: { email: "erase@x.com" }, headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/import/imap/test" do
    context "positive" do
      it "returns the connection test result (admin)" do
        service = instance_double(ImapImportService, test_connection: { ok: true, message_count: 42 })
        allow(ImapImportService).to receive(:new).and_return(service)

        post "/api/v1/orgs/#{org.key}/import/imap/test",
             params: { host: "imap.x.com", username: "u", password: "p" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["ok"]).to be true
      end
    end

    context "negative" do
      it "forbids regular members" do
        post "/api/v1/orgs/#{org.key}/import/imap/test",
             params: { host: "imap.x.com" }, headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/import/imap" do
    context "positive" do
      it "enqueues the import job and returns 202 (admin)" do
        expect(ImapImportJob).to receive(:perform_later)
          .with(org.id, hash_including(host: "imap.x.com"))

        post "/api/v1/orgs/#{org.key}/import/imap",
             params: { host: "imap.x.com", username: "u", password: "p" }, headers: headers
        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body["status"]).to eq("processing")
      end
    end

    context "negative" do
      it "forbids regular members" do
        post "/api/v1/orgs/#{org.key}/import/imap",
             params: { host: "imap.x.com" }, headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
