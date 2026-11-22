require "rails_helper"

# waseem+receipts@ is waseem@'s own mail: the +tag never changes whose it is.
RSpec.describe "Plus addressing", type: :model do
  let(:owner) { create(:user, username: "boss") }
  let(:org) { create(:organization, owner: owner, domain: "acme.com", with_default_domain: true) }
  let(:domain) { org.default_domain }
  let!(:boss) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let!(:ali) { create(:membership, user: create(:user, username: "ali"), organization: org, role: Membership::ROLE_ADMIN, status: Membership::STATUS_ACTIVE) }
  let!(:ali_box) { Mailbox.create!(membership: ali, domain: domain, local_part: "ali") }

  def deliver(rcpt)
    InboundMailProcessor.new({
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "shop@example.com", "rcpt_to" => Array(rcpt), "client_ip" => "203.0.113.4", "helo_domain" => "mx.example.com" },
      "headers" => { "message_id" => "<#{SecureRandom.hex(6)}@example.com>", "in_reply_to" => "", "references" => "",
                     "from" => "Shop <shop@example.com>", "to" => Array(rcpt).join(", "), "cc" => "", "subject" => "Your receipt",
                     "date" => Time.current.rfc2822, "content_type" => "text/plain" },
      "body" => { "plain" => "Thanks", "html" => "" }, "attachments" => [],
      "authentication" => { "spf" => { "result" => "pass" }, "dkim" => { "result" => "pass" }, "dmarc" => { "result" => "pass" } },
      "raw_size_bytes" => 10, "raw_message_b64" => ""
    }).process
    org.conversations.order(:id).last
  end

  it "splits the tag off a local part" do
    expect(Mailbox.base_local_part("ali+receipts")).to eq("ali")
    expect(Mailbox.tag_of("ali+receipts")).to eq("receipts")
    expect(Mailbox.tag_of("ali")).to be_nil
  end

  it "stamps mail to a tagged mailbox address as that member's" do
    expect(deliver("ali+receipts@acme.com").personal_membership_id).to eq(ali.id)
  end

  it "stamps mail to a tagged username address as that member's" do
    expect(deliver("boss+github@acme.com").personal_membership_id).to eq(boss.id)
  end

  it "keeps tagged mail out of a colleague's view, owners included" do
    conv = deliver("ali+receipts@acme.com")
    expect(org.conversations.visible_to(boss)).not_to include(conv)
    expect(org.conversations.visible_to(ali)).to include(conv)
  end

  it "leaves an untagged shared address in the domain's inbox" do
    conv = deliver("info@acme.com")
    expect(conv.personal_membership_id).to be_nil
    expect(org.conversations.visible_to(boss)).to include(conv)
  end

  it "lets the owner of the base address send as a tagged address, nobody else" do
    expect(ali.can_send_as?("ali+receipts@acme.com")).to be(true)
    expect(boss.can_send_as?("ali+receipts@acme.com")).to be(false)
  end

  it "backfills tagged threads that arrived before the fix" do
    require Rails.root.join("db/migrate/20261122100001_backfill_plus_address_ownership")
    conv = deliver("ali+receipts@acme.com")
    conv.update_column(:personal_membership_id, nil)
    shared = deliver("info@acme.com")
    BackfillPlusAddressOwnership.new.up
    expect(conv.reload.personal_membership_id).to eq(ali.id)
    expect(shared.reload.personal_membership_id).to be_nil
  end

  it "sends the owner's out-of-office reply for tagged mail, from the base address" do
    ali.user.update!(out_of_office_start: 1.day.ago, out_of_office_end: 3.days.from_now, out_of_office_message: "Away.")
    conv = deliver("ali+receipts@acme.com")
    reply = conv.messages.where(is_inbound: false).last
    expect(reply&.from_address).to eq("ali@acme.com")
  end

  it "does not let tagged mail join a shared thread it references" do
    shared = deliver("info@acme.com")
    parent = shared.messages.first.message_id_header
    InboundMailProcessor.new({
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "shop@example.com", "rcpt_to" => ["ali+receipts@acme.com"], "client_ip" => "203.0.113.4", "helo_domain" => "mx.example.com" },
      "headers" => { "message_id" => "<reply-#{SecureRandom.hex(4)}@example.com>", "in_reply_to" => parent, "references" => parent,
                     "from" => "Shop <shop@example.com>", "to" => "ali+receipts@acme.com", "cc" => "", "subject" => "Re: Your receipt",
                     "date" => Time.current.rfc2822, "content_type" => "text/plain" },
      "body" => { "plain" => "Private", "html" => "" }, "attachments" => [],
      "authentication" => { "spf" => { "result" => "pass" }, "dkim" => { "result" => "pass" }, "dmarc" => { "result" => "pass" } },
      "raw_size_bytes" => 10, "raw_message_b64" => ""
    }).process
    reply = org.conversations.order(:id).last
    expect(reply).not_to eq(shared)
    expect(reply.personal_membership_id).to eq(ali.id)
    expect(shared.messages.count).to eq(1)
  end

  it "does not auto-reply to a member writing between their own tagged addresses" do
    ali.user.update!(out_of_office_start: 1.day.ago, out_of_office_end: 3.days.from_now, out_of_office_message: "Away.")
    reply = OutOfOfficeResponder.maybe_reply(organization: org, domain: domain,
      message: org.conversations.create!(subject: "x", status: Conversation::STATUS_OPEN).messages.create!(
        organization: org, from_address: "ali+one@acme.com", to_address: "ali+two@acme.com", subject: "x",
        message_id_header: "<self-1@acme.com>", is_inbound: true, is_draft: false),
      envelope: { "mail_from" => "ali+one@acme.com" }, raw_mime: "From: ali+one@acme.com\r\n\r\nx", recipient_local_part: "ali")
    expect(reply).to be_nil
  end

  it "does not let untagged mail join someone's tagged thread" do
    tagged = deliver("ali+receipts@acme.com")
    parent = tagged.messages.first.message_id_header
    InboundMailProcessor.new({
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "shop@example.com", "rcpt_to" => ["info@acme.com"], "client_ip" => "203.0.113.4", "helo_domain" => "mx.example.com" },
      "headers" => { "message_id" => "<fw-#{SecureRandom.hex(4)}@example.com>", "in_reply_to" => parent, "references" => parent,
                     "from" => "Shop <shop@example.com>", "to" => "info@acme.com", "cc" => "", "subject" => "Re: Your receipt",
                     "date" => Time.current.rfc2822, "content_type" => "text/plain" },
      "body" => { "plain" => "For the team", "html" => "" }, "attachments" => [],
      "authentication" => { "spf" => { "result" => "pass" }, "dkim" => { "result" => "pass" }, "dmarc" => { "result" => "pass" } },
      "raw_size_bytes" => 10, "raw_message_b64" => ""
    }).process
    newest = org.conversations.order(:id).last
    expect(newest).not_to eq(tagged)
    expect(newest.personal_membership_id).to be_nil
    expect(tagged.messages.count).to eq(1)
  end

  def reply(rcpt, parent)
    InboundMailProcessor.new({
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "shop@example.com", "rcpt_to" => Array(rcpt), "client_ip" => "203.0.113.4", "helo_domain" => "mx.example.com" },
      "headers" => { "message_id" => "<r-#{SecureRandom.hex(4)}@example.com>", "in_reply_to" => parent, "references" => parent,
                     "from" => "Shop <shop@example.com>", "to" => Array(rcpt).join(", "), "cc" => "", "subject" => "Re: Your receipt",
                     "date" => Time.current.rfc2822, "content_type" => "text/plain" },
      "body" => { "plain" => "Re", "html" => "" }, "attachments" => [],
      "authentication" => { "spf" => { "result" => "pass" }, "dkim" => { "result" => "pass" }, "dmarc" => { "result" => "pass" } },
      "raw_size_bytes" => 10, "raw_message_b64" => ""
    }).process
    org.conversations.order(:id).last
  end

  describe "several recipients in one envelope" do
    let!(:sana) { create(:membership, user: create(:user, username: "sana"), organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }

    it "gives every personal recipient the thread, whatever the order" do
      conv = deliver(["ali+receipts@acme.com", "boss@acme.com"])
      expect(conv.personal_membership_id).to eq(ali.id)
      expect(org.conversations.visible_to(ali)).to include(conv)
      expect(org.conversations.visible_to(boss)).to include(conv)
      expect(org.conversations.visible_to(sana)).not_to include(conv)
    end

    it "makes the thread the team's when a shared address is in the envelope" do
      conv = deliver(["ali+receipts@acme.com", "info@acme.com"])
      expect(conv.personal_membership_id).to be_nil
      expect(org.conversations.visible_to(sana)).to include(conv)
      expect(org.conversations.visible_to(ali)).to include(conv)
    end
  end

  it "does not open someone's personal thread to a new recipient" do
    mine = deliver("ali@acme.com")
    other = reply("boss@acme.com", mine.messages.first.message_id_header)
    expect(other).not_to eq(mine)
    expect(org.conversations.visible_to(boss)).not_to include(mine)
  end

  it "still threads a reply to the owner of a personal thread" do
    mine = deliver("ali@acme.com")
    expect(reply("ali@acme.com", mine.messages.first.message_id_header)).to eq(mine)
  end
end
