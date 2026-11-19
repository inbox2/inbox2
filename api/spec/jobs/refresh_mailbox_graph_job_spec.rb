require "rails_helper"

RSpec.describe RefreshMailboxGraphJob, type: :job do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner, domain: "jobtest.com") }

  before do
    create(:conversation, organization: org, to_address: "inbox@jobtest.com", from_address: "a@b.com", read: false)
  end

  describe "#perform" do
    it "creates a snapshot for an organization" do
      expect { described_class.new.perform(org.id) }
        .to change { MailboxGraphSnapshot.count }.by(1)

      snapshot = org.reload.mailbox_graph_snapshot
      expect(snapshot).to be_present
      expect(snapshot.source_version).to be_present
      expect(snapshot.computed_at).to be_within(5.seconds).of(Time.current)

      payload = snapshot.payload.is_a?(String) ? JSON.parse(snapshot.payload) : snapshot.payload
      expect(payload["nodes"]).to be_an(Array)
      expect(payload["links"]).to be_an(Array)
    end

    it "upserts (does not duplicate) on repeated runs" do
      described_class.new.perform(org.id)

      # Change data to force a new version. Same sender as the setup conversation
      # so a@b.com reaches the aggregator's >= 2 conversations contact threshold.
      create(:conversation, organization: org, to_address: "inbox@jobtest.com", from_address: "a@b.com")

      expect { described_class.new.perform(org.id) }
        .not_to change { MailboxGraphSnapshot.count }

      snapshot = org.reload.mailbox_graph_snapshot
      payload = snapshot.payload.is_a?(String) ? JSON.parse(snapshot.payload) : snapshot.payload
      expect(payload["nodes"].length).to be >= 2
    end

    it "skips computation if source_version has not changed" do
      described_class.new.perform(org.id)
      original_computed_at = org.reload.mailbox_graph_snapshot.computed_at

      # Run again without data changes
      described_class.new.perform(org.id)
      expect(org.reload.mailbox_graph_snapshot.computed_at).to eq(original_computed_at)
    end

    it "processes all organizations when called without args" do
      org2 = create(:organization, owner: owner, domain: "other.com")
      create(:conversation, organization: org2, to_address: "box@other.com", from_address: "x@y.com")

      described_class.new.perform
      expect(org.reload.mailbox_graph_snapshot).to be_present
      expect(org2.reload.mailbox_graph_snapshot).to be_present
    end
  end
end
