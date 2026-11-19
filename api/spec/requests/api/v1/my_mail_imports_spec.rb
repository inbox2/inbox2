require "rails_helper"

# A person's own .mbox from Disk into their own mailbox (Settings › Account,
# docs/plans/mail-import.md "Takeout"). The parser itself is in
# spec/services/mail_importer_spec.rb.
RSpec.describe "My mail imports", type: :request do
  include ActiveJob::TestHelper
  include_context "disk org"

  let(:domain) { org.default_domain }
  let!(:mailbox) { create(:mailbox, membership: member, domain: domain, local_part: "mo") }
  let(:path) { "/api/v1/orgs/#{org.key}/my-mail-imports" }
  let(:mbox) do
    <<~MBOX.gsub("\n", "\r\n")
      From 1@xxx Mon Jan 01 00:00:00 +0000 2024
      X-GM-THRID: 111
      X-Gmail-Labels: Inbox,Unread
      Message-ID: <one@test>
      From: Ana <ana@else.test>
      To: mo@#{domain.name}
      Subject: Hello
      Date: Mon, 01 Jan 2024 00:00:00 +0000

      Hi Mo
      From 2@xxx Mon Jan 02 00:00:00 +0000 2024
      X-GM-THRID: 222
      X-Gmail-Labels: Spam
      Message-ID: <two@test>
      From: spam@else.test
      To: mo@#{domain.name}
      Subject: Win

      Junk
    MBOX
  end

  def mbox_on_c(membership, body = mbox)
    node = make_folder(c_root(membership), "All mail.mbox").tap { |n| n.update!(kind: Disk::Node::KIND_FILE, mime: "application/mbox") }
    key = Disk::Storage.new_key(node.organization)
    storage.put_bytes(key, body)
    node.add_version!(author: membership, storage_key: key, size_bytes: body.bytesize)
    node.reload
  end

  it "lists only my mailboxes, then imports my .mbox from Disk into my private history" do
    create(:mailbox, membership: other, domain: domain, local_part: "ola")
    get path, headers: auth_headers(member_user)
    expect(response.parsed_body["mailboxes"].map { |m| m["email_address"] }).to eq(["mo@#{domain.name}"])

    node = mbox_on_c(member)
    perform_enqueued_jobs do
      post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json
    end

    expect(response).to have_http_status(:accepted)
    import = MailImport.sole
    expect(import).to have_attributes(state: "done", source_node: node, owner: member, provider: MailImport::TAKEOUT)
    expect(import.counts).to include("imported" => 1, "skipped" => 1)
    conv = org.conversations.sole
    expect(conv).to have_attributes(private: true, subject: "Hello", read: false)
    expect(org.conversations.visible_to(owner)).to be_empty

    get path, headers: auth_headers(member_user)
    expect(response.parsed_body["imports"].map { |i| [i["state"], i["source_email"]] }).to eq([["done", "mo@#{domain.name}"]])
  end

  it "starts over on a new file, counting mail already there as duplicate" do
    node = mbox_on_c(member)
    perform_enqueued_jobs { post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json }
    perform_enqueued_jobs { post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json }

    expect(MailImport.sole.counts).to include("duplicate" => 1)
    expect(MailImport.sole.counts["imported"].to_i).to eq(0)
    expect(org.conversations.count).to eq(1)
  end

  it "resumes from Disk, pauses when the file has no content, and refuses once the file is deleted" do
    node = mbox_on_c(member)
    import = MailImport.create!(organization: org, membership: member, owner: member, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, source_node: node, state: MailImport::STATE_PAUSED)
    perform_enqueued_jobs { post "#{path}/#{import.key}/resume", headers: auth_headers(member_user), as: :json }
    expect(import.reload).to have_attributes(state: "done")

    node.update_columns(current_version_id: nil)
    import.update!(state: MailImport::STATE_PAUSED)
    perform_enqueued_jobs { post "#{path}/#{import.key}/resume", headers: auth_headers(member_user), as: :json }
    expect(import.reload).to have_attributes(state: "paused", error: "The .mbox file is no longer on Disk.")

    import.update_columns(source_node_id: nil) # the FK's on_delete: :nullify, when the file is purged
    post "#{path}/#{import.key}/resume", headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "starts over at 0 when the file was replaced since the cursor was saved" do
    node = mbox_on_c(member)
    old = node.current_version
    import = MailImport.create!(organization: org, membership: member, owner: member, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, source_node: node, state: MailImport::STATE_PAUSED,
                                cursor: "#{old.id}:#{mbox.bytesize}")
    key = Disk::Storage.new_key(node.organization)
    storage.put_bytes(key, mbox)
    node.add_version!(author: member, storage_key: key, size_bytes: mbox.bytesize)

    perform_enqueued_jobs { post "#{path}/#{import.key}/resume", headers: auth_headers(member_user), as: :json }

    expect(import.reload.counts).to include("imported" => 1)
    expect(import.cursor).to eq("#{node.reload.current_version_id}:#{mbox.bytesize}")
  end

  it "reports how far through the file a run is, and zero once the file was replaced" do
    node = mbox_on_c(member)
    import = MailImport.create!(organization: org, membership: member, owner: member, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, source_node: node, state: MailImport::STATE_PAUSED,
                                cursor: "#{node.current_version_id}:#{mbox.bytesize / 2}")
    get path, headers: auth_headers(member_user)
    expect(response.parsed_body["imports"].sole["progress"]).to be_within(0.01).of(0.5)

    import.update!(cursor: "0:#{mbox.bytesize}")
    get path, headers: auth_headers(member_user)
    expect(response.parsed_body["imports"].sole["progress"]).to eq(0.0)
  end

  it "keeps a new owner's mail out of the previous owner's threads when the address changed hands" do
    node = mbox_on_c(member)
    old_conv = create(:conversation, organization: org, domain: domain, private: true)
    import = MailImport.create!(organization: org, membership: other, owner: other, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, state: MailImport::STATE_DONE)
    import.threads.create!(source_thread_id: "111", conversation: old_conv)

    perform_enqueued_jobs { post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json }

    expect(import.reload.owner).to eq(member)
    expect(old_conv.messages).to be_empty
    expect(org.conversations.where.not(id: old_conv.id).sole.subject).to eq("Hello")
  end

  it "refuses to resume, and the job refuses to read, a file I can no longer see" do
    theirs = mbox_on_c(other)
    import = MailImport.create!(organization: org, membership: member, owner: member, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, source_node: theirs, state: MailImport::STATE_PAUSED)

    post "#{path}/#{import.key}/resume", headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)

    import.update!(state: MailImport::STATE_QUEUED)
    MailImportJob.perform_now(import.id)
    expect(import.reload).to have_attributes(state: "paused", error: "The .mbox file is no longer on Disk.")
    expect(org.conversations).to be_empty
  end

  it "refuses a new file while a run is queued or running, even a stale one, until it is stopped" do
    node = mbox_on_c(member)
    import = MailImport.create!(organization: org, membership: member, owner: member, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, source_node: node, state: MailImport::STATE_RUNNING,
                                cursor: "#{node.current_version_id}:10")
    import.update_column(:updated_at, 2.days.ago)
    post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:conflict)
    expect(import.reload.cursor).to eq("#{node.current_version_id}:10")

    delete "#{path}/#{import.key}", headers: auth_headers(member_user)
    post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:accepted)
  end

  it "keeps a stopped job that is still busy from writing over the run started after it" do
    node = mbox_on_c(member)
    perform_enqueued_jobs { post path, params: { mailbox_id: mailbox.key, node_id: node.key }, headers: auth_headers(member_user), as: :json }
    import = MailImport.sole
    old = MailImport.find(import.id).tap { |i| i.run -= 1 } # the previous run's job, still holding its row
    import.update!(cursor: "#{node.current_version_id}:1", counts: { "seen" => 7 })

    MailImporter.for(old).run

    expect(import.reload).to have_attributes(cursor: "#{node.current_version_id}:1", counts: { "seen" => 7 }, state: "done")
  end

  it "refuses someone else's mailbox, a file I can't see, and a folder" do
    ola_box = create(:mailbox, membership: other, domain: domain, local_part: "ola")
    mine = mbox_on_c(member)
    theirs = mbox_on_c(other)

    post path, params: { mailbox_id: ola_box.key, node_id: mine.key }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:not_found)
    post path, params: { mailbox_id: mailbox.key, node_id: theirs.key }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:not_found)
    post path, params: { mailbox_id: mailbox.key, node_id: c_root(member).key }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(MailImport.count).to eq(0)
  end

  it "keeps my imports from other members" do
    import = MailImport.create!(organization: org, membership: member, owner: member, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: mailbox.email_address, state: MailImport::STATE_DONE)

    get path, headers: auth_headers(other_user)
    expect(response.parsed_body["imports"]).to eq([])
    delete "#{path}/#{import.key}", headers: auth_headers(other_user)
    expect(response).to have_http_status(:not_found)
  end
end
