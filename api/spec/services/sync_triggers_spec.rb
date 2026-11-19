require "rails_helper"

# docs/MX-Sync.md — the change tracking lives in Postgres triggers that schema.rb
# cannot express. If this file fails with "trigger missing", the schema-load hook
# (config/initializers/sync_triggers.rb) stopped installing them and every other
# sync spec is testing nothing.
RSpec.describe SyncTriggers do
  let(:org) { create(:organization) }
  let(:conv) { create(:conversation, organization: org) }

  def seq(record) = record.class.where(id: record.id).pick(:change_seq)

  it "is installed in this database" do
    names = ActiveRecord::Base.connection.select_values(
      "SELECT tgname FROM pg_trigger WHERE tgname LIKE 'sync_%' AND NOT tgisinternal"
    )
    expected = SyncTriggers::STAMPED.size * 2 + SyncTriggers::BUMPS.size * 3
    expect(names.size).to eq(expected)
  end

  it "stamps inserts and updates — including update_all, which skips callbacks" do
    before = seq(conv)
    expect(before).to be_present

    Conversation.where(id: conv.id).update_all(status: Conversation::STATUS_ARCHIVED)
    expect(seq(conv)).to be > before
    expect(Conversation.where(id: conv.id).pick(:change_xid)).to be_present
  end

  it "bumps the thread version when a child changes" do
    v0 = seq(conv)
    msg = create(:message, conversation: conv, organization: org)
    v1 = seq(conv)
    expect(v1).to be > v0

    tag = create(:tag, organization: org)
    conv.tags << tag
    v2 = seq(conv)
    expect(v2).to be > v1

    conv.conversation_tags.delete_all
    v3 = seq(conv)
    expect(v3).to be > v2

    create(:attachment, message: msg, organization: org)
    expect(seq(msg)).to be > 0
    expect(seq(conv)).to be > v3
  end

  it "bumps both threads when messages move (merge)" do
    target = create(:conversation, organization: org)
    create(:message, conversation: conv, organization: org)
    a, b = seq(conv), seq(target)

    conv.messages.update_all(conversation_id: target.id)
    expect(seq(conv)).to be > a
    expect(seq(target)).to be > b
  end

  it "writes tombstones on delete — including delete_all and cascades" do
    msg = create(:message, conversation: conv, organization: org)
    Message.where(id: msg.id).delete_all
    expect(SyncTombstone.where(record_type: "message", record_key: msg.key, organization_id: org.id)).to exist

    key = conv.key
    conv.destroy!
    stone = SyncTombstone.find_by(record_type: "conversation", record_key: key)
    expect(stone.change_seq).to be_present
    expect(stone.change_xid).to be_present
  end

  it "records the thread a deleted message belonged to" do
    msg = create(:message, conversation: conv, organization: org)
    msg.destroy!
    expect(SyncTombstone.find_by(record_key: msg.key).parent_key).to eq(conv.key)
  end

  it "keeps each org's newest expired tombstone as its prune watermark" do
    other = create(:organization)
    SyncTombstone.create!(organization_id: other.id, record_type: "note", record_key: "note_o",
                          change_seq: 1, change_xid: 1, created_at: 200.days.ago)

    old = 2.times.map do |i|
      SyncTombstone.create!(organization_id: org.id, record_type: "note", record_key: "note_#{i}",
                            change_seq: i + 1, change_xid: i + 1, created_at: 100.days.ago)
    end
    fresh = SyncTombstone.create!(organization_id: org.id, record_type: "note", record_key: "note_f",
                                  change_seq: 9, change_xid: 9, created_at: 1.day.ago)

    SyncTombstone.prune!
    expect(SyncTombstone.where(organization_id: org.id).pluck(:id)).to contain_exactly(old.last.id, fresh.id)
    expect(SyncTombstone.watermark_xid(org.id)).to eq(2)
    expect(SyncTombstone.watermark_xid(other.id)).to eq(1) # an older id than org's survivors
  end
end
