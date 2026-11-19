require "rails_helper"

RSpec.describe RuleExecutor do
  let(:owner) { create(:user, username: "ruleexecowner") }
  let(:org) { create(:organization, owner: owner, domain: "ruleexec.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org, subject: "Invoice #123", from_address: "billing@client.com") }
  let(:message) { create(:message, conversation: conv, organization: org, from_address: "billing@client.com", to_address: "sales@ruleexec.com") }

  subject { described_class.new(org) }

  describe "#execute_for" do
    it "matches from condition and applies tag action (spec 7.2.2, 7.3.3)" do
      tag = create(:tag, organization: org, name: "billing")
      create(:rule, organization: org,
        conditions: [{ "field" => "from", "operator" => "contains", "value" => "billing" }],
        actions: [{ "type" => "add_tag", "value" => "billing" }])

      subject.execute_for(conv, message)
      expect(conv.tags).to include(tag)
    end

    it "matches subject condition and sets status (spec 7.2.3, 7.3.4)" do
      create(:rule, organization: org,
        conditions: [{ "field" => "subject", "operator" => "contains", "value" => "Invoice" }],
        actions: [{ "type" => "set_status", "value" => Conversation::STATUS_PENDING }])

      subject.execute_for(conv, message)
      expect(conv.reload.status).to eq(Conversation::STATUS_PENDING)
    end

    it "matches to condition and assigns member (spec 7.2.1, 7.3.1)" do
      create(:rule, organization: org,
        conditions: [{ "field" => "to", "operator" => "contains", "value" => "sales@" }],
        actions: [{ "type" => "assign", "value" => membership.key }])

      subject.execute_for(conv, message)
      expect(conv.assignees).to include(membership)
    end

    it "skips disabled rules" do
      tag = create(:tag, organization: org, name: "skip")
      create(:rule, organization: org, enabled: false,
        conditions: [{ "field" => "from", "operator" => "contains", "value" => "billing" }],
        actions: [{ "type" => "add_tag", "value" => "skip" }])

      subject.execute_for(conv, message)
      expect(conv.tags).not_to include(tag)
    end

    it "requires ALL conditions to match (AND logic)" do
      tag = create(:tag, organization: org, name: "both")
      create(:rule, organization: org,
        conditions: [
          { "field" => "from", "operator" => "contains", "value" => "billing" },
          { "field" => "subject", "operator" => "contains", "value" => "NONEXISTENT" }
        ],
        actions: [{ "type" => "add_tag", "value" => "both" }])

      subject.execute_for(conv, message)
      expect(conv.tags).not_to include(tag)
    end

    # spec 7.3.12 — Conditional branching
    context "with conditional branching" do
      it "applies else_actions when main conditions do not match" do
        tag = create(:tag, organization: org, name: "fallback")
        create(:rule, organization: org,
          conditions: [{ "field" => "from", "operator" => "equals", "value" => "nobody@example.com" }],
          actions: [{ "type" => "set_status", "value" => Conversation::STATUS_ARCHIVED }],
          else_actions: [{ "type" => "add_tag", "value" => "fallback" }])

        subject.execute_for(conv, message)
        expect(conv.tags).to include(tag)
        expect(conv.reload.status).not_to eq(Conversation::STATUS_ARCHIVED)
      end

      it "applies branch actions when branch conditions match" do
        tag = create(:tag, organization: org, name: "branch-hit")
        create(:rule, organization: org,
          conditions: [{ "field" => "from", "operator" => "equals", "value" => "nobody@example.com" }],
          actions: [{ "type" => "set_status", "value" => Conversation::STATUS_ARCHIVED }],
          branches: [
            {
              "conditions" => [{ "field" => "subject", "operator" => "contains", "value" => "Invoice" }],
              "actions" => [{ "type" => "add_tag", "value" => "branch-hit" }]
            }
          ],
          else_actions: [{ "type" => "set_status", "value" => Conversation::STATUS_SPAM }])

        subject.execute_for(conv, message)
        expect(conv.tags).to include(tag)
        expect(conv.reload.status).not_to eq(Conversation::STATUS_ARCHIVED)
        expect(conv.reload.status).not_to eq(Conversation::STATUS_SPAM)
      end

      it "applies else_actions when no branch matches" do
        tag_else = create(:tag, organization: org, name: "else-tag")
        create(:rule, organization: org,
          conditions: [{ "field" => "from", "operator" => "equals", "value" => "nobody@example.com" }],
          actions: [{ "type" => "set_status", "value" => Conversation::STATUS_ARCHIVED }],
          branches: [
            {
              "conditions" => [{ "field" => "subject", "operator" => "contains", "value" => "NOMATCH" }],
              "actions" => [{ "type" => "set_status", "value" => Conversation::STATUS_PENDING }]
            }
          ],
          else_actions: [{ "type" => "add_tag", "value" => "else-tag" }])

        subject.execute_for(conv, message)
        expect(conv.tags).to include(tag_else)
        expect(conv.reload.status).not_to eq(Conversation::STATUS_ARCHIVED)
        expect(conv.reload.status).not_to eq(Conversation::STATUS_PENDING)
      end

      it "stops at first matching branch (short-circuit)" do
        tag1 = create(:tag, organization: org, name: "branch1")
        tag2 = create(:tag, organization: org, name: "branch2")
        create(:rule, organization: org,
          conditions: [{ "field" => "from", "operator" => "equals", "value" => "nobody@example.com" }],
          actions: [],
          branches: [
            {
              "conditions" => [{ "field" => "from", "operator" => "contains", "value" => "billing" }],
              "actions" => [{ "type" => "add_tag", "value" => "branch1" }]
            },
            {
              "conditions" => [{ "field" => "subject", "operator" => "contains", "value" => "Invoice" }],
              "actions" => [{ "type" => "add_tag", "value" => "branch2" }]
            }
          ])

        subject.execute_for(conv, message)
        expect(conv.tags).to include(tag1)
        expect(conv.tags).not_to include(tag2)
      end

      it "skips branching when main conditions match" do
        main_tag = create(:tag, organization: org, name: "main")
        branch_tag = create(:tag, organization: org, name: "branch")
        create(:rule, organization: org,
          conditions: [{ "field" => "from", "operator" => "contains", "value" => "billing" }],
          actions: [{ "type" => "add_tag", "value" => "main" }],
          branches: [
            {
              "conditions" => [{ "field" => "subject", "operator" => "contains", "value" => "Invoice" }],
              "actions" => [{ "type" => "add_tag", "value" => "branch" }]
            }
          ],
          else_actions: [{ "type" => "set_status", "value" => Conversation::STATUS_SPAM }])

        subject.execute_for(conv, message)
        expect(conv.tags).to include(main_tag)
        expect(conv.tags).not_to include(branch_tag)
        expect(conv.reload.status).not_to eq(Conversation::STATUS_SPAM)
      end
    end

    # Field-name vocabulary matches the Rust core (from/to, no aliases);
    # has_attachment is a real boolean.
    context "with from/to fields and has_attachment (Rust-aligned)" do
      it "matches the 'from' field" do
        expect(described_class.new(org).match_rule?(
          [{ "field" => "from", "operator" => "contains", "value" => "billing" }], conv, message
        )).to be(true)
      end

      it "matches the 'to' field" do
        expect(described_class.new(org).match_rule?(
          [{ "field" => "to", "operator" => "contains", "value" => "sales@" }], conv, message
        )).to be(true)
      end

      it "does not recognise the old 'sender'/'recipient' field names" do
        %w[sender recipient].each do |field|
          expect(described_class.new(org).match_rule?(
            [{ "field" => field, "operator" => "contains", "value" => "billing" }], conv, message
          )).to be(false)
        end
      end

      it "treats an empty condition set as never matching" do
        expect(described_class.new(org).match_rule?([], conv, message)).to be(false)
      end

      it "evaluates has_attachment is_true/is_false against the real attachment state" do
        executor = described_class.new(org)
        expect(executor.match_rule?([{ "field" => "has_attachment", "operator" => "is_false", "value" => "" }], conv, message)).to be(true)
        expect(executor.match_rule?([{ "field" => "has_attachment", "operator" => "is_true", "value" => "" }], conv, message)).to be(false)

        create(:attachment, message: message)
        expect(executor.match_rule?([{ "field" => "has_attachment", "operator" => "is_true", "value" => "" }], conv, message.reload)).to be(true)
      end
    end

    # spec 7.3.11 — Stop processing
    context "with stop_processing flag" do
      it "stops processing subsequent rules when stop_processing is true" do
        tag1 = create(:tag, organization: org, name: "first")
        tag2 = create(:tag, organization: org, name: "second")

        create(:rule, organization: org, position: 0, stop_processing: true,
          conditions: [{ "field" => "from", "operator" => "contains", "value" => "billing" }],
          actions: [{ "type" => "add_tag", "value" => "first" }])
        create(:rule, organization: org, position: 1,
          conditions: [{ "field" => "from", "operator" => "contains", "value" => "billing" }],
          actions: [{ "type" => "add_tag", "value" => "second" }])

        subject.execute_for(conv, message)
        expect(conv.tags).to include(tag1)
        expect(conv.tags).not_to include(tag2)
      end
    end
  end
end
