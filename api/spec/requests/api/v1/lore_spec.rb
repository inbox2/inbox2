require "rails_helper"

# docs/Ontology.md — the Lore ontology API: entities, entity, graph.
RSpec.describe "Api::V1::Lore", type: :request do
  let(:owner) { create(:user, username: "loreowner") }
  let(:org) { create(:organization, owner: owner, domain: "lore-a.test") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:domain_a) { org.domains.first }
  let(:domain_b) { create(:domain, organization: org, name: "lore-b.test") }
  let(:base) { "/api/v1/orgs/#{org.key}/lore" }

  def mine(domain, from)
    conv = create(:conversation, organization: org, domain: domain, from_address: from)
    create(:message, conversation: conv, from_address: from)
    LoreMiner.new(conv).call(use_llm: false)
    conv
  end

  let!(:conv_a) { mine(domain_a, "jane@acme.com") }
  let!(:conv_b) { mine(domain_b, "bob@globex.com") }

  describe "GET entities" do
    it "lists entities with the declared fields, filterable by kind, q and domain" do
      get "#{base}/entities", headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["entities"]
      expect(rows.size).to eq(4)
      expect(rows.first.keys).to match_array(%w[id kind name email_domain address mention_count last_seen_at name_locked])

      get "#{base}/entities", params: { kind: "person", q: "jan" }, headers: auth_headers(owner)
      expect(response.parsed_body["entities"].map { |e| e["address"] }).to eq(["jane@acme.com"])

      get "#{base}/entities", params: { domain: "lore-b.test" }, headers: auth_headers(owner)
      expect(response.parsed_body["entities"].map { |e| e["name"] }).to match_array(%w[Bob Globex])
    end

    it "hides entities of domains a scoped member cannot read" do
      member = create(:user, username: "lorescoped")
      m = create(:membership, user: member, organization: org, role: "member", status: "active", all_domains: false)
      MembershipDomain.create!(membership: m, domain: domain_a)
      get "#{base}/entities", headers: auth_headers(member)
      expect(response.parsed_body["entities"].map { |e| e["email_domain"] }.uniq).to eq(["acme.com"])
    end

    it "404s for a non-member (tenant isolation)" do
      get "#{base}/entities", headers: auth_headers(create(:user, username: "loreoutsider"))
      expect(response).to have_http_status(:not_found)
    end

    it "401s without auth" do
      get "#{base}/entities"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET entities/:id" do
    it "returns facts with the related entity and the conversations" do
      person = LoreEntity.find_by!(address: "jane@acme.com")
      get "#{base}/entities/#{person.key}", headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
      e = response.parsed_body["entity"]
      expect(e["id"]).to eq(person.key)
      expect(e["conversations"]).to eq([conv_a.key])
      fact = e["facts"].sole
      expect(fact.keys).to match_array(%w[id kind name value related quote conversation_id confidence])
      expect(fact["related"]).to include("kind" => "organization", "name" => "Acme")
      expect(fact["conversation_id"]).to eq(conv_a.key)
    end

    it "404s for an entity of another org" do
      other = create(:organization, domain: "lore-other.test")
      conv = create(:conversation, organization: other, domain: other.domains.first)
      create(:message, conversation: conv, from_address: "x@initech.com")
      LoreMiner.new(conv).call(use_llm: false)
      get "#{base}/entities/#{LoreEntity.find_by!(address: 'x@initech.com').key}", headers: auth_headers(owner)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET graph" do
    it "returns nodes and works_at links between them" do
      get "#{base}/graph", headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["nodes"].first.keys).to match_array(%w[id kind name email_domain address weight])
      jane = LoreEntity.find_by!(address: "jane@acme.com")
      acme = LoreEntity.find_by!(name: "Acme")
      expect(body["links"]).to include({ "source" => jane.key, "target" => acme.key, "label" => "works_at", "weight" => 1 })
    end

    it "404s for a non-member" do
      get "#{base}/graph", headers: auth_headers(create(:user, username: "loreoutsider2"))
      expect(response).to have_http_status(:not_found)
    end
  end
end

