require "rails_helper"

# spec 5.4.1 — presence is per thread and only for people who may see it.
RSpec.describe PresenceChannel, type: :channel do
  let(:owner) { create(:user, username: "presowner") }
  let(:org) { create(:organization, owner: owner, domain: "pres.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org) }

  before { stub_connection current_user: owner }

  it "streams for a thread the user may see and announces them" do
    expect { subscribe(conversation_id: conv.key) }.to have_broadcasted_to(conv).with(hash_including("action" => "viewing"))
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(conv)
  end

  it "rejects a thread in an org the user is not a member of (E3)" do
    stranger_org = create(:organization, owner: create(:user, username: "stranger"), domain: "elsewhere.com")
    foreign = create(:conversation, organization: stranger_org)

    subscribe(conversation_id: foreign.key)
    expect(subscription).to be_rejected
  end

  it "rejects a colleague's private imported thread" do
    mate = create(:user, username: "presmate")
    mate_m = create(:membership, user: mate, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
    hidden = create(:conversation, organization: org, private: true, owner_membership_id: mate_m.id)

    subscribe(conversation_id: hidden.key)
    expect(subscription).to be_rejected
  end
end
