require "rails_helper"

RSpec.describe Disk::Node do
  include_context "disk org"

  let(:root) { make_share("Marketing").root_node }

  def folder(name, keep_both: false, parent: root)
    described_class.new(organization: org, share_id: parent.share_id, parent: parent,
                        kind: described_class::KIND_FOLDER, name: name).save_with_unique_name!(keep_both: keep_both)
  end

  describe "name uniqueness" do
    it "refuses a case-insensitive clash in the same folder" do
      folder("Launch")
      expect { folder("launch") }.to raise_error(described_class::NameTaken)
    end

    it "keeps both with a numbered suffix before the extension" do
      make_file(root, "a.pdf", mime: "application/pdf")
      make_file(root, "a (1).pdf", mime: "application/pdf")
      node = described_class.new(organization: org, share_id: root.share_id, parent: root,
                                 kind: described_class::KIND_FILE, name: "a.pdf", mime: "application/pdf")
      node.save_with_unique_name!(keep_both: true)
      expect(node.name).to eq("a (2).pdf")
    end

    it "keeps both for folders without treating dots as an extension" do
      folder("v1.2")
      expect(folder("v1.2", keep_both: true).name).to eq("v1.2 (1)")
    end

    it "retries when a racing writer takes the suffix after the check" do
      folder("Plans")
      node = described_class.new(organization: org, share_id: root.share_id, parent: root,
                                 kind: described_class::KIND_FOLDER, name: "Plans")
      # The other writer lands "Plans (1)" between our check and our insert.
      allow(node).to receive(:sibling_name_taken?).and_return(true, false)
      folder("Plans (1)")
      node.save_with_unique_name!(keep_both: true)
      expect(node.name).to eq("Plans (2)")
    end

    it "lets a trashed name be reused" do
      folder("Old").update!(trashed_at: Time.current, trash_root: true)
      expect { folder("Old") }.not_to raise_error
    end

    it "allows the same name in different folders" do
      a = folder("A")
      folder("Notes", parent: a)
      expect { folder("Notes") }.not_to raise_error
    end
  end

  describe "validation and constraints" do
    it "rejects slashes and blank names" do
      expect { folder("a/b") }.to raise_error(ActiveRecord::RecordInvalid)
      expect { folder("a\\b") }.to raise_error(ActiveRecord::RecordInvalid)
      expect { folder("  ") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "enforces sealed identity in the database" do
      node = folder("Plain")
      expect { node.update_columns(sealed: true) }.to raise_error(ActiveRecord::StatementInvalid, /sealed_identity/)
    end

    it "allows one root per share" do
      expect do
        described_class.create!(organization: org, share_id: root.share_id, kind: described_class::KIND_FOLDER)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  it ".suffixed handles dotfiles" do
    expect(described_class.suffixed(".env", 1)).to eq(".env (1)")
  end

  it ".paths_for returns each chain from the root" do
    a = folder("A")
    b = folder("B", parent: a)
    expect(described_class.paths_for([b])[b.id]).to eq([root, a, b])
  end
end

RSpec.describe Organization do
  include_context "disk org"

  it "deletes its Disk rows when the organization is destroyed" do
    share = make_share("Marketing")
    folder = make_folder(share.root_node, "Launch")
    make_folder(c_root(member), "Mine")
    Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "view")
    Disk::Grant.create!(organization: org, node: folder, membership: other, role: "view")
    Disk::Star.create!(organization: org, node: folder, membership: member)
    Disk::Event.record!(Disk::Event::ACTION_CREATED, actor: owner, node: folder, name: "Launch")

    org.destroy!
    [Disk::Share, Disk::Node, Disk::ShareMembership, Disk::Grant, Disk::Star, Disk::Event].each do |model|
      expect(model.where(organization_id: org.id)).to be_empty
    end
  end
end
