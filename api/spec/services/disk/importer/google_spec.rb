require "rails_helper"

# Google Drive adapter against hand-built Drive API v3 fixtures.
RSpec.describe Disk::Importer::Google do
  include_context "disk import"

  let(:api) { "https://www.googleapis.com/drive/v3" }
  let(:import) { personal_import(member, "google") }
  let(:target) { import.target_node }
  let(:xlsx) { "PK\x03\x04#{'x' * 30}[Content_Types].xml#{'y' * 10}".b }

  def file(id, name, mime: "text/plain", parent: "root-id", body: nil, **extra)
    { "id" => id, "name" => name, "mimeType" => mime, "parents" => [parent], "modifiedTime" => "2026-09-01T10:00:00Z",
      "size" => body&.bytesize&.to_s, "md5Checksum" => body && Digest::MD5.hexdigest(body), "shared" => false }
      .merge(extra).compact
  end

  def child(parent, name) = Disk::Node.live.find_by!(parent_id: parent.id, name: name)

  before do
    transport.on(:get, "/files/root?fields=id", { body: { id: "root-id" } })
    transport.on(:get, "/changes/startPageToken", { body: { startPageToken: "100" } })
  end

  def list_pages(*pages)
    pages.each_with_index do |files, i|
      body = { files: files }
      body[:nextPageToken] = "p#{i + 1}" if i < pages.size - 1
      match = i.zero? ? /files\?(?!.*pageToken)/ : /files\?.*pageToken=p#{i}(&|$)/
      transport.on(:get, match, { body: body })
    end
  end

  it "imports My Drive page by page: folders, files by md5, Docs as pages, Sheets as xlsx, and reports the rest" do
    list_pages(
      [file("f1", "Clients", mime: "application/vnd.google-apps.folder"),
       file("a", "brief.txt", parent: "f1", body: "hello brief")],
      [file("d", "Plan", mime: "application/vnd.google-apps.document"),
       file("s", "Budget", mime: "application/vnd.google-apps.spreadsheet", parent: "f1"),
       file("q", "Survey", mime: "application/vnd.google-apps.form"),
       file("k", "Link", mime: "application/vnd.google-apps.shortcut"),
       file("x", "From a colleague", body: "x").except("parents")]
    )
    transport.on(:get, "/files/a?alt=media", { body: "hello brief" })
    transport.on(:get, "/files/d/export?mimeType=text%2Fmarkdown", { body: "# Plan\n\n## Goals\n\n- ship\n" })
    transport.on(:get, %r{/files/s/export\?mimeType=application%2Fvnd.openxmlformats-officedocument.spreadsheetml.sheet},
                 { body: xlsx })

    import.update!(cursor: nil)
    Disk::Importer.for(import).run
    import.reload

    expect(import).to be_done
    expect(JSON.parse(import.cursor)).to eq("changes" => "100")
    clients = child(target, "Clients")
    expect(stored(child(clients, "brief.txt"))).to eq("hello brief")
    expect(Disk::Page.for(child(target, "Plan")).markdown).to include("## Goals", "- ship")
    expect(child(clients, "Budget.xlsx").current_version.size_bytes).to eq(xlsx.bytesize)
    expect(item_for(import, "q")).to have_attributes(status: "skipped", reason: "A Google form has no file to export")
    expect(item_for(import, "k").reason).to include("shortcut")
    expect(item_for(import, "x").reason).to eq("Shared with you but not in your My Drive")
    expect(transport.requests(%r{/files\?}).size).to eq(2)
    expect(transport.calls.map { |c| c.headers["Authorization"] }.uniq).to eq(["Bearer access"])
  end

  it "reads only changes on the next run: renames, moves and removals" do
    list_pages([file("f1", "A", mime: "application/vnd.google-apps.folder"), file("a", "a.txt", body: "one")])
    transport.on(:get, "/files/a?alt=media", { body: "one" })
    run_import(import)
    a = child(target, "a.txt")

    transport.on(:get, %r{/changes\?.*pageToken=100}, { body: { nextPageToken: "101", changes: [
      { fileId: "a", removed: false, file: file("a", "renamed.txt", parent: "f1", body: "one") }
    ] } })
    transport.on(:get, %r{/changes\?.*pageToken=101}, { body: { newStartPageToken: "102", changes: [
      { fileId: "f1", removed: true }
    ] } })
    again = Disk::Import.create!(import.attributes.except("id", "key", "created_at", "updated_at")
      .merge("state" => "running", "counts" => {}, "cursor" => import.cursor))
    run_import(again)

    expect(a.reload).to have_attributes(name: "renamed.txt", parent_id: child(target, "A").id)
    expect(a.versions.count).to eq(1)
    expect(again.counts).to include("renamed" => 1, "moved" => 1, "deleted_at_source" => 1)
    expect(JSON.parse(again.cursor)).to eq("changes" => "102")
    expect(transport.requests("restrictToMyDrive=true").size).to eq(2)
  end

  it "fails a file whose md5 differs after one retry and stores nothing" do
    list_pages([file("a", "a.txt", body: "expected")])
    transport.on(:get, "/files/a?alt=media", { body: "tampered" })
    run_import(import)
    expect(item_for(import, "a")).to have_attributes(status: "failed", reason: /hash/)
    expect(transport.requests("/files/a?alt=media").size).to eq(2)
    expect(storage.objects).to be_empty
  end

  it "imports a Doc whose markdown is over the page limit as a .md file instead of a page" do
    stub_const("Disk::Page::MAX_BYTES", 16)
    list_pages([file("d", "Big plan", mime: "application/vnd.google-apps.document")])
    transport.on(:get, "/files/d/export?mimeType=text%2Fmarkdown", { body: "# Plan\n\n#{'words ' * 10}" })
    run_import(import)
    node = child(target, "Big plan.md")
    expect(node.kind).to eq(Disk::Node::KIND_FILE)
    expect(stored(node)).to start_with("# Plan")
    expect(item_for(import, "d")).to have_attributes(status: "done", reason: /page limit, so it was imported as a file/)
    expect(item_for(import, "d").detail).to include("converted" => true, "format" => "md")
    expect(import.counts).to include("files" => 1, "converted" => 1)
  end

  it "reports a native file over Google's export limit" do
    list_pages([file("s", "Huge", mime: "application/vnd.google-apps.spreadsheet")])
    transport.on(:get, "/files/s/export", { status: 403, body: { error: { message: "This file is too large to be exported.",
                                                                          errors: [{ reason: "exportSizeLimitExceeded" }] } } })
    run_import(import)
    expect(item_for(import, "s")).to have_attributes(status: "failed", reason: /10 MB export limit/)
  end

  it "holds the tenant on a rate-limit 403 and schedules the import for later" do
    list_pages([file("a", "a.txt", body: "one")])
    transport.on(:get, "/files/a?alt=media", { status: 403, body: { error: { errors: [{ reason: "userRateLimitExceeded" }] } } })
    import.connection.update!(tenant: "acme.test")
    expect { run_import(import) }.to have_enqueued_job(Disk::ImportJob)
    expect(import).to be_queued
    expect(import.connection.reload.waiting_until).to be_within(5.seconds).of(60.seconds.from_now)
  end

  it "stops with a clear message when the authorisation was revoked" do
    import.connection.update!(access_token: nil)
    allow(OauthProvider).to receive(:refresh_tokens).and_raise(OauthProvider::Error, "token refresh failed: HTTP 400 invalid_grant")
    run_import(import)
    expect(import).to have_attributes(state: "paused", pause_reason: "authorization", error: /revoked or expired/)
  end

  describe "the org reach" do
    let(:org_conn) { connection_for(owner, "google", reach: "org", account_email: "admin@acme.test", tenant: "acme.test") }
    let(:key) { OpenSSL::PKey::RSA.new(2048) }

    def importer_for(space_kind: "shared", **attrs)
      Disk::Importer::Google.new(Disk::Import.new(organization: org, membership: owner, connection: org_conn,
                                                  provider: "google", space_kind: space_kind, **attrs))
    end

    it "lists shared drives, and members' drives through domain-wide delegation" do
      ENV["DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT"] = { client_email: "sa@proj.iam.gserviceaccount.com",
                                                    private_key: key.to_pem }.to_json
      transport.on(:get, "/drives?pageSize=100", { body: { drives: [{ id: "0AB", name: "Marketing" }] } })
      transport.on(:post, "oauth2.googleapis.com/token", lambda { |call|
        assertion = Rack::Utils.parse_query(call.body)["assertion"]
        input, sig = assertion.rpartition(".").values_at(0, 2)
        expect(key.verify(OpenSSL::Digest.new("SHA256"), Base64.urlsafe_decode64(sig), input)).to be(true)
        claims = JSON.parse(Base64.urlsafe_decode64(input.split(".")[1]))
        expect(claims).to include("sub" => "admin@acme.test", "iss" => "sa@proj.iam.gserviceaccount.com")
        { body: { access_token: "delegated", expires_in: 3600 } }
      })
      transport.on(:get, "admin/directory/v1/users", { body: { users: [
        { id: "u1", primaryEmail: "mo@acme.test", name: { fullName: "Mo Member" } },
        { id: "u2", primaryEmail: "old@acme.test", suspended: true }
      ] } })

      spaces = importer_for.spaces
      expect(spaces.map { |s| [s.id, s.kind, s.name, s.email] }).to eq(
        [["shared:0AB", "shared", "Marketing", nil], ["member:u1", "member", "Mo Member", "mo@acme.test"]]
      )
      expect(transport.requests("admin/directory").first.headers["Authorization"]).to eq("Bearer delegated")
    end

    it "imports a member's My Drive into their C:\\ as that member, through the service account" do
      ENV["DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT"] = { client_email: "sa@proj.iam.gserviceaccount.com", private_key: key.to_pem }.to_json
      import = personal_import(member, "google", connection: org_conn)
      import.update!(space_kind: "member", space_id: "member:u1", source_email: "mo@acme.test", membership: owner)
      transport.on(:post, "oauth2.googleapis.com/token", lambda { |call|
        claims = JSON.parse(Base64.urlsafe_decode64(Rack::Utils.parse_query(call.body)["assertion"].split(".")[1]))
        expect(claims).to include("sub" => "mo@acme.test", "scope" => "https://www.googleapis.com/auth/drive.readonly")
        { body: { access_token: "as-mo", expires_in: 3600 } }
      })
      list_pages([file("s", "Deck", mime: "application/vnd.google-apps.presentation")])
      transport.on(:get, %r{/files/s/export\?mimeType=application%2Fvnd.openxmlformats-officedocument.presentationml.presentation},
                   { body: xlsx })
      run_import(import)

      deck = child(import.target_node, "Deck.pptx")
      expect(deck).to have_attributes(custodian_membership_id: member.personal_membership_id, created_by_membership_id: member.id)
      expect(transport.calls.reject { |c| c.method == :post }.map { |c| c.headers["Authorization"] }.uniq).to eq(["Bearer as-mo"])
    end

    it "imports a shared drive into a share, with the drive's members as the share's" do
      allow(Disk::ImportSource).to receive(:member_index).and_return("mo@acme.test" => member)
      share = make_share("Marketing")
      import = Disk::Import.create!(organization: org, membership: owner, owner: owner, connection: org_conn, provider: "google",
                                    space_kind: "shared", space_id: "shared:0AB", space_name: "Marketing", share: share,
                                    target_node: share.root_node, state: "running")
      transport.on(:get, %r{/files/0AB/permissions}, { body: { permissions: [
        { type: "user", role: "organizer", emailAddress: "admin@acme.test" },
        { type: "user", role: "writer", emailAddress: "mo@acme.test" },
        { type: "group", role: "reader", emailAddress: "everyone@acme.test" }
      ] } })
      transport.on(:get, %r{/files\?.*corpora=drive.*driveId=0AB}, { body: { files: [
        { "id" => "a", "name" => "deck.txt", "mimeType" => "text/plain", "parents" => ["0AB"], "size" => "1",
          "md5Checksum" => Digest::MD5.hexdigest("d"), "modifiedTime" => "2026-09-01T10:00:00Z" }
      ] } })
      transport.on(:get, "/files/a?alt=media", { body: "d" })
      run_import(import)

      expect(stored(child(share.root_node, "deck.txt"))).to eq("d")
      expect(share.share_memberships.pluck(:membership_id, :role)).to eq([[member.id, "edit"]])
      expect(import.report).to include("unmatched_people" => { "admin@acme.test" => 1 },
                                       "unresolved_groups" => { "everyone@acme.test" => 1 })
      expect(transport.requests("changes/startPageToken?driveId=0AB&supportsAllDrives=true")).to be_present
    end
  end

  describe "endpoint overrides (a local fake provider for tests)" do
    around do |example|
      ENV["DISK_IMPORT_GOOGLE_API_URL"] = "http://localhost:4623/google/drive/v3/"
      ENV["DISK_IMPORT_GOOGLE_TOKEN_URL"] = "http://localhost:4623/google/token"
      example.run
    ensure
      ENV.delete("DISK_IMPORT_GOOGLE_API_URL")
      ENV.delete("DISK_IMPORT_GOOGLE_TOKEN_URL")
    end

    it "sends the importer's calls to the override, and only the importer's" do
      transport.on(:get, "localhost:4623/google/drive/v3/files?", { body: { files: [file("a", "a.txt", body: "a")] } })
      transport.on(:get, "localhost:4623/google/drive/v3/files/a?alt=media", { body: "a" })
      run_import(import)

      expect(stored(child(target, "a.txt"))).to eq("a")
      expect(transport.calls.map(&:url)).to all(start_with("http://localhost:4623/google/drive/v3/"))
      expect(Disk::ImportSource.client("google")[:token_url]).to eq("http://localhost:4623/google/token")
      expect(OauthProvider.token_url("google")).to eq("https://oauth2.googleapis.com/token") # mail grants untouched
    end

    it "refuses an override in production: it would send tokens to another host" do
      allow(Rails.env).to receive(:production?).and_return(true)
      expect { Disk::ImportSource.client("google") }.to raise_error(Disk::ImportSource::OverrideRefused, /DISK_IMPORT_GOOGLE_TOKEN_URL/)
      expect { described_class.at(:api) }.to raise_error(Disk::ImportSource::OverrideRefused)
      ENV.delete("DISK_IMPORT_GOOGLE_API_URL")
      ENV.delete("DISK_IMPORT_GOOGLE_TOKEN_URL")
      expect(described_class.at(:api)).to eq(described_class::API)
    end
  end
end
