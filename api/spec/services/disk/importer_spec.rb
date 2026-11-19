require "rails_helper"

# The importer base (spec F10) against an in-memory source: tree building,
# re-runs, the report, quota pause and resume, cancel, hash checks, sharing.
RSpec.describe Disk::Importer do
  include_context "disk import"

  # A source whose items, bytes and sharing the examples set. The cursor is
  # the index of the next item; the final cursor "end" makes the next run
  # read `changes` instead.
  let(:adapter_class) do
    Class.new(Disk::Importer) do
      class << self
        attr_accessor :items, :changes, :bytes, :corrupt, :perms, :folders, :on_item
      end

      def root_id = "root"

      def each_item(cursor)
        list = cursor == "end" ? self.class.changes.to_a : self.class.items
        start = cursor == "end" ? 0 : cursor.to_i
        list.each_with_index.drop(start).each do |item, i|
          self.class.on_item&.call(i)
          yield item.dup.tap { |it| it.cursor = cursor == "end" ? "end" : (i + 1).to_s }
        end
        "end"
      end

      def folder(id) = self.class.folders.to_h[id]

      def download(item)
        body = self.class.bytes.fetch(item.id)
        body = "#{body}!" if self.class.corrupt.to_a.shift
        tempfile.tap { |f| f.write(body) && f.rewind }
      end

      def export(item, _format) = download(item)

      def verify(item, file)
        return export_complete?(file, item.ext) if item.kind != :file

        Digest::MD5.file(file.path).hexdigest == item.hash
      end

      def permissions(item) = self.class.perms.to_h.fetch(item.id, [])
    end
  end

  before do
    allow(Disk::ImportSource).to receive(:adapter).and_return(adapter_class)
    adapter_class.items = []
    adapter_class.changes = []
    adapter_class.bytes = {}
    adapter_class.corrupt = []
    adapter_class.perms = {}
    adapter_class.folders = {}
    adapter_class.on_item = nil
  end

  def item(id, name, kind: :file, parent: "root", body: nil, modified: "2026-01-01T00:00:00Z", **attrs)
    adapter_class.bytes[id] = body if body
    hash = body && Digest::MD5.hexdigest(body)
    Disk::Importer::Item.new(id: id, name: name, kind: kind, parent_id: parent, modified_at: Time.zone.parse(modified),
                             size: body&.bytesize, hash: hash, **attrs)
  end

  def xlsx_bytes = "PK\x03\x04#{'x' * 20}[Content_Types].xml".b

  let(:import) { personal_import(member, "google") }
  let(:target) { import.target_node }

  def child(parent, name) = Disk::Node.live.find_by!(parent_id: parent.id, name: name)

  it "recreates the folder tree, files, converted files and pages, and reports conversions" do
    adapter_class.items = [
      item("f1", "Clients", kind: :folder),
      item("a", "brief.pdf", parent: "f1", body: "%PDF-1"),
      item("s", "Budget", kind: :export, format: "xlsx", ext: "xlsx", parent: "f1", body: xlsx_bytes),
      item("d", "Notes", kind: :page, format: "markdown", ext: "md", body: "# Notes\n\n- one\n- two\n"),
      item("n", "Notebook", skip: "OneNote notebooks have no file to download")
    ]
    run_import(import)

    expect(import).to be_done
    clients = child(target, "Clients")
    expect(stored(child(clients, "brief.pdf"))).to eq("%PDF-1")
    budget = child(clients, "Budget.xlsx")
    expect(budget.mime).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    page = child(target, "Notes")
    expect(page).to be_page
    expect(Disk::Page.for(page).markdown).to include("- one")
    expect(import.counts).to include("folders" => 1, "files" => 2, "pages" => 1, "converted" => 2, "skipped" => 1)
    expect(item_for(import, "a").detail).to include("hash_verified" => true)
    expect(item_for(import, "s").detail).to include("converted" => true, "hash_verified" => false, "format" => "xlsx")
    expect(item_for(import, "n")).to have_attributes(status: "skipped", reason: /OneNote/)
    expect(member_user.personal_organization.reload.disk_bytes_used).to eq(6 + xlsx_bytes.bytesize)
    expect(Disk::Event.where(node: child(clients, "brief.pdf"), action: "uploaded")).to exist
  end

  it "imports a parent folder first when a child arrives before it" do
    adapter_class.items = [item("a", "deep.txt", parent: "f2", body: "deep")]
    adapter_class.folders = { "f2" => item("f2", "Later", kind: :folder, parent: "f1"),
                              "f1" => item("f1", "Top", kind: :folder) }
    run_import(import)
    expect(stored(child(child(child(target, "Top"), "Later"), "deep.txt"))).to eq("deep")
  end

  it "skips an item whose parent is outside the space" do
    adapter_class.items = [item("a", "theirs.txt", parent: "elsewhere", body: "x")]
    run_import(import)
    expect(item_for(import, "a")).to have_attributes(status: "skipped", reason: "Not in this drive")
  end

  it "keeps names that differ only in case, renames illegal ones, and reports both" do
    adapter_class.items = [item("a", "Report.pdf", body: "A"), item("b", "report.pdf", body: "B"),
                           item("c", "Q1/Q2.txt", body: "C")]
    run_import(import)
    expect(child(target, "Report.pdf")).to be_present
    expect(child(target, "report (1).pdf")).to be_present
    expect(item_for(import, "b").detail).to include("renamed_from" => "report.pdf", "renamed_to" => "report (1).pdf",
                                                    "rename_reason" => Disk::Importer::RENAME_CLASH,
                                                    "clashed_with" => "Report.pdf")
    expect(item_for(import, "c").detail).to include("renamed_to" => "Q1_Q2.txt",
                                                    "rename_reason" => Disk::Importer::RENAME_ILLEGAL)
  end

  describe "a second run" do
    before do
      adapter_class.items = [item("f1", "A", kind: :folder), item("f2", "B", kind: :folder),
                             item("x", "x.txt", parent: "f1", body: "one"), item("y", "y.txt", body: "why"),
                             item("z", "z.txt", body: "zed")]
      run_import(import)
    end

    def rerun(changes)
      adapter_class.changes = changes
      again = Disk::Import.create!(import.attributes.except("id", "key", "created_at", "updated_at")
        .merge("state" => "running", "counts" => {}, "report" => {}, "cursor" => import.cursor))
      run_import(again)
    end

    it "updates the same nodes: new versions, renames and moves, deletions reported and kept" do
      x = child(child(target, "A"), "x.txt")
      again = rerun([item("x", "x.txt", parent: "f2", body: "two", modified: "2026-02-01T00:00:00Z"),
                     item("y", "why.txt", body: "why"),
                     Disk::Importer::Item.new(id: "z", deleted: true)])

      expect(again).to be_done
      expect(x.reload.parent).to eq(child(target, "B"))
      expect(x.versions.count).to eq(2)
      expect(stored(x)).to eq("two")
      expect(child(target, "why.txt").versions.count).to eq(1)
      expect(child(target, "z.txt")).to be_present
      expect(again.counts).to include("updated" => 1, "moved" => 1, "renamed" => 1, "deleted_at_source" => 1, "unchanged" => 1)
      expect(Disk::Node.live.where(parent_id: target.id, kind: "file").count).to eq(2)
      expect(item_for(import, "z").detail).to include("deleted_at_source" => true)
    end

    it "does not duplicate when the whole listing comes again" do
      adapter_class.changes = adapter_class.items
      again = rerun(adapter_class.items)
      expect(again.counts).to include("unchanged" => 3)
      expect(Disk::Node.live.where(organization_id: member_user.personal_organization.id, kind: "file").count).to eq(3)
      expect(Disk::Version.count).to eq(3)
    end
  end

  it "retries a download whose hash differs and fails it, storing nothing, when it differs again" do
    adapter_class.items = [item("a", "ok.txt", body: "fine"), item("b", "bad.txt", body: "flaky")]
    adapter_class.corrupt = [false, true, true]
    run_import(import)
    expect(item_for(import, "b")).to have_attributes(status: "failed", reason: /hash/)
    expect(Disk::Node.live.find_by(parent_id: target.id, name: "bad.txt")).to be_nil
    expect(member_user.personal_organization.reload.disk_bytes_used).to eq(4)
  end

  it "accepts a download that matches on the retry" do
    adapter_class.items = [item("a", "once.txt", body: "flaky")]
    adapter_class.corrupt = [true, false]
    run_import(import)
    expect(stored(child(target, "once.txt"))).to eq("flaky")
  end

  it "fails a converted item that is not a complete export" do
    adapter_class.items = [item("s", "Sheet", kind: :export, format: "xlsx", ext: "xlsx", body: "<html>quota</html>")]
    run_import(import)
    expect(item_for(import, "s")).to have_attributes(status: "failed", reason: /not a valid xlsx/)
  end

  it "pauses at the quota with a message and resumes where it stopped once space is freed" do
    member_user.personal_organization.update!(disk_quota_override_gb: 0) # the C:\ draws on the person's own allowance
    adapter_class.items = [item("a", "a.txt", body: "aaaa"), item("b", "b.txt", body: "bbbb")]
    run_import(import)
    expect(import).to have_attributes(state: "paused", pause_reason: "quota", error: /Free some space/)
    expect(Disk::Node.live.where(parent_id: target.id)).to be_empty
    expect(member_user.personal_organization.reload.disk_bytes_reserved).to eq(0)

    member_user.personal_organization.update!(disk_quota_override_gb: 1)
    import.update!(state: "queued")
    Disk::ImportJob.perform_now(import.id)
    expect(import.reload).to be_done
    expect(Disk::Node.live.where(parent_id: target.id).pluck(:name)).to contain_exactly("a.txt", "b.txt")
  end

  it "stops at the next item once cancelled and keeps what arrived" do
    adapter_class.items = [item("a", "a.txt", body: "a"), item("b", "b.txt", body: "b"), item("c", "c.txt", body: "c")]
    adapter_class.on_item = ->(i) { Disk::Import.where(id: import.id).update_all(state: "cancelled") if i == 1 }
    run_import(import)
    expect(import).to be_cancelled
    expect(Disk::Node.live.where(parent_id: target.id).pluck(:name)).to eq(["a.txt"])
  end

  it "shares with members at the mapped role and reports outsiders, groups and public links" do
    allow(Disk::ImportSource).to receive(:member_index).and_return("ola@acme.test" => other, "mo@acme.test" => member)
    adapter_class.items = [item("f1", "Shared", kind: :folder, shared: true)]
    adapter_class.perms = { "f1" => [
      Disk::Importer::Perm.new(type: :user, email: "Ola@acme.test", role: "writer"),
      Disk::Importer::Perm.new(type: :user, email: "mo@acme.test", role: "owner"),
      Disk::Importer::Perm.new(type: :user, email: "guest@else.test", role: "reader"),
      Disk::Importer::Perm.new(type: :group, name: "sales@acme.test", role: "reader"),
      Disk::Importer::Perm.new(type: :link, role: "reader")
    ] }
    run_import(import)
    folder = child(target, "Shared")
    expect(folder.grants.map { |g| [g.membership_id, g.role] }).to eq([[other.id, "edit"]])
    expect(import.report).to eq("unmatched_people" => { "guest@else.test" => 1 }, "unresolved_groups" => { "sales@acme.test" => 1 })
    expect(item_for(import, "f1").detail).to include("public_link" => true)
  end

  it "holds every import of the tenant on a throttle response and schedules itself for then" do
    adapter_class.class_eval do
      def download(_item)
        f = tempfile
        request(:get, "https://source.test/file", io: f)
        f
      end

      def fetch_token = ["t", 3600]
    end
    transport.on(:get, "source.test/file", { status: 429, headers: { "Retry-After" => "120" } })
    import.connection.update!(tenant: "acme.test")
    sibling = connection_for(owner, "google", tenant: "acme.test")
    adapter_class.items = [item("a", "a.txt", body: "a")]

    expect { run_import(import) }.to have_enqueued_job(Disk::ImportJob).with(import.id)
    expect(import).to be_queued
    expect(sibling.reload.waiting_until).to be_within(5.seconds).of(120.seconds.from_now)
    expect(transport.calls.size).to eq(1)
  end
end
