require "rails_helper"

RSpec.describe UserOffboarder do
  let(:owner) { create(:user, username: "ob_owner") }
  let(:org) { create(:organization, owner: owner, domain: "wipeco.com") }
  let(:domain) { org.default_domain }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:owner_mbx) { create(:mailbox, membership: owner_m, domain: domain, local_part: "boss") }
  let(:leaver) { create(:user, username: "leaver") }
  let!(:leaver_m) { create(:membership, user: leaver, organization: org, role: "member", status: "active") }
  let!(:leaver_mbx) { create(:mailbox, membership: leaver_m, domain: domain, local_part: "leaver") }

  def offboard(opts = {})
    described_class.new(
      user: leaver, organizations: [org], acting_user: owner,
      data_handling: opts[:data] || "archive",
      alias_handling: opts[:alias] || "bounce",
      reroute_target_key: opts[:target]
    ).call
  end

  it "removes the membership and records a bounce alias" do
    offboard
    expect(org.memberships.where(user: leaver)).not_to exist
    expect(org.mailbox_aliases.find_by(local_part: "leaver").mode).to eq("bounce")
  end

  it "archive retains the departed mailbox's mail" do
    conv = create(:conversation, organization: org)
    create(:message, conversation: conv, organization: org, from_address: "leaver@wipeco.com")
    expect { offboard(data: "archive") }.not_to change(Message, :count)
  end

  it "wipe deletes mail addressed to/from the mailbox and empties its threads" do
    conv = create(:conversation, organization: org)
    create(:message, conversation: conv, organization: org, from_address: "leaver@wipeco.com", to_address: "x@y.com")
    offboard(data: "wipe")
    expect(Conversation.exists?(conv.id)).to be false
  end

  it "reroute points the alias at the chosen active target" do
    offboard(alias: "reroute", target: owner_m.key)
    alias_row = org.mailbox_aliases.find_by(local_part: "leaver")
    expect(alias_row.mode).to eq("reroute")
    expect(alias_row.target_membership).to eq(owner_m)
  end

  it "offboards a member who is assigned to a conversation (FK cascade)" do
    conv = create(:conversation, organization: org)
    ConversationAssignee.create!(conversation: conv, membership: leaver_m)
    expect { offboard }.not_to raise_error
    expect(org.memberships.where(user: leaver)).not_to exist
    expect(ConversationAssignee.where(membership_id: leaver_m.id)).not_to exist
  end

  it "rolls back the whole offboard on an invalid reroute target" do
    expect {
      offboard(alias: "reroute", target: "mbr_nope")
    }.to raise_error(UserOffboarder::InvalidRerouteTarget)
    expect(org.memberships.where(user: leaver)).to exist # transaction rolled back
  end
end
