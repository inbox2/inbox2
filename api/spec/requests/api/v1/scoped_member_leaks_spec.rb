require "rails_helper"

# A domain-scoped member must get nothing from other domains through the side
# endpoints that never went through Conversation.visible_to (2026-10-21 audit,
# before inviting glu0n.com-only members into a multi-domain org).
RSpec.describe "Scoped member side endpoints", type: :request do
  let!(:org) { create(:organization, domain: "one.test") }
  let!(:dom_b) { create(:domain, organization: org, name: "two.test") }
  let!(:admin_m) { create(:membership, organization: org, role: "admin") }
  let!(:scoped) do
    create(:membership, organization: org, role: "member")
      .tap { |m| m.update!(all_domains: false, domains: [org.default_domain]) }
  end
  let!(:other_conv) { create(:conversation, organization: org, domain: dom_b, from_address: "a@x.test", to_address: "b@two.test") }
  let(:h) { auth_headers(scoped.user) }

  it "pair only counts threads the member can see" do
    get "/api/v1/orgs/#{org.key}/mailboxes/pair", params: { source: "a@x.test", target: "b@two.test" }, headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["total"]).to eq(0)
    expect(response.parsed_body["conversations"]).to be_empty
  end

  it "refuses the org-wide graph, admin overview, rules list and a teammate's activity feed" do
    get "/api/v1/orgs/#{org.key}/mailboxes/graph", headers: h
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/orgs/#{org.key}/mailboxes/stats", headers: h
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/orgs/#{org.key}/admin/overview", headers: h
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/orgs/#{org.key}/rules", headers: h
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/orgs/#{org.key}/members/#{admin_m.key}/activity", headers: h
    expect(response).to have_http_status(:forbidden)
  end

  it "still shows the member their own activity feed" do
    get "/api/v1/orgs/#{org.key}/members/#{scoped.key}/activity", headers: h
    expect(response).to have_http_status(:ok)
  end

  it "builds view suggestions from visible mail only" do
    create_list(:conversation, 3, organization: org, domain: dom_b, from_address: "x@secret.test")
    get "/api/v1/orgs/#{org.key}/views/suggestions", headers: h
    expect(response.parsed_body["suggestions"].map { |s| s["name"] }).not_to include("From secret.test")
  end
end

RSpec.describe "Rules-only member: own mailbox, tabs, send-as", type: :request do
  let!(:org) { create(:organization, domain: "one.test") }
  let!(:dom_b) { create(:domain, organization: org, name: "two.test") }
  # No domain grants: visibility comes from their mailbox + grant_access rules.
  let!(:member) do
    create(:membership, organization: org, role: "member").tap do |m|
      m.update!(all_domains: false, domains: [])
      m.mailboxes.create!(domain: dom_b, local_part: "badr")
    end
  end
  let(:h) { auth_headers(member.user) }

  it "sees only their own mailbox mail and what is shared with them" do
    mine = create(:conversation, organization: org, domain: dom_b, to_address: "Badr@two.test")
    sent = create(:conversation, organization: org, domain: dom_b, from_address: "badr@two.test", to_address: "x@out.test")
    info = create(:conversation, organization: org, domain: dom_b, to_address: "info@two.test")
    contact = create(:conversation, organization: org, domain: dom_b, to_address: "contact@two.test")
    info.accessible_members << member
    expect(org.conversations.visible_to(member)).to contain_exactly(mine, sent, info)
    expect(org.conversations.visible_to(member)).not_to include(contact)
  end

  it "gets a tab for the mailbox's domain only, and its From list" do
    member.update!(send_as_addresses: ["Info@two.test"])
    get "/api/v1/account", headers: h
    o = response.parsed_body["organizations"].first
    expect(o["domains"].map { |d| d["name"] }).to eq(["two.test"])
    expect(o["domain"]).to eq("two.test")
    expect(o["from_addresses"]).to contain_exactly("badr@two.test", "info@two.test")
    get "/api/v1/orgs/#{org.key}/domains/#{org.default_domain.key}/dns", headers: h
    expect(response).to have_http_status(:not_found)
  end

  it "sends as their mailbox and granted addresses only" do
    member.update!(send_as_addresses: ["info@two.test"])
    expect(member.can_send_as?("badr@two.test")).to be(true)
    expect(member.can_send_as?("info@two.test")).to be(true)
    expect(member.can_send_as?("sales@two.test")).to be(false)
    expect(member.can_send_as?("#{member.user.username}@two.test")).to be(false) # no pool, no username address
  end

  it "rejects send-as addresses outside the workspace's domains" do
    member.send_as_addresses = ["info@elsewhere.test"]
    expect(member).not_to be_valid
  end

  it "lets an admin set send-as on the member page; members can't" do
    admin = create(:membership, organization: org, role: "admin")
    patch "/api/v1/orgs/#{org.key}/members/#{member.key}",
      params: { send_as_addresses: ["sales@two.test"] }, headers: auth_headers(admin.user), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["member"]["send_as_addresses"]).to eq(["sales@two.test"])
    patch "/api/v1/orgs/#{org.key}/members/#{member.key}",
      params: { send_as_addresses: ["info@two.test"] }, headers: h, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end

