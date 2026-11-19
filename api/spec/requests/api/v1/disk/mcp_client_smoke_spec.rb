require "rails_helper"
require "puma"
require "open3"

# One run of a real MCP client (the official TypeScript SDK, through
# script/disk_mcp_smoke.mjs) against this app served by Puma on a free port.
# Skipped when node or the SDK is not installed.
RSpec.describe "Disk MCP with a real client", type: :request do
  include_context "disk org"

  let(:script) { Rails.root.join("script/disk_mcp_smoke.mjs").to_s }
  let(:sdk) { Rails.root.join("../ui/android/tools/android-mcp/node_modules/@modelcontextprotocol/sdk/dist/esm") }

  around do |example|
    skip "node is not installed" unless system("node --version", out: File::NULL, err: File::NULL)
    skip "the MCP SDK is not installed" unless sdk.join("client/streamableHttp.js").exist?

    # Transactional tests pin one connection for every thread, so the server
    # thread sees the rows this example has not committed.
    @server = Puma::Server.new(Rails.application, nil, min_threads: 1, max_threads: 1, log_writer: Puma::LogWriter.null)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run
    example.run
  ensure
    @server&.stop(true)
  end

  it "connects, lists tools, reads a page and writes a file" do
    share = make_share("Marketing")
    folder = make_folder(share.root_node, "Docs")
    page = make_folder(folder, "Plan").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
    Disk::Page.for(page).update!(markdown: "# Plan")
    m = create(:membership, user: create(:user), organization: org, role: "member", member_type: Membership::TYPE_AGENT)
    agent = create(:agent, organization: org, membership: m, permissions: Agent::DISK_PERMISSIONS)
    Disk::AgentGrant.create!(organization: org, agent: agent, node: folder, role: Disk::ROLE_EDIT, granted_by: owner)

    url = "http://127.0.0.1:#{@port}/api/v1/orgs/#{org.key}/disk/mcp"
    out, err, status = Open3.capture3("node", script, url, agent.generate_credential!, folder.key, page.key)
    expect(status).to be_success, err
    result = JSON.parse(out.lines.last)

    expect(result["protocol"]).to eq("2025-11-25")
    expect(result["server"]).to include("name" => "inbox2-disk")
    expect(result["tools"]).to include("disk_list", "disk_write_file", "disk_update_page")
    expect(result["page"]).to end_with("# Plan")
    expect(result["page"]).to include(Disk::McpTools::UNTRUSTED)
    expect(result["readBack"]).to end_with("written by the smoke test")
    expect(Disk::Node.find_by!(key: result["written"]).name).to eq("smoke.md")
  end
end
