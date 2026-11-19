require "rails_helper"

# spec 4.1.4 / A7.2 (download) and 8.1.3 / A7.3 (upload)
RSpec.describe "Api::V1::Attachments", type: :request do
  let(:owner) { create(:user, username: "attowner") }
  let(:org) { create(:organization, owner: owner, domain: "att.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }
  let(:conversation) { create(:conversation, organization: org) }
  let(:message) { create(:message, conversation: conversation, organization: org) }
  let(:storage) { instance_double(S3StorageService) }

  before { allow(S3StorageService).to receive(:new).and_return(storage) }

  def build_attachment(storage_key: "orgs/#{org.key}/file.txt")
    Attachment.create!(
      organization: org,
      message: message,
      filename: "report.txt",
      content_type: "text/plain",
      size_bytes: 12,
      storage_key: storage_key
    )
  end

  describe "GET /api/v1/orgs/:org_id/attachments/:id" do
    context "positive" do
      # Streams the bytes rather than redirecting to a presigned S3 URL: the web
      # app is a different origin from the API and the desktop runs on
      # tauri://localhost, so a cross-origin fetch of the S3 URL needs bucket CORS
      # that Garage doesn't have — every download died at the redirect.
      it "streams the bytes when content is available" do
        attachment = build_attachment
        allow(storage).to receive(:download_with_type).with("orgs/#{org.key}/file.txt")
                                                      .and_return(["hello world\n", "text/plain"])

        get "/api/v1/orgs/#{org.key}/attachments/#{attachment.key}", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.body).to eq("hello world\n")
        expect(response.media_type).to eq("text/plain")
        expect(response.headers["Content-Disposition"]).to include('filename="report.txt"')
      end

      # Storage being down is not a missing file: the client has to be able to tell
      # "retry later" from "this is gone", and a 500 says neither.
      it "returns 503 when object storage is unreachable" do
        attachment = build_attachment
        allow(storage).to receive(:download_with_type)
          .and_raise(Seahorse::Client::NetworkingError.new(StandardError.new("refused")))

        get "/api/v1/orgs/#{org.key}/attachments/#{attachment.key}", headers: headers
        expect(response).to have_http_status(:service_unavailable)
      end

      # A sealed attachment's row is written before the MX finishes spooling its
      # ciphertext, so "row exists, object doesn't" is a normal transient state and
      # must read as 404, not 500.
      it "returns 404 when the object is not in storage yet" do
        attachment = build_attachment
        allow(storage).to receive(:download_with_type)
          .and_raise(Aws::S3::Errors::NoSuchKey.new(nil, "missing"))

        get "/api/v1/orgs/#{org.key}/attachments/#{attachment.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative" do
      it "returns 404 for an unknown attachment key" do
        get "/api/v1/orgs/#{org.key}/attachments/att_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 when the attachment has no stored content" do
        attachment = build_attachment(storage_key: nil)
        get "/api/v1/orgs/#{org.key}/attachments/#{attachment.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for an attachment on a colleague's private imported thread" do
        mate = create(:user, username: "attmate")
        mate_m = create(:membership, user: mate, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
        hidden = create(:conversation, organization: org, private: true, owner_membership_id: mate_m.id)
        secret_msg = create(:message, conversation: hidden, organization: org)
        attachment = Attachment.create!(organization: org, message: secret_msg, filename: "payslip.pdf",
                                        content_type: "application/pdf", size_bytes: 3, storage_key: "orgs/x/p.pdf")

        get "/api/v1/orgs/#{org.key}/attachments/#{attachment.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for an attachment in another organization (E3 tenant isolation)" do
        attachment = build_attachment
        other = create(:user, username: "attother")
        other_org = create(:organization, owner: other, domain: "other.com")
        create(:membership, user: other, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)

        get "/api/v1/orgs/#{other_org.key}/attachments/#{attachment.key}", headers: auth_headers(other)
        expect(response).to have_http_status(:not_found)
      end

      it "requires authentication" do
        attachment = build_attachment
        get "/api/v1/orgs/#{org.key}/attachments/#{attachment.key}"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/attachments" do
    let(:upload) { Rack::Test::UploadedFile.new(StringIO.new("hello world\n"), "text/plain", original_filename: "note.txt") }

    before do
      allow(storage).to receive(:upload).and_return("orgs/#{org.key}/uploaded.txt")
    end

    context "positive" do
      it "uploads a file and creates an attachment scoped to the organization" do
        expect {
          post "/api/v1/orgs/#{org.key}/attachments",
               params: { file: upload, message_id: message.key },
               headers: headers
        }.to change(org.attachments, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body["attachment"]
        expect(body["id"]).to start_with("att_")
        expect(body["filename"]).to eq("note.txt")
        expect(body["has_content"]).to be true
      end
    end

    context "negative" do
      it "returns 422 when no file is provided" do
        post "/api/v1/orgs/#{org.key}/attachments",
             params: { message_id: message.key }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 422 when message_id is missing" do
        post "/api/v1/orgs/#{org.key}/attachments",
             params: { file: upload }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 404 when message_id belongs to another organization" do
        other = create(:user, username: "attother2")
        other_org = create(:organization, owner: other, domain: "other2.com")
        other_conv = create(:conversation, organization: other_org)
        other_msg = create(:message, conversation: other_conv, organization: other_org)

        post "/api/v1/orgs/#{org.key}/attachments",
             params: { file: upload, message_id: other_msg.key }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/attachments/:id" do
    let(:draft) { create(:message, conversation: conversation, organization: org, is_draft: true, owner_membership_id: membership.id) }

    def attach_to(msg, storage_key: "orgs/#{org.key}/draft.txt")
      Attachment.create!(organization: org, message: msg, filename: "draft.txt", content_type: "text/plain",
                         size_bytes: 3, storage_key: storage_key)
    end

    before { allow(storage).to receive(:delete) }

    it "removes the file from the caller's own draft and its stored object" do
      att = attach_to(draft)
      delete "/api/v1/orgs/#{org.key}/attachments/#{att.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Attachment.exists?(att.id)).to be(false)
      expect(storage).to have_received(:delete).with("orgs/#{org.key}/draft.txt")
    end

    it "still succeeds when storage is down" do
      allow(storage).to receive(:delete).and_raise(Seahorse::Client::NetworkingError.new(StandardError.new("down")))
      att = attach_to(draft)
      delete "/api/v1/orgs/#{org.key}/attachments/#{att.key}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for a file on sent mail" do
      att = attach_to(message)
      delete "/api/v1/orgs/#{org.key}/attachments/#{att.key}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(Attachment.exists?(att.id)).to be(true)
    end

    it "returns 404 for a file on a colleague's draft" do
      colleague = create(:membership, user: create(:user), organization: org, status: "active")
      att = attach_to(create(:message, conversation: conversation, organization: org, is_draft: true, owner_membership_id: colleague.id))
      delete "/api/v1/orgs/#{org.key}/attachments/#{att.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 across tenants" do
      att = attach_to(draft)
      other = create(:user, username: "attoutsider")
      other_org = create(:organization, owner: other, domain: "elsewhere.com")
      create(:membership, user: other, organization: other_org, role: Membership::ROLE_OWNER, status: "active")
      delete "/api/v1/orgs/#{other_org.key}/attachments/#{att.key}", headers: auth_headers(other)
      expect(response).to have_http_status(:not_found)
      expect(Attachment.exists?(att.id)).to be(true)
    end
  end
end
