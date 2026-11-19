require "rails_helper"
require "mail"

# E1 mapping: spec 22 — mail clients: IMAP and SMTP submission (docs/Mail-Clients.md)
RSpec.describe "Mail client API", type: :request do
  let(:org) { create(:organization, domain: "acme.test", plan: Plan.paid).tap { |o| o.update!(mail_clients_enabled: true) } }
  let(:domain) { org.default_domain }
  let(:membership) { create(:membership, organization: org) }
  let!(:mailbox) { create(:mailbox, membership: membership, domain: domain, local_part: "jane") }
  let(:password) { membership.mail_client_passwords.create!(name: "Apple Mail") }
  let(:headers) { basic("jane@acme.test", password.raw_token) }
  let(:base) { "/api/v1/mail-client" }

  def basic(login, secret)
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(login, secret) }
  end

  def thread_to_jane(attrs = {}, message_attrs = {})
    conversation = create(:conversation, { organization: org, domain: domain, to_address: "jane@acme.test",
      personal_membership_id: membership.id }.merge(attrs))
    create(:message, { conversation: conversation, to_address: "jane@acme.test" }.merge(message_attrs))
  end

  def list(folder) = get("#{base}/folders/#{folder}/messages", headers: headers).then { response.parsed_body["messages"] }

  describe "sign-in (22.2.1)" do
    it "accepts the person's address with an app password" do
      get "#{base}/session", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["login"]).to eq("jane@acme.test")
    end

    it "refuses a wrong password, someone else's address, and the account password" do
      get "#{base}/session", headers: basic("jane@acme.test", "imc_#{'0' * 32}")
      expect(response).to have_http_status(:unauthorized)

      other = create(:membership, organization: org)
      create(:mailbox, membership: other, domain: domain, local_part: "bob")
      get "#{base}/session", headers: basic("bob@acme.test", password.raw_token)
      expect(response).to have_http_status(:unauthorized)

      get "#{base}/session", headers: basic("jane@acme.test", "password123")
      expect(response).to have_http_status(:unauthorized)
    end

    it "is refused until an admin switches mail clients on (22.1.1)" do
      org.update!(mail_clients_enabled: false)
      get "#{base}/session", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["errors"].first["message"]).to match(/switched off/)
    end

    it "is a paid feature: Free cannot switch it on, and a downgrade closes it (22.1.4)" do
      org.update!(plan: Plan.free)
      get "#{base}/session", headers: headers
      expect(response).to have_http_status(:forbidden)

      free = create(:organization, plan: Plan.free)
      expect(free.update(mail_clients_enabled: true)).to be(false)
      expect(free.errors[:mail_clients_enabled]).to include("needs a paid plan")
    end

    it "is refused for a sealed domain (22.2.2)" do
      domain.update_column(:e2ee_enabled, true)
      get "#{base}/session", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "folders and messages (22.2.3)" do
    it "serves only the person's own mail, never the shared inbox or a teammate's (E3)" do
      mine = thread_to_jane
      create(:message, conversation: create(:conversation, organization: org, domain: domain, to_address: "info@acme.test"))
      other = create(:membership, organization: org)
      create(:mailbox, membership: other, domain: domain, local_part: "bob")
      create(:message, conversation: create(:conversation, organization: org, domain: domain, to_address: "bob@acme.test"))
      create(:message, conversation: mine.conversation, is_draft: true, is_inbound: false)
      # A shared thread that names her address is still the team's.
      create(:message, conversation: create(:conversation, organization: org, domain: domain, to_address: "jane@acme.test"))
      # So is a colleague's private thread she was given access to.
      shared = create(:conversation, organization: org, domain: domain, private: true, owner_membership_id: other.id)
      ConversationAccess.create!(conversation: shared, membership: membership)
      create(:message, conversation: shared)

      get "#{base}/folders", headers: headers
      folders = response.parsed_body["folders"]
      expect(folders.map { |f| f["name"] }).to eq(%w[INBOX Archive Sent Trash Junk])
      expect(folders.first).to include("exists" => 1, "unseen" => 1, "special_use" => nil)
      expect(folders.find { |f| f["name"] == "Sent" }["special_use"]).to eq("\\Sent")
    end

    it "puts each message in the folder its thread's status means" do
      thread_to_jane
      thread_to_jane(status: "archived")
      thread_to_jane(status: "spam")
      thread_to_jane(status: "trash")
      thread_to_jane({ from_address: "jane@acme.test", to_address: "x@example.com" }, { is_inbound: false, from_address: "jane@acme.test" })

      get "#{base}/folders", headers: headers
      counts = response.parsed_body["folders"].to_h { |f| [f["name"], f["exists"]] }
      expect(counts).to eq("INBOX" => 1, "Archive" => 1, "Sent" => 1, "Trash" => 1, "Junk" => 1)
    end

    it "keeps a message's UID stable and gives new mail the next one" do
      thread_to_jane
      first = list("INBOX")
      thread_to_jane
      second = list("INBOX")
      expect(second.map { |m| m["uid"] }).to eq([first.first["uid"], first.first["uid"] + 1])
    end

    it "serves the message with its original headers and a size that matches the bytes (22.2.4)" do
      message = thread_to_jane({}, { body_html: "<p>Hello</p>", subject: "Hi",
        raw_headers: "From: Bob <bob@example.com>\r\nSubject: Hi\r\nX-Original: yes\r\n folded\r\nContent-Type: multipart/x; boundary=old\r\nDKIM-Signature: v=1; a=b" })
      create(:attachment, message: message, size_bytes: 100, storage_key: "k/doc.pdf")
      allow(S3StorageService).to receive(:new).and_return(instance_double(S3StorageService, download: "x" * 100))

      listed = list("INBOX").first
      get "#{base}/folders/INBOX/messages/#{listed['uid']}/raw", headers: headers
      raw = response.body
      expect(raw.bytesize).to eq(listed["size"])
      expect(raw).to include("X-Original: yes\r\n folded", "DKIM-Signature: v=1")
      expect(raw).not_to include("boundary=old")
      parsed = Mail.new(raw)
      expect(parsed.text_part.decoded).to eq(message.body_plain)
      expect(parsed.html_part.decoded).to eq("<p>Hello</p>")
      expect(parsed.attachments.first.decoded).to eq("x" * 100)

      get "#{base}/folders/INBOX/messages/#{listed['uid']}/header", headers: headers
      expect(raw).to start_with(response.body)
      expect(response.body).to end_with("\r\n\r\n")
    end

    it "rebuilds headers for mail that arrived before headers were kept" do
      thread_to_jane({}, { subject: "Old mail" })
      uid = list("INBOX").first["uid"]
      get "#{base}/folders/INBOX/messages/#{uid}/header", headers: headers
      expect(response.body).to include("Subject: Old mail", "From: sender@example.com", "MIME-Version: 1.0")
    end

    it "answers 404 for another folder's UID or an unknown folder" do
      thread_to_jane
      uid = list("INBOX").first["uid"]
      get "#{base}/folders/Archive/messages/#{uid}/raw", headers: headers
      expect(response).to have_http_status(:not_found)
      get "#{base}/folders/Nope/messages", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  it "keeps the header block of a raw message, cut at the first empty line and safe for Postgres (22.2.4)" do
    block = MailClient::Mime.header_block("Subject: Hi\r\nX-Bin: \xFF\x00\r\n\r\nbody\r\n\r\nmore".b)
    expect(block).to eq("Subject: Hi\r\nX-Bin: ?")
    expect(MailClient::Mime.header_block("")).to be_nil
  end

  describe "changing mail (22.2.5)" do
    it "marks the thread read with \\Seen and keeps other flags per message" do
      message = thread_to_jane
      uid = list("INBOX").first["uid"]
      post "#{base}/folders/INBOX/flags", params: { uids: [uid], mode: "add", flags: ["\\Seen", "\\Flagged"] }, headers: headers, as: :json
      expect(response.parsed_body["messages"].first["flags"]).to match_array(["\\Seen", "\\Flagged"])
      expect(message.conversation.reload.read).to be(true)

      post "#{base}/folders/INBOX/flags", params: { uids: [uid], mode: "remove", flags: ["\\Seen"] }, headers: headers, as: :json
      expect(response.parsed_body["messages"].first["flags"]).to eq(["\\Flagged"])
      expect(message.conversation.reload.read).to be(false)
    end

    it "moves a message by changing its thread's status, with a new UID in the target" do
      message = thread_to_jane
      uid = list("INBOX").first["uid"]
      post "#{base}/folders/INBOX/move", params: { uids: [uid], to: "Archive" }, headers: headers, as: :json
      moved = response.parsed_body["moved"]
      expect(moved.first["uid"]).to eq(uid)
      expect(message.conversation.reload.status).to eq("archived")
      expect(list("INBOX")).to be_empty
      expect(list("Archive").map { |m| m["uid"] }).to eq([moved.first["to_uid"]])
    end

    it "trains the junk filter on a move into Junk" do
      thread_to_jane
      uid = list("INBOX").first["uid"]
      expect {
        post "#{base}/folders/INBOX/move", params: { uids: [uid], to: "Junk" }, headers: headers, as: :json
      }.to have_enqueued_job(SpamFeedbackJob)
    end

    it "leaves a sent message, and its thread, alone unless the move is to Trash and back" do
      sent = thread_to_jane({ from_address: "jane@acme.test", to_address: "x@example.com" }, { is_inbound: false, from_address: "jane@acme.test" })
      uid = list("Sent").first["uid"]
      post "#{base}/folders/Sent/move", params: { uids: [uid], to: "Archive" }, headers: headers, as: :json
      expect(response.parsed_body["moved"]).to be_empty
      expect(sent.conversation.reload.status).to eq("open")

      post "#{base}/folders/Sent/move", params: { uids: [uid], to: "Trash" }, headers: headers, as: :json
      trash_uid = response.parsed_body["moved"].first["to_uid"]
      post "#{base}/folders/Trash/move", params: { uids: [trash_uid], to: "Sent" }, headers: headers, as: :json
      expect(response.parsed_body["moved"].size).to eq(1)
      expect(sent.conversation.reload.status).to eq("open")

      inbound_uid = thread_to_jane.then { list("INBOX").first["uid"] }
      post "#{base}/folders/INBOX/move", params: { uids: [inbound_uid], to: "Sent" }, headers: headers, as: :json
      expect(response.parsed_body["moved"]).to be_empty
    end

    it "expunges to Trash, and from Trash only hides the message from mail clients" do
      message = thread_to_jane
      uid = list("INBOX").first["uid"]
      post "#{base}/folders/INBOX/flags", params: { uids: [uid], mode: "add", flags: ["\\Deleted"] }, headers: headers, as: :json
      post "#{base}/folders/INBOX/expunge", params: {}, headers: headers, as: :json
      expect(response.parsed_body["expunged"]).to eq([uid])
      expect(message.conversation.reload.status).to eq("trash")

      trash_uid = list("Trash").first["uid"]
      post "#{base}/folders/Trash/flags", params: { uids: [trash_uid], mode: "add", flags: ["\\Deleted"] }, headers: headers, as: :json
      post "#{base}/folders/Trash/expunge", params: { uids: [trash_uid] }, headers: headers, as: :json
      expect(list("Trash")).to be_empty
      expect(Message.exists?(message.id)).to be(true)
    end

    it "searches the folder" do
      thread_to_jane({}, { subject: "Invoice 42", from_address: "billing@vendor.example" })
      thread_to_jane({}, { subject: "Lunch" })
      post "#{base}/folders/INBOX/search", params: { subject: "invoice" }, headers: headers, as: :json
      expect(response.parsed_body["uids"].size).to eq(1)
      post "#{base}/folders/INBOX/search", params: { from: "vendor", since: "2999-01-01" }, headers: headers, as: :json
      expect(response.parsed_body["uids"]).to be_empty
    end
  end

  describe "sending (22.2.6)" do
    let(:raw) do
      "From: Jane <jane@acme.test>\r\nTo: bob@example.com\r\nSubject: Hello\r\nMessage-ID: <abc@client>\r\n" \
        "X-Mailer: Test\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nHi Bob\r\n"
    end

    def submit(params = {})
      post "#{base}/submit", params: { mail_from: "jane@acme.test", rcpt_to: ["bob@example.com", "hidden@example.com"],
        raw_b64: Base64.strict_encode64(raw) }.merge(params), headers: headers, as: :json
    end

    it "sends through the normal pipeline as the person's own sent mail, Bcc kept out of the headers" do
      expect { submit }.to have_enqueued_job(OutboundDeliveryJob)
      expect(response).to have_http_status(:ok)
      message = Message.find_by!(key: response.parsed_body["id"])
      expect(message).to have_attributes(is_inbound: false, subject: "Hello", bcc_address: "hidden@example.com",
        message_id_header: "<abc@client>", sender_membership_id: membership.id)
      expect(message.body_plain.strip).to eq("Hi Bob")
      expect(list("Sent").size).to eq(1)

      # The client then files its own copy in Sent: accepted, nothing stored twice.
      post "#{base}/folders/Sent/append", params: { raw_b64: Base64.strict_encode64(raw) }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(Message.where(message_id_header: "<abc@client>").count).to eq(1)
    end

    it "keeps a message sent from a send-as address in the sender's own Sent folder" do
      membership.update!(send_as_addresses: ["billing@acme.test"])
      submit(mail_from: "billing@acme.test", raw_b64: Base64.strict_encode64(raw.sub("Jane <jane@acme.test>", "billing@acme.test")))
      expect(response).to have_http_status(:ok)
      expect(Message.find_by!(key: response.parsed_body["id"]).conversation.personal_membership_id).to eq(membership.id)
      expect(list("Sent").size).to eq(1)
    end

    it "does not send twice when the client repeats a submission, and queues it again in case the first try did not" do
      submit
      expect { submit }.to have_enqueued_job(OutboundDeliveryJob).and(not_change(Message, :count))
      expect(response).to have_http_status(:ok)
    end

    it "does not treat a colleague's Message-ID as this person's earlier send" do
      other = create(:membership, organization: org)
      theirs = create(:message, conversation: create(:conversation, organization: org), is_inbound: false,
        sender_membership_id: other.id, message_id_header: "<abc@client>")
      submit
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).not_to include("id" => theirs.key)
    end

    it "leaves nothing behind when an attachment cannot be stored, so the retry sends in full" do
      with_file = Mail.new(raw).tap { |m| m.add_file(filename: "a.txt", content: "data") }.encoded
      allow(S3StorageService).to receive(:new).and_return(instance_double(S3StorageService).tap { |s| allow(s).to receive(:upload).and_raise("storage down") })
      expect { submit(raw_b64: Base64.strict_encode64(with_file)) }.to raise_error("storage down")
      expect(Message.where(is_inbound: false).count).to eq(0)

      allow(S3StorageService).to receive(:new).and_return(instance_double(S3StorageService, upload: "k/a.txt"))
      submit(raw_b64: Base64.strict_encode64(with_file))
      expect(response).to have_http_status(:ok)
      expect(Message.find_by!(key: response.parsed_body["id"]).attachments.pluck(:filename)).to eq(["a.txt"])
    end

    it "threads a reply into the thread it answers" do
      parent = thread_to_jane({}, { message_id_header: "<parent@example.com>" })
      reply = raw.sub("Message-ID: <abc@client>", "Message-ID: <r1@client>\r\nIn-Reply-To: <parent@example.com>")
      submit(raw_b64: Base64.strict_encode64(reply))
      expect(Message.find_by!(message_id_header: "<r1@client>").conversation).to eq(parent.conversation)
    end

    it "takes a thread out of Trash when the person replies to it, so the reply is in Sent" do
      parent = thread_to_jane({ status: Conversation::STATUS_TRASH }, { message_id_header: "<parent@example.com>" })
      reply = raw.sub("Message-ID: <abc@client>", "Message-ID: <r2@client>\r\nIn-Reply-To: <parent@example.com>")
      submit(raw_b64: Base64.strict_encode64(reply))
      expect(parent.conversation.reload.status).to eq(Conversation::STATUS_OPEN)
    end

    it "keeps an inline calendar part, so an invitation sent from a mail client still carries its event" do
      ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:e1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
      invite = "From: Jane <jane@acme.test>\r\nTo: bob@example.com\r\nSubject: Lunch\r\nMessage-ID: <inv@client>\r\n" \
        "MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=b1\r\n\r\n" \
        "--b1\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nLunch on Friday\r\n" \
        "--b1\r\nContent-Type: text/calendar; method=REQUEST; charset=UTF-8\r\n\r\n#{ics}--b1--\r\n"
      submit(raw_b64: Base64.strict_encode64(invite), rcpt_to: ["bob@example.com"])
      message = Message.find_by!(message_id_header: "<inv@client>")
      expect(message.calendar_reply).to include("METHOD:REQUEST", "UID:e1")
      expect(message.body_plain.strip).to eq("Lunch on Friday")
    end

    it "refuses to send as someone else" do
      submit(mail_from: "ceo@acme.test")
      expect(response).to have_http_status(:forbidden)
      submit(raw_b64: Base64.strict_encode64(raw.sub("jane@acme.test", "ceo@acme.test")))
      expect(response).to have_http_status(:forbidden)
      expect(Message.where(is_inbound: false).count).to eq(0)
    end

    it "refuses a From header that names a second sender" do
      submit(raw_b64: Base64.strict_encode64(raw.sub("From: Jane <jane@acme.test>", "From: Jane <jane@acme.test>, ceo@acme.test")))
      expect(response).to have_http_status(:unprocessable_content)
      expect(Message.where(is_inbound: false).count).to eq(0)
    end

    it "refuses a header recipient the envelope does not carry, so nobody extra is mailed" do
      submit(rcpt_to: ["hidden@example.com"])
      expect(response).to have_http_status(:unprocessable_content)
      expect(Message.where(is_inbound: false).count).to eq(0)
    end

    it "refuses to import mail by APPEND" do
      post "#{base}/folders/INBOX/append", params: { raw_b64: Base64.strict_encode64(raw) }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "app passwords and the org switch (22.1)" do
    let(:session_headers) { auth_headers(membership.user) }
    let(:org_base) { "/api/v1/orgs/#{org.key}" }

    it "lets a member create, list and revoke their own app passwords (22.1.2)" do
      post "#{org_base}/mail-client/passwords", params: { name: "Thunderbird" }, headers: session_headers
      expect(response).to have_http_status(:created)
      token = response.parsed_body["token"]
      expect(token).to start_with("imc_")

      get "#{org_base}/mail-client/passwords", headers: session_headers
      listed = response.parsed_body["passwords"]
      expect(listed.first.keys).not_to include("token", "token_digest")

      delete "#{org_base}/mail-client/passwords/#{listed.first['id']}", headers: session_headers
      expect(response).to have_http_status(:no_content)
      get "#{base}/session", headers: basic("jane@acme.test", token)
      expect(response).to have_http_status(:unauthorized)
    end

    it "gives the settings to type into a mail client (22.1.3)" do
      get "#{org_base}/mail-client", headers: session_headers
      expect(response.parsed_body["mail_client"]).to include("enabled" => true, "addresses" => ["jane@acme.test"])
      expect(response.parsed_body["mail_client"]["imap"]).to include("port" => 993)
    end

    it "creates no password while the org has mail clients off, and only an admin can switch it on (22.1.1)" do
      org.update!(mail_clients_enabled: false)
      post "#{org_base}/mail-client/passwords", params: { name: "x" }, headers: session_headers
      expect(response).to have_http_status(:forbidden)

      patch org_base, params: { mail_clients_enabled: true }, headers: session_headers
      expect(response).to have_http_status(:forbidden)

      admin = create(:membership, organization: org, role: Membership::ROLE_ADMIN)
      patch org_base, params: { mail_clients_enabled: true }, headers: auth_headers(admin.user)
      expect(response.parsed_body["organization"]["mail_clients_enabled"]).to be(true)
    end
  end
end
