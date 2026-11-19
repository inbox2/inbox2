require "rails_helper"

# Small additions for the web client: copy with replace, has_thumbnail in
# listings, and preview failure reports (spec F2, F5).
RSpec.describe "Disk web extras", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:root) { make_share("Marketing", openness: Disk::Share::OPENNESS_ORG, org_role: Disk::ROLE_VIEW).root_node }
  let(:a) { make_folder(root, "A") }
  let(:b) { make_folder(root, "B") }

  describe "POST /nodes/:id/copy with on_conflict=replace" do
    it "adds the copy as a new version of the same-named file and counts it" do
      source = make_stored_file(a, "deck.pdf", size: 7)
      existing = make_stored_file(b, "Deck.pdf", size: 3)
      used = org.reload.disk_bytes_used
      post disk_path("/nodes/#{source.key}/copy"), params: { target_id: b.key, on_conflict: "replace" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["node"]).to include("id" => existing.key, "size_bytes" => 7)
      expect(existing.reload.versions.count).to eq(2)
      expect(b.children.live.count).to eq(1)
      expect(org.reload.disk_bytes_used).to eq(used + 7)
    end

    it "refuses when a folder holds the name, and over quota" do
      source = make_stored_file(a, "x", size: 5)
      make_folder(b, "x")
      post disk_path("/nodes/#{source.key}/copy"), params: { target_id: b.key, on_conflict: "replace" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:conflict)

      c = make_folder(root, "C")
      make_stored_file(c, "x", size: 1)
      org.update!(disk_quota_override_gb: 0)
      post disk_path("/nodes/#{source.key}/copy"), params: { target_id: c.key, on_conflict: "replace" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["code"]).to eq("disk_quota_exceeded")
    end

    it "is not found across tenants" do
      source = make_stored_file(a, "deck.pdf", size: 7)
      post disk_path("/nodes/#{source.key}/copy"), params: { target_id: foreign_node.key, on_conflict: "replace" },
                                                   headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "has_thumbnail" do
    it "is in listings and follows the current version" do
      with = make_stored_file(a, "with.png", size: 1, mime: "image/png")
      with.current_version.update!(thumbnail_storage_key: "#{with.current_version.storage_key}.thumbnail")
      make_stored_file(a, "without.png", size: 1, mime: "image/png")
      make_folder(a, "Sub")
      get disk_path("/nodes/#{a.key}/children"), headers: owner_h
      flags = response.parsed_body["nodes"].to_h { |n| [n["name"], n["has_thumbnail"]] }
      expect(flags).to eq("Sub" => false, "with.png" => true, "without.png" => false)
    end

    it "costs no query per row" do
      3.times { |i| make_stored_file(a, "f#{i}.png", size: 1, mime: "image/png") }
      get disk_path("/nodes/#{a.key}/children"), headers: owner_h
      queries = 0
      counter = ->(*, payload) { queries += 1 if payload[:sql].include?("disk_versions") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get disk_path("/nodes/#{a.key}/children"), headers: owner_h
      end
      expect(queries).to eq(1)
    end
  end

  describe "POST /nodes/:id/preview-failures" do
    let(:file) { make_stored_file(a, "broken.pdf", size: 1) }

    it "records a failure with its type, kept out of the activity feed" do
      post disk_path("/nodes/#{file.key}/preview-failures"), params: { renderer: "pdfium", reason: "corrupt" },
                                                             headers: auth_headers(member_user), as: :json
      expect(response).to have_http_status(:no_content)
      event = Disk::Event.find_by!(node: file, action: "preview_failed")
      expect(event.detail).to eq("renderer" => "pdfium", "reason" => "corrupt", "mime" => "application/pdf")
      get disk_path("/nodes/#{file.key}/events"), headers: owner_h
      expect(response.parsed_body["events"].pluck("action")).not_to include("preview_failed")
    end

    it "keeps only the renderer for a sealed file and refuses free text" do
      file = make_sealed_file(make_sealed_share.root_node)
      post disk_path("/nodes/#{file.key}/preview-failures"), params: { renderer: "pdfium", reason: "secret-plan" },
                                                             headers: owner_h, as: :json
      expect(Disk::Event.find_by!(node: file, action: "preview_failed").detail).to eq("renderer" => "pdfium")
      post disk_path("/nodes/#{file.key}/preview-failures"), params: { renderer: "my file.pdf" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is not found across tenants and rate limited per caller" do
      post disk_path("/nodes/#{foreign_node.key}/preview-failures"), params: { renderer: "pdfium" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)

      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      statuses = Array.new(31) do
        post disk_path("/nodes/#{file.key}/preview-failures"), params: { renderer: "pdfium" }, headers: owner_h, as: :json
        response.status
      end
      expect(statuses.last).to eq(429)
    ensure
      Rack::Attack.cache.store = Rails.cache
    end
  end
end
