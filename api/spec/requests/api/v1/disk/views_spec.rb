require "rails_helper"

RSpec.describe "Api::V1::Disk::Views", type: :request do
  include_context "disk org"

  let(:member_h) { auth_headers(member_user) }
  let(:file) { make_file(c_root(member), "brief.pdf", mime: "application/pdf") }

  it "Recent lists files I opened, newest first" do
    older = make_file(c_root(member), "older.pdf", mime: "application/pdf")
    get disk_path("/nodes/#{older.key}"), headers: member_h
    get disk_path("/nodes/#{file.key}"), headers: member_h
    get disk_path("/views/recent"), headers: member_h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["nodes"].map { |n| n["name"] }).to eq(%w[brief.pdf older.pdf])
  end

  it "Starred lists what I starred, flagged as starred" do
    Disk::Star.create!(organization: org, node: file, membership: member)
    get disk_path("/views/starred"), headers: member_h
    expect(response.parsed_body["nodes"].map { |n| [n["name"], n["starred"]] }).to eq([["brief.pdf", true]])
  end

  it "Shared with me lists direct grants only" do
    folder = make_folder(c_root(other), "Plans")
    Disk::Grant.create!(organization: org, node: folder, membership: member, role: "view")
    make_folder(folder, "Inside")
    get disk_path("/views/shared-with-me"), headers: member_h
    expect(response.parsed_body["nodes"].map { |n| n["name"] }).to eq(["Plans"])
  end

  it "Trash shows what I deleted and what was deleted from my C:\\, not others' deletions in shares" do
    file.update!(trashed_at: Time.current, trash_root: true, trashed_by: other)
    share = make_share("Open", openness: "org", org_role: "edit")
    make_folder(share.root_node, "Theirs").update!(trashed_at: Time.current, trash_root: true, trashed_by: other)
    get disk_path("/views/trash"), headers: member_h
    expect(response.parsed_body["nodes"].map { |n| n["name"] }).to eq(["brief.pdf"])
  end

  it "never leaks another member's starred, recent or trashed items" do
    Disk::Star.create!(organization: org, node: file, membership: member)
    Disk::Recent.touch!(member, file)
    %w[starred recent trash shared-with-me].each do |view|
      get disk_path("/views/#{view}"), headers: auth_headers(other_user)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["nodes"]).to eq([])
    end
  end

  it "404s for another org" do
    %w[starred recent trash shared-with-me].each do |view|
      get "/api/v1/orgs/#{outsider_org.key}/disk/views/#{view}", headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end
end
