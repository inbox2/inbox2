require "rails_helper"

RSpec.describe "Api::V1::Organizations fetch_icon", type: :request do
  let(:owner) { create(:user, username: "iconowner") }
  let(:org) { create(:organization, owner: owner, domain: "iconme.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "POST /api/v1/orgs/:org_id/icon/fetch" do
    context "positive" do
      it "fetches the favicon, stores the key, and exposes the brand URL" do
        result = FaviconFetcher::Result.new(bytes: "PNGDATA", content_type: "image/png", source_url: "https://iconme.com/apple.png")
        allow(FaviconFetcher).to receive(:new).and_return(instance_double(FaviconFetcher, call: result))
        storage = instance_double(S3StorageService, upload: "icons/iconme/favicon.png")
        allow(S3StorageService).to receive(:new).and_return(storage)

        post "/api/v1/orgs/#{org.key}/icon/fetch", headers: headers
        expect(response).to have_http_status(:ok)
        # Serialized icon_url is the public brand endpoint; favicon_url holds the key.
        expect(response.parsed_body["organization"]["icon_url"]).to end_with("/orgs/#{org.key}/brand/icon")
        expect(response.parsed_body["organization"]["icon_source"]).to eq("favicon")
        expect(org.reload.favicon_url).to eq("icons/iconme/favicon.png")
        expect(org.icon_url).to be_nil
      end
    end

    context "negative" do
      it "422s when no icon can be found" do
        allow(FaviconFetcher).to receive(:new).and_return(instance_double(FaviconFetcher, call: nil))
        post "/api/v1/orgs/#{org.key}/icon/fetch", headers: headers
        expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
      end

      it "forbids a plain member" do
        member = create(:user, username: "iconmember")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        post "/api/v1/orgs/#{org.key}/icon/fetch", headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/icon (upload)" do
    let(:png) { Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\n"), "image/png", original_filename: "icon.png") }

    it "stores an uploaded icon that wins over a fetched favicon" do
      org.update!(favicon_url: "icons/iconme/favicon.png")
      storage = instance_double(S3StorageService, upload: "icons/iconme/upload.png")
      allow(S3StorageService).to receive(:new).and_return(storage)

      post "/api/v1/orgs/#{org.key}/icon", params: { file: png }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["organization"]["icon_source"]).to eq("upload")
      expect(org.reload.icon_url).to eq("icons/iconme/upload.png")
      # favicon retained underneath, but the upload takes precedence.
      expect(org.favicon_url).to eq("icons/iconme/favicon.png")
      expect(org.resolved_icon_key).to eq("icons/iconme/upload.png")
    end
  end
end
