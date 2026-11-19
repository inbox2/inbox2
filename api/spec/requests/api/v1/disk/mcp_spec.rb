require "rails_helper"

# Disk over MCP (spec F12, build guide 9c), driven through the JSON-RPC endpoint.
RSpec.describe "Disk MCP", type: :request do
  include_context "disk org"

  let(:share) { make_share("Marketing", openness: Disk::Share::OPENNESS_ORG, org_role: Disk::ROLE_EDIT) }
  let(:root) { share.root_node }
  let!(:docs) { make_folder(root, "Docs") }
  let!(:sub) { make_folder(docs, "Notes") }
  let!(:sibling) { make_folder(root, "Private") }
  let(:agent) { make_agent }
  let(:token) { agent.generate_credential! }

  def make_agent(perms = Agent::DISK_PERMISSIONS, name: "Scribe")
    m = create(:membership, user: create(:user), organization: org, role: "member",
                            member_type: Membership::TYPE_AGENT)
    create(:agent, organization: org, membership: m, permissions: perms, name: name)
  end

  def grant(node, role, agent: self.agent, by: owner)
    Disk::AgentGrant.create!(organization: org, agent: agent, node: node, role: role, granted_by: by)
  end

  def rpc(method, params = {}, id: 1, bearer: token, headers: {}, org_id: org.key)
    body = { jsonrpc: "2.0", method: method, params: params }
    body[:id] = id if id
    post "/api/v1/orgs/#{org_id}/disk/mcp", params: body.to_json,
                                            headers: { "Authorization" => "Bearer #{bearer}",
                                                       "Content-Type" => "application/json",
                                                       "Accept" => "application/json, text/event-stream" }.merge(headers)
    response.body.present? ? response.parsed_body : nil
  end

  def tool(name, args = {}) = rpc("tools/call", { name: name, arguments: args })["result"]
  def data(result) = result["structuredContent"]

  describe "transport" do
    it "completes the handshake, negotiating the protocol version" do
      body = rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } })
      expect(response).to have_http_status(:ok)
      expect(body["result"]).to include("protocolVersion" => "2025-06-18", "serverInfo" => hash_including("name" => "inbox2-disk"))
      expect(body["result"]["capabilities"]).to include("tools", "resources")

      expect(rpc("initialize", { protocolVersion: "1999-01-01" })["result"]["protocolVersion"]).to eq("2025-11-25")
      rpc("notifications/initialized", {}, id: nil)
      expect(response).to have_http_status(:accepted)
      expect(rpc("ping")["result"]).to include("resultType" => "complete")
    end

    it "refuses an unsupported MCP-Protocol-Version header and unknown methods" do
      body = rpc("tools/list", {}, headers: { "MCP-Protocol-Version" => "2023-01-01" })
      expect(response).to have_http_status(:bad_request)
      expect(body["error"]["code"]).to eq(-32_022)
      expect(rpc("nope")["error"]["code"]).to eq(-32_601)
    end

    it "serves stateless 2026-07-28 requests whose headers match the body" do
      meta = { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" }
      h = { "MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/call",
            "Mcp-Name" => "=?base64?#{Base64.strict_encode64('disk_list_drives')}?=" }
      body = rpc("tools/call", { name: "disk_list_drives", arguments: {}, _meta: meta }, headers: h)
      expect(response).to have_http_status(:ok)
      expect(body["result"]["isError"]).to be(false)

      body = rpc("tools/call", { name: "disk_list_drives", arguments: {}, _meta: meta },
                 headers: h.merge("Mcp-Name" => "disk_trash"))
      expect(response).to have_http_status(:bad_request)
      expect(body["error"]["code"]).to eq(-32_020)
      expect(rpc("server/discover", { _meta: meta }, headers: h.merge("Mcp-Method" => "server/discover"))["result"]["supportedVersions"])
        .to include("2026-07-28")
    end

    it "answers GET with 405 and a parse error with 400" do
      get disk_path("/mcp"), headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:method_not_allowed)
      post disk_path("/mcp"), params: "{", headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end

    it "refuses a bad, revoked or human credential with 401" do
      rpc("tools/list", {}, bearer: "agt_nope")
      expect(response).to have_http_status(:unauthorized)
      agent.update!(status: Agent::STATUS_DISABLED)
      rpc("tools/list")
      expect(response).to have_http_status(:unauthorized)
      rpc("tools/list", {}, bearer: auth_headers(owner_user)["Authorization"].split.last)
      expect(response).to have_http_status(:unauthorized)
    end

    it "is not found under another org and refused on a plan without Disk" do
      rpc("tools/list", {}, org_id: outsider_org.key)
      expect(response).to have_http_status(:not_found)
      org.subscription.update!(plan: Plan.free)
      org.update!(disk_lost_at: 31.days.ago)
      rpc("tools/list")
      expect(response).to have_http_status(:forbidden)
    end

    it "reads but does not write in the read-only month after a downgrade" do
      grant(docs, Disk::ROLE_EDIT)
      org.subscription.update!(plan: Plan.free)
      expect(tool("disk_list", id: docs.key)["isError"]).to be(false)
      result = tool("disk_create_folder", parent_id: docs.key, name: "X")
      expect(result["content"].first["text"]).to include("read-only")
      expect(docs.children.count).to eq(1)
    end

    it "refuses a browser page from a foreign origin" do
      rpc("tools/list", {}, headers: { "Origin" => "https://evil.example" })
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "tools/list" do
    it "shows only read tools to a disk_read agent and describes text as untrusted" do
      agent.update!(permissions: [Agent::DISK_READ])
      tools = rpc("tools/list")["result"]["tools"]
      names = tools.pluck("name")
      expect(names).to include("disk_list", "disk_read_file", "disk_read_page", "disk_download_link")
      expect(names).not_to include("disk_write_file", "disk_trash", "disk_share")
      expect(tools.find { |t| t["name"] == "disk_read_file" }["description"]).to include("untrusted")
      expect(tools.first["inputSchema"]).to include("type" => "object")
    end

    it "offers the manage tools only with disk_manage, and never the never-available actions" do
      names = rpc("tools/list")["result"]["tools"].pluck("name")
      expect(names).to include("disk_trash", "disk_restore", "disk_restore_version", "disk_share", "disk_create_link",
                               "disk_revoke_link")
      expect(names.grep(/purge|delete|seal|key|setting|quota|archive/)).to be_empty
      agent.update!(permissions: [Agent::DISK_READ, Agent::DISK_WRITE])
      expect(rpc("tools/list")["result"]["tools"].pluck("name")).not_to include("disk_trash", "disk_share")
    end

    it "refuses a tool call without its permission" do
      agent.update!(permissions: [Agent::DISK_READ])
      grant(docs, Disk::ROLE_EDIT)
      result = tool("disk_create_folder", parent_id: docs.key, name: "X")
      expect(result["isError"]).to be(true)
      expect(docs.children.count).to eq(1)
    end
  end

  describe "reach" do
    it "lists nothing for a new agent" do
      expect(data(tool("disk_list_drives"))["roots"]).to eq([])
      expect(tool("disk_get", id: docs.key)["structuredContent"]).to include("status" => 404)
    end

    it "reads a granted folder and its subfolders, not a sibling, and cannot write at view" do
      grant(docs, Disk::ROLE_VIEW)
      roots = data(tool("disk_list_drives"))["roots"]
      expect(roots.map { |r| [r["id"], r["path"], r["role"]] }).to eq([[docs.key, "...\\Docs", "view"]])
      expect(data(tool("disk_list", id: docs.key))["nodes"].pluck("id")).to eq([sub.key])
      expect(data(tool("disk_get", id: sub.key))).to include("role" => "view", "path" => "...\\Docs\\Notes")
      expect(tool("disk_list", id: sibling.key)["isError"]).to be(true)
      expect(tool("disk_get", id: root.key)["isError"]).to be(true)
      write = tool("disk_create_folder", parent_id: docs.key, name: "New")
      expect(write).to include("isError" => true)
      expect(data(write)).to include("status" => 403)
    end

    it "ignores open shares and share membership" do
      share.share_memberships.create!(organization: org, membership: agent.membership, role: Disk::ROLE_MANAGE)
      expect(tool("disk_get", id: docs.key)["isError"]).to be(true)
    end

    it "is capped by the granter's current access" do
      admin = create(:membership, user: create(:user), organization: org, role: "admin")
      locked = make_share("Board", openness: Disk::Share::OPENNESS_ASSIGNED)
      grant(locked.root_node, Disk::ROLE_EDIT, by: admin)
      expect(data(tool("disk_get", id: locked.root_node.key))["role"]).to eq("manage") # edit plus disk_manage where the granter manages
      admin.update!(role: "member")
      expect(tool("disk_get", id: locked.root_node.key)["isError"]).to be(true)
    end

    it "never sees sealed items inside a granted share" do
      grant(root, Disk::ROLE_VIEW)
      sealed = make_folder(root, "Vault")
      sealed.update_columns(sealed: true, name: nil, metadata_ciphertext: "x")
      expect(data(tool("disk_list", id: root.key))["nodes"].pluck("id")).not_to include(sealed.key)
      expect(tool("disk_get", id: sealed.key)["structuredContent"]["status"]).to eq(404)
      expect(data(tool("disk_search", q: "a"))["results"].pluck("id")).not_to include(sealed.key)
    end
  end

  describe "reading" do
    before { grant(docs, Disk::ROLE_VIEW) }

    it "finds a file by name and reads a 2 MB markdown file in pages, labelled as file content" do
      text = "# Big\n" + ("é line of text\n" * 140_000)
      node = make_folder(docs, "big.md").tap { |n| n.update!(kind: Disk::Node::KIND_FILE, mime: "text/markdown") }
      key = Disk::Storage.new_key(org)
      storage.put_bytes(key, text.b)
      node.add_version!(author: owner, storage_key: key, size_bytes: text.bytesize)

      found = data(tool("disk_search", q: "big"))["results"]
      expect(found.map { |r| [r["id"], r["path"]] }).to eq([[node.key, "...\\Docs\\big.md"]])

      read = ""
      offset = 0
      pages = 0
      while offset
        result = tool("disk_read_file", id: node.key, offset: offset, limit: 512.kilobytes)
        expect(result["content"].last["text"]).to start_with(Disk::McpTools::UNTRUSTED)
        read << result["content"].last["text"].delete_prefix("#{Disk::McpTools::UNTRUSTED}\n\n")
        offset = data(result)["next_offset"]
        pages += 1
      end
      expect(pages).to be > 3
      expect(read).to eq(text)
    end

    it "gives a short-lived link for a PDF and lists its versions" do
      pdf = make_stored_file(docs, "deck.pdf", size: 10, versions: [5])
      expect(tool("disk_read_file", id: pdf.key)["isError"]).to be(true)
      link = data(tool("disk_download_link", id: pdf.key))
      expect(link["url"]).to include(pdf.current_version.storage_key)
      expect(Time.zone.parse(link["expires_at"])).to be <= 5.minutes.from_now
      expect(data(tool("disk_list_versions", id: pdf.key))["versions"].pluck("number")).to eq([2, 1])
    end

    it "lists pages as resources and reads one" do
      page = make_folder(docs, "Plan").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
      Disk::Page.for(page).update!(markdown: "# Plan")
      list = rpc("resources/list")["result"]["resources"]
      expect(list.pluck("uri")).to include("disk://node/#{page.key}")
      read = rpc("resources/read", { uri: "disk://node/#{page.key}" })["result"]["contents"].first
      expect(read["text"]).to eq("#{Disk::McpTools::UNTRUSTED}\n\n# Plan")
      expect(rpc("resources/read", { uri: "disk://node/#{sibling.key}" })["error"]).to be_present
    end
  end

  describe "writing" do
    before { grant(docs, Disk::ROLE_EDIT) }

    it "writes a text file as the agent, and a second write makes a new version" do
      first = tool("disk_write_file", parent_id: docs.key, name: "notes.md", text: "hello")
      expect(first["isError"]).to be(false)
      node = Disk::Node.find_by!(key: data(first)["id"])
      expect(data(first)).to include("path" => "...\\Docs\\notes.md", "version" => 1)
      expect(data(first)["modified_by"]).to include("name" => "Scribe", "agent" => true)
      expect(storage.read_range(node.current_version.storage_key, 0, 5)).to eq("hello")

      expect(data(tool("disk_write_file", parent_id: docs.key, name: "notes.md", text: "hello again"))["version"]).to eq(2)
      event = Disk::Event.where(node: node).order(:id).last
      expect(event.actor_agent).to eq(agent)
      get disk_path("/nodes/#{node.key}/events"), headers: auth_headers(owner_user)
      expect(response.parsed_body["events"].first).to include("agent_id" => agent.key)
      expect(response.parsed_body["events"].first["actor"]).to include("name" => "Scribe")
      expect(org.reload.disk_bytes_used).to eq(16)
    end

    it "refuses an oversized body with 413 before parsing it" do
      post "/api/v1/orgs/#{org.key}/disk/mcp", params: "{#{'x' * Api::V1::Disk::McpController::BODY_MAX}",
                                              headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body).to include("jsonrpc" => "2.0", "error" => hash_including("code" => -32_600))
    end

    it "refuses base64 longer than the write limit before decoding it" do
      encoded = "!" * ((((Disk::McpTools::WRITE_MAX + 2) / 3) * 4) + 4) # not base64 at all: never decoded
      result = tool("disk_write_file", parent_id: docs.key, name: "big.bin", base64: encoded)
      expect(result["isError"]).to be(true)
      expect(result.to_json).to include("Write at most 4 MB")
    end

    it "refuses a write over the quota with the quota error and stores nothing" do
      org.update!(disk_quota_override_gb: 0)
      result = tool("disk_write_file", parent_id: docs.key, name: "a.txt", text: "x")
      expect(result["isError"]).to be(true)
      expect(data(result)).to include("code" => "disk_quota_exceeded")
      expect(docs.children.where(name: "a.txt")).to be_empty
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "uploads a large file through the upload tools" do
      size = 200.megabytes
      upload = data(tool("disk_start_upload", parent_id: docs.key, name: "video.mp4", size_bytes: size))
      numbers = (1..upload["part_count"]).to_a
      parts = data(tool("disk_upload_parts", upload_id: upload["id"], numbers: numbers))["parts"]
      expect(parts.size).to eq(numbers.size)
      mp = Disk::Upload.find_by!(key: upload["id"]).multipart_upload_id
      numbers.each { |n| storage.put_part(mp, n, [upload["part_bytes"], size - ((n - 1) * upload["part_bytes"])].min) }
      done = tool("disk_complete_upload", upload_id: upload["id"])
      expect(data(done)).to include("name" => "video.mp4", "size_bytes" => size)
    end

    it "creates folders, renames, moves, copies and stars" do
      folder = data(tool("disk_create_folder", parent_id: docs.key, name: "Drafts"))
      file = data(tool("disk_write_file", parent_id: docs.key, name: "a.txt", text: "a"))
      expect(data(tool("disk_rename", id: file["id"], name: "b.txt"))["name"]).to eq("b.txt")
      expect(data(tool("disk_move", id: file["id"], target_id: folder["id"]))["parent_id"]).to eq(folder["id"])
      expect(data(tool("disk_copy", id: file["id"], target_id: docs.key))["name"]).to eq("b.txt")
      expect(data(tool("disk_star", id: file["id"]))["starred"]).to be(true)
      expect(tool("disk_move", id: file["id"], target_id: sibling.key)["isError"]).to be(true)
    end
  end

  describe "pages" do
    before { grant(docs, Disk::ROLE_EDIT) }

    let(:md) { "# Plan\n\n- one\n- two\n\n- [ ] todo\n" }

    it "creates a page from markdown and keeps it up to date by revision" do
      created = data(tool("disk_create_page", parent_id: docs.key, name: "Plan", markdown: md))
      expect(created["revision"]).to eq(1)
      page = Disk::Node.find_by!(key: created["id"])
      expect(Disk::Page.for(page)).to have_attributes(markdown: md, ydoc: nil)

      read = tool("disk_read_page", id: page.key)
      expect(read["content"].last["text"]).to eq("#{Disk::McpTools::UNTRUSTED}\n\n#{md}")

      expect do
        expect(data(tool("disk_update_page", id: page.key, base_revision: 1, mode: "append", markdown: "More"))["revision"]).to eq(2)
      end.to have_broadcasted_to(DiskPageChannel.broadcasting_for(page))
        .with(hash_including("type" => "page_replaced", "agent" => true, "name" => "Scribe", "revision" => 2))
      expect(Disk::Page.for(page).markdown).to eq("#{md.rstrip}\n\nMore")

      edited = tool("disk_update_page", id: page.key, base_revision: 2, mode: "edits",
                                        edits: [{ find: "- one", replace: "- uno" }])
      expect(data(edited)["revision"]).to eq(3)
      expect(Disk::Page.for(page).markdown).to include("- uno")

      expect(data(tool("disk_update_page", id: page.key, base_revision: 3, mode: "replace", markdown: "# New")))
        .to include("revision" => 4)
    end

    it "refuses a stale revision with the current markdown, and a missing or ambiguous find" do
      page = Disk::Node.find_by!(key: data(tool("disk_create_page", parent_id: docs.key, name: "P", markdown: "a a b"))["id"])
      stale = tool("disk_update_page", id: page.key, base_revision: 0, mode: "replace", markdown: "x")
      expect(stale["isError"]).to be(true)
      expect(data(stale)).to include("status" => 409, "current_revision" => 1)
      expect(stale["content"].last["text"]).to end_with("a a b")

      missing = tool("disk_update_page", id: page.key, base_revision: 1, mode: "edits", edits: [{ find: "zzz", replace: "y" }])
      expect(missing["content"].first["text"]).to include("is not in the page")
      ambiguous = tool("disk_update_page", id: page.key, base_revision: 1, mode: "edits", edits: [{ find: "a", replace: "y" }])
      expect(ambiguous["content"].first["text"]).to include("appears 2 times")
      expect(Disk::Page.for(page).reload.revision).to eq(1)
    end
  end

  describe "manage" do
    before { grant(docs, Disk::ROLE_EDIT) }

    it "trashes, restores, restores a version, shares and makes and revokes a link" do
      file = make_stored_file(docs, "a.pdf", size: 3, versions: [2])
      expect(data(tool("disk_trash", id: file.key))["trashed_at"]).to be_present
      expect(data(tool("disk_restore", id: file.key))["trashed_at"]).to be_nil
      first = file.versions.find_by(number: 1)
      expect(data(tool("disk_restore_version", version_id: first.key))["version"]["number"]).to eq(3)
      expect(data(tool("disk_share", id: file.key, member_id: member.key, role: "view"))["role"]).to eq("view")
      link = data(tool("disk_create_link", id: file.key))
      expect(link["url"]).to include("/share/a-pdf/")
      expect(data(tool("disk_revoke_link", link_id: link["id"]))["revoked_at"]).to be_present
    end

    it "cannot share or link where its granter could not" do
      plain_admin = create(:membership, user: create(:user), organization: org, role: "admin")
      Disk::AgentGrant.where(agent: agent).delete_all
      grant(docs, Disk::ROLE_VIEW, by: plain_admin)
      expect(tool("disk_share", id: docs.key, member_id: member.key, role: "view")["isError"]).to be(true)
    end
  end

  describe "limits and logging" do
    before { grant(docs, Disk::ROLE_EDIT) }

    it "logs every call with its outcome and refuses past the rate limit without changing anything" do
      agent.update!(rate_limit: 2)
      tool("disk_list", id: docs.key)
      tool("disk_get", id: sibling.key)
      result = tool("disk_create_folder", parent_id: docs.key, name: "Blocked")
      expect(result).to include("isError" => true)
      expect(result["content"].first["text"]).to eq("Agent rate limit exceeded")
      expect(docs.children.where(name: "Blocked")).to be_empty
      expect(agent.run_logs.order(:id).pluck(:action, :status)).to eq([
        %w[disk_list success], %w[disk_get failure], %w[disk_create_folder rate_limited]
      ])
    end
  end
end
