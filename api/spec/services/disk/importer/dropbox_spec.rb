require "rails_helper"

# Dropbox adapter against hand-built Dropbox API v2 fixtures.
RSpec.describe Disk::Importer::Dropbox do
  include_context "disk import"

  let(:api) { "https://api.dropboxapi.com/2" }
  let(:import) { personal_import(member, "dropbox") }
  let(:target) { import.target_node }
  let(:xlsx) { "PK\x03\x04#{'x' * 30}[Content_Types].xml".b }

  def ch(body) = Disk::Importer::Dropbox::ContentHash.of_io(StringIO.new(body))
  def child(parent, name) = Disk::Node.live.find_by!(parent_id: parent.id, name: name)

  def folder(id, path, **extra) = { ".tag" => "folder", "id" => id, "name" => File.basename(path), "path_lower" => path.downcase }.merge(extra)

  def file(id, path, body: nil, **extra)
    { ".tag" => "file", "id" => id, "name" => File.basename(path), "path_lower" => path.downcase,
      "server_modified" => "2026-09-01T10:00:00Z", "size" => body.to_s.bytesize, "content_hash" => body && ch(body),
      "is_downloadable" => true }.merge(extra).compact
  end

  def downloads(id, body, result: {})
    transport.on(:post, "content.dropboxapi.com/2/files/download", lambda { |call|
      arg = JSON.parse(call.headers["Dropbox-API-Arg"])
      raise "unexpected #{arg}" unless arg["path"] == id

      { body: body, headers: { "Dropbox-API-Result" => result.to_json } }
    })
  end

  describe Disk::Importer::Dropbox::ContentHash do
    it "matches Dropbox's published example once its block hashes are combined" do
      blocks = %w[2a846fa617c3361fc117e1c5c1e1838c336b6a5cef982c1a2d9bdf68f2f1992a
                  c68469027410ea393eba6551b9fa1e26db775f00eae70a0c3c129a0011a39cf9
                  7376192de020925ce6c5ef5a8a0405e931b0a9a8c75517aacd9ca24a8a56818b]
      expect(Digest::SHA256.hexdigest(blocks.map { |h| [h].pack("H*") }.join))
        .to eq("485291fa0ee50c016982abbfa943957bcd231aae0492ccbaa22c58e3997b35e0")
    end

    it "hashes 4 MiB blocks, and an empty file as the hash of nothing" do
      data = ("a" * ((4 * 1024 * 1024) + 3)).b
      expected = Digest::SHA256.hexdigest(Digest::SHA256.digest(data[0, 4 * 1024 * 1024]) + Digest::SHA256.digest("aaa"))
      expect(described_class.of_io(StringIO.new(data))).to eq(expected)
      expect(described_class.of_io(StringIO.new(""))).to eq(Digest::SHA256.hexdigest(""))
    end
  end

  it "imports a Dropbox across pages: content-hashed files, Paper as a page, exports and the unexportable" do
    transport.on(:post, "#{api}/files/list_folder", lambda { |call|
      expect(JSON.parse(call.body)).to include("path" => "", "recursive" => true)
      { body: { entries: [folder("id:f1", "/Clients"), file("id:a", "/Clients/brief.txt", body: "brief")],
                cursor: "c1", has_more: true } }
    })
    transport.on(:post, "#{api}/files/list_folder/continue", { body: { entries: [
      file("id:p", "/Plan.paper", is_downloadable: false, export_info: { export_as: "html", export_options: %w[html markdown] }),
      file("id:g", "/Clients/Budget.gsheet", is_downloadable: false, export_info: { export_as: "xlsx" }),
      file("id:z", "/Odd.web", is_downloadable: false)
    ], cursor: "c2", has_more: false } })
    downloads("id:a", "brief")
    transport.on(:post, "content.dropboxapi.com/2/files/export", lambda { |call|
      arg = JSON.parse(call.headers["Dropbox-API-Arg"])
      body = arg["export_format"] == "markdown" ? "# Plan\n\n- item\n" : xlsx
      { body: body, headers: { "Dropbox-API-Result" => { export_metadata: { size: body.bytesize } }.to_json } }
    })
    run_import(import)

    expect(import).to have_attributes(state: "done", cursor: "c2")
    clients = child(target, "Clients")
    expect(stored(child(clients, "brief.txt"))).to eq("brief")
    expect(Disk::Page.for(child(target, "Plan")).markdown).to eq("# Plan\n\n- item\n")
    expect(child(clients, "Budget.xlsx")).to be_present
    expect(item_for(import, "id:g").detail).to include("converted" => true, "hash_verified" => false)
    expect(item_for(import, "id:z")).to have_attributes(status: "skipped", reason: /neither a download nor an export/)
  end

  it "continues from the stored cursor on a re-run: renames by id and reports deletions by path" do
    transport.on(:post, "#{api}/files/list_folder", { body: { entries: [file("id:a", "/a.txt", body: "a"),
                                                                       file("id:b", "/b.txt", body: "b")],
                                                             cursor: "c1", has_more: false } })
    transport.on(:post, "content.dropboxapi.com/2/files/download", lambda { |call|
      { body: JSON.parse(call.headers["Dropbox-API-Arg"])["path"] == "id:a" ? "a" : "b" }
    })
    run_import(import)

    transport.on(:post, "#{api}/files/list_folder/continue", lambda { |call|
      expect(JSON.parse(call.body)).to eq("cursor" => "c1")
      { body: { entries: [{ ".tag" => "deleted", "name" => "a.txt", "path_lower" => "/a.txt" },
                          file("id:a", "/renamed.txt", body: "a"), { ".tag" => "deleted", "name" => "b.txt", "path_lower" => "/b.txt" }],
                cursor: "c2", has_more: false } }
    })
    again = Disk::Import.create!(import.attributes.except("id", "key", "created_at", "updated_at")
      .merge("state" => "running", "counts" => {}, "cursor" => import.cursor))
    run_import(again)
    expect(child(target, "renamed.txt").versions.count).to eq(1)
    expect(again.counts).to include("renamed" => 1, "deleted_at_source" => 1)
    expect(item_for(import, "id:b").detail).to include("deleted_at_source" => true)
    expect(item_for(import, "id:a").detail).not_to include("deleted_at_source")
    expect(child(target, "b.txt")).to be_present
  end

  it "lists everything again when the cursor was reset" do
    import.update!(cursor: "stale")
    transport.on(:post, "#{api}/files/list_folder/continue", { status: 409, body: { error_summary: "reset/..", error: { ".tag" => "reset" } } })
    transport.on(:post, "#{api}/files/list_folder", { body: { entries: [file("id:a", "/a.txt", body: "a")], cursor: "c9", has_more: false } })
    downloads("id:a", "a")
    run_import(import)
    expect(import).to have_attributes(state: "done", cursor: "c9")
    expect(child(target, "a.txt")).to be_present
  end

  it "fails a file whose content_hash differs, after one retry" do
    transport.on(:post, "#{api}/files/list_folder", { body: { entries: [file("id:a", "/a.txt", body: "right")], cursor: "c", has_more: false } })
    downloads("id:a", "wrong")
    run_import(import)
    expect(item_for(import, "id:a")).to have_attributes(status: "failed", reason: /hash/)
  end

  it "holds the tenant for Retry-After on a 429" do
    import.connection.update!(tenant: "dbid:1")
    transport.on(:post, "#{api}/files/list_folder", { status: 429, headers: { "Retry-After" => "15" }, body: { error_summary: "too_many_requests/" } })
    expect { run_import(import) }.to have_enqueued_job(Disk::ImportJob)
    expect(import.connection.reload.waiting_until).to be_within(5.seconds).of(15.seconds.from_now)
  end

  it "stops at the team's data transport cap with Dropbox's message, resumable" do
    transport.on(:post, "#{api}/files/list_folder", { body: { entries: [file("id:a", "/a.txt", body: "a")], cursor: "c", has_more: false } })
    transport.on(:post, "content.dropboxapi.com/2/files/download", { status: 403, body: {
      error_summary: "invalid_account_type/feature/.", error: { ".tag" => "invalid_account_type", "invalid_account_type" => { ".tag" => "feature" } },
      user_message: { locale: "en", text: "Your team has used all of its data transport API calls for the month." }
    } })
    run_import(import)
    expect(import).to have_attributes(state: "paused", pause_reason: "transfer_cap", error: /data transport API calls/)
    expect(import).to be_resumable
  end

  describe "a team" do
    let(:org_conn) { connection_for(owner, "dropbox", reach: "org", tenant: "dbtid:1") }

    it "lists active members' home folders and team folders" do
      transport.on(:post, "#{api}/team/members/list_v2", { body: { members: [
        { profile: { team_member_id: "dbmid:1", email: "mo@acme.test", status: { ".tag" => "active" }, name: { display_name: "Mo" } } },
        { profile: { team_member_id: "dbmid:2", email: "x@acme.test", status: { ".tag" => "suspended" } } }
      ], cursor: "m", has_more: false } })
      transport.on(:post, "#{api}/team/namespaces/list", { body: { namespaces: [
        { name: "Sales", namespace_id: "111", namespace_type: { ".tag" => "team_folder" } },
        { name: "Mo", namespace_id: "222", namespace_type: { ".tag" => "team_member_folder" } },
        { name: "Sales", namespace_id: "111", namespace_type: { ".tag" => "team_folder" } }
      ], cursor: "n", has_more: false } })
      spaces = Disk::Importer::Dropbox.new(Disk::Import.new(organization: org, membership: owner, connection: org_conn,
                                                            provider: "dropbox", space_kind: "shared")).spaces
      expect(spaces.map { |s| [s.id, s.kind, s.email] }).to eq([["member:dbmid:1", "member", "mo@acme.test"], ["shared:111", "shared", nil]])
      expect(transport.calls.map { |c| c.headers.keys.grep(/Select/) }.flatten).to be_empty
    end

    it "imports a team folder into a share as the admin, in the folder's namespace, with its members" do
      allow(Disk::ImportSource).to receive(:member_index).and_return("mo@acme.test" => member)
      share = make_share("Sales")
      import = Disk::Import.create!(organization: org, membership: owner, owner: owner, connection: org_conn, provider: "dropbox",
                                    space_kind: "shared", space_id: "shared:111", space_name: "Sales", share: share,
                                    target_node: share.root_node, state: "running")
      transport.on(:post, "#{api}/team/token/get_authenticated_admin", { body: { admin_profile: { team_member_id: "dbmid:admin" } } })
      transport.on(:post, "#{api}/sharing/list_folder_members", lambda { |call|
        expect(JSON.parse(call.body)).to include("shared_folder_id" => "111")
        { body: { users: [{ access_type: { ".tag" => "editor" }, user: { email: "mo@acme.test" } }],
                  groups: [{ access_type: { ".tag" => "viewer" }, group: { group_name: "Everyone at Acme" } }], invitees: [] } }
      })
      transport.on(:post, "#{api}/files/list_folder", { body: { entries: [file("id:q", "/q3.txt", body: "q")], cursor: "c", has_more: false } })
      downloads("id:q", "q")
      run_import(import)

      expect(stored(child(share.root_node, "q3.txt"))).to eq("q")
      expect(share.share_memberships.pluck(:membership_id, :role)).to eq([[member.id, "edit"]])
      expect(import.report).to eq("unresolved_groups" => { "Everyone at Acme" => 1 })
      listing = transport.requests("/files/list_folder").first
      expect(listing.headers).to include("Dropbox-API-Select-Admin" => "dbmid:admin")
      expect(JSON.parse(listing.headers["Dropbox-API-Path-Root"])).to eq(".tag" => "namespace_id", "namespace_id" => "111")
    end

    it "reads a member's home folder as that member, without the team folders mounted in it" do
      import = personal_import(member, "dropbox", connection: org_conn)
      import.update!(space_kind: "member", space_id: "member:dbmid:1")
      transport.on(:post, "#{api}/files/list_folder", lambda { |call|
        expect(call.headers["Dropbox-API-Select-User"]).to eq("dbmid:1")
        expect(JSON.parse(call.body)).to include("include_mounted_folders" => false)
        { body: { entries: [], cursor: "c", has_more: false } }
      })
      run_import(import)
      expect(import).to be_done
    end
  end

  it "learns the account and tenant when connecting" do
    transport.on(:post, "#{api}/users/get_current_account", { body: { email: "mo@acme.test" } })
    conn = Disk::ImportConnection.new(reach: "member")
    described_class.identify(conn, "access_token" => "t", "account_id" => "dbid:7")
    expect(conn).to have_attributes(account_email: "mo@acme.test", tenant: "dbid:7")
  end
end
