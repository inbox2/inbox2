require "rails_helper"

# Spec F4: "A person is told when something is shared with them."
RSpec.describe "Disk share notifications", type: :request do
  include_context "disk org"
  include ActiveJob::TestHelper

  let(:folder) { make_folder(c_root(member), "Contracts") }
  let(:share) { make_share("Marketing") }

  def sent_mail = enqueued_jobs.select { |j| j["job_class"] == "MessyTriggerJob" }.map { |j| j["arguments"].last }

  it "notifies in-app and by email with a working link when a folder is shared with someone" do
    put disk_path("/nodes/#{folder.key}/grants/#{other.key}"), params: { role: "edit" },
                                                                headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:ok)

    get "/api/v1/notifications", headers: auth_headers(other_user)
    n = response.parsed_body["notifications"].first
    expect(n).to include("kind" => "disk_shared", "title" => "Mo Member shared “Contracts” with you",
                         "body" => "You can edit it in Disk.", "url" => "/disk/shared/Contracts-#{folder.short_id}")

    mail = sent_mail.sole
    expect(mail).to include("to" => other_user.billing_email, "subject" => n["title"])
    # The grantee cannot see the owner's C:\ above the folder, so the path starts at what was shared.
    expect(mail["body"]).to include("https://app.inbox2.com/disk/shared/Contracts-#{folder.short_id}")
    # The link works: the grantee can open what it points at.
    get disk_path("/nodes/#{folder.key}"), headers: auth_headers(other_user)
    expect(response).to have_http_status(:ok)
  end

  it "notifies a member added to a share, and nobody on a role change" do
    put disk_path("/shares/#{share.key}/members/#{member.key}"), params: { role: "view" },
                                                                 headers: auth_headers(owner_user), as: :json
    n = Notification.sole
    expect([n.user, n.kind, n.url]).to eq([member_user, "disk_shared", "/disk/d/marketing"])
    expect(n.title).to eq("Olive Owner added you to the “Marketing” share")

    put disk_path("/shares/#{share.key}/members/#{member.key}"), params: { role: "edit" },
                                                                 headers: auth_headers(owner_user), as: :json
    put disk_path("/nodes/#{folder.key}/grants/#{other.key}"), params: { role: "view" },
                                                                headers: auth_headers(member_user), as: :json
    put disk_path("/nodes/#{folder.key}/grants/#{other.key}"), params: { role: "edit" },
                                                                headers: auth_headers(member_user), as: :json
    expect(Notification.count).to eq(2)
    expect(sent_mail.size).to eq(2)
  end

  it "sends nothing when a manager shares with themselves, or the request is refused" do
    put disk_path("/shares/#{share.key}/members/#{owner.key}"), params: { role: "manage" },
                                                                headers: auth_headers(owner_user), as: :json
    put disk_path("/nodes/#{folder.key}/grants/#{other.key}"), params: { role: "view" },
                                                                headers: auth_headers(other_user), as: :json
    expect(response).to have_http_status(:not_found)
    expect(Notification.count).to eq(0)
    expect(sent_mail).to be_empty
  end
end
