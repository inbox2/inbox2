require "rails_helper"

# Microsoft 365 adapter against hand-built Microsoft Graph fixtures.
RSpec.describe Disk::Importer::Microsoft do
  include_context "disk import"

  let(:graph) { "https://graph.microsoft.com/v1.0" }
  let(:import) { personal_import(member, "microsoft") }
  let(:target) { import.target_node }

  def qx(body) = Disk::Importer::Microsoft::QuickXor.new.tap { |q| q << body }.base64
  def child(parent, name) = Disk::Node.live.find_by!(parent_id: parent.id, name: name)

  def item(id, name, parent: "root1", body: nil, **extra)
    base = { id: id, name: name, parentReference: { id: parent }, lastModifiedDateTime: "2026-09-01T10:00:00Z" }
    base.merge!(file: { hashes: { quickXorHash: qx(body) } }, size: body.bytesize) if body
    base.merge(extra)
  end

  def downloadable(id, body)
    transport.on(:get, "/me/drive/items/#{id}", { body: { id: id, "@microsoft.graph.downloadUrl" => "https://dl.test/#{id}?sig=x" } })
    transport.on(:get, "https://dl.test/#{id}", { body: body })
  end

  before { transport.on(:get, "/me/drive/root?$select=id", { body: { id: "root1" } }) }

  # Vectors from rclone's quickxorhash tests, checked against Microsoft's
  # published algorithm (input base64, output base64).
  describe Disk::Importer::Microsoft::QuickXor do
    {
      "" => "AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "Sg==" => "SgAAAAAAAAAAAAAAAQAAAAAAAAA=",
      "eAV52qE=" => "eChAHrQRCgAAAAAABQAAAAAAAAA=",
      "2fuxhBJXtpWFe8dOfdGeHw==" => "O9tHLAghgSvYohKFyMMxnNCHaHg=",
      "jyibxJSzO6ZiZ0O1qe3tG/bvIAYssvukh9suIT5wEy1JBINVgPiqdsTW0cOpP0aUfP7mgqLfADkzI/m/GgCuVhr8oFLrOCoTx1/psBOW" \
      "whltCbhUx51Icm9aH8tY4Z3ccU+6BKpYQkLCy0B/A9Zc" => "hZfLIilSITC6N3e3tQ/iSgEzkto=",
      "PfxMcUd0vIW6VbHG/uj/Y0W6qEoKmyBD0nYebEKazKaKG+UaDqBEcmQjbfQeVnVLuodMoPp7P7TR1htX5n2VnkHh22xDyoJ8C/ZQKiSN" \
      "qQfXvh83judf4RVr9exJCud8Uvgip6aVZTaPrJHVjQhMCp/dEnGvqg0oN5OVkM2qqAXvA0teKUDhgNM71sDBVBCGXxNOR2bpbD1iM4dn" \
      "uT0ey4L+loXEHTL0fqMeUcEi2asgImnlNakwenDzz0x57aBwyq3AspCFGB1ncX4yYCr/OaCcS5OKi/00WH+wNQU3" => "QX/YEpG0gDsmhEpCdWhsxDzsfVE="
    }.each do |input, expected|
      it "hashes #{Base64.decode64(input).bytesize} bytes, whole and in uneven pieces" do
        data = Base64.decode64(input)
        expect(described_class.new.tap { |q| q << data }.base64).to eq(expected)
        pieces = described_class.new
        data.bytes.each_slice(7) { |s| pieces << s.pack("C*") }
        expect(pieces.base64).to eq(expected)
      end
    end
  end

  it "imports OneDrive across delta pages, skips OneNote and others' items, and keeps the delta link" do
    transport.on(:get, "/me/drive/root/delta?$select=", { body: {
      value: [{ id: "root1", name: "root", root: {} }, item("f1", "Clients", folder: {}),
              item("a", "draft.txt", parent: "f1", body: "v1")],
      "@odata.nextLink" => "#{graph}/me/drive/root/delta?token=page2"
    } })
    transport.on(:get, "delta?token=page2", { body: {
      value: [item("n", "Team notes", package: { type: "oneNote" }),
              item("r", "Their file", remoteItem: { id: "x" }),
              item("a", "final.txt", parent: "f1", body: "v1")], # repeated in the same run: the last one wins
      "@odata.deltaLink" => "#{graph}/me/drive/root/delta?token=d1"
    } })
    downloadable("a", "v1")
    run_import(import)

    expect(import).to be_done
    expect(import.cursor).to eq("#{graph}/me/drive/root/delta?token=d1")
    clients = child(target, "Clients")
    expect(Disk::Node.live.where(parent_id: clients.id).pluck(:name)).to eq(["final.txt"])
    expect(stored(child(clients, "final.txt"))).to eq("v1")
    expect(item_for(import, "n")).to have_attributes(status: "skipped", reason: /OneNote notebook has no file/)
    expect(item_for(import, "r").reason).to include("someone else's drive")
    expect(transport.requests("https://dl.test/a").last.headers).not_to have_key("Authorization")
    expect(transport.requests("/me/drive/items/a").first.headers["Authorization"]).to eq("Bearer access")
    expect(Disk::ImportItem.where(source_id: "root1")).to be_empty
  end

  it "starts the drive over from Graph's Location when the delta link answers 410" do
    import.update!(cursor: "#{graph}/me/drive/root/delta?token=old")
    transport.on(:get, "token=old", { status: 410, headers: { "Location" => "#{graph}/me/drive/root/delta?token=fresh" },
                                      body: { error: { code: "resyncRequired" } } })
    transport.on(:get, "token=fresh", { body: { value: [item("a", "a.txt", body: "a")],
                                                "@odata.deltaLink" => "#{graph}/me/drive/root/delta?token=d2" } })
    downloadable("a", "a")
    run_import(import)
    expect(import).to be_done
    expect(child(target, "a.txt")).to be_present
    expect(import.cursor).to end_with("token=d2")
  end

  describe "server-supplied URLs (review round two)" do
    it "refuses a nextLink on another host before sending the token there" do
      transport.on(:get, "/me/drive/root/delta?$select=", { body: { value: [],
                                                                     "@odata.nextLink" => "https://evil.test/v1.0/steal" } })
      expect { run_import(import) }.to raise_error(Disk::Importer::ItemFailed, /outside Microsoft Graph/)
      expect(transport.requests("evil.test")).to be_empty
    end

    it "refuses to store a deltaLink outside Graph's version path" do
      transport.on(:get, "/me/drive/root/delta?$select=", { body: { value: [],
                                                                     "@odata.deltaLink" => "https://graph.microsoft.com/beta/x" } })
      expect { run_import(import) }.to raise_error(Disk::Importer::ItemFailed, /outside Microsoft Graph/)
      expect(import.reload.cursor).to be_nil
    end

    it "refuses a 410 Location on plain http" do
      import.update!(cursor: "#{graph}/me/drive/root/delta?token=old")
      transport.on(:get, "token=old", { status: 410, headers: { "Location" => "http://graph.microsoft.com/v1.0/me/drive/root/delta" } })
      expect { run_import(import) }.to raise_error(Disk::Importer::ItemFailed, /outside Microsoft Graph/)
      expect(transport.calls.map(&:url)).to all(start_with("https://"))
    end

    it "follows a continuation on the configured override host" do
      ENV["DISK_IMPORT_MICROSOFT_GRAPH_URL"] = "http://127.0.0.1:9999/microsoft/graph"
      transport.on(:get, "/me/drive/root/delta?$select=", { body: { value: [],
                                                                     "@odata.deltaLink" => "http://127.0.0.1:9999/microsoft/graph/d1" } })
      expect(run_import(import).cursor).to eq("http://127.0.0.1:9999/microsoft/graph/d1")
    ensure
      ENV.delete("DISK_IMPORT_MICROSOFT_GRAPH_URL")
    end

    def offered_download(url)
      transport.on(:get, "/me/drive/root/delta", { body: { value: [item("a", "a.txt", body: "a")], "@odata.deltaLink" => "#{graph}/d" } })
      transport.on(:get, "/me/drive/items/a", { body: { "@microsoft.graph.downloadUrl" => url } })
      transport.on(:get, url, { body: "a" })
    end

    { "the metadata address" => "https://169.254.169.254/latest/meta-data",
      "loopback" => "https://127.0.0.1/a", "plain http" => "http://dl.test/a" }.each do |what, url|
      it "never fetches a download URL at #{what}" do
        offered_download(url)
        run_import(import)
        expect(item_for(import, "a")).to have_attributes(status: "failed", reason: /does not fetch from/)
        expect(transport.requests(url)).to be_empty
      end
    end

    it "never fetches a download host that resolves to a private address" do
      allow(PrivateAddressGuard).to receive(:resolve).with("inside.test").and_return(["10.0.0.5"])
      offered_download("https://inside.test/a")
      run_import(import)
      expect(item_for(import, "a").status).to eq("failed")
      expect(transport.requests("inside.test")).to be_empty
    end

    it "pins a public download host's connection to the address it checked" do
      offered_download("https://dl.test/a")
      run_import(import)
      expect(transport.requests("https://dl.test/a").last.pin).to eq("203.0.113.7")
    end

    it "lets the e2e fake's own origin through outside production" do
      ENV["DISK_IMPORT_MICROSOFT_GRAPH_URL"] = "http://127.0.0.1:9999/microsoft/graph"
      transport.on(:get, "/me/drive/root?$select=id", { body: { id: "root1" } })
      transport.on(:get, "/me/drive/root/delta", { body: { value: [item("a", "a.txt", body: "a")],
                                                           "@odata.deltaLink" => "http://127.0.0.1:9999/microsoft/graph/d" } })
      transport.on(:get, "/me/drive/items/a", { body: { "@microsoft.graph.downloadUrl" => "http://127.0.0.1:9999/microsoft/graph/dl/a" } })
      transport.on(:get, "/graph/dl/a", { body: "a" })
      run_import(import)
      expect(item_for(import, "a").status).to eq("done")
    ensure
      ENV.delete("DISK_IMPORT_MICROSOFT_GRAPH_URL")
    end
  end

  it "holds the tenant for Retry-After on a 429" do
    import.connection.update!(tenant: "tid-1")
    transport.on(:get, "/me/drive/root/delta", { status: 429, headers: { "Retry-After" => "30" } })
    expect { run_import(import) }.to have_enqueued_job(Disk::ImportJob).with(import.id)
    expect(import.connection.reload.waiting_until).to be_within(5.seconds).of(30.seconds.from_now)
  end

  it "fails a file whose quickXorHash differs, after one retry" do
    transport.on(:get, "/me/drive/root/delta", { body: { value: [item("a", "a.txt", body: "right")],
                                                         "@odata.deltaLink" => "#{graph}/d" } })
    downloadable("a", "wrong")
    run_import(import)
    expect(item_for(import, "a")).to have_attributes(status: "failed", reason: /hash/)
    expect(transport.requests("https://dl.test/a").size).to eq(2)
  end

  it "maps sharing roles and reports links and groups" do
    allow(Disk::ImportSource).to receive(:member_index).and_return("ola@acme.test" => other)
    transport.on(:get, "/me/drive/root/delta", { body: { value: [item("f1", "Shared", folder: {}, shared: { scope: "users" })],
                                                         "@odata.deltaLink" => "#{graph}/d" } })
    transport.on(:get, "/items/f1/permissions", { body: { value: [
      { roles: ["write"], grantedToV2: { user: { email: "ola@acme.test", displayName: "Ola" } } },
      { roles: ["read"], link: { scope: "anonymous", type: "view" } },
      { roles: ["read"], grantedToV2: { siteGroup: { displayName: "Visitors" } } }
    ] } })
    run_import(import)
    folder = child(target, "Shared")
    expect(folder.grants.pluck(:membership_id, :role)).to eq([[other.id, "edit"]])
    expect(item_for(import, "f1").detail).to include("public_link" => true)
    expect(import.report).to eq("unresolved_groups" => { "Visitors" => 1 })
  end

  describe "with a tenant admin's consent" do
    let(:org_conn) { connection_for(owner, "microsoft", reach: "org", tenant: "tid-1", refresh_token: nil, access_token: nil) }

    before do
      transport.on(:post, "login.microsoftonline.com/tid-1/oauth2/v2.0/token", lambda { |call|
        form = Rack::Utils.parse_query(call.body)
        expect(form).to include("grant_type" => "client_credentials", "client_id" => "microsoft-client",
                                "scope" => "https://graph.microsoft.com/.default")
        { body: { access_token: "app-token", expires_in: 3599 } }
      })
    end

    it "lists users' OneDrives and every document library with an app token" do
      transport.on(:get, "/users?", { body: { value: [{ id: "u1", displayName: "Mo", mail: "mo@acme.test" }] } })
      transport.on(:get, "/sites/getAllSites", { body: { value: [{ id: "s1", displayName: "Marketing" }] } })
      transport.on(:get, "/sites/s1/drives", { body: { value: [{ id: "b1", name: "Documents" }, { id: "b2", name: "Assets" }] } })
      spaces = Disk::Importer::Microsoft.new(Disk::Import.new(organization: org, membership: owner, provider: "microsoft",
                                                              connection: org_conn, space_kind: "shared")).spaces
      expect(spaces.map { |s| [s.id, s.name, s.email] }).to eq(
        [["member:u1", "Mo", "mo@acme.test"], ["shared:b1", "Marketing", nil], ["shared:b2", "Marketing - Assets", nil]]
      )
      expect(transport.requests("/users?").first.headers["Authorization"]).to eq("Bearer app-token")
    end

    it "imports a document library into a share and reports the site's lists" do
      share = make_share("Marketing")
      import = Disk::Import.create!(organization: org, membership: owner, owner: owner, connection: org_conn,
                                    provider: "microsoft", space_kind: "shared", space_id: "shared:b1", space_name: "Marketing",
                                    share: share, target_node: share.root_node, state: "running")
      transport.on(:get, "/drives/b1/root?$select=id", { body: { id: "lib-root" } })
      transport.on(:get, "/drives/b1/root/permissions", { body: { value: [] } })
      transport.on(:get, "/drives/b1?$select=id,sharePointIds", { body: { sharePointIds: { siteId: "s1" } } })
      transport.on(:get, "/sites/s1/lists", { body: { value: [
        { id: "l1", displayName: "Documents", list: { template: "documentLibrary" } },
        { id: "l2", displayName: "Issue tracker", list: { template: "genericList" } }
      ] } })
      transport.on(:get, "/drives/b1/root/delta", { body: { value: [item("a", "plan.txt", parent: "lib-root", body: "p")],
                                                             "@odata.deltaLink" => "#{graph}/d" } })
      transport.on(:get, "/drives/b1/items/a", { body: { "@microsoft.graph.downloadUrl" => "https://dl.test/a" } })
      transport.on(:get, "https://dl.test/a", { body: "p" })
      run_import(import)

      expect(stored(child(share.root_node, "plan.txt"))).to eq("p")
      expect(item_for(import, "list:l2")).to have_attributes(status: "skipped", name: "Issue tracker",
                                                             reason: /SharePoint list has no files/)
      expect(Disk::ImportItem.where(source_id: "list:l1")).to be_empty
    end

    it "imports a user's OneDrive into the matching member's C:\\ with the app token" do
      import = personal_import(member, "microsoft", connection: org_conn)
      import.update!(space_kind: "member", space_id: "member:u1", membership: owner)
      transport.on(:get, "/users/u1/drive/root?$select=id", { body: { id: "r9" } })
      transport.on(:get, "/users/u1/drive/root/delta", { body: { value: [item("a", "cv.txt", parent: "r9", body: "cv")],
                                                                  "@odata.deltaLink" => "#{graph}/d" } })
      transport.on(:get, "/users/u1/drive/items/a", { body: { "@microsoft.graph.downloadUrl" => "https://dl.test/a" } })
      transport.on(:get, "https://dl.test/a", { body: "cv" })
      run_import(import)
      expect(stored(child(import.target_node, "cv.txt"))).to eq("cv")
      expect(transport.requests("/users/u1/drive/root/delta").first.headers["Authorization"]).to eq("Bearer app-token")
    end

    it "pauses with a message when the tenant withdrew consent" do
      import = personal_import(owner, "microsoft", connection: org_conn)
      import.update!(space_kind: "member", space_id: "member:u1")
      transport.on(:post, "login.microsoftonline.com/tid-1/oauth2/v2.0/token", { status: 400, body: { error: "invalid_client" } })
      run_import(import)
      expect(import).to have_attributes(state: "paused", pause_reason: "authorization", error: /consent again/)
    end
  end

  it "learns the tenant id from the access token when connecting" do
    allow(OauthProvider).to receive(:fetch_email).and_return("mo@acme.test")
    token = "x.#{Base64.urlsafe_encode64({ tid: 'tid-9' }.to_json, padding: false)}.y"
    conn = Disk::ImportConnection.new
    described_class.identify(conn, "access_token" => token)
    expect(conn).to have_attributes(account_email: "mo@acme.test", tenant: "tid-9")
  end
end
