require "rails_helper"

RSpec.describe PurgeExpiredJunkJob do
  let(:owner) { create(:user, username: "purgeowner") }
  let(:org) { create(:organization, owner: owner, domain: "purge.com") }

  # updated_at is the retention clock; set it directly to age a record past cutoff.
  def aged(status, age)
    conv = create(:conversation, organization: org, status: status)
    conv.update_column(:updated_at, age)
    conv
  end

  describe "#perform" do
    it "permanently deletes spam/trash older than the retention window" do
      old_spam  = aged("spam", 31.days.ago)
      old_trash = aged("trash", 40.days.ago)

      count = described_class.new.perform

      expect(count).to eq(2)
      expect(Conversation.where(id: [old_spam.id, old_trash.id])).to be_empty
    end

    it "keeps junk that is still within the window" do
      recent_spam = aged("spam", 29.days.ago)

      described_class.new.perform

      expect(recent_spam.reload).to be_present
    end

    it "never purges non-disposable folders, however old" do
      old_archived = aged("archived", 90.days.ago)
      old_open     = aged("open", 90.days.ago)

      described_class.new.perform

      expect(old_archived.reload).to be_present
      expect(old_open.reload).to be_present
    end

    it "cascades to the conversation's messages" do
      old_spam = aged("spam", 31.days.ago)
      create(:message, organization: org, conversation: old_spam, body_plain: "junk")

      expect { described_class.new.perform }
        .to change { Message.where(conversation_id: old_spam.id).count }.to(0)
    end

    # The nightly run died here for months: rule_logs holds a DB-level FK to
    # conversations and Conversation declared no dependent rule, so `destroy`
    # raised ActiveRecord::InvalidForeignKey on the first purgeable thread and
    # nothing was ever purged. Every conversation-destroying path had it.
    it "cascades to rule logs and releases agent run logs" do
      old_spam = aged("spam", 31.days.ago)
      rule = create(:rule, organization: org)
      RuleLog.create!(rule: rule, conversation: old_spam, result: "matched", actions_taken: [])
      agent = create(:agent, organization: org)
      run = AgentRunLog.create!(agent: agent, conversation: old_spam, action: "tag",
                                status: AgentRunLog::STATUS_SUCCESS, cost_cents: 7)

      expect { described_class.new.perform }.not_to raise_error

      expect(Conversation.where(id: old_spam.id)).to be_empty
      expect(RuleLog.where(conversation_id: old_spam.id)).to be_empty
      # Usage the org is billed on outlives the thread, just unlinked.
      expect(run.reload.conversation_id).to be_nil
      expect(run.cost_cents).to eq(7)
    end

    it "honours a custom retention window" do
      recent = aged("spam", 10.days.ago)
      described_class.new.perform(retention: 7.days)
      expect(Conversation.where(id: recent.id)).to be_empty
    end
  end
end
