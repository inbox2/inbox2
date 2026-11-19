require "rails_helper"
require "rbnacl"
require "mail"

# docs/plans/mail-import.md: Gmail and Graph against hand-built fixtures, the
# quiet writer, private visibility, Message-ID dedupe across owners, re-runs.
RSpec.describe MailImporter do
  include ActiveJob::TestHelper

  let(:transport) { FakeImportTransport.new }
  let(:owner_user) { create(:user) }
  let(:org) { create(:organization, owner: owner_user, domain: "lalaaji.test") }
  let(:domain) { org.default_domain }
  let!(:admin) { create(:membership, user: owner_user, organization: org, role: "owner") }
  let!(:ana) { create(:membership, organization: org, role: "member") }
  let!(:bob) { create(:membership, organization: org, role: "member") }
  let(:uploads) { [] }

  around do |example|
    keys = %w[DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT DISK_IMPORT_MICROSOFT_CLIENT_ID DISK_IMPORT_MICROSOFT_CLIENT_SECRET]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV["DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT"] = { client_email: "sa@x.iam.gserviceaccount.com",
                                                  private_key: OpenSSL::PKey::RSA.new(2048).to_pem }.to_json
    ENV["DISK_IMPORT_MICROSOFT_CLIENT_ID"] = "ms-client"
    ENV["DISK_IMPORT_MICROSOFT_CLIENT_SECRET"] = "ms-secret"
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before do
    Disk::Importer.transport = transport
    storage = instance_double(S3StorageService)
    allow(storage).to receive(:upload) { |data, **| uploads << data.b; "att/#{uploads.size}" }
    allow(S3StorageService).to receive(:new).and_return(storage)
    transport.on(:post, "oauth2.googleapis.com/token", { body: { access_token: "delegated", expires_in: 3600 } })
    transport.on(:get, "/users/me/labels", { body: { labels: [] } })
  end
  after { Disk::Importer.transport = nil }

  def connection(provider)
    Disk::ImportConnection.find_or_create_by!(organization: org, membership: admin, provider: provider,
                                              reach: Disk::ImportConnection::REACH_ORG) do |c|
      c.assign_attributes(account_email: "boss@lalaaji.test", tenant: "tenant-1")
    end
  end

  def import_for(member, provider, email, cursor: nil)
    MailImport.create!(organization: org, membership: admin, owner: member, domain: domain, connection: connection(provider),
                       provider: provider, source_email: email, state: MailImport::STATE_RUNNING, cursor: cursor)
  end

  def run(import)
    MailImporter.for(import).run
    import.reload
  end

  def mime(id, subject: "Quarterly figures", from: "Partner <p@ext.test>", to: "ana@lalaaji.test", date: "Mon, 1 Sep 2025 10:00:00 +0000",
           reply_to: nil, attachment: nil)
    m = Mail.new
    m.message_id = "<#{id}@ext.test>"
    m.subject = subject
    m.from = from
    m.to = to
    m.date = date
    m.in_reply_to = "<#{reply_to}@ext.test>" if reply_to
    m.body = "Body of #{id}"
    m.add_file(filename: attachment[0], content: attachment[1]) if attachment
    m.to_s
  end

  def gmail(id, raw, labels:, thread: "t1")
    { body: { id: id, threadId: thread, labelIds: labels, raw: Base64.urlsafe_encode64(raw) } }
  end

  def conversation_of(id) = Message.find_by!(message_id_header: "<#{id}@ext.test>").conversation

  describe MailImporter::Takeout do
    let(:import) do
      MailImport.create!(organization: org, membership: ana, owner: ana, domain: domain, provider: MailImport::TAKEOUT,
                         source_email: "ana@lalaaji.test", state: MailImport::STATE_RUNNING)
    end
    let(:mbox) { Tempfile.new(["takeout", ".mbox"]).tap(&:binmode) }

    # Gmail's Takeout form: a "From " line, its headers first, CRLF lines, body "From " lines quoted.
    def entry(raw, labels:, thread: "111")
      "From 1881225503451928284@xxx Sat Nov 07 18:34:06 +0000 2026\r\n" \
        "X-GM-THRID: #{thread}\r\nX-Gmail-Labels: #{labels}\r\n#{raw.gsub(/^From /, ">From ")}\r\n"
    end

    def feed(*entries)
      mbox.write(entries.join)
      mbox.flush
      MailImporter::Takeout.new(import, mbox.path).run
      import.reload
    end

    it "imports the export by its Gmail headers: thread, folder, read state, labels; skips spam and trash" do
      first = mime("t1", attachment: ["q3.txt", "figures"]).sub("Body of t1", "Body of t1\r\nFrom the desk of Partner")
      feed(entry(first, labels: 'Inbox,Unread,Starred, "Clients, Acme",Category Updates,Important'),
           entry(mime("t2", from: "ana@lalaaji.test", to: "p@ext.test", reply_to: "t1",
                            date: "Tue, 2 Sep 2025 09:00:00 +0000"), labels: "Sent,Opened"),
           entry(mime("t3", subject: "Win big"), labels: "Spam,Unread", thread: "999"),
           entry(mime("t4", subject: "Old"), labels: "Trash", thread: "998"))

      expect(import).to be_done
      expect(import.counts).to include("seen" => 4, "imported" => 2, "skipped" => 2)
      expect(import.cursor.to_i).to eq(File.size(mbox.path))
      conv = conversation_of("t1")
      expect(conv).to have_attributes(private: true, status: "open", read: false, messages_count: 2)
      expect(conv.messages.order(:created_at).map(&:is_inbound)).to eq([true, false])
      expect(conv.messages.order(:created_at).first.body_plain).to include("From the desk of Partner")
      expect(uploads).to eq(["figures"])
      expect(conv.tags.map(&:name)).to contain_exactly("Clients, Acme", "Starred")
      expect(Message.where(message_id_header: ["<t3@ext.test>", "<t4@ext.test>"])).to be_empty
      expect(enqueued_jobs).to be_empty
    end

    it "files a message without Inbox as archived, and a re-run of the same file stores nothing new" do
      feed(entry(mime("t5"), labels: "Archived,Opened"))
      expect(conversation_of("t5")).to have_attributes(status: "archived", read: true)

      import.update!(cursor: nil)
      MailImporter::Takeout.new(import, mbox.path).run
      expect(import.reload.counts).to include("duplicate" => 1)
      expect(Message.where(message_id_header: "<t5@ext.test>").count).to eq(1)
    end

    it "is not resumable through the API, which has no file to read" do
      import.update!(state: MailImport::STATE_PAUSED)
      expect(import).not_to be_resumable
    end
  end

  describe MailImporter::Google do
    let(:import) { import_for(ana, "google", "ana@lalaaji.test") }

    before do
      transport.on(:get, "/users/me/profile", { body: { historyId: "500" } })
      transport.on(:get, "/users/me/labels", { body: { labels: [{ id: "Label_1", name: "Clients/Acme", type: "user" },
                                                                 { id: "INBOX", name: "INBOX", type: "system" }] } })
      transport.on(:get, %r{/users/me/messages\?}, { body: { messages: [{ id: "m1" }, { id: "m2" }, { id: "m3" }] } })
      transport.on(:get, "/messages/m1?format=raw", gmail("m1", mime("m1", attachment: ["q3.txt", "figures"]),
                                                         labels: %w[INBOX UNREAD Label_1 STARRED]))
      transport.on(:get, "/messages/m2?format=raw",
                   gmail("m2", mime("m2", from: "ana@lalaaji.test", to: "p@ext.test", reply_to: "m1",
                                          date: "Tue, 2 Sep 2025 09:00:00 +0000"), labels: %w[SENT]))
      transport.on(:get, "/messages/m3?format=raw", gmail("m3", mime("m3", subject: "Win big"), labels: %w[SPAM], thread: "t9"))
    end

    it "imports the mailbox quietly into one private thread, at the source's dates, and skips spam" do
      expect(RuleExecutor).not_to receive(:new)
      expect(OutOfOfficeResponder).not_to receive(:new) if defined?(OutOfOfficeResponder)

      run(import)

      expect(import).to be_done
      expect(import.counts).to include("seen" => 3, "imported" => 2, "skipped" => 1)
      expect(JSON.parse(import.cursor)).to eq("history" => "500", "done" => true)
      conv = conversation_of("m1")
      expect(conv).to have_attributes(private: true, status: "open", read: false, domain_id: domain.id, messages_count: 2)
      expect(conv.updated_at).to eq(Time.utc(2025, 9, 2, 9))
      expect(conv.messages.order(:created_at).map(&:is_inbound)).to eq([true, false])
      expect(conv.messages.first.attachments.first).to have_attributes(filename: "q3.txt", size_bytes: 7)
      expect(uploads).to eq(["figures"])
      expect(Message.where(message_id_header: "<m3@ext.test>")).to be_empty
      expect(enqueued_jobs).to be_empty
      expect(conv.tags.map { |t| [t.name, t.membership_id] }).to contain_exactly(["Clients/Acme", ana.id], ["Starred", ana.id])
      expect(transport.requests("/users/me/messages").map { |c| c.headers["Authorization"] }.uniq).to eq(["Bearer delegated"])
    end

    it "names an imported label apart from a team tag of the same name" do
      org.tags.create!(name: "starred", color: "#111111")

      run(import)

      expect(conversation_of("m1").tags.map(&:name)).to contain_exactly("Clients/Acme", "Starred (Google)")
    end

    it "shows the history to its owner only: not to the domain inbox, other members, admins or org-wide readers" do
      run(import)
      conv = conversation_of("m1")

      expect(Conversation.visible_to(ana)).to include(conv)
      expect(Conversation.visible_to(bob)).not_to include(conv)
      expect(Conversation.visible_to(admin)).not_to include(conv)
      expect(org.conversations.not_private).not_to include(conv)
    end

    it "gives each colleague their own copy of a thread they both had" do
      run(import)
      bobs = import_for(bob, "google", "bob@lalaaji.test")
      run(bobs)

      expect(bobs.counts).to include("imported" => 2, "skipped" => 1)
      anas, bobs_copy = Message.where(message_id_header: "<m1@ext.test>").order(:id).map(&:conversation)
      expect([anas.owner_membership_id, bobs_copy.owner_membership_id]).to eq([ana.id, bob.id])
      expect(Conversation.visible_to(bob)).to include(bobs_copy)
      expect(Conversation.visible_to(bob)).not_to include(anas)
      expect(Conversation.visible_to(ana)).not_to include(bobs_copy)
    end

    it "stores nothing twice when the same mailbox is imported again" do
      run(import)
      import.update!(state: MailImport::STATE_RUNNING, cursor: nil)
      run(import)

      expect(import.counts).to include("duplicate" => 2)
      expect(Message.where(message_id_header: "<m1@ext.test>").count).to eq(1)
    end

    describe "a reply arriving after the switch (D10)" do
      let!(:ana_box) { create(:mailbox, membership: ana, domain: domain, local_part: "ana") }
      let!(:bob_box) { create(:mailbox, membership: bob, domain: domain, local_part: "bob") }

      before do
        run(import)
        run(import_for(bob, "google", "bob@lalaaji.test"))
      end

      def deliver(id, rcpt)
        InboundMailProcessor.new(
          "envelope" => { "rcpt_to" => rcpt, "mail_from" => "p@ext.test" },
          "headers" => { "subject" => "Re: Quarterly figures", "from" => "Partner <p@ext.test>", "to" => rcpt.join(", "),
                         "message_id" => "<#{id}@ext.test>", "in_reply_to" => "<m2@ext.test>" },
          "body" => { "plain" => "reply" }
        ).process
      end

      it "lands in each recipient's own copy and nowhere shared" do
        expect(RuleExecutor).not_to receive(:new)

        deliver("r1", ["ana@lalaaji.test", "bob@lalaaji.test"])

        rows = Message.where(message_id_header: "<r1@ext.test>")
        expect(rows.map(&:owner_membership_id)).to contain_exactly(ana.id, bob.id)
        expect(rows.map { |m| m.conversation.messages_count }).to all(eq(3))
        expect(rows.map(&:conversation)).to all(have_attributes(read: false))
      end

      it "also goes to the domain inbox for a recipient without a copy" do
        deliver("r2", ["ana@lalaaji.test", "sales@lalaaji.test"])

        rows = Message.where(message_id_header: "<r2@ext.test>")
        expect(rows.map(&:owner_membership_id)).to contain_exactly(ana.id, nil)
        expect(rows.find { |m| m.owner_membership_id.nil? }.conversation).to have_attributes(private: false)
      end

      it "is not stored twice when the delivery is retried" do
        2.times { deliver("r3", ["ana@lalaaji.test"]) }

        expect(Message.where(message_id_header: "<r3@ext.test>").count).to eq(1)
      end
    end

    it "reads only what arrived since on a re-run, through history" do
      run(import)
      transport.on(:get, "/history?startHistoryId=500",
                   { body: { historyId: "640", history: [{ messagesAdded: [{ message: { id: "m4" } }] }] } })
      transport.on(:get, "/messages/m4?format=raw",
                   gmail("m4", mime("m4", reply_to: "m2", date: "Wed, 3 Sep 2025 09:00:00 +0000"), labels: %w[INBOX], thread: "t1"))
      import.update!(state: MailImport::STATE_RUNNING)

      run(import)

      expect(JSON.parse(import.cursor)).to eq("history" => "640", "done" => true)
      expect(conversation_of("m4")).to eq(conversation_of("m1"))
      expect(transport.requests("/messages/m1?").size).to eq(1)
    end

    it "pauses with the cause when Google refuses the delegation" do
      transport.on(:post, "oauth2.googleapis.com/token", { status: 401, body: { error: "unauthorized_client" } })

      run(import)

      expect(import).to have_attributes(state: "paused", pause_reason: "authorization")
      expect(import.error).to include("domain-wide")
    end

    it "lists the directory as the admin who connected Google" do
      transport.on(:get, %r{admin/directory/v1/users}, { body: { users: [
        { primaryEmail: "ana@lalaaji.test", name: { fullName: "Ana" } },
        { primaryEmail: "gone@lalaaji.test", suspended: true }
      ] } })

      expect(MailImporter.for(import).directory).to eq([["ana@lalaaji.test", "Ana"]])
    end
  end

  describe MailImporter::Microsoft do
    let(:import) { import_for(ana, "microsoft", "ana@lalaaji.test") }
    let(:base) { "graph.microsoft.com/v1.0/users/ana%40lalaaji.test" }

    before do
      transport.on(:post, "/tenant-1/oauth2/v2.0/token", { body: { access_token: "app", expires_in: 3600 } })
      { "inbox" => "IN", "sentitems" => "SENT", "junkemail" => "JUNK", "deleteditems" => "DEL", "drafts" => "DRAFTS",
        "outbox" => "OUT", "archive" => "ARCH" }.each { |name, id| transport.on(:get, "#{base}/mailFolders/#{name}?", { body: { id: id } }) }
      transport.on(:get, "#{base}/mailFolders/conversationhistory?", { status: 404, body: {} })
      transport.on(:get, "#{base}/mailFolders?", { body: { value: [
        { id: "IN", childFolderCount: 1 }, { id: "SENT" }, { id: "JUNK" }, { id: "DEL", childFolderCount: 1 }
      ] } })
      transport.on(:get, "#{base}/mailFolders/IN/childFolders", { body: { value: [{ id: "PROJ", displayName: "Projects" }] } })
      transport.on(:get, "#{base}/mailFolders/IN/messages/delta",
                   { body: { value: [{ id: "a1", conversationId: "c1", isRead: false }], "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/d/in" } })
      transport.on(:get, "#{base}/mailFolders/PROJ/messages/delta",
                   { body: { value: [{ id: "a2", conversationId: "c2", isRead: true, categories: ["Red"],
                                       flag: { flagStatus: "flagged" } }, { id: "a3", isDraft: true }],
                             "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/d/proj" } })
      transport.on(:get, "#{base}/mailFolders/SENT/messages/delta",
                   { body: { value: [{ id: "a4", conversationId: "c1", isRead: true }], "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/d/sent" } })
      transport.on(:get, "#{base}/messages/a1/$value", { body: mime("a1") })
      transport.on(:get, "#{base}/messages/a2/$value", { body: mime("a2", subject: "Project") })
      transport.on(:get, "#{base}/messages/a4/$value", { body: mime("a4", from: "ana@lalaaji.test", reply_to: "a1") })
    end

    it "reads every folder but Junk, Deleted Items and Drafts, keeping each folder's delta link" do
      run(import)

      expect(import).to be_done
      expect(import.counts).to include("imported" => 3, "skipped" => 1)
      expect(conversation_of("a1")).to have_attributes(status: "open", read: false, private: true)
      expect(conversation_of("a2")).to have_attributes(status: "archived", read: true)
      expect(conversation_of("a2").tags.map(&:name)).to contain_exactly("Projects", "Red", "Flagged")
      expect(conversation_of("a1").tags).to be_empty
      expect(conversation_of("a4")).to eq(conversation_of("a1"))
      expect(Message.find_by!(message_id_header: "<a4@ext.test>").is_inbound).to be(false)
      expect(transport.requests("mailFolders/JUNK/messages")).to be_empty
      expect(transport.requests("mailFolders/DEL/childFolders")).to be_empty
      expect(JSON.parse(import.cursor)["delta"]).to include("IN" => "https://graph.microsoft.com/v1.0/d/in", "PROJ" => "https://graph.microsoft.com/v1.0/d/proj")
    end

    it "reads a folder again from the start when its delta link has expired" do
      run(import)
      transport.on(:get, "graph.microsoft.com/v1.0/d/in", { status: 410, body: { error: { code: "syncStateNotFound" } } })
      transport.on(:get, "graph.microsoft.com/v1.0/d/proj", { body: { value: [], "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/d/proj2" } })
      transport.on(:get, "graph.microsoft.com/v1.0/d/sent", { body: { value: [], "@odata.deltaLink" => "https://graph.microsoft.com/v1.0/d/sent2" } })
      import.update!(state: MailImport::STATE_RUNNING)

      run(import)

      expect(import).to be_done
      expect(import.counts).to include("duplicate" => 1)
      expect(Message.where(message_id_header: "<a1@ext.test>").count).to eq(1)
    end

    it "lists enabled users from the tenant" do
      transport.on(:get, "#{'graph.microsoft.com/v1.0'}/users?$select", { body: { value: [
        { mail: "ana@lalaaji.test", displayName: "Ana" }, { userPrincipalName: "off@lalaaji.test", accountEnabled: false }
      ] } })

      expect(MailImporter.for(import).directory).to eq([["ana@lalaaji.test", "Ana"]])
    end
  end

  describe "a sealed domain" do
    let(:keypair) { RbNaCl::PrivateKey.generate }
    let(:import) { import_for(ana, "google", "ana@lalaaji.test") }

    before do
      org.update!(plan: create(:plan, e2ee: true, tier: Plan::TIER_PAID))
      create(:domain_key, domain: domain, version: 1, public_key: Base64.strict_encode64(keypair.public_key.to_bytes))
      domain.update_column(:e2ee_enabled, true)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("INBOX2_E2EE_FORCE_OFF", anything).and_return("false")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("INBOX2_THREADING_HMAC_KEY").and_return("import-spec-key")
      transport.on(:get, "/users/me/profile", { body: { historyId: "1" } })
      transport.on(:get, %r{/users/me/messages\?}, { body: { messages: [{ id: "s1" }] } })
      transport.on(:get, "/messages/s1?format=raw", gmail("s1", mime("s1", subject: "SECRET-SUBJECT", attachment: ["plan.txt", "SECRET-ATT"]),
                                                          labels: %w[INBOX]))
    end

    it "seals the row and the attachment under the domain key, as the MX does" do
      run(import)

      msg = Message.find_by!(msgid_hmac: E2ee.threading_hmac("<s1@ext.test>"))
      expect(msg).to have_attributes(sealed?: true, subject: nil, body_plain: nil, from_address: nil)
      expect(msg.conversation).to have_attributes(subject: nil, from_address: nil, private: true)
      dek = RbNaCl::Boxes::Sealed.new(keypair.public_key, keypair).open(Base64.strict_decode64(msg.sealed_dek))
      aead = RbNaCl::AEAD::XChaCha20Poly1305IETF.new(dek)
      att = msg.attachments.first
      att_aad = "#{msg.seal_aad}|att:0"
      expect(aead.decrypt(Base64.strict_decode64(att.content_nonce), uploads.first, att_aad)).to eq("SECRET-ATT")
      expect(aead.decrypt(Base64.strict_decode64(att.filename_nonce), Base64.strict_decode64(att.sealed_filename),
                          "#{att_aad}|name")).to eq("plan.txt")
      expect(uploads.first).not_to include("SECRET-ATT")
    end
  end

  it "never threads new mail into private history by subject" do
    import = import_for(ana, "google", "ana@lalaaji.test")
    private_conv = org.conversations.create!(domain: domain, private: true, subject: "Invoice 2291", status: "open")
    MailImportThread.create!(mail_import: import, source_thread_id: "x", conversation: private_conv)
    payload = { "envelope" => { "rcpt_to" => ["sales@lalaaji.test"] },
                "headers" => { "subject" => "Invoice 2291", "from" => "p@ext.test", "message_id" => "<new@ext.test>" },
                "body" => { "plain" => "hi" } }

    InboundMailProcessor.new(payload).process

    expect(Message.find_by!(message_id_header: "<new@ext.test>").conversation).not_to eq(private_conv)
  end
end
