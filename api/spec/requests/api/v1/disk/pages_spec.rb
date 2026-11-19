require "rails_helper"

# Spec F6, API half (package 7).
RSpec.describe "Api::V1::Disk::Pages", type: :request do
  include_context "disk org"

  let(:share) { make_share("Marketing") }
  let(:folder) { make_folder(share.root_node, "Launch") }
  let(:h) { auth_headers(owner_user) }

  before { share.share_memberships.create!(organization: org, membership: member, role: "view") }

  def new_page(parent = folder, name = "Plan", headers: h)
    post disk_path("/nodes"), params: { parent_id: parent.key, name: name, kind: "page" }, headers: headers, as: :json
    response.parsed_body["node"]
  end

  def save(key, md, base:, headers: h, **extra)
    put disk_path("/pages/#{key}"), params: { ydoc: Base64.strict_encode64("y:#{md}"), markdown: md,
                                              base_revision: base, **extra }, headers: headers, as: :json
  end

  it "creates a page in a folder, empty at revision 0, listed with its kind" do
    node = new_page
    expect(response).to have_http_status(:created)
    expect(node).to include("kind" => "page", "name" => "Plan", "size_bytes" => 0)
    get disk_path("/pages/#{node['id']}"), headers: h
    expect(response.parsed_body["page"]).to include("node_id" => node["id"], "revision" => 0, "ydoc" => nil,
                                                    "markdown" => nil, "sealed" => false)
    expect(response.parsed_body["role"]).to eq("manage")
    get disk_path("/nodes/#{folder.key}/children"), headers: h
    expect(response.parsed_body["nodes"].map { |n| [n["name"], n["kind"]] }).to eq([%w[Plan page]])
  end

  it "saves a snapshot: revision, node size and modified, folder size, history and an event" do
    key = new_page["id"]
    expect { save(key, "# Plan\n\nhello", base: 0) }.to have_broadcasted_to(Disk::Node.find_by!(key: key))
      .from_channel(DiskPageChannel).with(hash_including("type" => "page_saved", "revision" => 1))
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["page"]).to include("revision" => 1, "markdown" => "# Plan\n\nhello",
                                    "ydoc" => Base64.strict_encode64("y:# Plan\n\nhello"))
    expect(body["node"]).to include("size_bytes" => 13)
    expect(body["node"]["modified_by"]["id"]).to eq(owner.key)
    expect(folder.reload.size_bytes).to eq(13)
    expect(Disk::Event.where(action: "page_saved").count).to eq(1)

    # A second save by the same person soon after refines the same history entry.
    save(key, "# Plan\n\nhello world", base: 1)
    get disk_path("/pages/#{key}/versions"), headers: h
    expect(response.parsed_body["versions"].map { |v| v["revision"] }).to eq([2])
    expect(folder.reload.size_bytes).to eq(19)
  end

  it "replaces a page from markdown alone (a .docx imported in the browser): no ydoc, editors told to rebuild" do
    key = new_page["id"]
    save(key, "old", base: 0)
    expect do
      put disk_path("/pages/#{key}"), params: { markdown: "# From Word\n\n- a\n", base_revision: 1 }, headers: h, as: :json
    end.to have_broadcasted_to(Disk::Node.find_by!(key: key)).from_channel(DiskPageChannel)
      .with(hash_including("type" => "page_replaced", "revision" => 2))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["page"]).to include("ydoc" => nil, "markdown" => "# From Word\n\n- a\n")
    put disk_path("/pages/#{key}"), params: { markdown: "x", base_revision: 2 }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a save from an older revision with the current one, so the client can merge" do
    key = new_page["id"]
    save(key, "one", base: 0)
    save(key, "two", base: 0)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["current_revision"]).to eq(1)
  end

  it "keeps history like files: a later entry per person or window, readable, and restorable by saving it" do
    key = new_page["id"]
    save(key, "monday", base: 0)
    Disk::PageVersion.update_all(created_at: 1.day.ago)
    save(key, "tuesday", base: 1)
    get disk_path("/pages/#{key}/versions"), headers: h
    expect(response.parsed_body["versions"].map { |v| [v["revision"], v["markdown"]] }).to eq([[2, nil], [1, nil]])

    get disk_path("/pages/#{key}/versions/1"), headers: h
    old = response.parsed_body["version"]
    expect(old).to include("revision" => 1, "markdown" => "monday", "ydoc" => Base64.strict_encode64("y:monday"))

    save(key, old["markdown"], base: 2, restored_from: 1)
    expect(response.parsed_body["page"]).to include("revision" => 3, "markdown" => "monday")
    expect(Disk::Event.find_by!(action: "page_restored").detail).to include("from" => 1, "revision" => 3)
    get disk_path("/pages/#{key}/versions"), headers: h
    expect(response.parsed_body["versions"].map { |v| v["revision"] }).to eq([3, 2, 1])
  end

  it "builds a page tree: sub-pages under pages, listed, moved, copied, trashed and found by title" do
    parent = new_page(folder, "Handbook")["id"]
    parent_node = Disk::Node.find_by!(key: parent)
    child = new_page(parent_node, "Onboarding")["id"]
    expect(response).to have_http_status(:created)
    save(child, "welcome", base: 0)
    get disk_path("/nodes/#{parent}/children"), headers: h
    expect(response.parsed_body["nodes"].map { |n| n["id"] }).to eq([child])
    get disk_path("/nodes/#{folder.key}/tree"), headers: h
    expect(response.parsed_body["nodes"].map { |n| n["id"] }).to contain_exactly(parent, child)

    post disk_path("/nodes"), params: { parent_id: parent, name: "Sub", kind: "folder" }, headers: h, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    patch disk_path("/nodes/#{child}"), params: { name: "First week" }, headers: h, as: :json
    expect(response.parsed_body["node"]["name"]).to eq("First week")
    get disk_path("/search"), params: { q: "first" }, headers: h
    expect(response.parsed_body["results"].map { |r| r["id"] }).to eq([child])

    post disk_path("/nodes/#{parent}/copy"), params: { target_id: share.root_node.key }, headers: h, as: :json
    copy = Disk::Node.find_by!(key: response.parsed_body["node"]["id"])
    copied_child = copy.children.sole
    get disk_path("/pages/#{copied_child.key}"), headers: h
    expect(response.parsed_body["page"]["markdown"]).to eq("welcome")
    expect(copy.reload.size_bytes).to eq(7)

    post disk_path("/nodes/#{child}/move"), params: { target_id: folder.key }, headers: h, as: :json
    expect(response).to have_http_status(:ok)
    delete disk_path("/nodes/#{child}"), headers: h
    save(child, "x", base: 1)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "lets a viewer read but not save, and refuses non-pages, sealed pages and bad input" do
    key = new_page["id"]
    mh = auth_headers(member_user)
    get disk_path("/pages/#{key}"), headers: mh
    expect(response.parsed_body["role"]).to eq("view")
    save(key, "hi", base: 0, headers: mh)
    expect(response).to have_http_status(:forbidden)
    new_page(folder, "Mine", headers: mh)
    expect(response).to have_http_status(:forbidden)

    get disk_path("/pages/#{folder.key}"), headers: h
    expect(response).to have_http_status(:unprocessable_content)
    put disk_path("/pages/#{key}"), params: { ydoc: "%%%", markdown: "x", base_revision: 0 }, headers: h, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    vault = make_sealed_share.root_node
    new_page(vault, "Secret")
    expect(response.parsed_body["errors"].first["message"]).to match(/sealing client/)
    key = make_sealed_node(vault, kind: Disk::Node::KIND_PAGE).key
    save(key, "hi", base: 0)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"].first["message"]).to match(/sealing client/)
    get disk_path("/pages/#{key}"), headers: h
    expect(response.parsed_body["page"]).to include("sealed" => true, "markdown" => nil, "update_seq" => 0)
  end

  it "404s a page the caller cannot see and another org's page" do
    mine = make_folder(c_root(owner), "Private").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
    theirs = make_folder(foreign_share.root_node, "Theirs").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
    mh = auth_headers(member_user)
    [[mine, mh], [theirs, h]].each do |node, headers|
      get disk_path("/pages/#{node.key}"), headers: headers
      expect(response).to have_http_status(:not_found)
      save(node.key, "x", base: 0, headers: headers)
      expect(response).to have_http_status(:not_found)
      get disk_path("/pages/#{node.key}/versions"), headers: headers
      expect(response).to have_http_status(:not_found)
      get disk_path("/pages/#{node.key}/versions/1"), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
