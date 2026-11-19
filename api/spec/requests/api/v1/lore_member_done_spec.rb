require "rails_helper"

# docs/TODO.md 48.11 — per-member done for Lore's personal buckets on a shared domain.
RSpec.describe "Lore per-member done", type: :request do
  let(:owner) { create(:user, username: "lmd_owner") }
  let(:teammate) { create(:user, username: "lmd_mate") }
  let(:org) { create(:organization, owner: owner, domain: "lmd.test") }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:mate_m) { create(:membership, user: teammate, organization: org, role: "member", status: "active") }
  let!(:fyi) { create(:conversation, organization: org, status: "open", triage_label: TriageLabel::FYI) }
  let!(:work) { create(:conversation, organization: org, status: "open", triage_label: TriageLabel::ACTION_REQUIRED) }
  let(:base) { "/api/v1/orgs/#{org.key}/conversations" }

  def bulk(user, ids, action)
    post "#{base}/bulk", params: { conversation_ids: ids, action_name: action }, headers: auth_headers(user)
  end

  def listed(user, **params)
    get base, params: params, headers: auth_headers(user)
    response.parsed_body["conversations"].index_by { |c| c["id"] }
  end

  it "hides a personal item for the member who ticked it, and only them" do
    bulk(owner, [fyi.key], LoreMemberDone::ACTION_DONE)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["updated"]).to eq(1)
    expect(fyi.reload.status).to eq("open") # the thread itself is untouched

    expect(listed(owner, lore_done: "false")).not_to have_key(fyi.key)
    expect(listed(owner, lore_done: "true").keys).to eq([fyi.key])
    expect(listed(owner)[fyi.key]["lore_done"]).to be(true)

    expect(listed(teammate, lore_done: "false")).to have_key(fyi.key)
    expect(listed(teammate)[fyi.key]["lore_done"]).to be(false)
  end

  it "reverses on undo, and a repeat is harmless" do
    2.times { bulk(owner, [fyi.key], LoreMemberDone::ACTION_DONE) }
    expect(response.parsed_body["updated"]).to eq(1)
    expect(LoreMemberDone.count).to eq(1)
    bulk(owner, [fyi.key], LoreMemberDone::ACTION_UNDONE)
    expect(response).to have_http_status(:ok)
    expect(LoreMemberDone.count).to eq(0)
    expect(listed(owner, lore_done: "false")).to have_key(fyi.key)
  end

  it "leaves work items out: they archive for the team" do
    bulk(owner, [work.key], LoreMemberDone::ACTION_DONE)
    expect(response.parsed_body["updated"]).to eq(0)
    expect(LoreMemberDone.count).to eq(0)
  end

  it "cannot reach another org's thread (422, same as every bulk miss)" do
    other = create(:conversation, organization: create(:organization, domain: "other-lmd.test"), triage_label: TriageLabel::FYI)
    bulk(owner, [other.key], LoreMemberDone::ACTION_DONE)
    expect(response).to have_http_status(:unprocessable_content)
    expect(LoreMemberDone.count).to eq(0)
  end

  it "404s for a non-member" do
    bulk(create(:user, username: "lmd_out"), [fyi.key], LoreMemberDone::ACTION_DONE)
    expect(response).to have_http_status(:not_found)
  end

  it "bumps the thread version, and each member's mirror reads its own value" do
    before_seq = fyi.reload.change_seq
    bulk(owner, [fyi.key], LoreMemberDone::ACTION_DONE)
    expect(fyi.reload.change_seq).to be > before_seq

    read = lambda do |user|
      get "/api/v1/orgs/#{org.key}/sync/threads", params: { ids: [fyi.key] }, headers: auth_headers(user)
      response.parsed_body.dig("records", "conversations", 0, "lore_done")
    end
    expect(read.call(owner)).to be(true)
    expect(read.call(teammate)).to be(false)
  end

  it "comes back when new mail threads in" do
    LoreMemberDone.mark!([fyi], owner_m)
    InboundMailProcessor.allocate.send(:revive_hidden_thread, fyi)
    expect(LoreMemberDone.count).to eq(0)
  end
end
