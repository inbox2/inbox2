require "rails_helper"

RSpec.describe DraftChannel, type: :channel do
  let(:owner) { create(:user, username: "draftowner") }
  let(:org) { create(:organization, owner: owner, domain: "draft.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org) }
  let(:draft) { create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: membership.id, from_address: "owner@draft.com") }

  before do
    stub_connection current_user: owner
  end

  describe "#subscribed (spec 5.4.4)" do
    it "streams for the draft" do
      subscribe(draft_id: draft.key)
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(draft)
    end

    it "rejects when draft not found" do
      subscribe(draft_id: "msg_nonexistent")
      expect(subscription).to be_rejected
    end

    it "rejects a draft in an org the user is not a member of (E3)" do
      stranger_org = create(:organization, owner: create(:user, username: "draftstranger"), domain: "elsewhere.com")
      foreign_conv = create(:conversation, organization: stranger_org)
      foreign_draft = create(:message, conversation: foreign_conv, organization: stranger_org, is_draft: true)

      subscribe(draft_id: foreign_draft.key)
      expect(subscription).to be_rejected
    end
  end

  describe "#update_content" do
    it "broadcasts content update to draft stream" do
      subscribe(draft_id: draft.key)

      expect {
        perform :update_content, body: "Updated draft body", version: 2
      }.to have_broadcasted_to(draft).with(hash_including(
        "type" => "content_update",
        "user_id" => owner.key,
        "body" => "Updated draft body",
        "version" => 2
      ))
    end
  end

  describe "#update_cursor" do
    it "broadcasts cursor position to draft stream" do
      subscribe(draft_id: draft.key)

      expect {
        perform :update_cursor, position: 42, selection: { start: 10, end: 20 }
      }.to have_broadcasted_to(draft).with(hash_including(
        "type" => "cursor_update",
        "user_id" => owner.key,
        "position" => 42
      ))
    end
  end

  describe "#sync_update (Yjs CRDT relay)" do
    it "broadcasts Yjs binary update to draft stream" do
      subscribe(draft_id: draft.key)

      yjs_data = Base64.strict_encode64("yjs-binary-update")
      expect {
        perform :sync_update, update: yjs_data
      }.to have_broadcasted_to(draft).with(hash_including(
        "type" => "yjs_update",
        "user_id" => owner.key,
        "update" => yjs_data
      ))
    end
  end

  describe "#sync_awareness (Yjs cursor relay)" do
    it "broadcasts Yjs awareness update to draft stream" do
      subscribe(draft_id: draft.key)

      awareness_data = Base64.strict_encode64("awareness-binary")
      expect {
        perform :sync_awareness, update: awareness_data
      }.to have_broadcasted_to(draft).with(hash_including(
        "type" => "yjs_awareness",
        "user_id" => owner.key,
        "update" => awareness_data
      ))
    end
  end
end
