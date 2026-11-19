require "rails_helper"

RSpec.describe "Domain access model", type: :model do
  let(:org) { create(:organization, domain: "one.test", with_default_domain: true) }
  let(:dom_a) { org.default_domain }
  let!(:dom_b) { create(:domain, organization: org, name: "two.test") }
  let(:user) { create(:user) }

  def member(role: "member", status: "active")
    create(:membership, organization: org, user: user, role: role, status: status)
  end

  describe "Membership#all_domains_access?" do
    it "is always true for owners/admins regardless of the flag" do
      m = member(role: "admin")
      m.update_column(:all_domains, false)
      expect(m.all_domains_access?).to be(true)
    end

    it "follows the flag for regular members" do
      m = member
      expect(m.all_domains_access?).to be(true) # default
      m.update!(all_domains: false, domains: [dom_a])
      expect(m.all_domains_access?).to be(false)
    end
  end

  describe "Membership#accessible_domain_ids" do
    it "is every org domain when unscoped, else just the grants" do
      m = member
      expect(m.accessible_domain_ids).to match_array(org.domains.ids)
      m.update!(all_domains: false, domains: [dom_a])
      expect(m.reload.accessible_domain_ids).to contain_exactly(dom_a.id)
    end
  end

  describe "limited members (scoped, zero domain grants — spec 5.1.6)" do
    it "allows an ACTIVE scoped member with zero grants" do
      m = member
      m.all_domains = false
      m.domains = []
      expect(m).to be_valid
    end
  end

  describe "MembershipDomain" do
    it "is unique per (membership, domain)" do
      m = member
      MembershipDomain.create!(membership: m, domain: dom_a)
      dup = MembershipDomain.new(membership: m, domain: dom_a)
      expect(dup).not_to be_valid
    end

    it "rejects a domain from another org" do
      other = create(:organization, domain: "elsewhere.test")
      m = member
      bad = MembershipDomain.new(membership: m, domain: other.default_domain)
      expect(bad).not_to be_valid
    end
  end

  describe "Conversation.visible_to" do
    let!(:m) { member.tap { |x| x.update!(all_domains: false, domains: [dom_a]) } }
    let!(:ca) { create(:conversation, organization: org, domain: dom_a) }
    let!(:cb) { create(:conversation, organization: org, domain: dom_b) }

    it "returns only granted-domain threads for a scoped member" do
      expect(org.conversations.visible_to(m)).to contain_exactly(ca)
    end

    it "returns everything for an all-domains member" do
      m.update!(all_domains: true)
      expect(org.conversations.visible_to(m)).to contain_exactly(ca, cb)
    end

    it "includes a directly-assigned out-of-domain thread" do
      cb.assignees << m
      expect(org.conversations.visible_to(m)).to contain_exactly(ca, cb)
    end

    it "shows a limited member (zero grants) only access-granted/assigned threads" do
      m.update!(all_domains: false, domains: [])
      expect(org.conversations.visible_to(m)).to be_empty
      cb.accessible_members << m # what a grant_access visibility rule writes
      expect(org.conversations.visible_to(m)).to contain_exactly(cb)
    end
  end

  describe "personal mailboxes are private to their member" do
    let!(:m) { member.tap { |x| x.update!(all_domains: false, domains: [dom_a]) } }
    let(:teammate_user) { create(:user) }
    let!(:teammate) do
      create(:membership, organization: org, user: teammate_user, role: "member")
        .tap { |t| t.mailboxes.create!(domain: dom_a, local_part: "waseem") }
    end
    let!(:shared) { create(:conversation, organization: org, domain: dom_a, to_address: "info@one.test") }
    let!(:personal) { create(:conversation, organization: org, domain: dom_a, to_address: "Waseem@one.test") }
    let!(:from_personal) { create(:conversation, organization: org, domain: dom_a, from_address: "waseem@one.test") }
    let!(:sealed) { create(:conversation, organization: org, domain: dom_a, to_address: nil, from_address: nil) }

    it "hides teammates' personal threads from the domain grant (case-insensitively)" do
      expect(org.conversations.visible_to(m)).to contain_exactly(shared, sealed)
    end

    it "hides them from owners and all-domains members too" do
      boss = create(:membership, organization: org, user: create(:user), role: "owner")
      expect(org.conversations.visible_to(boss)).to contain_exactly(shared, sealed)
      m.update!(all_domains: true)
      expect(org.conversations.visible_to(m)).to contain_exactly(shared, sealed)
    end

    it "keeps them from org-wide readers that are no member (API keys, Explorer, Lore)" do
      expect(org.conversations.org_readable).to contain_exactly(shared, sealed)
    end

    it "still shows a personal thread explicitly shared with them" do
      personal.accessible_members << m
      expect(org.conversations.visible_to(m)).to include(personal)
    end

    it "never hides the member's own mailbox threads" do
      m.mailboxes.create!(domain: dom_a, local_part: "atiq")
      mine = create(:conversation, organization: org, domain: dom_a, to_address: "atiq@one.test")
      expect(org.conversations.visible_to(m)).to include(mine)
    end

    it "hides a teammate's username address that has no Mailbox row (can_send_as? allows it)" do
      owner_like = create(:membership, organization: org, user: create(:user, username: "boss"), role: "owner")
      to_boss = create(:conversation, organization: org, domain: dom_a, to_address: "boss@one.test")
      expect(owner_like.can_send_as?("boss@one.test")).to be(true)
      expect(org.conversations.visible_to(m)).not_to include(to_boss)
    end
  end

  describe "inbound stamps the conversation's domain" do
    it "sets conversation.domain to the recipient domain" do
      dom_b.update!(status: Domain::STATUS_VERIFIED)
      payload = {
        "envelope" => { "mail_from" => "outsider@world.test", "rcpt_to" => ["hello@#{dom_b.name}"], "client_ip" => "203.0.113.9" },
        "headers" => { "from" => "Out <outsider@world.test>", "to" => "hello@#{dom_b.name}", "subject" => "hi there",
                       "content_type" => "text/plain", "message_id" => "<stamp-#{SecureRandom.hex(3)}@world.test>" },
        "body" => { "plain" => "body", "html" => "" },
        "attachments" => [],
        "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
        "raw_message_b64" => ""
      }
      InboundMailProcessor.new(payload).process
      conv = org.conversations.order(:created_at).last
      expect(conv.domain).to eq(dom_b)
    end
  end
end