# docs/TODO.md 48.15 — editing, and the miner keeping the edits.
RSpec.describe "Api::V1::Lore editing", type: :request do
  let(:owner) { create(:user, username: "loreedit") }
  let(:org) { create(:organization, owner: owner, domain: "edit-a.test") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:domain) { org.domains.first }
  let(:base) { "/api/v1/orgs/#{org.key}/lore" }

  def mine(from)
    conv = create(:conversation, organization: org, domain: domain, from_address: from)
    create(:message, conversation: conv, from_address: from)
    LoreMiner.new(conv).call(use_llm: false)
    conv
  end

  let!(:conv) { mine("jane@acme.com") }
  let(:person) { LoreEntity.find_by!(address: "jane@acme.com") }
  let(:acme) { LoreEntity.find_by!(kind: "organization", normalized_name: "acme") }
  let(:h) { auth_headers(owner) }

  it "renames, and the miner keeps the new name" do
    patch "#{base}/entities/#{person.key}", params: { name: "Jane Doe" }, headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("entity", "name")).to eq("Jane Doe")
    conv2 = create(:conversation, organization: org, domain: domain, from_address: "jane@acme.com")
    create(:message, conversation: conv2, from_address: "jane@acme.com")
    LoreMiner.new(conv2).call(from_name: "Janey", use_llm: false)
    expect(person.reload.name).to eq("Jane Doe")
  end

  it "refuses a blank rename, and an unknown kind" do
    patch "#{base}/entities/#{person.key}", params: { name: " " }, headers: h
    expect(response).to have_http_status(:unprocessable_content)
    patch "#{base}/entities/#{person.key}", params: { kind: "spaceship" }, headers: h
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "changes kind, and the headers pass lands on the same entity" do
    patch "#{base}/entities/#{person.key}", params: { kind: "project" }, headers: h
    expect(response).to have_http_status(:ok)
    expect(person.reload.kind).to eq("project")
    mine("jane@acme.com")
    expect(LoreEntity.live.where(normalized_name: "jane@acme.com").pluck(:kind)).to eq(["project"])
    expect(person.reload.mention_count).to eq(2)
  end

  it "removes, and the miner does not bring it back" do
    delete "#{base}/entities/#{acme.key}", headers: h
    expect(response).to have_http_status(:no_content)
    get "#{base}/entities/#{acme.key}", headers: h
    expect(response).to have_http_status(:not_found)
    mine("bob@acme.com")
    expect(LoreEntity.live.where(kind: "organization", normalized_name: "acme")).to be_empty
    get "#{base}/entities", headers: h
    expect(response.parsed_body["entities"].map { |e| e["name"] }).not_to include("Acme")
  end

  it "edits and removes a fact, and the miner keeps both" do
    fact = person.facts.first
    patch "#{base}/entities/#{person.key}/facts/#{fact.fingerprint}", params: { value: "Acme Holding" }, headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("fact", "value")).to eq("Acme Holding")
    mine("jane@acme.com")
    expect(person.reload.facts.live.count).to eq(1)
    expect(fact.reload.value).to eq("Acme Holding")

    delete "#{base}/entities/#{person.key}/facts/#{fact.fingerprint}", headers: h
    expect(response).to have_http_status(:no_content)
    mine("jane@acme.com")
    get "#{base}/entities/#{person.key}", headers: h
    expect(response.parsed_body.dig("entity", "facts")).to eq([])
  end

  it "merges: facts, mentions and relations move, and later mail lands on the target" do
    mine("bo@globex.com")
    bo = LoreEntity.find_by!(address: "bo@globex.com")
    jane_fact_fp = person.facts.first.fingerprint
    post "#{base}/entities/#{bo.key}/merge", params: { into: person.key }, headers: h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("entity", "id")).to eq(person.key)
    expect(person.reload.mention_count).to eq(2)
    expect(person.facts.pluck(:fingerprint)).to include(jane_fact_fp)
    get "#{base}/entities/#{bo.key}", headers: h
    expect(response).to have_http_status(:not_found)

    mine("bo@globex.com")
    expect(person.reload.mention_count).to eq(3)
    expect(LoreEntity.live.where(address: "bo@globex.com")).to be_empty
  end

  it "refuses merging into itself, or across domains" do
    post "#{base}/entities/#{person.key}/merge", params: { into: person.key }, headers: h
    expect(response).to have_http_status(:unprocessable_content)
    other_dom = create(:domain, organization: org, name: "edit-b.test")
    other = LoreEntity.create!(organization: org, domain: other_dom, kind: "project", name: "X", normalized_name: "x")
    post "#{base}/entities/#{person.key}/merge", params: { into: other.key }, headers: h
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "404s for a non-member and for another org's entity (tenant isolation)" do
    patch "#{base}/entities/#{person.key}", params: { name: "X" }, headers: auth_headers(create(:user, username: "editout"))
    expect(response).to have_http_status(:not_found)
    other_org = create(:organization, owner: owner, domain: "edit-other.test")
    create(:membership, user: owner, organization: other_org, role: "owner", status: "active")
    patch "/api/v1/orgs/#{other_org.key}/lore/entities/#{person.key}", params: { name: "X" }, headers: h
    expect(response).to have_http_status(:not_found)
    delete "#{base}/entities/ent_missing", headers: h
    expect(response).to have_http_status(:not_found)
  end
end