RSpec.describe "Send-as can't claim a teammate's mailbox; scoped directory", type: :request do
  let!(:org) { create(:organization, domain: "one.test") }
  let!(:dom_b) { create(:domain, organization: org, name: "two.test") }
  let!(:alice) { create(:membership, organization: org, role: "member").tap { |m| m.mailboxes.create!(domain: dom_b, local_part: "alice") } }
  let!(:other_team) { create(:membership, organization: org, role: "member").tap { |m| m.update!(all_domains: false, domains: [org.default_domain]); m.mailboxes.create!(domain: org.default_domain, local_part: "zed") } }
  let!(:scoped) do
    create(:membership, organization: org, role: "member", user: create(:user, username: "alice2")).tap do |m|
      m.update!(all_domains: false, domains: [])
      m.mailboxes.create!(domain: dom_b, local_part: "bob")
    end
  end

  it "refuses a send-as grant of a teammate's mailbox" do
    scoped.send_as_addresses = ["alice@two.test"]
    expect(scoped).not_to be_valid
  end

  it "never lets a username stand in for a teammate's mailbox" do
    clash = create(:membership, organization: org, role: "member", user: create(:user, username: "alice"))
    expect(clash.can_send_as?("alice@two.test")).to be(false)
  end

  it "lists only teammates on the caller's domains, with only those domains' addresses" do
    get "/api/v1/orgs/#{org.key}/members", headers: auth_headers(scoped.user)
    rows = response.parsed_body["members"]
    expect(rows.map { |r| r["id"] }).not_to include(other_team.key)
    expect(rows.flat_map { |r| r["email_addresses"] }).to all(end_with("@two.test"))
  end
end

RSpec.describe "Send-as vs mailboxes, either order", type: :model do
  let!(:org) { create(:organization, domain: "one.test") }
  let(:dom) { org.default_domain }

  it "refuses a mailbox at an address already granted as send-as, and a grant never beats a mailbox" do
    granted = create(:membership, organization: org).tap { |m| m.update!(send_as_addresses: ["info@one.test"]) }
    other = create(:membership, organization: org)
    expect(other.mailboxes.build(domain: dom, local_part: "info")).not_to be_valid
    # A mailbox that predates the rule (or got there another way) still wins.
    Mailbox.new(membership: other, domain: dom, local_part: "info").save!(validate: false)
    expect(granted.can_send_as?("info@one.test")).to be(false)
  end

  it "keeps from_addresses to what can_send_as? allows" do
    m = create(:membership, organization: org, user: create(:user, username: "sam"))
    create(:membership, organization: org).mailboxes.create!(domain: dom, local_part: "sam")
    expect(m.from_addresses).not_to include("sam@one.test")
  end
