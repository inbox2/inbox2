require "rails_helper"

# Address folders (AddressFolders): Inbox = mail for you, the rest one click away.
RSpec.describe "Api::V1::Folders", type: :request do
  let(:boss_user) { create(:user, username: "boss") }
  let(:org) { create(:organization, owner: boss_user, domain: "husttle.com", with_default_domain: true) }
  let(:domain) { org.default_domain }
  let!(:boss) { create(:membership, user: boss_user, organization: org, role: "owner", status: "active") }
  let(:ali_user) { create(:user, username: "ali") }
  let!(:ali) { create(:membership, user: ali_user, organization: org, role: "member", status: "active", send_as_addresses: ["info@husttle.com"]) }
  let!(:ali_box) { Mailbox.create!(membership: ali, domain: domain, local_part: "ali") }
  let(:other_org) { create(:organization, domain: "else.com", with_default_domain: true) }

  before { domain.update!(shared_addresses: [{ "local_part" => "info" }, { "local_part" => "support" }]) }

  def thread(to:, owner: nil, read: false, from: "c@example.com")
    org.conversations.create!(domain: domain, subject: "S #{to}", status: Conversation::STATUS_OPEN, read: read,
                              to_address: to, from_address: from, personal_membership_id: owner&.id)
  end

  let!(:boss_mail) { thread(to: "boss@husttle.com", owner: boss) }
  let!(:boss_receipt) { thread(to: "boss+receipts@husttle.com", owner: boss) }
  let!(:info_mail) { thread(to: "info@husttle.com") }
  let!(:support_mail) { thread(to: "support@husttle.com") }
  let!(:stray) { thread(to: "jobs@husttle.com") }
  let!(:ali_mail) { thread(to: "ali@husttle.com", owner: ali) }

  def keys(headers, **params)
    get "/api/v1/orgs/#{org.key}/conversations", params: params, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body["conversations"].map { |c| c["id"] }
  end

  describe "GET folders" do
    it "gives the owner own, tag, shared and other folders with counts and reply rights" do
      get "/api/v1/orgs/#{org.key}/folders", params: { domain: domain.key }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:ok)
      f = response.parsed_body["folders"].index_by { |x| x["key"] }
      expect(f.keys).to eq(%w[inbox boss boss+receipts info support other])
      expect(f["inbox"]["unread"]).to eq(1)
      expect(f["boss+receipts"]).to include("kind" => "tag", "parent" => "boss", "in_inbox" => false)
      expect(f["info"]).to include("kind" => "shared", "can_reply" => false, "in_inbox" => false, "notify" => false)
      expect(f["other"]["unread"]).to eq(1)
      expect(f["inbox"]["notify"]).to be(true)
    end

    it "shows a member with reply-as their shared address in Inbox" do
      get "/api/v1/orgs/#{org.key}/folders", params: { domain: domain.key }, headers: auth_headers(ali_user)
      f = response.parsed_body["folders"].index_by { |x| x["key"] }
      expect(f["info"]).to include("can_reply" => true, "in_inbox" => true)
      expect(f["inbox"]["unread"]).to eq(2)
    end

    it "404s for a domain of another org (E3)" do
      get "/api/v1/orgs/#{org.key}/folders", params: { domain: other_org.default_domain.key }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "conversations ?folder=" do
    it "Inbox is only the owner's own untagged mail" do
      expect(keys(auth_headers(boss_user), folder: "inbox")).to eq([boss_mail.key])
    end

    it "lists one folder of the domain" do
      h = auth_headers(boss_user)
      expect(keys(h, folder: "boss+receipts", domain: domain.key)).to eq([boss_receipt.key])
      expect(keys(h, folder: "info", domain: domain.key)).to eq([info_mail.key])
      expect(keys(h, folder: "other", domain: domain.key)).to eq([stray.key])
    end

    it "never lists a colleague's mail in a folder" do
      expect(keys(auth_headers(boss_user), folder: "ali", domain: domain.key)).to be_empty
    end

    it "keeps the old pool listing when no folder is asked for" do
      expect(keys(auth_headers(boss_user))).to include(info_mail.key, support_mail.key, boss_mail.key)
    end

    it "counts the Inbox badge with the same rule" do
      get "/api/v1/orgs/#{org.key}/conversations/unread-count", params: { folder: "inbox" }, headers: auth_headers(ali_user)
      expect(response.parsed_body["unread_count"]).to eq(2)
    end
  end

  describe "PATCH folders/prefs" do
    it "shows a tag in Inbox and turns its bell on" do
      h = auth_headers(boss_user)
      patch "/api/v1/orgs/#{org.key}/folders/prefs", params: { address: "boss+receipts@husttle.com", inbox: true, notify: true }, headers: h
      expect(response).to have_http_status(:ok)
      expect(keys(h, folder: "inbox")).to contain_exactly(boss_mail.key, boss_receipt.key)
      expect(boss.reload.folder_prefs["boss+receipts@husttle.com"]).to eq("inbox" => true, "notify" => true)
    end

    it "turns the Inbox bell off" do
      patch "/api/v1/orgs/#{org.key}/folders/prefs", params: { address: "inbox", notify: false }, headers: auth_headers(boss_user)
      expect(boss.reload.folder_prefs.dig("inbox", "notify")).to be(false)
    end

    it "refuses an address outside the member's domains" do
      patch "/api/v1/orgs/#{org.key}/folders/prefs", params: { address: "x@else.com", notify: true }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "domain shared addresses" do
    let(:base) { "/api/v1/orgs/#{org.key}/domains/#{domain.key}/shared-addresses" }

    it "lists them with who replies" do
      get base, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:ok)
      info = response.parsed_body["shared_addresses"].find { |a| a["local_part"] == "info" }
      expect(info["address"]).to eq("info@husttle.com")
      expect(info["repliers"]).to eq([ali_user.display_name.presence || "ali"])
    end

    it "lets an admin replace the list" do
      put base, params: { shared_addresses: [{ local_part: "Sales", display_name: "Husttle Sales" }] }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:ok)
      expect(domain.reload.shared_addresses).to eq([{ "local_part" => "sales", "display_name" => "Husttle Sales" }])
    end

    it "refuses a member's own mailbox as a shared address" do
      put base, params: { shared_addresses: [{ local_part: "ali" }] }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "keeps a listed address the team's even when a username matches it" do
      domain.update!(shared_addresses: [{ "local_part" => "boss" }])
      t = thread(to: "boss@husttle.com")
      expect(org.personal_membership_id_for("boss@husttle.com")).to be_nil
      expect(org.conversations.visible_to(ali)).to include(t)
      expect(org.conversations.org_readable).to include(t)
      get "/api/v1/orgs/#{org.key}/folders", params: { domain: domain.key }, headers: auth_headers(boss_user)
      f = response.parsed_body["folders"].map { |x| [x["key"], x["kind"]] }
      expect(f).to include(["boss", "shared"])
    end

    it "refuses a mailbox named like a shared address" do
      expect(Mailbox.new(membership: ali, domain: domain, local_part: "info")).not_to be_valid
    end

    it "refuses a retired mailbox as a shared address" do
      MailboxAlias.create!(organization: org, domain: domain, local_part: "oldie", mode: MailboxAlias::MODE_BOUNCE)
      put base, params: { shared_addresses: [{ local_part: "oldie" }] }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is admin-only" do
      put base, params: { shared_addresses: [] }, headers: auth_headers(ali_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "edges" do
    it "keeps a multi-part tag whole" do
      t = thread(to: "boss+travel+2026@husttle.com", owner: boss)
      expect(keys(auth_headers(boss_user), folder: "boss+travel+2026", domain: domain.key)).to eq([t.key])
    end

    it "gives each own address its own folder" do
      Mailbox.create!(membership: boss, domain: domain, local_part: "waseem")
      w = thread(to: "waseem@husttle.com", owner: boss)
      h = auth_headers(boss_user)
      get "/api/v1/orgs/#{org.key}/folders", params: { domain: domain.key }, headers: h
      expect(response.parsed_body["folders"].map { |f| f["key"] }).to include("boss", "waseem")
      expect(keys(h, folder: "waseem", domain: domain.key)).to eq([w.key])
      expect(keys(h, folder: "boss", domain: domain.key)).to eq([boss_mail.key])
    end

    it "keeps a thread assigned on another domain in the Inbox" do
      other = create(:domain, organization: org, name: "lalaaji.com")
      ali.update!(all_domains: false, domains: [domain])
      t = org.conversations.create!(domain: other, subject: "x", status: Conversation::STATUS_OPEN, to_address: "hello@lalaaji.com", from_address: "c@example.com")
      ConversationAssignee.create!(conversation: t, membership: ali)
      expect(keys(auth_headers(ali_user), folder: "inbox")).to include(t.key)
    end
  
    it "files a thread you started by its From when the recipient's host only contains the domain" do
      t = org.conversations.create!(domain: domain, subject: "x", status: Conversation::STATUS_OPEN, read: false,
        to_address: "client@nothusttle.com.au", from_address: "info@husttle.com")
      expect(keys(auth_headers(boss_user), folder: "info", domain: domain.key)).to include(t.key)
    end

    it "shows only the tag you chose in Inbox, not the same tag on your other address" do
      Mailbox.create!(membership: boss, domain: domain, local_part: "waseem")
      other_tag = thread(to: "waseem+receipts@husttle.com", owner: boss)
      h = auth_headers(boss_user)
      patch "/api/v1/orgs/#{org.key}/folders/prefs", params: { address: "boss+receipts@husttle.com", inbox: true }, headers: h
      expect(keys(h, folder: "inbox")).to include(boss_receipt.key)
      expect(keys(h, folder: "inbox")).not_to include(other_tag.key)
    end
  
    it "keeps your mail to a tagged shared address in your own folder and Inbox" do
      t = thread(to: "info+press@husttle.com", owner: boss, from: "boss@husttle.com")
      h = auth_headers(boss_user)
      expect(keys(h, folder: "boss", domain: domain.key)).to include(t.key)
      expect(keys(h, folder: "inbox")).to include(t.key)
    end

    it "refuses a folder name as a shared address" do
      put "/api/v1/orgs/#{org.key}/domains/#{domain.key}/shared-addresses", params: { shared_addresses: [{ local_part: "inbox" }] }, headers: auth_headers(boss_user)
      expect(response).to have_http_status(:unprocessable_content)
    end
  
    it "keeps tagged mail to a shared address out of Inbox, in the shared folder" do
      t = thread(to: "info+press@husttle.com")
      h = auth_headers(ali_user)
      expect(keys(h, folder: "inbox")).not_to include(t.key)
      expect(keys(h, folder: "info", domain: domain.key)).to include(t.key)
    end
  end
end
