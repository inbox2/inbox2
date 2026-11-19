require "rails_helper"
require "net/http"

# The upload protocol against real object storage (local Garage, bucket
# inbox2-test-disk; bin/garage-init creates it). Skipped when storage is not
# reachable, like the attachment S3 specs. Bytes go straight to storage through
# the presigned URLs the API issues, never through Rails.
RSpec.describe "Disk storage against Garage", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:root) { make_share("Marketing").root_node }
  let(:mib) { 1.megabyte }
  let(:real) { Disk::Storage.current }

  before do
    allow(Disk::Storage).to receive(:current).and_call_original
    real.each_object { break }
  rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, S3StorageService::ConfigurationError => e
    skip "Disk storage unavailable: #{e.class}"
  end

  def reserve(size, name: "big.bin")
    post disk_path("/uploads"), params: { parent_id: root.key, name: name, size_bytes: size }, headers: owner_h, as: :json
    expect(response).to have_http_status(:created)
    response.parsed_body["upload"]
  end

  def part_urls(upload, numbers)
    post disk_path("/uploads/#{upload['id']}/parts"), params: { numbers: numbers }, headers: owner_h, as: :json
    response.parsed_body["parts"].to_h { |p| [p["number"], p["url"]] }
  end

  def http(method, url, body: nil, headers: {})
    uri = URI(url)
    req = (method == :put ? Net::HTTP::Put : Net::HTTP::Get).new(uri, headers)
    req.body = body if body
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def put_part(url, bytes)
    res = http(:put, url, body: bytes)
    expect(res.code).to eq("200")
  end

  def complete(upload)
    post disk_path("/uploads/#{upload['id']}/complete"), headers: owner_h, as: :json
  end

  def upload_row(upload) = Disk::Upload.find_by!(key: upload["id"])

  it "uploads in parts through presigned URLs, completes, and range-reads through a presigned GET" do
    first = ("a" * (8 * mib)).b
    last = (("0123456789" * (3 * mib / 10)) + "TAIL").b
    upload = reserve(first.bytesize + last.bytesize)
    expect(upload["part_count"]).to eq(2)
    urls = part_urls(upload, [1, 2])
    put_part(urls[2], last) # parts may arrive in any order
    put_part(urls[1], first)

    get disk_path("/uploads/#{upload['id']}"), headers: owner_h
    expect(response.parsed_body["parts"].map { |p| [p["number"], p["size_bytes"]] }).to eq([[1, first.bytesize],
                                                                                            [2, last.bytesize]])
    complete(upload)
    expect(response).to have_http_status(:ok)
    version = Disk::Version.find_by!(key: response.parsed_body["version"]["id"])
    expect(real.size(version.storage_key)).to eq(first.bytesize + last.bytesize)
    expect(org.reload).to have_attributes(disk_bytes_used: version.size_bytes, disk_bytes_reserved: 0)

    get disk_path("/nodes/#{response.parsed_body['node']['id']}/download"), headers: owner_h
    url = response.parsed_body["download"]["url"]
    ranged = http(:get, url, headers: { "Range" => "bytes=#{first.bytesize - 2}-#{first.bytesize + 3}" })
    expect(ranged.code).to eq("206")
    expect(ranged.body).to eq("aa0123")
    expect(http(:get, url, headers: { "Range" => "bytes=-4" }).body).to eq("TAIL")
    # Garage 1.0.1 applies response-content-disposition to full GETs only, not
    # to 206s; a download is a full GET, so it still arrives as an attachment.
    full = http(:get, url)
    expect(full.body.bytesize).to eq(version.size_bytes)
    expect(full["Content-Disposition"]).to eq(%(attachment; filename="big.bin"; filename*=UTF-8''big.bin))
  ensure
    real.delete([version&.storage_key])
  end

  it "refuses a completion holding a part the API never issued" do
    upload = reserve(9 * mib)
    urls = part_urls(upload, [1])
    put_part(urls[1], "x" * (8 * mib))
    put_part(real.part_url(upload_row(upload).storage_key, upload_row(upload).multipart_upload_id, 2), "y" * mib)
    complete(upload)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"].first["message"]).to eq("Part 2 was not issued for this upload")
    expect { real.parts(upload_row(upload).storage_key, upload_row(upload).multipart_upload_id) }
      .to raise_error(Aws::S3::Errors::NoSuchUpload)
    expect(org.reload.disk_bytes_reserved).to eq(0)
  end

  it "refuses parts that do not add up to the declared size" do
    upload = reserve(9 * mib)
    urls = part_urls(upload, [1, 2])
    put_part(urls[1], "x" * (8 * mib))
    put_part(urls[2], "y" * (2 * mib))
    complete(upload)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"].first["message"]).to include("not the #{9 * mib} declared")
    expect(upload_row(upload).state).to eq("aborted")
    expect(org.reload.disk_bytes_reserved).to eq(0)
  end

  it "releases the reservation and the stored parts on abort" do
    upload = reserve(9 * mib)
    put_part(part_urls(upload, [1])[1], "x" * (8 * mib))
    expect(org.reload.disk_bytes_reserved).to eq(9 * mib)
    delete disk_path("/uploads/#{upload['id']}"), headers: owner_h
    expect(response).to have_http_status(:ok)
    expect(org.reload.disk_bytes_reserved).to eq(0)
    expect { real.parts(upload_row(upload).storage_key, upload_row(upload).multipart_upload_id) }
      .to raise_error(Aws::S3::Errors::NoSuchUpload)
  end

  it "copies server-side and sets CORS for the web origin idempotently" do
    src = Disk::Storage.new_key(org)
    dst = Disk::Storage.new_key(org)
    real.put_empty(src)
    real.copy(src, dst, 0)
    expect(real.size(dst)).to eq(0)
    2.times { real.setup!(["https://mail.example.test", "tauri://localhost"]) }
    expect(real.cors_rules.map(&:allowed_origins)).to eq([["https://mail.example.test"], ["tauri://localhost"]])
    # A browser rejects a preflight answer that lists more than one origin.
    uri = URI.parse(real.preview_url(src))
    preflight = Net::HTTP.start(uri.host, uri.port) do |http|
      http.send_request("OPTIONS", uri.request_uri, nil,
                        "Origin" => "https://mail.example.test", "Access-Control-Request-Method" => "PUT")
    end
    expect(preflight["access-control-allow-origin"]).to eq("https://mail.example.test")
    expect(real.lifecycle_rules.first.abort_incomplete_multipart_upload.days_after_initiation)
      .to eq(Disk::Storage::ABORT_MULTIPART_DAYS)

    # The browser's ranged reads (zip listings, media) need Range allowed and
    # these response headers readable cross-origin.
    real.put_bytes(src, "0123456789")
    uri = URI(real.get_url(src))
    preflight = Net::HTTP.start(uri.host, uri.port) do |h|
      h.request(Net::HTTPGenericRequest.new("OPTIONS", false, true, uri.request_uri,
                                            "Origin" => "https://mail.example.test",
                                            "Access-Control-Request-Method" => "GET",
                                            "Access-Control-Request-Headers" => "range"))
    end
    expect(preflight.code).to eq("200")
    expect(preflight["Access-Control-Allow-Headers"].to_s.downcase).to match(/range|\*/)
    ranged = http(:get, uri.to_s, headers: { "Origin" => "https://mail.example.test", "Range" => "bytes=2-4" })
    expect(ranged.body).to eq("234")
    exposed = ranged["Access-Control-Expose-Headers"].to_s.downcase.split(/,\s*/)
    expect(exposed).to include("etag", "content-length", "content-range", "accept-ranges")
  ensure
    real.delete([src, dst])
    real.setup!
  end

  it "lets an agent write, read back and download a text file over MCP" do
    folder = make_folder(root, "Docs")
    m = create(:membership, user: create(:user), organization: org, role: "member", member_type: Membership::TYPE_AGENT)
    agent = create(:agent, organization: org, membership: m, permissions: Agent::DISK_PERMISSIONS)
    Disk::AgentGrant.create!(organization: org, agent: agent, node: folder, role: Disk::ROLE_EDIT, granted_by: owner)
    token = agent.generate_credential!
    call = lambda do |name, args|
      post disk_path("/mcp"), params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: args } }.to_json,
                              headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      response.parsed_body["result"]
    end
    text = "héllo from an agent\n" * 1000
    written = call.call("disk_write_file", { parent_id: folder.key, name: "a.md", text: text })["structuredContent"]
    node = Disk::Node.find_by!(key: written["id"])
    first = call.call("disk_read_file", { id: node.key, limit: 7000 })
    rest = call.call("disk_read_file", { id: node.key, offset: first["structuredContent"]["next_offset"] })
    body = [first, rest].map { |r| r["content"].last["text"].delete_prefix("#{Disk::McpTools::UNTRUSTED}\n\n") }.join
    expect(body).to eq(text)

    link = call.call("disk_download_link", { id: node.key })["structuredContent"]
    expect(http(:get, link["url"]).body.force_encoding("UTF-8")).to eq(text)
  ensure
    real.delete([node&.current_version&.storage_key])
  end
end
