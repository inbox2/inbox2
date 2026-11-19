require "rails_helper"

RSpec.describe "Api::V1::Organizations upload_logo", type: :request do
  let(:owner) { create(:user, username: "logoowner") }
  let(:org) { create(:organization, owner: owner, domain: "logome.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # Full 8-byte PNG signature — uploads are validated by magic bytes, not the
  # client-supplied Content-Type.
  let(:image) { Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\n"), "image/png", original_filename: "logo.png") }

  def stub_storage!
    storage = instance_double(S3StorageService, upload: "logos/logome/logo.png")
    allow(storage).to receive(:download_with_type).and_return(["PNGBYTES", "image/png"])
    allow(S3StorageService).to receive(:new).and_return(storage)
  end

  describe "POST /api/v1/orgs/:org_id/logo" do
    context "positive" do
      it "stores the object key and exposes the brand URL" do
        stub_storage!
        post "/api/v1/orgs/#{org.key}/logo", params: { file: image }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["organization"]["logo_url"]).to end_with("/orgs/#{org.key}/brand/logo")
        expect(org.reload.logo_url).to eq("logos/logome/logo.png")
      end
    end

    context "brand stream (public)" do
      it "streams the stored logo bytes without auth" do
        stub_storage!
        post "/api/v1/orgs/#{org.key}/logo", params: { file: image }, headers: headers

        get "/api/v1/orgs/#{org.key}/brand/logo"
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to start_with("image/png")
        expect(response.body).to eq("PNGBYTES")
      end

      it "404s when no logo is set" do
        get "/api/v1/orgs/#{org.key}/brand/logo"
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative" do
      it "422s when no file is provided" do
        post "/api/v1/orgs/#{org.key}/logo", headers: headers
        expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
      end

      it "422s when the file is not an image" do
        text = Rack::Test::UploadedFile.new(StringIO.new("nope"), "text/plain", original_filename: "logo.txt")
        post "/api/v1/orgs/#{org.key}/logo", params: { file: text }, headers: headers
        expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
      end

      it "forbids a plain member" do
        member = create(:user, username: "logomember")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        post "/api/v1/orgs/#{org.key}/logo", params: { file: image }, headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
