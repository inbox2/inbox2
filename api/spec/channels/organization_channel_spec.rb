require "rails_helper"

RSpec.describe OrganizationChannel, type: :channel do
  let(:member) { create(:user, username: "orgmember") }
  let(:org) { create(:organization, owner: member, domain: "orgstream.com") }
  let!(:membership) do
    create(:membership, user: member, organization: org,
                        role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
  end

  before { stub_connection current_user: member }

  describe "#subscribed" do
    it "streams from the org channel for an active member" do
      subscribe(key: org.key)
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("organization_#{org.key}")
    end

    it "rejects an unknown org key" do
      subscribe(key: "org_nonexistent")
      expect(subscription).to be_rejected
    end

    it "rejects a missing org key" do
      subscribe
      expect(subscription).to be_rejected
    end

    # E3 tenant isolation: a non-member (no active membership) can't open the org
    # stream, so they never receive another tenant's new-mail signals.
    it "rejects an org the user is not a member of" do
      other = create(:user, username: "outsider")
      other_org = create(:organization, owner: other, domain: "elsewhere.com")
      create(:membership, user: other, organization: other_org,
                          role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)

      subscribe(key: other_org.key)
      expect(subscription).to be_rejected
    end

    # A suspended/inactive membership is not "accessible", so the stream closes to
    # a member whose access was revoked.
    it "rejects when the membership is not active" do
      membership.update!(status: Membership::STATUS_DISABLED)
      subscribe(key: org.key)
      expect(subscription).to be_rejected
    end
  end
end
