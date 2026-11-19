require "rails_helper"

# Spec F2 (abandoned uploads released within a day, trash purged after 30
# days with bytes back to the quota, versions kept 180 days) and the
# reconcile step of docs/plans/disk-build.md section 8.
RSpec.describe "Disk jobs" do
  include_context "disk org"

  let(:share) { make_share("Marketing") }
  let(:root) { share.root_node }

  def reserve(size, name: "a.pdf")
    Disk::UploadOps.new(owner).reserve(size: size, parent_key: root.key, name: name).first
  end

  describe Disk::ExpireUploadsJob do
    it "releases expired reservations and their parts, and leaves live ones" do
      stale = reserve(10)
      live = reserve(5, name: "b.pdf")
      stale.update!(expires_at: 1.minute.ago)
      expect(described_class.perform_now).to eq(1)
      expect(stale.reload.state).to eq("aborted")
      expect(live.reload.state).to eq("reserved")
      expect(org.reload.disk_bytes_reserved).to eq(5)
      expect(storage.multiparts.keys).to eq([live.multipart_upload_id])
    end
  end

  describe Disk::PurgeTrashJob do
    it "purges items trashed over 30 days ago and shares past purge_at, freeing their bytes" do
      old = make_stored_file(root, "old.pdf", size: 10)
      recent = make_stored_file(root, "recent.pdf", size: 3)
      ops = Disk::NodeOps.new(owner)
      ops.trash(old)
      ops.trash(recent)
      old.update!(trashed_at: 31.days.ago)
      gone = make_share("Gone")
      make_stored_file(gone.root_node, "g.pdf", size: 4)
      gone.update!(trashed_at: 31.days.ago, purge_at: 1.day.ago)

      expect(described_class.perform_now).to eq(nodes: 1, shares: 1)
      expect(Disk::Node.exists?(old.id)).to be(false)
      expect(Disk::Node.exists?(recent.id)).to be(true)
      expect(Disk::Share.exists?(gone.id)).to be(false)
      expect(org.reload.disk_bytes_used).to eq(3)
    end
  end

  describe Disk::ExpireVersionsJob do
    it "deletes replaced versions past 180 days, never a current one" do
      file = make_stored_file(root, "a.pdf", size: 30, versions: [10, 20])
      file.versions.find_by!(number: 1).update!(expires_at: 1.day.ago)
      file.current_version.update!(expires_at: 1.day.ago) # defensive: current never expires
      expect(described_class.perform_now).to eq(1)
      expect(file.versions.pluck(:number)).to contain_exactly(2, 3)
      expect(org.reload.disk_bytes_used).to eq(50)
    end

    it "deletes page history past 180 days but keeps each page's newest entry" do
      page = make_folder(root, "Notes").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
      old = Array.new(3) do |i|
        Disk::PageVersion.create!(organization: org, node: page, revision: i + 1, markdown: "v#{i}",
                                  updated_at: 200.days.ago)
      end
      expect(described_class.perform_now).to eq(2)
      expect(Disk::PageVersion.pluck(:id)).to eq([old.last.id])
    end
  end

  describe Disk::ReconcileStorageJob do
    it "finishes a stuck completion whose object exists and aborts one whose object is gone" do
      done = reserve(10)
      Disk::UploadPart.create!(organization: org, upload: done, number: 1, issued_at: Time.current)
      storage.put_part(done.multipart_upload_id, 1, 10)
      storage.complete_multipart(done.storage_key, done.multipart_upload_id, storage.parts(nil, done.multipart_upload_id))
      lost = reserve(5, name: "b.pdf")
      storage.abort_multipart(nil, lost.multipart_upload_id)
      Disk::Upload.where(id: [done.id, lost.id]).update_all(state: "completing", updated_at: 2.hours.ago)

      report = described_class.perform_now
      expect(report).to include(finished: 1, aborted: 1)
      expect(done.reload.state).to eq("done")
      expect(lost.reload.state).to eq("aborted")
      expect(org.reload).to have_attributes(disk_bytes_used: 10, disk_bytes_reserved: 0)
      expect(report[:quota_drift]).to eq({})
    end

    it "reports old objects and open multipart uploads nothing points at, without deleting them" do
      make_stored_file(root, "a.pdf", size: 1)
      storage.put("#{org.key}/stray", 4, at: 2.days.ago)
      storage.create_multipart("#{org.key}/ghost")
      storage.multiparts.each_value { |mp| mp[:at] = 2.days.ago }
      org.update!(disk_bytes_used: 99)

      report = described_class.perform_now
      expect(report[:orphan_objects]).to eq(["#{org.key}/stray"])
      expect(report[:orphan_multiparts]).to eq(["#{org.key}/ghost"])
      expect(report[:quota_drift]).to eq(org.key => { used: [99, 1], reserved: [0, 0] })
      expect(storage.size("#{org.key}/stray")).to eq(4)
    end
  end
end
