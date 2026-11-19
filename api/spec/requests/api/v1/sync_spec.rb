require "rails_helper"

# MX sync protocol (docs/MX-Sync.md, spec 16.7). Transactional tests share one
# transaction with the request, which is exactly the "own writes are visible"
# branch of the horizon filter — the horizon itself is exercised by faking a
# row's writing transaction (see "commit-order safety").
RSpec.describe "Sync API (spec 16.7)", type: :request do
  let(:owner) { create(:user, username: "sync_owner") }
  let(:org) { create(:organization, owner: owner, domain: "sync-test.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { { "Authorization" => "Bearer #{create(:session, user: owner).token}" } }
  let(:base) { "/api/v1/orgs/#{org.key}/sync" }

  def pull(since: nil, limit: nil, as: headers)
    get "#{base}/pull", params: { since: since, limit: limit }.compact, headers: as
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def ids(data, type) = data.dig("records", type).map { |r| r["id"] }

  # Drain every page; returns [all pages merged, final cursor].
  def pull_all(since: nil, limit: nil)
    seen = Hash.new { |h, k| h[k] = [] }
    loop do
      data = pull(since: since, limit: limit)
      %w[conversations messages notes].each { |t| seen[t].concat(ids(data, t)) }
      seen["deleted"].concat(data["deleted"])
      since = data["cursor"]
      return [seen, since] unless data["has_more"]
    end
  end

  describe "GET sync/pull" do
    it "returns changed records in the API's own shapes, then nothing on the returned cursor" do
      conv = create(:conversation, organization: org, subject: "Hello")
      msg = create(:message, conversation: conv, organization: org)
      note = create(:note, conversation: conv, organization: org, membership: membership)

      data = pull
      expect(ids(data, "conversations")).to eq([conv.key])
      expect(ids(data, "messages")).to eq([msg.key])
      expect(ids(data, "notes")).to eq([note.key])
      row = data.dig("records", "conversations", 0)
      expect(row).to include("subject" => "Hello", "domain_id" => conv.domain&.key)
      expect(row["change_seq"]).to be > 0
      expect(data.dig("records", "messages", 0, "conversation_id")).to eq(conv.key)
      expect(data.dig("records", "notes", 0, "conversation_id")).to eq(conv.key)
      expect(data.to_json).not_to match(/"(organization_id|change_xid)"/) # E4/E5

      again = pull(since: data["cursor"])
      expect(again["records"].values.flatten).to be_empty
      expect(again["has_more"]).to be false
    end

    it "sees update_all writes (bulk archive skips callbacks)" do
      conv = create(:conversation, organization: org)
      cursor = pull["cursor"]

      Conversation.where(id: conv.id).update_all(status: Conversation::STATUS_ARCHIVED)
      data = pull(since: cursor)
      expect(data.dig("records", "conversations", 0)).to include("id" => conv.key, "status" => "archived")
    end

    it "always ships a changed message's parent thread (the local FK needs it)" do
      conv = create(:conversation, organization: org)
      cursor = pull["cursor"]

      msg = create(:message, conversation: conv, organization: org)
      data = pull(since: cursor)
      expect(ids(data, "messages")).to eq([msg.key])
      expect(ids(data, "conversations")).to eq([conv.key])
    end

    it "reports deletes" do
      conv = create(:conversation, organization: org)
      msg = create(:message, conversation: conv, organization: org)
      cursor = pull["cursor"]

      draft = create(:message, conversation: conv, organization: org)
      draft.destroy!
      data = pull(since: cursor)
      expect(data["deleted"]).to eq([{ "type" => "message", "id" => draft.key }])

      # A deleted thread is one tombstone — it covers its children on the client.
      conv.destroy!
      expect(pull(since: data["cursor"])["deleted"]).to eq([{ "type" => "conversation", "id" => conv.key }])
      expect(SyncTombstone.where(record_key: msg.key)).to exist
    end

    it "pages without losing or repeating a row" do
      convs = 7.times.map { create(:conversation, organization: org) }
      seen, = pull_all(limit: 3)
      expect(seen["conversations"]).to match_array(convs.map(&:key))
    end

    it "stops a page early at the byte budget and resumes after it" do
      stub_const("Api::V1::SyncController::BYTE_BUDGET", 1_000)
      conv = create(:conversation, organization: org)
      msgs = 3.times.map { create(:message, conversation: conv, organization: org, body_plain: "x" * 800) }

      first = pull
      expect(first["has_more"]).to be true
      expect(ids(first, "messages").size).to be < 3
      seen, = pull_all
      expect(seen["messages"].uniq).to match_array(msgs.map(&:key))
    end

    it "rejects a malformed cursor" do
      get "#{base}/pull", params: { since: "2026-01-01T00:00:00Z" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "flags a cursor older than the pruned-tombstone watermark" do
      create(:conversation, organization: org)
      cursor = pull["cursor"]
      xid = cursor.split(".").first.to_i
      SyncTombstone.create!(organization_id: org.id, record_type: "note", record_key: "note_x",
                            change_seq: 1, change_xid: xid + 5, created_at: 100.days.ago)

      expect(pull(since: cursor)["cursor_expired"]).to be true
      expect(pull["cursor_expired"]).to be false # a fresh client has nothing to lose
    end

    it "restarts a cursor from another database (xids past this one's) and flags it expired" do
      create(:conversation, organization: org)
      data = pull(since: "999999999999.0")
      expect(data["cursor_expired"]).to be true
      expect(data["cursor"].split(".").first.to_i).to be < 999_999_999_999
      # The client can carry on from the reset cursor: new writes reach it.
      conv = create(:conversation, organization: org)
      expect(ids(pull(since: data["cursor"]), "conversations")).to include(conv.key)
    end

    describe "commit-order safety" do
      # Re-stamp a row as if another, still-running transaction had written it.
      def written_by(conv, xid)
        conn = ActiveRecord::Base.connection
        conn.execute("ALTER TABLE conversations DISABLE TRIGGER sync_stamp")
        Conversation.where(id: conv.id).update_all(change_xid: xid)
        conn.execute("ALTER TABLE conversations ENABLE TRIGGER sync_stamp")
      end

      it "withholds rows from in-flight transactions and never moves the cursor past them" do
        conv = create(:conversation, organization: org)
        get "#{base}/head", headers: headers
        hi = response.parsed_body["cursor"].split(".").first.to_i
        written_by(conv, hi + 3)

        data = pull
        expect(ids(data, "conversations")).to be_empty
        expect(data["cursor"].split(".").first.to_i).to be <= hi + 3

        # …that transaction commits and the horizon moves on: the row arrives.
        allow_any_instance_of(Api::V1::SyncController).to receive(:horizon).and_return(hi + 10)
        expect(ids(pull(since: data["cursor"]), "conversations")).to eq([conv.key])
      end
    end

    describe "visibility (E3)" do
      let(:member_user) { create(:user, username: "sync_member") }
      let!(:member) { create(:membership, user: member_user, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE, all_domains: false) }
      let(:member_headers) { { "Authorization" => "Bearer #{create(:session, user: member_user).token}" } }
      let(:conv) { create(:conversation, organization: org, domain: org.default_domain) }

      it "never ships a thread the member can't see, nor its messages or notes" do
        msg = create(:message, conversation: conv, organization: org)
        create(:note, conversation: conv, organization: org, membership: membership)

        data = pull(as: member_headers)
        expect(data["records"].values.flatten).to be_empty
        expect(data.to_json).not_to include(msg.key)
      end

      it "hides deleted messages of threads the member can't see, and reports them once visible" do
        hidden = create(:message, conversation: conv, organization: org)
        shared = create(:conversation, organization: org, domain: org.default_domain)
        shared.conversation_assignees.create!(membership: member)
        shown = create(:message, conversation: shared, organization: org)
        cursor = pull(as: member_headers)["cursor"]

        hidden.destroy!
        shown.destroy!
        deleted = pull(since: cursor, as: member_headers)["deleted"]
        expect(deleted).to include({ "type" => "message", "id" => shown.key })
        expect(deleted.to_json).not_to include(hidden.key)
      end

      it "delivers a thread when it is assigned, and deletes it when the assignment is revoked" do
        create(:message, conversation: conv, organization: org)
        cursor = pull(as: member_headers)["cursor"]

        conv.conversation_assignees.create!(membership: member)
        data = pull(since: cursor, as: member_headers)
        expect(ids(data, "conversations")).to eq([conv.key])

        conv.conversation_assignees.destroy_all
        data = pull(since: data["cursor"], as: member_headers)
        expect(ids(data, "conversations")).to be_empty
        expect(data["deleted"]).to include({ "type" => "conversation", "id" => conv.key })
      end
    end

    it "is tenant-isolated" do
      other_org = create(:organization, domain: "other-sync.com")
      foreign = create(:conversation, organization: other_org)
      create(:message, conversation: foreign, organization: other_org)
      foreign_key = foreign.key
      foreign.destroy!

      data = pull
      expect(data.to_json).not_to include(foreign_key)

      get "/api/v1/orgs/#{other_org.key}/sync/pull", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "#{base}/pull"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET sync/backfill" do
    it "walks history newest-first in whole threads, including rows that predate change tracking" do
      convs = 5.times.map { |i| create(:conversation, organization: org, updated_at: i.days.ago) }
      convs.each { |c| create(:message, conversation: c, organization: org) }
      ActiveRecord::Base.connection.execute("ALTER TABLE conversations DISABLE TRIGGER sync_stamp")
      Conversation.where(id: convs.map(&:id)).update_all(change_seq: nil, change_xid: nil)
      ActiveRecord::Base.connection.execute("ALTER TABLE conversations ENABLE TRIGGER sync_stamp")

      seen, token = [], nil
      loop do
        get "#{base}/backfill", params: { before: token, limit: 2 }.compact, headers: headers
        data = response.parsed_body
        page = data.dig("records", "conversations")
        expect(data.dig("records", "messages").map { |m| m["conversation_id"] }).to match_array(page.map { |c| c["id"] })
        seen.concat(page.map { |c| c["id"] })
        token = data["next"] or break
      end
      expect(seen).to eq(convs.map(&:key))
    end

    it "rejects a malformed token" do
      get "#{base}/backfill", params: { before: "nope" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET sync/keys" do
    it "lists every visible thread with its version" do
      convs = 3.times.map { create(:conversation, organization: org) }
      create(:conversation, organization: create(:organization, domain: "keys-other.com"))

      stub_const("Api::V1::SyncController::KEYS_LIMIT", 2)
      keys, after = [], nil
      loop do
        get "#{base}/keys", params: { after: after }.compact, headers: headers
        keys.concat(response.parsed_body["keys"])
        after = response.parsed_body["next"] or break
      end
      expect(keys.map(&:first)).to match_array(convs.map(&:key))
      expect(keys.map(&:last)).to all(be > 0)
    end
  end

  describe "GET sync/threads" do
    it "returns whole visible threads in sync shapes and names the ones it can't" do
      conv = create(:conversation, organization: org)
      msg = create(:message, conversation: conv, organization: org)
      note = create(:note, conversation: conv, organization: org, membership: membership)
      foreign = create(:conversation, organization: create(:organization, domain: "threads-other.com"))

      get "#{base}/threads", params: { ids: [conv.key, foreign.key, "conv_nope"] }, headers: headers
      data = response.parsed_body
      expect(ids(data, "conversations")).to eq([conv.key])
      expect(ids(data, "messages")).to eq([msg.key])
      expect(ids(data, "notes")).to eq([note.key])
      expect(data.dig("records", "conversations", 0)).to include("change_seq", "domain_id")
      expect(data["missing"]).to contain_exactly(foreign.key, "conv_nope")
      expect(data["remaining"]).to be_empty
    end

    it "leaves out a colleague's draft but carries the member's own" do
      conv = create(:conversation, organization: org)
      mate = create(:membership, organization: org, role: "member", status: "active")
      theirs = create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: mate.id)
      mine = create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: membership.id)

      get "#{base}/threads", params: { ids: [conv.key] }, headers: headers
      expect(ids(response.parsed_body, "messages")).to eq([mine.key])
      expect(ids(response.parsed_body, "messages")).not_to include(theirs.key)
    end

    it "hands back what didn't fit the byte budget" do
      stub_const("Api::V1::SyncController::BYTE_BUDGET", 1_000)
      convs = 3.times.map do
        create(:conversation, organization: org).tap { |c| create(:message, conversation: c, organization: org, body_plain: "x" * 800) }
      end

      get "#{base}/threads", params: { ids: convs.map(&:key) }, headers: headers
      data = response.parsed_body
      expect(ids(data, "conversations").size).to eq(1)
      expect(ids(data, "conversations") + data["remaining"]).to match_array(convs.map(&:key))
    end
  end

  it "has no push endpoint — writes go through the real endpoints" do
    post "#{base}/push", params: { changes: [] }, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "nudges the org's devices after a write, debounced" do
    conv = create(:conversation, organization: org)
    Api::V1::BaseController::SYNC_HINT_SENT.clear
    expect(ActionCable.server).to receive(:broadcast).with("organization_#{org.key}", { type: "sync", scope: "mail" }).once
    allow(ActionCable.server).to receive(:broadcast) # anything else the action sends
    2.times { patch "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", params: { read: true }, headers: headers }
  end
end
