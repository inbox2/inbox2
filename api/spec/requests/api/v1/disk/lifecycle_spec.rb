require "rails_helper"

# The downgrade lifecycle and quota warnings (spec F8), and SaaS ops (spec F11).
RSpec.describe "Disk lifecycle", type: :request do
  include_context "disk import" # the "disk org" context plus import helpers

  let(:owner_h) { auth_headers(owner_user) }
  let(:share) { make_share("Marketing", openness: Disk::Share::OPENNESS_ORG, org_role: Disk::ROLE_EDIT) }
  let!(:file) { make_stored_file(share.root_node, "a.pdf", size: 5) }

  def downgrade!(days_ago = 0)
    org.subscription.update!(plan: Plan.free)
    org.update!(disk_lost_at: days_ago.days.ago) if days_ago.positive?
  end

  describe "read-only month" do
    before { downgrade! }

    it "marks the loss once, tells the owners, and keeps reads, downloads, deletes and export working" do
      expect { get disk_path, headers: owner_h }.to change(Notification.where(kind: "disk_plan"), :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["settings"]).to include("state" => "read_only")
      expect(org.reload.disk_lost_at).to be_within(1.minute).of(Time.current)

      get disk_path("/nodes/#{share.root_node.key}/children"), headers: owner_h
      expect(response).to have_http_status(:ok)
      get disk_path("/nodes/#{file.key}/download"), headers: owner_h
      expect(response).to have_http_status(:ok)
      get disk_path("/admin/export"), headers: owner_h
      expect(response).to have_http_status(:ok)
      delete disk_path("/nodes/#{file.key}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      expect(Notification.where(kind: "disk_plan").count).to eq(1)
    end

    it "refuses uploads, folders, pages, edits, shares and new links with the read-only error" do
      [[:post, "/uploads", { parent_id: share.root_node.key, name: "b", size_bytes: 1 }],
       [:post, "/nodes", { parent_id: share.root_node.key, name: "F" }],
       [:patch, "/nodes/#{file.key}", { name: "b.pdf" }],
       [:put, "/nodes/#{file.key}/grants/#{member.key}", { role: "view" }],
       [:post, "/nodes/#{file.key}/links", {}]].each do |verb, p, body|
        send(verb, disk_path(p), params: body, headers: owner_h, as: :json)
        expect(response).to have_http_status(:forbidden), "#{verb} #{p}"
        expect(response.parsed_body["code"]).to eq("disk_read_only")
      end
    end

    it "keeps public links resolving" do
      _, token = Disk::NodeOps.new(owner).create_link(file)
      get "/api/v1/disk/links/#{token}"
      expect(response).to have_http_status(:ok)
    end
  end

  it "blocks everything from day 31, links included" do
    _, token = Disk::NodeOps.new(owner).create_link(file)
    downgrade!(31)
    get disk_path, headers: owner_h
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["errors"].first["message"]).to match(/not included/)
    get "/api/v1/disk/links/#{token}"
    expect(response).to have_http_status(:not_found)
  end

  it "restores everything on upgrade before day 90" do
    downgrade!(60)
    org.subscription.update!(plan: Plan.paid)
    get disk_path("/nodes/#{share.root_node.key}/children"), headers: owner_h
    expect(response.parsed_body["nodes"].pluck("name")).to eq(["a.pdf"])
    expect(org.reload.disk_lost_at).to be_nil
  end

  describe Disk::LifecycleJob do
    it "warns owners on days 23 and 83 and purges from day 90" do
      downgrade!(23)
      expect { described_class.perform_now }.to change(Notification.where(kind: "disk_plan"), :count).by(1)
      org.update!(disk_lost_at: 83.days.ago)
      expect { described_class.perform_now }.to change(Notification.where(kind: "disk_plan"), :count).by(1)
      org.update!(disk_lost_at: 50.days.ago)
      expect { described_class.perform_now }.not_to change(Notification, :count)

      key = file.current_version.storage_key
      org.update!(disk_lost_at: 91.days.ago)
      described_class.perform_now
      expect(Disk::Node.where(organization_id: org.id)).to be_empty
      expect(Disk::Share.where(organization_id: org.id)).to be_empty
      expect(storage.deleted).to include(key)
      expect(org.reload).to have_attributes(disk_lost_at: nil, disk_bytes_used: 0)
      delete "/api/v1/orgs/#{org.key}/members/#{member.key}", headers: owner_h
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "quota warnings" do
    it "tells owners and admins once at 80 and once at 100 percent, again after dropping under 80" do
      org.update!(disk_quota_override_gb: 1)
      notes = -> { Notification.where(kind: "disk_quota").count }
      admins = org.memberships.where(role: Membership::ADMIN_ROLES).count
      expect { make_stored_file(share.root_node, "big", size: 850.megabytes) }.to change(notes, :call).by(admins)
      expect(org.reload.disk_quota_notified_level).to eq(80)
      expect { make_stored_file(share.root_node, "more", size: 10.megabytes) }.not_to change(notes, :call)
      expect { make_stored_file(share.root_node, "full", size: 200.megabytes) }.to change(notes, :call).by(admins)
      Disk::Quota.move!(org.id, used: -900.megabytes)
      expect(org.reload.disk_quota_notified_level).to eq(0)
      expect { Disk::Quota.move!(org.id, used: 800.megabytes) }.to change(notes, :call).by(admins)
    end

    it "shrinks the pool when a member leaves" do
      before = Disk::Quota.new(org).pool_bytes
      other.destroy!
      expect(Disk::Quota.new(org.reload).pool_bytes).to eq(before - Plan.paid.disk_gb_per_member.gigabytes)
    end
  end

  describe "SaaS ops", :saas do
    let(:headers) { saas_headers(create(:admin_credential)) }

    it "shows Disk usage and overrides the quota, with an audit row" do
      get "/api/v1/saas/organizations/#{org.key}/usage", headers: headers
      expect(response.parsed_body["usage"]["disk"]).to include("used_bytes" => 5, "enabled" => true)

      post "/api/v1/saas/organizations/#{org.key}/disk_quota", params: { quota_gb: 500 }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["usage"]["disk"]).to include("quota_bytes" => 500.gigabytes, "quota_override_gb" => 500)
      get disk_path, headers: owner_h
      expect(response.parsed_body["quota"]["pool_bytes"]).to eq(500.gigabytes)
      expect(SaasAuditLog.last.action).to eq("org.disk_quota")

      post "/api/v1/saas/organizations/#{org.key}/disk_quota", params: { quota_gb: "lots" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/saas/organizations/#{org.key}/disk_quota", params: { quota_gb: nil }, headers: headers, as: :json
      expect(org.reload.disk_quota_override_gb).to be_nil
      post "/api/v1/saas/organizations/org_missing/disk_quota", params: { quota_gb: 1 }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "puts Disk on the ops dashboard" do
      Disk::Recent.touch!(owner, file)
      Disk::Event.record!(Disk::Event::ACTION_PREVIEW_FAILED, actor: owner, node: file, renderer: "pdfium", mime: "application/pdf")
      Disk::NodeOps.new(owner).create_link(file)
      personal_import(member, "google")
      get "/api/v1/saas/dashboard", headers: headers
      disk = response.parsed_body["metrics"]["disk"]
      expect(disk).to include("bytes_stored" => org.reload.disk_bytes_used, "links_created_7d" => 1)
      expect(disk["previews_7d"]).to include("mime" => "application/pdf", "opens" => 1, "failures" => 1)
      expect(disk["imports_7d"]).to eq("running" => 1)
    end
  end
end