end

RSpec.describe "Scoped member: no directory of the org's other teams (2026-11-08)", type: :request do
  let!(:org) { create(:organization, domain: "one.test") }
  let!(:dom_b) { create(:domain, organization: org, name: "two.test") }
  let!(:zed) do
    create(:membership, organization: org, role: "member", user: create(:user, username: "zed", display_name: "Zed Other"))
      .tap { |m| m.update!(all_domains: false, domains: [org.default_domain]); m.mailboxes.create!(domain: org.default_domain, local_part: "zed") }
  end
  let!(:scoped) do
    create(:membership, organization: org, role: "member").tap do |m|
      m.update!(all_domains: false, domains: [dom_b])
      m.mailboxes.create!(domain: dom_b, local_part: "bob")
    end
  end
  let(:h) { auth_headers(scoped.user) }
  let(:range) { { start: "2026-11-09T00:00:00Z", end: "2026-11-10T00:00:00Z" } }

  it "lists only their own domains' mailboxes" do
    get "/api/v1/orgs/#{org.key}/mailboxes", headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["mailboxes"].map { |m| m["email_address"] }).to eq(["bob@two.test"])
  end

  it "keeps other teams out of the calendar directory, free/busy and the scheduling grid" do
    get "/api/v1/orgs/#{org.key}/events/directory", headers: h
    expect(response.parsed_body["people"].map { |p| p["email"] }).to eq(["bob@two.test"])

    get "/api/v1/orgs/#{org.key}/events/free-busy", params: range.merge(emails: ["zed@one.test", "guest@out.test"]), headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["free_busy"].keys).not_to include("zed@one.test")

    get "/api/v1/orgs/#{org.key}/events/availability", params: range.merge(emails: ["zed@one.test", "guest@out.test"]), headers: h
    expect(response).to have_http_status(:ok)
    emails = response.parsed_body["attendees"].map { |a| a["email"] }
    expect(emails).to include("bob@two.test", "guest@out.test")
    expect(emails).not_to include("zed@one.test")
  end

  it "404s another domain's E2EE page and lists only teammates on their own" do
    get "/api/v1/orgs/#{org.key}/domains/#{org.default_domain.key}/e2ee", headers: h
    expect(response).to have_http_status(:not_found)
    get "/api/v1/orgs/#{org.key}/domains/#{dom_b.key}/e2ee", headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("e2ee", "members").map { |m| m["membership_id"] }).to eq([scoped.key])

    # A key grant on the other domain (a sealed thread assigned there) opens its
    # key page again, with the directory still their own teammates.
    key = org.default_domain.domain_keys.create!(version: 1, public_key: "pk")
    key.grants.create!(membership: scoped, sealed_secret_key: "sealed")
    get "/api/v1/orgs/#{org.key}/domains/#{org.default_domain.key}/e2ee", headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("e2ee", "my_grant", "sealed_secret_key")).to eq("sealed")
    expect(response.parsed_body.dig("e2ee", "members").map { |m| m["membership_id"] }).to eq([scoped.key])

    # Rotated away: a grant only on a retired version no longer opens the page.
    key.update!(retired_at: Time.current)
    org.default_domain.domain_keys.create!(version: 2, public_key: "pk2")
    get "/api/v1/orgs/#{org.key}/domains/#{org.default_domain.key}/e2ee", headers: h
    expect(response).to have_http_status(:not_found)
  end

  it "hides other teams' people from space member lists" do
    Space.ensure_default_spaces(org)
    space = org.spaces.first
    space.space_memberships.create!(membership: zed)
    space.space_memberships.create!(membership: scoped)
    get "/api/v1/orgs/#{org.key}/spaces", headers: h
    row = response.parsed_body["spaces"].find { |s| s["id"] == space.key }
    expect(row["members"].map { |m| m["key"] }).to eq([scoped.key])
  end
end
